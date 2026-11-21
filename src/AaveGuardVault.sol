// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool, IWETH} from "./interfaces/IPool.sol";

/// @title AaveGuardVault
/// @notice Owner-owned vault that supplies ETH/WETH (and optionally USDC) to Aave V3 as collateral.
///         Authorized agents may borrow USDC to allowlisted destinations, within a per-tx and
///         per-period cap, only if the vault health factor stays above an owner-set floor
///         (checked after the borrow). Agents and anyone else may repay. The owner can pause,
///         revoke, withdraw and repay.
/// @dev    PROTOTYPE - NOT AUDITED. Variable-rate USDC borrows only. The vault is the single
///         Aave user; per-agent outstanding is principal borrowed minus principal repaid
///         (Aave interest accrues on the shared position). Liquidation risk sits with the owner.
contract AaveGuardVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant VARIABLE = 2;
    uint256 public constant DEFAULT_HF_FLOOR = 1.5e18;
    uint256 public constant MIN_HF_FLOOR = 1.1e18;

    struct Agent {
        bool active;
        uint64 expiry;
        uint32 epoch;
        uint128 outstanding; // principal borrowed minus principal repaid, this epoch
    }

    struct Budget {
        uint128 perTxCap;
        uint128 periodCap;
        uint64 period;
        uint64 windowStart;
        uint128 borrowedInWindow;
    }

    IPool public immutable pool;
    address public immutable weth;
    address public immutable usdc;
    address public immutable variableDebtUsdc;

    address public guardian;
    uint256 public healthFactorFloor;

    mapping(address agent => Agent) public agents;
    /// @dev key = keccak256(agent, epoch)
    mapping(bytes32 key => Budget) internal _budgets;
    /// @dev key = keccak256(agent, epoch, recipient)
    mapping(bytes32 key => bool) internal _recipientAllowed;

    event Supplied(address indexed from, address indexed asset, uint256 amount);
    event Withdrawn(address indexed to, address indexed asset, uint256 amount, bool asEth);
    event GuardianSet(address indexed guardian);
    event HealthFactorFloorSet(uint256 floor);
    event AgentGranted(address indexed agent, uint64 expiry, uint32 epoch);
    event AgentRevoked(address indexed agent, address indexed by, uint32 newEpoch);
    event BudgetSet(address indexed agent, uint128 perTxCap, uint128 periodCap, uint64 period);
    event BudgetRemoved(address indexed agent);
    event RecipientSet(address indexed agent, address indexed recipient, bool allowed);
    event Borrowed(
        address indexed agent,
        address indexed to,
        uint256 amount,
        bytes32 memo,
        uint256 borrowedInWindow,
        uint64 windowStart,
        uint256 healthFactor
    );
    event Repaid(address indexed payer, address indexed agent, uint256 amount, uint128 outstandingLeft);

    error NotAgent();
    error AgentExpired();
    error NoBudget();
    error RecipientNotAllowed();
    error ExceedsPerTxCap(uint256 amount, uint256 cap);
    error ExceedsPeriodCap(uint256 wouldBorrow, uint256 cap);
    error InvalidBudget();
    error InvalidExpiry();
    error InvalidFloor();
    error AssetNotAllowed();
    error ZeroAddress();
    error ZeroAmount();
    error NotOwnerOrGuardian();
    error EthTransferFailed();
    error HealthFactorTooLow(uint256 healthFactor, uint256 floor);

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        _;
    }

    constructor(address initialOwner, address pool_, address weth_, address usdc_, address variableDebtUsdc_)
        Ownable(initialOwner)
    {
        if (pool_ == address(0) || weth_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        pool = IPool(pool_);
        weth = weth_;
        usdc = usdc_;
        variableDebtUsdc = variableDebtUsdc_;
        healthFactorFloor = DEFAULT_HF_FLOOR;
        IERC20(weth_).forceApprove(pool_, type(uint256).max);
        IERC20(usdc_).forceApprove(pool_, type(uint256).max);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ funding (owner)

    /// @notice Wrap `msg.value` ETH to WETH and supply it to Aave as collateral.
    function supplyETH() external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        IWETH(weth).deposit{value: msg.value}();
        pool.supply(weth, msg.value, address(this), 0);
        emit Supplied(msg.sender, weth, msg.value);
    }

    /// @notice Wrap any leftover ETH sitting on the vault and supply it.
    function wrapAndSupplyETH() external onlyOwner nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert ZeroAmount();
        IWETH(weth).deposit{value: amount}();
        pool.supply(weth, amount, address(this), 0);
        emit Supplied(msg.sender, weth, amount);
    }

    /// @notice Pull WETH or USDC and supply it to Aave as collateral.
    function supply(address asset, uint256 amount) external onlyOwner nonReentrant {
        if (asset != weth && asset != usdc) revert AssetNotAllowed();
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        pool.supply(asset, amount, address(this), 0);
        emit Supplied(msg.sender, asset, amount);
    }

    /// @notice Withdraw WETH or USDC collateral from Aave to `to`. Reverts if post-withdraw HF < floor
    ///         (when there is still debt). Works while paused so funds are never stuck.
    function withdraw(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (asset != weth && asset != usdc) revert AssetNotAllowed();
        if (to == address(0)) revert ZeroAddress();
        uint256 withdrawn = pool.withdraw(asset, amount, to);
        _assertFloor();
        emit Withdrawn(to, asset, withdrawn, false);
    }

    /// @notice Withdraw WETH collateral from Aave, unwrap, and send ETH to `to`.
    function withdrawETH(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 withdrawn = pool.withdraw(weth, amount, address(this));
        _assertFloor();
        IWETH(weth).withdraw(withdrawn);
        (bool ok,) = to.call{value: withdrawn}("");
        if (!ok) revert EthTransferFailed();
        emit Withdrawn(to, weth, withdrawn, true);
    }

    // ------------------------------------------------------------------ admin

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Set the post-borrow (and post-withdraw) health-factor floor. Minimum is 1.1e18.
    function setHealthFactorFloor(uint256 floor) external onlyOwner {
        if (floor < MIN_HF_FLOOR) revert InvalidFloor();
        healthFactorFloor = floor;
        emit HealthFactorFloorSet(floor);
    }

    function grantAgent(address agent, uint64 expiry) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        Agent storage a = agents[agent];
        a.active = true;
        a.expiry = expiry;
        emit AgentGranted(agent, expiry, a.epoch);
    }

    function setBudget(address agent, uint128 perTxCap, uint128 periodCap, uint64 period) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        if (perTxCap == 0 || periodCap == 0 || period == 0 || perTxCap > periodCap) revert InvalidBudget();
        Budget storage b = _budgets[_agentKey(agent, agents[agent].epoch)];
        if (b.period != period) {
            b.period = period;
            b.windowStart = uint64(block.timestamp);
            b.borrowedInWindow = 0;
        }
        b.perTxCap = perTxCap;
        b.periodCap = periodCap;
        emit BudgetSet(agent, perTxCap, periodCap, period);
    }

    function removeBudget(address agent) external onlyOwner {
        delete _budgets[_agentKey(agent, agents[agent].epoch)];
        emit BudgetRemoved(agent);
    }

    function setRecipient(address agent, address recipient, bool allowed) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _recipientAllowed[_recipKey(agent, agents[agent].epoch, recipient)] = allowed;
        emit RecipientSet(agent, recipient, allowed);
    }

    function revokeAgent(address agent) external onlyOwnerOrGuardian {
        _revoke(agent);
    }

    function renounceAgent() external {
        if (!agents[msg.sender].active) revert NotAgent();
        _revoke(msg.sender);
    }

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ agent borrow / repay

    /// @notice Agent borrows `amount` USDC from Aave to an allowlisted `to`. Reverts if the
    ///         resulting health factor is below the owner-set floor (the whole tx is atomic).
    function borrow(address to, uint256 amount, bytes32 memo) external whenNotPaused nonReentrant {
        Agent storage a = agents[msg.sender];
        if (!a.active) revert NotAgent();
        if (block.timestamp >= a.expiry) revert AgentExpired();
        if (amount == 0) revert ZeroAmount();
        if (!_recipientAllowed[_recipKey(msg.sender, a.epoch, to)]) revert RecipientNotAllowed();

        Budget storage b = _budgets[_agentKey(msg.sender, a.epoch)];
        if (b.period == 0) revert NoBudget();
        if (amount > b.perTxCap) revert ExceedsPerTxCap(amount, b.perTxCap);

        _roll(b);
        uint256 would = uint256(b.borrowedInWindow) + amount;
        if (would > b.periodCap) revert ExceedsPeriodCap(would, b.periodCap);
        b.borrowedInWindow = uint128(would);
        a.outstanding = uint128(uint256(a.outstanding) + amount);

        pool.borrow(usdc, amount, VARIABLE, 0, address(this));
        uint256 hf = _assertFloor();

        emit Borrowed(msg.sender, to, amount, memo, would, b.windowStart, hf);
        IERC20(usdc).safeTransfer(to, amount);
    }

    /// @notice Repay USDC debt on Aave. Pulls `amount` from the caller. If the caller is an
    ///         agent with outstanding principal, that outstanding is reduced first.
    function repay(uint256 amount) external nonReentrant {
        _repay(amount, msg.sender, agents[msg.sender].outstanding > 0 || agents[msg.sender].active);
    }

    /// @notice Repay USDC debt and attribute the principal reduction to `agent`.
    function repayFor(address agent, uint256 amount) external nonReentrant {
        _repay(amount, agent, true);
    }

    // ------------------------------------------------------------------ views

    function getBudget(address agent) external view returns (Budget memory b) {
        b = _budgets[_agentKey(agent, agents[agent].epoch)];
    }

    function isRecipientAllowed(address agent, address recipient) external view returns (bool) {
        return _recipientAllowed[_recipKey(agent, agents[agent].epoch, recipient)];
    }

    /// @notice USDC this agent could borrow right now under its caps (does not account for Aave
    ///         available borrows or the HF floor).
    function borrowableNow(address agent) external view returns (uint256 amount, uint64 windowEnd) {
        Agent memory a = agents[agent];
        Budget memory b = _budgets[_agentKey(agent, a.epoch)];
        if (b.period == 0) return (0, 0);
        (uint64 ws, uint128 spent) = _currentWindow(b);
        windowEnd = ws + b.period;
        if (!a.active || block.timestamp >= a.expiry || paused()) return (0, windowEnd);
        uint256 left = b.periodCap > spent ? b.periodCap - spent : 0;
        amount = left < b.perTxCap ? left : b.perTxCap;
    }

    /// @notice Aave account data for this vault, plus the owner-set HF floor.
    function accountData()
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor,
            uint256 floor
        )
    {
        (totalCollateralBase, totalDebtBase, availableBorrowsBase, currentLiquidationThreshold, ltv, healthFactor) =
            pool.getUserAccountData(address(this));
        floor = healthFactorFloor;
    }

    /// @notice Current variable-rate USDC debt (principal + accrued interest) of the vault.
    function usdcDebt() public view returns (uint256) {
        if (variableDebtUsdc == address(0)) return 0;
        return IERC20(variableDebtUsdc).balanceOf(address(this));
    }

    // ------------------------------------------------------------------ internal

    function _repay(uint256 amount, address agent, bool attribute) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 owed = usdcDebt();
        uint256 pay = (owed > 0 && amount > owed) ? owed : amount;
        uint128 left = 0;
        if (attribute && agent != address(0)) {
            uint256 o = agents[agent].outstanding;
            uint256 red = pay < o ? pay : o;
            left = uint128(o - red);
            agents[agent].outstanding = left; // effects before Aave interaction
        }
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), pay);
        uint256 repaid = pool.repay(usdc, pay, VARIABLE, address(this));
        uint256 leftover = IERC20(usdc).balanceOf(address(this));
        if (leftover > 0) IERC20(usdc).safeTransfer(msg.sender, leftover);
        emit Repaid(msg.sender, agent, repaid, left);
    }

    function _assertFloor() internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(address(this));
        if (hf < healthFactorFloor) revert HealthFactorTooLow(hf, healthFactorFloor);
    }

    function _agentKey(address agent, uint32 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, epoch));
    }

    function _recipKey(address agent, uint32 epoch, address recipient) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, epoch, recipient));
    }

    function _currentWindow(Budget memory b) internal view returns (uint64 ws, uint128 spent) {
        ws = b.windowStart;
        spent = b.borrowedInWindow;
        if (block.timestamp >= uint256(ws) + b.period) {
            uint256 elapsed = (block.timestamp - ws) / b.period;
            ws = uint64(uint256(ws) + elapsed * b.period);
            spent = 0;
        }
    }

    function _roll(Budget storage b) internal {
        (uint64 ws, uint128 spent) = _currentWindow(b);
        if (ws != b.windowStart) {
            b.windowStart = ws;
            b.borrowedInWindow = spent;
        }
    }

    function _revoke(address agent) internal {
        Agent storage a = agents[agent];
        a.active = false;
        a.expiry = 0;
        a.outstanding = 0;
        unchecked {
            a.epoch += 1;
        }
        emit AgentRevoked(agent, msg.sender, a.epoch);
    }
}
