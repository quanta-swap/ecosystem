// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_native.sol";
import "../src/IZ156Flash.sol";
import "../src/IZRC20.sol";

/*──────── Constants ───────*/
uint64  constant ONE      = 1e8;          // 8-dec token unit
uint256 constant WEI_ONE  = ONE * 1e10;   // wei per token (scale)

/*────────────────── Helper flash-loan receivers ──────────────────*/
contract SimpleBorrower is IZ156FlashBorrower {
    IZRC20 immutable tok;
    constructor(IZRC20 t) { tok = t; }
    function onFlashLoan(
        address initiator,
        address token,
        uint64 amount,
        uint64,
        bytes calldata
    ) external override returns (bytes32) {
        tok.approve(initiator, amount);          // hand back the loan
        return keccak256("IZ156.ok");
    }
}

/* re-enters flashLoan → should trigger ReentrancyGuard */
contract ReentrantBorrower is IZ156FlashBorrower {
    WrappedQRL immutable w;
    constructor(WrappedQRL _w) { w = _w; }
    function onFlashLoan(
        address,
        address,
        uint64,
        uint64,
        bytes calldata
    ) external override returns (bytes32) {
        w.flashLoan(this, address(w), 1, "");
        return keccak256("IZ156.ok");
    }
}

/* sets allowance *before* requesting → must hit “pre-allow” branch */
contract BorrowerPreAllow is IZ156FlashBorrower {
    WrappedQRL immutable w;
    constructor(WrappedQRL _w) { w = _w; }
    function kick(uint64 amt) external {
        w.approve(address(w), amt);              // triggers pre-allow check
        w.flashLoan(this, address(w), amt, "");
    }
    function onFlashLoan(
        address initiator,
        address token,
        uint64 amount,
        uint64,
        bytes calldata
    ) external override returns (bytes32) {
        IZRC20(token).approve(initiator, amount);
        return keccak256("IZ156.ok");
    }
}

/*────────────────── Branch-coverage test-bed ──────────────────*/
contract WrappedQRL_BranchCoverage is Test {
    address constant CTRL = address(0xC0FE);
    address constant USER = address(0xBEEF);

    WrappedQRL w;

    function setUp() public {
        vm.deal(address(this), 10 * WEI_ONE);    // war-chest
        w = new WrappedQRL{value: WEI_ONE}();    // mint 1 token to self
    }

    /* helper: spin up a protocol with zero lock window for rapid exit */
    function _newPid(uint64 minStake) internal returns (uint64) {
        return w.createProtocol(CTRL, 0, minStake);
    }

    /*──────── Free-list reuse ───────*/
    function testFreeListReuse() public {
        uint64 pid1 = _newPid(ONE);

        vm.deal(CTRL, WEI_ONE);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE}();
        w.setMembership([pid1,0,0,0,0,0,0,0], 0);      // join
        w.setMembership([uint64(0),0,0,0,0,0,0,0], 0); // leave (lockWin=0)
        vm.stopPrank();

        (uint256 resFreeBefore, uint256 memFreeBefore) = w.freeLists();

        uint64 pid2 = _newPid(ONE);
        vm.startPrank(CTRL);
        w.setMembership([pid2,0,0,0,0,0,0,0], 0);      // join again – should reuse free-list entry
        vm.stopPrank();

        (uint256 resFreeAfter, uint256 memFreeAfter) = w.freeLists();
        assertLt(resFreeAfter, resFreeBefore);         // entry popped
        assertLt(memFreeAfter, memFreeBefore);
    }

    /*──────── Second-quad allocation (slots 4-7) ───────*/
    function testSecondQuadAllocation() public {
        uint64[8] memory join;
        for (uint8 i; i < 5; ++i) join[i] = _newPid(ONE);

        vm.deal(USER, WEI_ONE * 5);
        vm.startPrank(USER);
        w.deposit{value: WEI_ONE * 5}();
        w.setMembership(join, 0);                      // slot 4 lands in ptrB
        vm.stopPrank();

        (uint64 pidSlot4,,,,) = w.memberInfo(USER, 4);
        assertEq(pidSlot4, join[4]);                   // confirms ptrB path executed
    }

    /*──────── collectHaircut early-exit branch ───────*/
    function testCollectHaircutEarlyExit() public {
        uint64 pid = _newPid(ONE);

        vm.deal(CTRL, WEI_ONE * 2);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE * 2}();
        w.setMembership([pid,0,0,0,0,0,0,0], 0);

        w.signalHaircut(pid, ONE);
        vm.roll(block.number + 1);
        w.transfer(CTRL, 0);                           // burn executes
        uint64 minted1 = w.collectHaircut(pid, CTRL);
        assertGt(minted1, 0);

        uint64 minted2 = w.collectHaircut(pid, CTRL);  // early-exit (nothing left)
        assertEq(minted2, 0);
        vm.stopPrank();
    }

    /*──────── addYield balance-shortfall branch ───────*/
    function testAddYieldBalanceRevert() public {
        uint64 pid = _newPid(ONE);

        vm.deal(CTRL, WEI_ONE);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE}();                   // balance = 1
        w.setMembership([pid,0,0,0,0,0,0,0], 0);

        vm.expectRevert(bytes("bal"));
        w.addYield(pid, ONE * 2);                      // asks for 2, has 1
        vm.stopPrank();
    }

    /*──────── Re-entrancy guard ───────*/
    function testFlashLoanReentrancyGuard() public {
        ReentrantBorrower b = new ReentrantBorrower(w);
        vm.expectRevert(bytes("re-enter"));
        vm.prank(address(b));
        w.flashLoan(b, address(w), ONE, "");
    }

    /*──────── flashLoan exotic rejects ───────*/
    function testFlashLoanTokenMismatch() public {
        SimpleBorrower b = new SimpleBorrower(IZRC20(address(w)));
        vm.prank(address(b));
        vm.expectRevert(bytes("tok"));
        w.flashLoan(b, address(0x1234), ONE, "");
    }

    function testFlashLoanReceiverMismatch() public {
        SimpleBorrower b = new SimpleBorrower(IZRC20(address(w)));
        vm.expectRevert(bytes("receiver mismatch"));   // caller ≠ borrower
        w.flashLoan(b, address(w), ONE, "");
    }

    function testFlashLoanPreAllowReverts() public {
        BorrowerPreAllow b = new BorrowerPreAllow(w);
        vm.expectRevert(bytes("pre-allow"));
        vm.prank(address(b));
        b.kick(ONE);
    }

    /*──────── Zero-value guard branches ───────*/
    function testSignalHaircutZeroReverts() public {
        uint64 pid = _newPid(ONE);

        vm.deal(CTRL, WEI_ONE);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE}();
        w.setMembership([pid,0,0,0,0,0,0,0], 0);

        vm.expectRevert(bytes("zero"));
        w.signalHaircut(pid, 0);
        vm.stopPrank();
    }

    function testWithdrawZeroReverts() public {
        vm.expectRevert(bytes("zero"));
        w.withdraw(0);
    }

    /*──────── Duplicate-PID detector ───────*/
    function testSetMembershipDuplicateAddReverts() public {
        uint64 p0 = _newPid(ONE);
        uint64 p1 = _newPid(ONE);

        vm.deal(USER, WEI_ONE * 2);
        vm.startPrank(USER);
        w.deposit{value: WEI_ONE * 2}();
        w.setMembership([p0,0,0,0,0,0,0,0], 0);        // already in p0

        uint64[8] memory dup;
        dup[0] = p0;
        dup[1] = p0;                                   // duplicate in add-list
        vm.expectRevert();                             // "dup"
        w.setMembership(dup, 1);                       // keep slot0, try to add dup
        vm.stopPrank();
    }
}
