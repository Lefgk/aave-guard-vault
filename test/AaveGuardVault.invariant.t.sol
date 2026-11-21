// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AaveGuardVault} from "../src/AaveGuardVault.sol";
import {AaveGuardVaultFactory} from "../src/AaveGuardVaultFactory.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockAavePool, MockVariableDebtToken} from "../src/mocks/MockAavePool.sol";

contract Handler is Test {
    AaveGuardVault public vault;
    MockUSDC public usdc;
    address public owner;
    address public agent;
    address[] public recipients;
    address public outsider = makeAddr("outsider-not-allowlisted");

    uint256 public constant PER_TX = 1_000e6;
    uint256 public constant CAP = 2_500e6;
    uint64 public constant PERIOD = 1 days;

    mapping(uint64 => uint256) public ghostBorrowedInWindow;
    uint256 public ghostMaxSingle;
    uint256 public ghostMaxWindow;
    uint256 public ghostTotalOut;
    uint256 public ghostOutsiderReceived;
    uint256 public ghostBorrowsWhileInactive;
    uint256 public ghostHfViolations;
    uint256 public ghostRepaid;
    uint256 public calls;

    constructor(AaveGuardVault v, MockUSDC u, address o, address a, address[] memory r) {
        vault = v;
        usdc = u;
        owner = o;
        agent = a;
        recipients = r;
    }

    function borrow(uint256 amt, uint256 rIdx) external {
        calls++;
        amt = bound(amt, 1, 3_000e6);
        address to = rIdx % 8 == 0 ? outsider : recipients[rIdx % recipients.length];
        (bool activeBefore,,,) = vault.agents(agent);
        bool pausedBefore = vault.paused();
        vm.prank(agent);
        try vault.borrow(to, amt, bytes32(calls)) {
            if (!activeBefore || pausedBefore) ghostBorrowsWhileInactive++;
            if (to == outsider) ghostOutsiderReceived += amt;
            AaveGuardVault.Budget memory b = vault.getBudget(agent);
            ghostBorrowedInWindow[b.windowStart] += amt;
            uint256 w = ghostBorrowedInWindow[b.windowStart];
            ghostTotalOut += amt;
            if (amt > ghostMaxSingle) ghostMaxSingle = amt;
            if (w > ghostMaxWindow) ghostMaxWindow = w;
            (,,,,, uint256 hf,) = vault.accountData();
            if (hf < vault.healthFactorFloor()) ghostHfViolations++;
        } catch {}
    }

    function repay(uint256 amt) external {
        amt = bound(amt, 1, 5_000e6);
        uint256 bal = usdc.balanceOf(agent);
        if (bal == 0) return;
        if (amt > bal) amt = bal;
        vm.startPrank(agent);
        usdc.approve(address(vault), amt);
        try vault.repay(amt) {
            ghostRepaid += amt;
        } catch {}
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }

    function togglePause(bool p) external {
        bool isPaused = vault.paused();
        vm.prank(owner);
        if (p && !isPaused) vault.pause();
        if (!p && isPaused) vault.unpause();
    }

    function ownerRepay(uint256 amt) external {
        amt = bound(amt, 1, 5_000e6);
        uint256 bal = usdc.balanceOf(owner);
        if (bal == 0) return;
        if (amt > bal) amt = bal;
        vm.startPrank(owner);
        usdc.approve(address(vault), amt);
        try vault.repay(amt) {} catch {}
        vm.stopPrank();
    }
}

contract AaveGuardVaultInvariantTest is Test {
    Handler handler;
    AaveGuardVault vault;
    MockUSDC usdc;
    MockWETH weth;
    MockAavePool pool;

    address owner = makeAddr("inv-owner");
    address agent = makeAddr("inv-agent");

    function setUp() public {
        usdc = new MockUSDC();
        weth = new MockWETH();
        MockVariableDebtToken debt = new MockVariableDebtToken();
        pool = new MockAavePool(address(weth), address(usdc), address(debt));
        debt.setPool(address(pool));
        usdc.mint(address(pool), 50_000_000e6);

        AaveGuardVaultFactory factory =
            new AaveGuardVaultFactory(address(pool), address(weth), address(usdc), address(debt));
        vm.prank(owner);
        vault = AaveGuardVault(payable(factory.createVault()));

        vm.deal(owner, 100 ether);
        usdc.mint(owner, 1_000_000e6);
        usdc.mint(agent, 1_000_000e6);

        address[] memory recips = new address[](2);
        recips[0] = makeAddr("shop-a");
        recips[1] = makeAddr("shop-b");

        vm.startPrank(owner);
        vault.supplyETH{value: 20 ether}();
        vault.grantAgent(agent, uint64(block.timestamp + 365 days));
        vault.setBudget(agent, 1_000e6, 2_500e6, 1 days);
        vault.setRecipient(agent, recips[0], true);
        vault.setRecipient(agent, recips[1], true);
        vm.stopPrank();

        handler = new Handler(vault, usdc, owner, agent, recips);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](5);
        sels[0] = Handler.borrow.selector;
        sels[1] = Handler.repay.selector;
        sels[2] = Handler.warp.selector;
        sels[3] = Handler.togglePause.selector;
        sels[4] = Handler.ownerRepay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_capsHold() public view {
        assertLe(handler.ghostMaxSingle(), 1_000e6);
        assertLe(handler.ghostMaxWindow(), 2_500e6);
    }

    function invariant_outsiderGetsNothing() public view {
        assertEq(handler.ghostOutsiderReceived(), 0);
    }

    function invariant_noBorrowWhileInactive() public view {
        assertEq(handler.ghostBorrowsWhileInactive(), 0);
    }

    function invariant_hfFloorHonored() public view {
        assertEq(handler.ghostHfViolations(), 0);
        (,,,,, uint256 hf,) = vault.accountData();
        if (vault.usdcDebt() > 0) assertGe(hf, vault.healthFactorFloor());
    }

    function invariant_shopBalancesMatchOutflow() public view {
        uint256 sum;
        for (uint256 i; i < 2; i++) {
            sum += usdc.balanceOf(handler.recipients(i));
        }
        assertEq(sum, handler.ghostTotalOut());
        assertEq(sum + handler.ghostOutsiderReceived(), handler.ghostTotalOut());
    }
}
