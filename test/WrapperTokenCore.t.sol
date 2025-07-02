// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import {IZ156FlashBorrower} from "../src/IZ156Flash.sol";
import {IZRC20} from "../src/IZRC20.sol";
import {WrappedQRL} from "../src/_native.sol";

/*───────────────────────── Helpers ─────────────────────────*/
uint64 constant ONE = 1e8;               // 1 token (8-dec)
uint256 constant WEI_ONE = ONE * 1e10;   // 1 token in wei (scale = 1e10)

/* mock borrower for the flash-loan path */
contract FlashBorrower is IZ156FlashBorrower {
    IZRC20 public immutable tok;
    constructor(IZRC20 t) { tok = t; }

    /* receive loan, approve lender for repayment */
    function onFlashLoan(
        address initiator,
        address token,
        uint64 amount,
        uint64 /*fee*/,
        bytes calldata /*data*/
    ) external override returns (bytes32) {
        require(msg.sender == initiator, "initiator");       // sender check
        require(token == address(tok),   "token");           // token match
        tok.approve(initiator, amount);                      // repay
        return keccak256("IZ156.ok");
    }
}

/*────────────────────── Test Suite ───────────────────────*/
contract WrappedQRL_Test is Test {
    /* actors */
    address alice   = address(0xA11);
    address bob     = address(0xB22);
    address ctrl    = address(0xC33);     // controller of protocol #1
    address outsider= address(0xD44);     // for revert cases

    WrappedQRL w;         // token under test
    FlashBorrower borrower;

    /* deploy with 5 tokens pre-minted to msg.sender */
    function setUp() public {
        vm.deal(address(this), 5 * WEI_ONE);
        w = new WrappedQRL{ value: 5 * WEI_ONE }();  // constructor path with ETH

        /* seed ETH for deposit/withdraw paths */
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(ctrl,  10 ether);

        /* blanket approvals */
        vm.startPrank(alice);
        w.approve(address(this), type(uint64).max);
        vm.stopPrank();
    }

    /*────────────────────  ERC-20 Basics  ────────────────────*/
    function testConstructorSupply() public {
        assertEq(w.totalSupply(), 5*ONE);
        assertEq(w.balanceOf(address(this)), 5*ONE);
    }

    function testDepositAndWithdraw() public {
        vm.startPrank(alice);
        w.deposit{value: WEI_ONE * 2}();                 // +2
        assertEq(w.balanceOf(alice), 2*ONE);

        uint64 bal = w.balanceOf(alice);
        w.withdraw(bal);                                 // full exit
        assertEq(w.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function testTransferAndTransferFrom() public {
        /* give alice 1 token via deposit */
        vm.prank(alice);
        w.deposit{value: WEI_ONE}();

        vm.prank(alice);
        w.transfer(bob, ONE);                            // bare transfer
        assertEq(w.balanceOf(bob), ONE);

        /* pull it back with allowance path */
        vm.prank(bob);
        w.approve(address(this), ONE);
        w.transferFrom(bob, alice, ONE);
        assertEq(w.balanceOf(alice), ONE);
    }

    /*────────────────── Protocol / Membership ─────────────────*/
    function _bootstrapProtocol() internal returns (uint64 pid) {
        /* controller creates protocol with tiny stake */
        pid = w.createProtocol(ctrl, 1, ONE);          // lockWin = 1 block
        vm.startPrank(ctrl);
        w.deposit{value: WEI_ONE * 2}();               // 2 tokens stake
        w.setMembership([pid, 0, 0, 0, 0, 0, 0, 0], 0);
        vm.stopPrank();

        /* bump block so the next joiner isn’t flagged “dup” */
        vm.roll(block.number + 1);
    }

    function testJoinLeaveStakeMin() public {
        uint64 pid = _bootstrapProtocol();

        /* Alice joins */
        vm.prank(alice);
        w.deposit{value: WEI_ONE}();
        uint64[8] memory add;  add[0] = pid;
        vm.prank(alice);
        w.setMembership(add, 0);
        (, uint64[8] memory pids, ) = w.accountInfo(alice);
        assertEq(pids[0], pid);

        /* withdraw below min-stake must revert */
        vm.startPrank(alice);
        vm.expectRevert("minStake");
        w.withdraw(ONE / 2);
        vm.stopPrank();

        /* wait out lock window and leave */
        vm.roll(block.number + 2);
        uint64[8] memory none;                    // all zeros
        vm.prank(alice);
        w.setMembership(none, 0);
        (, uint64[8] memory afterwards, ) = w.accountInfo(alice);
        assertEq(afterwards[0], 0);
    }

    /*──────────────────── Yield & Haircut ───────────────────*/
    function testYieldDistributionAndHaircut() public {
        uint64 pid = _bootstrapProtocol();

        /* Alice joins with 2 tokens – roll to avoid “dup” */
        vm.roll(block.number + 1);
        vm.startPrank(alice);
        w.deposit{value: WEI_ONE * 2}();
        uint64[8] memory arr; arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();

        /* controller adds 1-token yield */
        vm.startPrank(ctrl);
        w.addYield(pid, ONE);
        vm.stopPrank();

        /* advance 1 block so Alice is past lock-window */
        vm.roll(block.number + 1);

        /* harvest – record balance */
        vm.startPrank(alice);
        w.transfer(alice, 0);
        uint64 balBefore = w.balanceOf(alice);
        vm.stopPrank();

        /* controller signals 1-token haircut */
        vm.prank(ctrl);
        w.signalHaircut(pid, ONE);

        /* advance a block & harvest again – balance must drop */
        vm.roll(block.number + 1);
        vm.prank(alice);
        w.transfer(alice, 0);
        assertLt(w.balanceOf(alice), balBefore);  // haircut applied

        /* controller collects haircut mint */
        vm.prank(ctrl);                           // <-- needs controller sender
        uint64 minted = w.collectHaircut(pid, ctrl);
        assertGt(minted, 0);
    }

    /*──────────────────── Flash-Loan Path ───────────────────*/
    function testFlashLoanRoundTrip() public {
        borrower = new FlashBorrower(IZRC20(w));

        /* borrower requests 3 tokens flash-loan */
        uint64 amt = 3*ONE;
        vm.prank(address(borrower));
        bool ok = w.flashLoan(
            borrower,
            address(w),
            amt,
            "0x"
        );
        assertTrue(ok);
        assertEq(w.balanceOf(address(borrower)), 0);     // full round-trip
    }

    function testFlashLoanRevertsForMember() public {
        uint64 pid = _bootstrapProtocol();

        borrower = new FlashBorrower(w);

        /* give borrower ETH and join protocol */
        vm.deal(address(borrower), 2 * WEI_ONE);          // fund deposit
        vm.roll(block.number + 1);                        // avoid “dup”
        vm.prank(address(borrower));
        w.deposit{value: WEI_ONE}();                      // 1 token
        uint64[8] memory join; join[0] = pid;
        vm.prank(address(borrower));
        w.setMembership(join, 0);                         // borrower is now a member

        /* flash-loan should revert (any reason acceptable) */
        vm.expectRevert();
        vm.prank(address(borrower));
        w.flashLoan(borrower, address(w), ONE, "");
    }

    /*────────────────── Revert Guard Checks ─────────────────*/
    function testWithdrawBelowMinStakeReverts() public {
        uint64 pid = _bootstrapProtocol();

        vm.roll(block.number + 1);
        vm.startPrank(bob);
        w.deposit{value: WEI_ONE}();
        uint64[8] memory add;  add[0] = pid;
        w.setMembership(add, 0);

        vm.expectRevert("minStake");
        w.withdraw(ONE);                                // would zero stake
        vm.stopPrank();
    }

    /* ───────────────── test: create-protocol guards ───────────────── */
    function testCreateProtocolValidation() public {
        vm.expectRevert("ctrl0");
        w.createProtocol(address(0), 1, ONE);

        uint64 tooLong = w.MAX_LOCK_WIN() + 1;         // getter now exists
        vm.expectRevert("lockWin");
        w.createProtocol(outsider, tooLong, ONE);
    }

    function testTransferLockedReverts() public {
        uint64 pid = _bootstrapProtocol();

        vm.roll(block.number + 1);
        vm.prank(alice);
        w.deposit{value: WEI_ONE}();
        uint64[8] memory add;  add[0] = pid;
        vm.prank(alice);
        w.setMembership(add, 0);

        vm.prank(alice);
        vm.expectRevert("locked");
        w.transfer(bob, ONE / 2);
    }

    /*──────────────────— Misc sanity paths —────────────────*/
    function testThemeStrings() public view {
        assertGt(bytes(w.theme()).length, 0);
    }
}
