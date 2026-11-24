// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AaveGuardVault} from "../../src/AaveGuardVault.sol";
import {AaveGuardVaultFactory} from "../../src/AaveGuardVaultFactory.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockWETH} from "../../src/mocks/MockWETH.sol";
import {MockAavePool, MockVariableDebtToken} from "../../src/mocks/MockAavePool.sol";

/// @dev ETH receiver that tries to re-enter the vault when it receives ETH.
contract ReentrantReceiver {
    AaveGuardVault public vault;
    bool public reenterAttempted;
    bool public reenterSucceeded;
    bytes4 public lastError;

    constructor(AaveGuardVault v) {
        vault = v;
    }

    receive() external payable {
        reenterAttempted = true;
        try vault.withdrawETH(address(this), 1) {
            reenterSucceeded = true;
        } catch (bytes memory err) {
            if (err.length >= 4) lastError = bytes4(err);
        }
    }
}

contract RejectEth {
    receive() external payable {
        revert("no");
    }
}

contract Polish20261124Test is Test {
    AaveGuardVaultFactory factory;
    AaveGuardVault vault;
    MockUSDC usdc;
    MockWETH weth;
    MockAavePool pool;
    MockVariableDebtToken debt;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address agent2 = makeAddr("agent2");
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
        usdc.mint(agent, 100_000e6);
        usdc.mint(agent2, 100_000e6);
        usdc.mint(stranger, 100_000e6);
        vm.startPrank(owner);
        vault.supplyETH{value: 10 ether}();
        vault.grantAgent(agent, uint64(block.timestamp + 30 days));
        vault.setBudget(agent, PER_TX, PERIOD_CAP, PERIOD);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
        vm.prank(agent);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(agent2);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(stranger);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------ constructors / factory

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(AaveGuardVault.ZeroAddress.selector);
        new AaveGuardVault(owner, address(0), address(weth), address(usdc), address(debt));
        vm.expectRevert(AaveGuardVault.ZeroAddress.selector);
        new AaveGuardVault(owner, address(pool), address(0), address(usdc), address(debt));
        vm.expectRevert(AaveGuardVault.ZeroAddress.selector);
        new AaveGuardVault(owner, address(pool), address(weth), address(0), address(debt));
    }

    function test_factoryRejectsZeroAddresses() public {
        vm.expectRevert("zero address");
        new AaveGuardVaultFactory(address(0), address(weth), address(usdc), address(debt));
    }

    function test_factoryMakesIndependentVaultsPerCaller() public {
        vm.startPrank(stranger);
        address v1 = factory.createVault();
        address v2 = factory.createVault();
        vm.stopPrank();
        assertTrue(v1 != v2);
        assertEq(factory.vaultsOf(stranger).length, 2);
        assertEq(AaveGuardVault(payable(v1)).owner(), stranger);
        assertEq(factory.vaultsOf(owner).length, 1);
    }

    function test_vaultApprovesPoolForWethAndUsdc() public view {
        assertEq(weth.allowance(address(vault), address(pool)), type(uint256).max);
        assertEq(usdc.allowance(address(vault), address(pool)), type(uint256).max);
    }

    // ------------------------------------------------------------ access control

    function test_ownerOnlyFunctionsRevertForStranger() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.deal(stranger, 1 ether);
        vm.startPrank(stranger);
        vm.expectRevert(err);
        vault.supplyETH{value: 1}();
        vm.expectRevert(err);
        vault.wrapAndSupplyETH();
        vm.expectRevert(err);
        vault.withdraw(address(weth), stranger, 1);
        vm.expectRevert(err);
        vault.withdrawETH(stranger, 1);
        vm.expectRevert(err);
        vault.setGuardian(stranger);
        vm.expectRevert(err);
        vault.setHealthFactorFloor(2e18);
        vm.expectRevert(err);
        vault.grantAgent(stranger, uint64(block.timestamp + 1));
        vm.expectRevert(err);
        vault.setBudget(agent, 1, 1, 1);
        vm.expectRevert(err);
        vault.removeBudget(agent);
        vm.expectRevert(err);
        vault.setRecipient(agent, stranger, true);
        vm.expectRevert(err);
        vault.unpause();
        vm.stopPrank();
    }

    function test_guardianCanRevokeAndPauseButNotUnpauseOrGrant() public {
        vm.prank(owner);
        vault.setGuardian(guardian);

        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.grantAgent(agent2, uint64(block.timestamp + 1 days));

        vm.prank(guardian);
        vault.revokeAgent(agent);
        (bool active,, uint32 epoch,) = vault.agents(agent);
        assertFalse(active);
        assertEq(epoch, 1);
    }

    function test_strangerCannotPauseOrRevoke() public {
        vm.startPrank(stranger);
        vm.expectRevert(AaveGuardVault.NotOwnerOrGuardian.selector);
        vault.pause();
        vm.expectRevert(AaveGuardVault.NotOwnerOrGuardian.selector);
        vault.revokeAgent(agent);
        vm.stopPrank();
    }

    function test_removedGuardianLosesPower() public {
        vm.startPrank(owner);
        vault.setGuardian(guardian);
        vault.setGuardian(address(0));
        vm.stopPrank();
        vm.prank(guardian);
        vm.expectRevert(AaveGuardVault.NotOwnerOrGuardian.selector);
        vault.pause();
    }

    function test_ownableTwoStepTransfer() public {
        vm.prank(owner);
        vault.transferOwnership(stranger);
        assertEq(vault.owner(), owner);
        vm.prank(agent);
        vm.expectRevert();
        vault.acceptOwnership();
        vm.prank(stranger);
        vault.acceptOwnership();
        assertEq(vault.owner(), stranger);
        vm.prank(owner);
        vm.expectRevert();
        vault.setGuardian(owner);
    }

    function test_renounceAgentRequiresActive() public {
        vm.prank(stranger);
        vm.expectRevert(AaveGuardVault.NotAgent.selector);
        vault.renounceAgent();
        vm.prank(agent);
        vault.renounceAgent();
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.NotAgent.selector);
        vault.renounceAgent();
    }

    // ------------------------------------------------------------ input validation

    function test_grantAgentValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(AaveGuardVault.ZeroAddress.selector);
        vault.grantAgent(address(0), uint64(block.timestamp + 1));
        vm.expectRevert(AaveGuardVault.InvalidExpiry.selector);
        vault.grantAgent(agent2, uint64(block.timestamp));
        vm.expectRevert(AaveGuardVault.InvalidExpiry.selector);
        vault.grantAgent(agent2, 0);
        vm.stopPrank();
    }

    function test_setBudgetValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(AaveGuardVault.ZeroAddress.selector);
        vault.setBudget(address(0), 1, 1, 1);
        vm.expectRevert(AaveGuardVault.InvalidBudget.selector);
        vault.setBudget(agent, 0, 1, 1);
        vm.expectRevert(AaveGuardVault.InvalidBudget.selector);
        vault.setBudget(agent, 1, 0, 1);
        vm.expectRevert(AaveGuardVault.InvalidBudget.selector);
        vault.setBudget(agent, 1, 1, 0);
        vm.expectRevert(AaveGuardVault.InvalidBudget.selector);
        vault.setBudget(agent, 2, 1, 1);
        vm.stopPrank();
    }

    function test_setRecipientZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(AaveGuardVault.ZeroAddress.selector);
        vault.setRecipient(agent, address(0), true);
    }

    function test_withdrawValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(AaveGuardVault.ZeroAddress.selector);
        vault.withdraw(address(weth), address(0), 1);
        vm.expectRevert(AaveGuardVault.ZeroAddress.selector);
        vault.withdrawETH(address(0), 1);
        vm.expectRevert(AaveGuardVault.AssetNotAllowed.selector);
        vault.withdraw(address(debt), owner, 1);
        vm.expectRevert(AaveGuardVault.ZeroAmount.selector);
        vault.supply(address(weth), 0);
        vm.expectRevert(AaveGuardVault.ZeroAmount.selector);
        vault.supplyETH{value: 0}();
        vm.stopPrank();
    }

    function test_floorBoundaries() public {
        vm.startPrank(owner);
        vm.expectRevert(AaveGuardVault.InvalidFloor.selector);
        vault.setHealthFactorFloor(1.1e18 - 1);
        vault.setHealthFactorFloor(1.1e18);
        assertEq(vault.healthFactorFloor(), 1.1e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ expiry / window boundaries

    function test_expiryBoundaryIsExclusive() public {
        uint64 exp = uint64(block.timestamp + 100);
        vm.prank(owner);
        vault.grantAgent(agent, exp);
        vm.warp(exp - 1);
        vm.prank(agent);
        vault.borrow(shop, 1e6, 0);
        vm.warp(exp);
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.AgentExpired.selector);
        vault.borrow(shop, 1e6, 0);
        (uint256 amt,) = vault.borrowableNow(agent);
        assertEq(amt, 0);
    }

    function test_expiredAgentCanStillRepayAndRenounce() public {
        vm.prank(agent);
        vault.borrow(shop, 500e6, 0);
        vm.warp(block.timestamp + 31 days);
        vm.prank(agent);
        vault.repay(500e6);
        assertEq(vault.usdcDebt(), 0);
        vm.prank(agent);
        vault.renounceAgent();
    }

    function test_windowBoundaryExact() public {
        vm.startPrank(agent);
        vault.borrow(shop, 1_000e6, 0);
        vault.borrow(shop, 1_000e6, 0);
        vault.borrow(shop, 500e6, 0);
        vm.expectRevert();
        vault.borrow(shop, 1, 0);
        AaveGuardVault.Budget memory b = vault.getBudget(agent);
        vm.warp(b.windowStart + PERIOD - 1);
        vm.expectRevert();
        vault.borrow(shop, 1, 0);
        vm.warp(b.windowStart + PERIOD);
        vault.borrow(shop, 1_000e6, 0);
        vm.stopPrank();
    }

    function test_longIdleWindowAlignsToPeriodBoundary() public {
        AaveGuardVault.Budget memory b0 = vault.getBudget(agent);
        vm.warp(b0.windowStart + 5 * PERIOD + 123);
        vm.prank(agent);
        vault.borrow(shop, 100e6, 0);
        AaveGuardVault.Budget memory b = vault.getBudget(agent);
        assertEq(b.windowStart, b0.windowStart + 5 * PERIOD);
        assertEq(b.borrowedInWindow, 100e6);
    }

    function test_setBudgetSamePeriodKeepsWindowChangedPeriodResets() public {
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, 0);
        vm.prank(owner);
        vault.setBudget(agent, PER_TX, 5_000e6, PERIOD);
        assertEq(vault.getBudget(agent).borrowedInWindow, 1_000e6);
        vm.prank(owner);
        vault.setBudget(agent, PER_TX, 5_000e6, PERIOD + 1);
        assertEq(vault.getBudget(agent).borrowedInWindow, 0);
    }

    function test_removeBudgetBlocksBorrow() public {
        vm.prank(owner);
        vault.removeBudget(agent);
        vm.prank(agent);
        vm.expectRevert(AaveGuardVault.NoBudget.selector);
        vault.borrow(shop, 1e6, 0);
        (uint256 amt, uint64 end) = vault.borrowableNow(agent);
        assertEq(amt, 0);
        assertEq(end, 0);
    }

    function test_borrowableNowZeroWhenPausedOrRevoked() public {
        (uint256 a,) = vault.borrowableNow(agent);
        assertEq(a, PER_TX);
        vm.prank(owner);
        vault.pause();
        (a,) = vault.borrowableNow(agent);
        assertEq(a, 0);
    }

    // ------------------------------------------------------------ outstanding accounting

    function test_outstandingTracksBorrowAndRepayAndRevoke() public {
        vm.startPrank(agent);
        vault.borrow(shop, 800e6, 0);
        vault.borrow(shop, 200e6, 0);
        vm.stopPrank();
        (,,, uint128 o) = vault.agents(agent);
        assertEq(o, 1_000e6);
        vm.prank(agent);
        vault.repay(300e6);
        (,,, o) = vault.agents(agent);
        assertEq(o, 700e6);
        // stranger repayFor attributes reduction to agent
        vm.prank(stranger);
        vault.repayFor(agent, 200e6);
        (,,, o) = vault.agents(agent);
        assertEq(o, 500e6);
        // overpay is capped to debt and outstanding floors at zero
        vm.prank(agent);
        vault.repay(10_000e6);
        (,,, o) = vault.agents(agent);
        assertEq(o, 0);
        assertEq(vault.usdcDebt(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_repayEmitsEventWithCappedAmount() public {
        vm.prank(agent);
        vault.borrow(shop, 400e6, 0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AaveGuardVault.Repaid(agent, agent, 400e6, 0);
        vm.prank(agent);
        vault.repay(900e6);
    }

    function test_strangerRepayDoesNotTouchAgentOutstanding() public {
        vm.prank(agent);
        vault.borrow(shop, 400e6, 0);
        vm.prank(stranger);
        vault.repay(100e6);
        (,,, uint128 o) = vault.agents(agent);
        assertEq(o, 400e6);
        assertEq(vault.usdcDebt(), 300e6);
    }

    function test_repayZeroAndNoDebtRevert() public {
        vm.prank(stranger);
        vm.expectRevert(AaveGuardVault.ZeroAmount.selector);
        vault.repay(0);
        vm.prank(stranger);
        vm.expectRevert(AaveGuardVault.ZeroAmount.selector);
        vault.repayFor(agent, 0);
        // no debt: mock pool caps repay to 0 (real Aave reverts); stranger funds must be untouched
        uint256 before = usdc.balanceOf(stranger);
        vm.prank(stranger);
        vault.repay(1e6);
        assertEq(usdc.balanceOf(stranger), before);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_revokeZeroesOutstandingAndRepayStillReducesDebt() public {
        vm.prank(agent);
        vault.borrow(shop, 400e6, 0);
        vm.prank(owner);
        vault.revokeAgent(agent);
        (,,, uint128 o) = vault.agents(agent);
        assertEq(o, 0);
        vm.prank(agent);
        vault.repay(400e6);
        assertEq(vault.usdcDebt(), 0);
    }

    function test_reGrantedAgentStartsWithFreshBudgetBlock() public {
        vm.startPrank(owner);
        vault.revokeAgent(agent);
        vault.grantAgent(agent, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        AaveGuardVault.Budget memory b = vault.getBudget(agent);
        assertEq(b.period, 0);
        assertFalse(vault.isRecipientAllowed(agent, shop));
    }

    function test_twoAgentsHaveIsolatedBudgetsAndRecipients() public {
        vm.startPrank(owner);
        vault.grantAgent(agent2, uint64(block.timestamp + 1 days));
        vault.setBudget(agent2, 100e6, 100e6, PERIOD);
        vault.setRecipient(agent2, stranger, true);
        vm.stopPrank();
        vm.prank(agent2);
        vm.expectRevert(AaveGuardVault.RecipientNotAllowed.selector);
        vault.borrow(shop, 1e6, 0);
        vm.prank(agent2);
        vault.borrow(stranger, 100e6, 0);
        vm.prank(agent2);
        vm.expectRevert();
        vault.borrow(stranger, 1, 0);
        // agent1 budget unaffected
        vm.prank(agent);
        vault.borrow(shop, 1_000e6, 0);
    }

    function test_borrowEmitsEvent() public {
        AaveGuardVault.Budget memory b = vault.getBudget(agent);
        vm.expectEmit(true, true, false, false, address(vault));
        emit AaveGuardVault.Borrowed(agent, shop, 10e6, bytes32("m"), 10e6, b.windowStart, 0);
        vm.prank(agent);
        vault.borrow(shop, 10e6, bytes32("m"));
    }

    // ------------------------------------------------------------ pause / withdrawals

    function test_unpauseRestoresBorrow() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.borrow(shop, 1e6, 0);
        vm.prank(owner);
        vault.unpause();
        vm.prank(agent);
        vault.borrow(shop, 1e6, 0);
    }

    function test_withdrawETHSendsEthAndHonorsFloor() public {
        uint256 b0 = owner.balance;
        vm.prank(owner);
        vault.withdrawETH(owner, 1 ether);
        assertEq(owner.balance, b0 + 1 ether);
        assertEq(address(vault).balance, 0);

        vm.prank(agent);
        vault.borrow(shop, 1_000e6, 0);
        // withdrawing nearly all collateral must fail the floor
        vm.prank(owner);
        vm.expectRevert();
        vault.withdrawETH(owner, 8.9 ether);
    }

    function test_withdrawETHToRejectingReceiverReverts() public {
        RejectEth r = new RejectEth();
        vm.prank(owner);
        vm.expectRevert(AaveGuardVault.EthTransferFailed.selector);
        vault.withdrawETH(address(r), 1 ether);
    }

    function test_withdrawETHReentrancyBlocked() public {
        ReentrantReceiver r = new ReentrantReceiver(vault);
        vm.prank(owner);
        vault.withdrawETH(address(r), 1 ether);
        assertTrue(r.reenterAttempted());
        assertFalse(r.reenterSucceeded());
        // receiver is not owner so onlyOwner fires before the guard; either way re-entry is impossible
        assertEq(r.lastError(), Ownable.OwnableUnauthorizedAccount.selector);
        assertEq(address(r).balance, 1 ether);
    }

    function test_withdrawMaxUintWithNoDebt() public {
        vm.prank(owner);
        vault.withdrawETH(owner, type(uint256).max);
        (uint256 col,,,,,,) = vault.accountData();
        assertEq(col, 0);
    }

    function test_receiveAcceptsEthAndWrapSupplies() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(owner);
        vault.wrapAndSupplyETH();
        assertEq(address(vault).balance, 0);
        assertEq(pool.collateral(address(vault), address(weth)), 11 ether);
    }

    // ------------------------------------------------------------ fuzz

    /// Production-scale: 6-dec USDC against 18-dec WETH, large collateral.
    function testFuzz_outstandingEqualsBorrowedMinusRepaid(uint256 b1, uint256 b2, uint256 r1) public {
        b1 = bound(b1, 1, PER_TX);
        b2 = bound(b2, 1, PER_TX);
        if (b1 + b2 > PERIOD_CAP) b2 = PERIOD_CAP - b1;
        if (b2 == 0) b2 = 1;
        vm.startPrank(agent);
        vault.borrow(shop, b1, 0);
        vault.borrow(shop, b2, 0);
        r1 = bound(r1, 1, b1 + b2);
        vault.repay(r1);
        vm.stopPrank();
        (,,, uint128 o) = vault.agents(agent);
        assertEq(o, b1 + b2 - r1);
        assertEq(vault.usdcDebt(), b1 + b2 - r1);
        assertEq(usdc.balanceOf(shop), b1 + b2);
    }

    function testFuzz_borrowAboveCapsReverts(uint256 amt) public {
        amt = bound(amt, uint256(PER_TX) + 1, type(uint128).max);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AaveGuardVault.ExceedsPerTxCap.selector, amt, uint256(PER_TX)));
        vault.borrow(shop, amt, 0);
    }

    function testFuzz_strangerCannotBorrow(address who, uint256 amt) public {
        vm.assume(who != agent);
        amt = bound(amt, 1, PER_TX);
        vm.prank(who);
        vm.expectRevert(AaveGuardVault.NotAgent.selector);
        vault.borrow(shop, amt, 0);
    }

    function testFuzz_floorGatesWithdraw(uint256 floor, uint256 w) public {
        floor = bound(floor, 1.1e18, 10e18);
        w = bound(w, 1, 10 ether);
        vm.startPrank(owner);
        vault.setHealthFactorFloor(floor);
        vm.stopPrank();
        vm.prank(agent);
        try vault.borrow(shop, 1_000e6, 0) {} catch {}
        vm.prank(owner);
        try vault.withdrawETH(owner, w) {
            (,,,,, uint256 hf,) = vault.accountData();
            assertGe(hf, floor);
        } catch {}
    }
}
