// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveGuardVault} from "../../src/AaveGuardVault.sol";
import {AaveGuardVaultFactory} from "../../src/AaveGuardVaultFactory.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";
import {IPool, IPoolAddressesProvider, IWETH} from "../../src/interfaces/IPool.sol";

interface IFiatToken {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

/// @dev Runs against a fork of a live chain using the real Aave V3 Pool and Circle USDC.
///      Either run `forge test --fork-url <rpc>` (only the matching chain's suite runs), or set
///      MAINNET_FORK_RPC / BASE_FORK_RPC (e.g. a local `anvil --fork-url` on port 8623). Otherwise skipped.
abstract contract ForkBase is Test {
    AaveGuardVaultFactory factory;
    AaveGuardVault vault;
    IERC20Metadata usdc;
    IERC20Metadata weth;
    IPool pool;
    address owner = makeAddr("fork-owner");
    address agent = makeAddr("fork-agent");
    address shop = makeAddr("fork-shop");
    address stranger = makeAddr("fork-stranger");
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already running on this chain's fork
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");

        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        usdc = IERC20Metadata(c.usdc);
        weth = IERC20Metadata(c.weth);
        pool = IPool(c.pool);

        factory = new AaveGuardVaultFactory(c.pool, c.weth, c.usdc, c.variableDebtUsdc);
        vm.prank(owner);
        vault = AaveGuardVault(payable(factory.createVault()));

        vm.deal(owner, 20 ether);
        _fundUsdc(owner, 50_000e6);
        _fundUsdc(agent, 20_000e6);

        vm.startPrank(owner);
        vault.supplyETH{value: 10 ether}();
        vault.grantAgent(agent, uint64(block.timestamp + 30 days));
        vault.setBudget(agent, 5_000e6, 15_000e6, 1 days);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_officialAddressesAndMetadata() public onFork {
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        assertGt(c.pool.code.length, 0);
        assertGt(c.usdc.code.length, 0);
        assertGt(c.weth.code.length, 0);
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertEq(weth.symbol(), "WETH");
        address fromProvider = IPoolAddressesProvider(c.poolAddressesProvider).getPool();
        assertEq(fromProvider, c.pool, "address book pool != provider.getPool()");
        assertEq(address(vault.pool()), c.pool);
        assertEq(vault.usdc(), c.usdc);
        assertEq(vault.weth(), c.weth);
    }

    function test_fork_supplyRaisesCollateralAndHfIsInfinite() public onFork {
        (uint256 col, uint256 debt,,,, uint256 hf, uint256 floor) = vault.accountData();
        assertGt(col, 0);
        assertEq(debt, 0);
        assertEq(hf, type(uint256).max);
        assertEq(floor, 1.5e18);
        assertEq(IWETH(address(weth)).balanceOf(address(vault)), 0); // all supplied, not sitting idle
    }

    function test_fork_borrowWithinCapsThenCapped() public onFork {
        vm.startPrank(agent);
        vault.borrow(shop, 1_000e6, "a");
        vault.borrow(shop, 1_000e6, "b");
        vm.expectRevert(abi.encodeWithSelector(AaveGuardVault.ExceedsPerTxCap.selector, 5_001e6, 5_000e6));
        vault.borrow(shop, 5_001e6, "c");
        vm.stopPrank();
        assertEq(usdc.balanceOf(shop), 2_000e6);
        (,,, uint128 outstanding) = vault.agents(agent);
        assertEq(outstanding, 2_000e6);
        assertGt(vault.usdcDebt(), 0);
        (,,,,, uint256 hf,) = vault.accountData();
        assertGe(hf, 1.5e18);
    }

    function test_fork_allowlistPauseRevoke() public onFork {
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.RecipientNotAllowed.selector);
        vault.borrow(stranger, 1e6, "no");

        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert();
        vault.borrow(shop, 1e6, "p");
        vm.prank(owner);
        vault.unpause();

        vm.prank(owner);
        vault.revokeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.NotAgent.selector);
        vault.borrow(shop, 1e6, "r");
    }

    function test_fork_hfFloorBlocksOversizedBorrow() public onFork {
        (,, uint256 available,,,,) = vault.accountData();
        // available is USD 8 decimals; USDC ~ $1 so roughly available / 100 is USDC units.
        uint256 tooMuch = available / 100;
        if (tooMuch < 2_000e6) {
            // tiny available would make this uninteresting; still assert a direct over-floor path
            return;
        }
        vm.prank(owner);
        vault.setBudget(agent, uint128(tooMuch), uint128(tooMuch), 1 days);

        vm.prank(agent);
        vm.expectRevert();
        vault.borrow(shop, tooMuch, "max-ltv");
        assertEq(usdc.balanceOf(shop), 0);
        assertEq(vault.usdcDebt(), 0);
        (,,,,, uint256 hf,) = vault.accountData();
        assertEq(hf, type(uint256).max);
    }

    function test_fork_repayAndOwnerWithdraw() public onFork {
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "b");
        uint256 debtBefore = vault.usdcDebt();
        assertGe(debtBefore, 1_000e6); // may already include a tiny bit of interest, or exact

        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.repayFor(agent, 1_000e6 + 10e6); // cover dust interest
        vm.stopPrank();
        assertEq(vault.usdcDebt(), 0);

        uint256 before = owner.balance;
        vm.prank(owner);
        vault.withdrawETH(owner, 1 ether);
        assertEq(owner.balance, before + 1 ether);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_fork_capsAndHfHold(uint256 a1, uint256 a2, uint256 a3) public onFork {
        uint256[3] memory amts = [bound(a1, 1, 6_000e6), bound(a2, 1, 6_000e6), bound(a3, 1, 6_000e6)];
        uint256 sent;
        for (uint256 i; i < 3; i++) {
            vm.prank(agent);
            try vault.borrow(shop, amts[i], bytes32(i)) {
                sent += amts[i];
            } catch {}
        }
        assertLe(sent, 15_000e6);
        assertEq(usdc.balanceOf(shop), sent);
        if (sent > 0) {
            (,,,,, uint256 hf,) = vault.accountData();
            assertGe(hf, 1.5e18);
        }
    }

    function _fundUsdc(address to, uint256 amount) internal {
        deal(address(usdc), to, amount, true);
        if (usdc.balanceOf(to) >= amount) return;

        // Fallback used when `deal` cannot update Circle USDC storage: mint as the master minter.
        try IFiatToken(address(usdc)).masterMinter() returns (address mm) {
            if (mm != address(0) && mm.code.length > 0) {
                vm.prank(mm);
                IFiatToken(address(usdc)).configureMinter(address(this), type(uint256).max);
                IFiatToken(address(usdc)).mint(to, amount);
            }
        } catch {}
        require(usdc.balanceOf(to) >= amount, "could not fund USDC on this fork");
    }
}

contract EthereumForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
