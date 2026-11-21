// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock variable-debt token (6 decimals) minted/burned only by the mock pool.
contract MockVariableDebtToken is ERC20 {
    address public pool;

    constructor() ERC20("Mock Variable Debt USDC", "variableDebtUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setPool(address p) external {
        require(pool == address(0), "already set");
        pool = p;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        _burn(from, amount);
    }
}

/// @notice Minimal Aave V3 Pool mock. Prices are USD with 8 decimals. No interest.
contract MockAavePool {
    using SafeERC20 for IERC20;

    uint256 public constant VARIABLE = 2;
    uint256 public constant LIQ_HF = 1e18;

    mapping(address => uint256) public price;
    mapping(address => uint256) public liqThresholdBps;
    mapping(address => mapping(address => uint256)) public collateral;
    mapping(address => mapping(address => uint256)) public debt;

    address public immutable usdc;
    address public immutable weth;
    MockVariableDebtToken public immutable variableDebtUsdc;

    error HealthFactorBelowOne(uint256 hf);
    error InsufficientLiquidity();
    error InvalidRateMode();
    error ZeroAmount();

    constructor(address weth_, address usdc_, address debtToken_) {
        weth = weth_;
        usdc = usdc_;
        variableDebtUsdc = MockVariableDebtToken(debtToken_);
        price[weth_] = 3000e8;
        price[usdc_] = 1e8;
        liqThresholdBps[weth_] = 8250;
        liqThresholdBps[usdc_] = 7800;
    }

    function setPrice(address asset, uint256 p) external {
        price[asset] = p;
    }

    function setLiqThresholdBps(address asset, uint256 bps) external {
        liqThresholdBps[asset] = bps;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        collateral[onBehalfOf][asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 bal = collateral[msg.sender][asset];
        if (amount == type(uint256).max) amount = bal;
        if (amount == 0) revert ZeroAmount();
        collateral[msg.sender][asset] = bal - amount;
        _assertHf(msg.sender);
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16, address onBehalfOf) external {
        if (interestRateMode != VARIABLE) revert InvalidRateMode();
        if (amount == 0) revert ZeroAmount();
        if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientLiquidity();
        debt[onBehalfOf][asset] += amount;
        if (asset == usdc) variableDebtUsdc.mint(onBehalfOf, amount);
        _assertHf(onBehalfOf);
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256)
    {
        if (interestRateMode != VARIABLE) revert InvalidRateMode();
        uint256 owed = debt[onBehalfOf][asset];
        if (amount == type(uint256).max) amount = owed;
        if (amount == 0) revert ZeroAmount();
        if (amount > owed) amount = owed;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        debt[onBehalfOf][asset] = owed - amount;
        if (asset == usdc) variableDebtUsdc.burn(onBehalfOf, amount);
        return amount;
    }

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        (totalCollateralBase, totalDebtBase, currentLiquidationThreshold, healthFactor) = _account(user);
        uint256 borrowBase = (totalCollateralBase * 8000) / 10_000;
        availableBorrowsBase = borrowBase > totalDebtBase ? borrowBase - totalDebtBase : 0;
        ltv = 8000;
    }

    function _assertHf(address user) internal view {
        (,,, uint256 hf) = _account(user);
        if (hf < LIQ_HF) revert HealthFactorBelowOne(hf);
    }

    function _account(address user)
        internal
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 avgLt, uint256 healthFactor)
    {
        uint256 cW = _base(user, weth, false);
        uint256 cU = _base(user, usdc, false);
        uint256 dW = _base(user, weth, true);
        uint256 dU = _base(user, usdc, true);
        totalCollateralBase = cW + cU;
        totalDebtBase = dW + dU;
        if (totalCollateralBase > 0) {
            avgLt = (cW * liqThresholdBps[weth] + cU * liqThresholdBps[usdc]) / totalCollateralBase;
        }
        if (totalDebtBase == 0) {
            healthFactor = type(uint256).max;
        } else {
            healthFactor = (totalCollateralBase * avgLt * 1e18) / (totalDebtBase * 10_000);
        }
    }

    function _base(address user, address asset, bool forDebt) internal view returns (uint256) {
        uint256 p = price[asset];
        if (p == 0) return 0;
        uint256 amt = forDebt ? debt[user][asset] : collateral[user][asset];
        return (amt * p) / (10 ** IERC20Metadata(asset).decimals());
    }
}
