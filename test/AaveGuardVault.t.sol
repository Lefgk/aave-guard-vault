// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AaveGuardVault} from "../src/AaveGuardVault.sol";
import {AaveGuardVaultFactory} from "../src/AaveGuardVaultFactory.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockAavePool, MockVariableDebtToken} from "../src/mocks/MockAavePool.sol";

contract AaveGuardVaultTest is Test {
    AaveGuardVaultFactory factory;
    AaveGuardVault vault;
    MockUSDC usdc;
    MockWETH weth;
    MockAavePool pool;
    MockVariableDebtToken debt;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address stranger = makeAddr("stranger");
    address guardian = makeAddr("guardian");

    uint64 constant PERIOD = 1 days;
    uint128 constant PER_TX = 1_000e6;
    uint128 constant PERIOD_CAP = 2_500e6;

    function setUp() public {
        usdc = new MockUSDC();
        weth = new MockWETH();
        debt = new MockVariableDebtToken();
        pool = new MockAavePool(address(weth), address(usdc), address(debt));
        debt.setPool(address(pool));
        usdc.mint(address(pool), 50_000_000e6);

        factory = new AaveGuardVaultFactory(address(pool), address(weth), address(usdc), address(debt));
        vm.prank(owner);
        vault = AaveGuardVault(payable(factory.createVault()));

        vm.deal(owner, 100 ether);
        usdc.mint(owner, 1_000_000e6);
        usdc.mint(agent, 100_000e6);
        usdc.mint(stranger, 100_000e6);

        vm.startPrank(owner);
        vault.supplyETH{value: 10 ether}();
        vault.grantAgent(agent, uint64(block.timestamp + 30 days));
        vault.setBudget(agent, PER_TX, PERIOD_CAP, PERIOD);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
    }

    function test_factoryIndexesVaultAndWiresImmutables() public view {
        assertEq(factory.vaultsOf(owner).length, 1);
        assertEq(factory.vaultsOf(owner)[0], address(vault));
        assertEq(vault.owner(), owner);
        assertEq(address(vault.pool()), address(pool));
        assertEq(vault.weth(), address(weth));
        assertEq(vault.usdc(), address(usdc));
        assertEq(vault.healthFactorFloor(), 1.5e18);
    }

    function test_supplyETHAndWethAndUsdc() public {
        vm.startPrank(owner);
        vault.supplyETH{value: 1 ether}();
        weth.deposit{value: 2 ether}();
        weth.approve(address(vault), 2 ether);
        vault.supply(address(weth), 2 ether);
        usdc.approve(address(vault), 5_000e6);
        vault.supply(address(usdc), 5_000e6);
        vm.stopPrank();
        (uint256 col,,,,, uint256 hf,) = vault.accountData();
        assertGt(col, 0);
        assertEq(hf, type(uint256).max);
    }

    function test_rejectUnknownAsset() public {
        MockUSDC other = new MockUSDC();
        vm.prank(owner);
        vm.expectRevert(AaveGuardVault.AssetNotAllowed.selector);
        vault.supply(address(other), 1);
    }

    function test_strangerCannotSupply() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        vault.supplyETH{value: 1 ether}();
    }

    function test_borrowWithinCapsAndAllowlist() public {
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "invoice-1");
        assertEq(usdc.balanceOf(shop), 1_000e6);
        // Agent struct: active, expiry, epoch, outstanding — use getter
        (bool active,,, uint128 out) = vault.agents(agent);
        assertTrue(active);
        assertEq(out, 1_000e6);
        assertEq(vault.usdcDebt(), 1_000e6);
        (,,,,, uint256 hf,) = vault.accountData();
        assertGe(hf, 1.5e18);
    }

    function test_exceedsPerTxAndPeriodCap() public {
        vm.startPrank(agent);
        vault.borrow(shop, 1_000e6, "a");
        vault.borrow(shop, 1_000e6, "b");
        vm.expectRevert(abi.encodeWithSelector(AaveGuardVault.ExceedsPerTxCap.selector, 1_001e6, PER_TX));
        vault.borrow(shop, 1_001e6, "c");
        vm.expectRevert(abi.encodeWithSelector(AaveGuardVault.ExceedsPeriodCap.selector, 2_501e6, PERIOD_CAP));
        vault.borrow(shop, 501e6, "d");
        vault.borrow(shop, 500e6, "e");
        vm.stopPrank();
        assertEq(usdc.balanceOf(shop), 2_500e6);
    }

    function test_periodRollsOver() public {
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "day1");
        vm.warp(block.timestamp + PERIOD);
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "day2");
        assertEq(usdc.balanceOf(shop), 2_000e6);
        AaveGuardVault.Budget memory b = vault.getBudget(agent);
        assertEq(b.borrowedInWindow, 1_000e6);
    }

    function test_recipientNotAllowedAndZeroAmount() public {
        vm.startPrank(agent);
        vm.expectRevert(AaveGuardVault.RecipientNotAllowed.selector);
        vault.borrow(stranger, 1e6, "no");
        vm.expectRevert(AaveGuardVault.ZeroAmount.selector);
        vault.borrow(shop, 0, "zero");
        vm.stopPrank();
    }

    function test_expiredRevokedPausedBlocked() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(); // EnforcedPause
        vault.borrow(shop, 1e6, "p");

        vm.prank(owner);
        vault.unpause();

        vm.warp(block.timestamp + 31 days);
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.AgentExpired.selector);
        vault.borrow(shop, 1e6, "x");

        vm.prank(owner);
        vault.grantAgent(agent, uint64(block.timestamp + 7 days));
        vm.prank(owner);
        vault.setBudget(agent, PER_TX, PERIOD_CAP, PERIOD);
        vm.prank(owner);
        vault.setRecipient(agent, shop, true);

        vm.prank(guardian);
        vm.expectRevert(AaveGuardVault.NotOwnerOrGuardian.selector);
        vault.revokeAgent(agent);

        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(guardian);
        vault.revokeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.NotAgent.selector);
        vault.borrow(shop, 1e6, "r");
    }

    function test_healthFactorFloorBlocksBorrow() public {
        // 10 ETH * $3000 * 82.5% = $24,750 collateral for HF.
        // Floor 1.5 => max debt ~ $16,500. Borrowing $17,000 should fail the vault floor
        // (Aave mock still allows down to HF 1.0).
        vm.startPrank(owner);
        vault.grantAgent(agent, uint64(block.timestamp + 30 days));
        vault.setBudget(agent, 20_000e6, 20_000e6, PERIOD);
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AaveGuardVault.HealthFactorTooLow.selector, _hfAfter(17_000e6), 1.5e18));
        vault.borrow(shop, 17_000e6, "too-much");

        vm.prank(agent);
        vault.borrow(shop, 10_000e6, "ok");
        (,,,,, uint256 hf,) = vault.accountData();
        assertGe(hf, 1.5e18);
        assertEq(usdc.balanceOf(shop), 10_000e6);
    }

    function test_priceDropThenBorrowReverts() public {
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "ok");
        pool.setPrice(address(weth), 200e8); // $200 / ETH, 10 ETH * 0.825 = $1,650; 1,000 debt -> HF 1.65 still ok-ish
        pool.setPrice(address(weth), 100e8); // $100 * 10 * 0.825 = $825; debt 1000 -> HF 0.825, already < 1
        vm.prank(agent);
        vm.expectRevert();
        vault.borrow(shop, 1e6, "after-crash");
    }

    function test_setFloorMinimumAndOwnerWithdrawRespectsFloor() public {
        vm.prank(owner);
        vm.expectRevert(AaveGuardVault.InvalidFloor.selector);
        vault.setHealthFactorFloor(1.05e18);

        vm.prank(owner);
        vault.setHealthFactorFloor(1.6e18);
        assertEq(vault.healthFactorFloor(), 1.6e18);

        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "b");

        // Trying to withdraw almost all WETH would tank HF.
        vm.prank(owner);
        vm.expectRevert();
        vault.withdrawETH(owner, 9.9 ether);

        uint256 before = owner.balance;
        vm.prank(owner);
        vault.withdrawETH(owner, 0.1 ether);
        assertEq(owner.balance, before + 0.1 ether);
        (,,,,, uint256 hf,) = vault.accountData();
        assertGe(hf, 1.6e18);
    }

    function test_repayByAgentOwnerAndStranger() public {
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "b");

        vm.startPrank(agent);
        usdc.approve(address(vault), type(uint256).max);
        vault.repay(400e6);
        vm.stopPrank();
        (,,, uint128 out) = vault.agents(agent);
        assertEq(out, 600e6);
        assertEq(vault.usdcDebt(), 600e6);

        vm.startPrank(stranger);
        usdc.approve(address(vault), type(uint256).max);
        vault.repayFor(agent, 200e6);
        vm.stopPrank();
        (,,, out) = vault.agents(agent);
        assertEq(out, 400e6);

        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.repay(400e6); // owner has no outstanding; just pays the vault debt
        vm.stopPrank();
        assertEq(vault.usdcDebt(), 0);
        (,,,,, uint256 hf,) = vault.accountData();
        assertEq(hf, type(uint256).max);
    }

    function test_ownerWithdrawAfterFullRepay() public {
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "b");
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.repayFor(agent, 1_000e6);
        uint256 before = owner.balance;
        vault.withdrawETH(owner, 10 ether);
        assertEq(owner.balance, before + 10 ether);
        vm.stopPrank();
    }

    function test_pauseBlocksBorrowButRepayAndWithdrawWork() public {
        vm.prank(agent);
        vault.borrow(shop, 500e6, "b");
        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert();
        vault.borrow(shop, 1e6, "p");

        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.repayFor(agent, 500e6);
        vault.withdrawETH(owner, 1 ether);
        vm.stopPrank();
    }

    function test_renounceAndRegrantWipesBudget() public {
        vm.prank(agent);
        vault.renounceAgent();
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.NotAgent.selector);
        vault.borrow(shop, 1e6, "x");

        vm.startPrank(owner);
        vault.grantAgent(agent, uint64(block.timestamp + 7 days));
        // old budget and allowlist were epoch-keyed and are gone
        vm.stopPrank();
        assertEq(vault.getBudget(agent).period, 0);
        assertFalse(vault.isRecipientAllowed(agent, shop));
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.RecipientNotAllowed.selector);
        vault.borrow(shop, 1e6, "y");
    }

    function test_borrowableNow() public {
        (uint256 amt, uint64 end) = vault.borrowableNow(agent);
        assertEq(amt, PER_TX);
        assertGt(end, block.timestamp);
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "b");
        (amt,) = vault.borrowableNow(agent);
        assertEq(amt, 1_000e6); // 2500-1000 left, per-tx 1000
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, "c");
        (amt,) = vault.borrowableNow(agent);
        assertEq(amt, 500e6);
    }

    function test_wrapAndSupplyLeftoverEth() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(owner);
        vault.wrapAndSupplyETH();
        (uint256 col,,,,,,) = vault.accountData();
        // 11 ETH at $3000
        assertEq(col, 11 * 3000e8);
    }

    function testFuzz_capsHold(uint256 a1, uint256 a2, uint256 a3) public {
        uint256[3] memory amts = [bound(a1, 1, 1_500e6), bound(a2, 1, 1_500e6), bound(a3, 1, 1_500e6)];
        uint256 sent;
        for (uint256 i; i < 3; i++) {
            vm.prank(agent);
            try vault.borrow(shop, amts[i], bytes32(i)) {
                sent += amts[i];
            } catch {}
        }
        assertLe(sent, PERIOD_CAP);
        assertEq(usdc.balanceOf(shop), sent);
        assertLe(vault.getBudget(agent).borrowedInWindow, PERIOD_CAP);
        (,,,,, uint256 hf,) = vault.accountData();
        if (sent > 0) assertGe(hf, 1.5e18);
    }

    function testFuzz_hfFloorHolds(uint256 amount) public {
        amount = bound(amount, 1e6, 30_000e6);
        vm.prank(owner);
        vault.setBudget(agent, 30_000e6, 30_000e6, PERIOD);
        vm.prank(agent);
        try vault.borrow(shop, amount, "fuzz") {
            (,,,,, uint256 hf,) = vault.accountData();
            assertGe(hf, vault.healthFactorFloor());
            assertEq(usdc.balanceOf(shop), amount);
        } catch (bytes memory err) {
            // Must be a cap or HF revert, not a silent success past the floor.
            assertGt(err.length, 0);
            assertEq(usdc.balanceOf(shop), 0);
        }
    }

    function _hfAfter(uint256 extraDebt) internal view returns (uint256) {
        // Mirror mock: 10 WETH * 3000e8 * 8250 / (debtBase * 10000) * 1e18
        uint256 colBase = (10 ether * 3000e8) / 1e18;
        uint256 debtBase = extraDebt; // USDC 6 dec * 1e8 / 1e6 = 1:1 with e8?  extraDebt * 1e8 / 1e6 = extraDebt * 100
        debtBase = (extraDebt * 1e8) / 1e6;
        return (colBase * 8250 * 1e18) / (debtBase * 10_000);
    }

    function _agent(address a) internal view returns (bool, uint64, uint32, uint128) {
        return vault.agents(a);
    }
}
