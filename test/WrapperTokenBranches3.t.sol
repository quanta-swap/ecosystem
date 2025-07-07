// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_native.sol";

/*──────── Constants ───────*/
uint64  constant ONE      = 1e9;          // 8-dec token unit
uint256 constant WEI_ONE  = ONE * 1e9;   // wei per token (scale)

/*────────────────── Additional Branch Suite ──────────────────*/
contract WrappedQRL_BranchCoverage2 is Test {
    address constant CTRL = address(0xC0FE);
    address constant AL   = address(0xA11);

    WrappedQRL w;

    function setUp() public {
        vm.deal(address(this), 10 * WEI_ONE);
        w = new WrappedQRL{value: WEI_ONE}();          // 1 token minted here
    }

    /* helper: quick protocol spin-up */
    function _newPid(uint64 minStake) internal returns (uint64) {
        return w.createProtocol(CTRL, 0, minStake);    // lockWin = 0
    }

    /*───────────────────────────────────────────────────────────
    | 1) Fill eight slots, then call setMembership(extra, 0):
    |    – drops all previous memberships
    |    – succeeds in joining the ninth PID
    ───────────────────────────────────────────────────────────*/
    function testDropAllThenJoinNinth() public {
        uint64[8] memory eight;
        for (uint8 i; i < 8; ++i) eight[i] = _newPid(ONE);

        w.setMembership(eight, 0);                    // join 8 protocols

        uint64 ninth = _newPid(ONE);
        uint64[8] memory addOne; addOne[0] = ninth;
        w.setMembership(addOne, 0);                   // stayMask = 0 ⇒ drop all

        (, uint64[8] memory pids, ) = w.accountInfo(address(this));
        assertEq(pids[0], ninth);                     // slot-0 is the new PID
        for (uint8 i = 1; i < 8; ++i) assertEq(pids[i], 0); // others cleared
    }

    /* slot-index guard on memberInfo */
    function testMemberInfoSlotOutOfRange() public {
        vm.expectRevert();
        w.memberInfo(address(this), 8);               // valid slots: 0-7
    }

    /* bogus PID ⇒ "pid" revert */
    function testSetMembershipInvalidPidReverts() public {
        uint64 bad = 999_999;                         // > protocolCount
        uint64[8] memory arr; arr[0] = bad;
        vm.expectRevert(bytes("pid"));
        w.setMembership(arr, 0);
    }

    /* unlimited-allowance path pulled twice (allowance unchanged) */
    function testUnlimitedAllowancePulledTwice() public {
        vm.deal(AL, WEI_ONE);
        vm.prank(AL);
        w.deposit{value: WEI_ONE}();

        vm.prank(AL);
        w.approve(address(this), type(uint64).max);

        w.transferFrom(AL, address(0xB0B), ONE / 4);
        w.transferFrom(AL, address(0xB0B), ONE / 4);

        assertEq(w.allowance(AL, address(this)), type(uint64).max);
    }

    /* withdraw min-stake check across two simultaneous memberships */
    function testWithdrawMinStakeAcrossTwoPids() public {
        uint64 pA = _newPid(ONE);
        uint64 pB = _newPid(ONE / 2);

        vm.deal(AL, WEI_ONE * 2);
        vm.startPrank(AL);
        w.deposit{value: WEI_ONE * 2}();

        uint64[8] memory both; both[0] = pA; both[1] = pB;
        w.setMembership(both, 0);

        vm.expectRevert(bytes("minStake"));
        w.withdraw(ONE + ONE / 2);                    // would break pA stake

        w.withdraw(ONE / 2);                          // OK
        vm.stopPrank();
    }

    /* explicit zero-value guard on signalHaircut */
    function testSignalHaircutZeroGuard() public {
        uint64 pid = _newPid(ONE);

        vm.deal(CTRL, WEI_ONE);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE}();
        w.setMembership([pid,0,0,0,0,0,0,0], 0);

        vm.expectRevert(bytes("zero"));
        w.signalHaircut(pid, 0);
        vm.stopPrank();
    }
}
