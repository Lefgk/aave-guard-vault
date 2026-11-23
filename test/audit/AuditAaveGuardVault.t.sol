// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AaveGuardVault} from "../../src/AaveGuardVault.sol";
import {AaveGuardVaultFactory} from "../../src/AaveGuardVaultFactory.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockWETH} from "../../src/mocks/MockWETH.sol";
import {MockAavePool, MockVariableDebtToken} from "../../src/mocks/MockAavePool.sol";

/// @notice Audit 2026-11-23 PoCs (Low findings) and refutation fuzz for suspected H/M issues.
contract AuditAaveGuardVaultTest is Test {
    AaveGuardVault vault;
    MockUSDC usdc;
    MockWETH weth;
    MockAavePool pool;
    MockVariableDebtToken debt;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address stranger = makeAddr("stranger");

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
        AaveGuardVaultFactory factory =
            new AaveGuardVaultFactory(address(pool), address(weth), address(usdc), address(debt));
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
        vm.prank(agent);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(stranger);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// L-1 PoC: repay() refunds the vault's whole USDC balance to the caller, so any USDC
    /// that ends up idle on the vault (owner withdraws USDC collateral to the vault itself,
    /// a donation, or a mis-sent transfer) can be taken by anyone for a 1-wei repay.
    function test_L1_repaySweepsIdleUsdcToCaller() public {
        vm.prank(agent);
        vault.borrow(shop, 500e6, bytes32(0));
        vm.startPrank(owner);
        usdc.approve(address(vault), 1_000e6);
        vault.supply(address(usdc), 1_000e6);
        vault.withdraw(address(usdc), address(vault), 1_000e6); // owner mistake: to = vault
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);

        uint256 before = usdc.balanceOf(stranger);
        vm.prank(stranger);
        vault.repay(1);
        assertEq(usdc.balanceOf(stranger), before - 1 + 1_000e6, "stranger took idle USDC");
    }

    /// L-2 PoC: WETH withdrawn to the vault address has no way out.
    function test_L2_wethWithdrawnToVaultIsStuck() public {
        vm.prank(owner);
        vault.withdraw(address(weth), address(vault), 1 ether);
        assertEq(weth.balanceOf(address(vault)), 1 ether);
        // supply() pulls from msg.sender, wrapAndSupplyETH() only wraps native ETH: no path to re-use it.
        vm.prank(owner);
        vm.expectRevert(AaveGuardVault.ZeroAmount.selector);
        vault.wrapAndSupplyETH();
    }

    /// Refutation: repaying (by the agent or anyone) never refills the agent's period budget.
    function testFuzz_repayDoesNotRefillBudget(uint256 b1, uint256 r, uint256 b2) public {
        b1 = bound(b1, 1, PER_TX);
        vm.prank(agent);
        vault.borrow(shop, b1, bytes32(0));
        r = bound(r, 1, b1);
        vm.prank(agent);
        vault.repay(r);
        (uint256 left,) = vault.borrowableNow(agent);
        uint256 expectLeft = PERIOD_CAP - b1 < PER_TX ? PERIOD_CAP - b1 : PER_TX;
        assertEq(left, expectLeft, "repay refilled budget");
        b2 = bound(b2, 1, PER_TX);
        uint256 spentAfter = b1;
        for (uint256 i; i < 5; ++i) {
            vm.prank(agent);
            try vault.borrow(shop, b2, bytes32(0)) {
                spentAfter += b2;
            } catch {}
        }
        assertLe(spentAfter, PERIOD_CAP, "period cap exceeded");
        assertEq(usdc.balanceOf(shop), spentAfter);
    }

    /// Refutation: after revoke + re-grant the old budget and allowlist are gone (epoch keyed).
    function testFuzz_revokeWipesBudgetAndRecipients(address newRecipient) public {
        vm.assume(newRecipient != address(0) && newRecipient != shop);
        vm.prank(owner);
        vault.revokeAgent(agent);
        vm.prank(owner);
        vault.grantAgent(agent, uint64(block.timestamp + 1 days));
        assertFalse(vault.isRecipientAllowed(agent, shop));
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.RecipientNotAllowed.selector);
        vault.borrow(shop, 1e6, bytes32(0));
        vm.prank(owner);
        vault.setRecipient(agent, newRecipient, true);
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.NoBudget.selector);
        vault.borrow(newRecipient, 1e6, bytes32(0));
    }

    /// Refutation: no borrow can leave the vault below the HF floor, whatever the price.
    function testFuzz_borrowNeverBelowFloor(uint256 price, uint256 amt) public {
        price = bound(price, 1e8, 10_000e8);
        pool.setPrice(address(weth), price);
        amt = bound(amt, 1, PER_TX);
        vm.prank(agent);
        try vault.borrow(shop, amt, bytes32(0)) {
            (,,,,, uint256 hf,) = vault.accountData();
            assertGe(hf, vault.healthFactorFloor());
        } catch {}
    }

    /// Refutation: a stranger's repayFor only ever reduces debt with the stranger's own USDC.
    function testFuzz_repayForCannotStealOrInflate(uint256 b, uint256 r) public {
        b = bound(b, 1, PER_TX);
        vm.prank(agent);
        vault.borrow(shop, b, bytes32(0));
        r = bound(r, 1, 10 * PER_TX);
        uint256 s0 = usdc.balanceOf(stranger);
        uint256 d0 = vault.usdcDebt();
        vm.prank(stranger);
        vault.repayFor(agent, r);
        uint256 paid = s0 - usdc.balanceOf(stranger);
        assertEq(paid, r < d0 ? r : d0);
        assertEq(vault.usdcDebt(), d0 - paid);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }
}
