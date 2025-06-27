// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_native.sol";

/*───────────────────────── Helpers ─────────────────────────*/
uint64  constant ONE      = 1e8;           // token units (8-dec)
uint256 constant WEI_ONE  = ONE * 1e10;    // wei per token (scale = 1e10)

/*───────────────────────── Test Suite ──────────────────────*/
contract WrappedQRL_ViewCoverage is Test {
    address constant CTRL = address(0xC0FE);
    address constant AL   = address(0xA11);

    WrappedQRL w;

    function setUp() public {
        /* mint one token into the test contract via constructor */
        vm.deal(address(this), WEI_ONE);
        w = new WrappedQRL{value: WEI_ONE}();
    }

    /*──────── 1. protocolCount / protocolInfo coverage ───────*/
    function testProtocolCountAndInfo() public {
        uint64 pid1 = w.createProtocol(CTRL, 5, ONE);     // lockWin = 5 blocks
        uint64 pid2 = w.createProtocol(AL,   0, ONE * 2); // minStake = 2 tokens

        /* slot-zero dummy entry + two created above */
        assertEq(w.protocolCount(), 3);

        (address c1, uint64 ms1, uint64 lw1,,,,,) = w.protocolInfo(pid1);
        assertEq(c1, CTRL);
        assertEq(ms1, ONE);
        assertEq(lw1, 5);

        (address c2, uint64 ms2, uint64 lw2,,,,,) = w.protocolInfo(pid2);
        assertEq(c2, AL);
        assertEq(ms2, ONE * 2);
        assertEq(lw2, 0);
    }

    /* helper to fund / deposit / join */
    function _join(address who, uint64 pid, uint256 weiAmt) internal {
        vm.deal(who, weiAmt);
        vm.prank(who);
        w.deposit{value: weiAmt}();
        uint64[8] memory arr; arr[0] = pid;
        vm.prank(who);
        w.setMembership(arr, 0);
    }

    /*──────── 2. memberInfo / reservedInfo coverage ──────────*/
    function testMemberAndReservedInfo() public {
        uint64 pid = w.createProtocol(CTRL, 1, ONE);   // 1-block lock window

        _join(CTRL, pid, WEI_ONE * 2);                 // controller stakes 2

        vm.roll(block.number + 1);                     // avoid “dup”

        _join(AL, pid, WEI_ONE);                       // Alice stakes 1

        (uint64 mpid,uint64 stake,uint64 unlock,uint64 joinMin,uint64 rPtr)
            = w.memberInfo(AL, 0);

        assertEq(mpid,    pid);
        assertEq(stake,   ONE);
        assertGt(unlock,  block.number);
        assertEq(joinMin, ONE);

        (uint128 inS, uint128 outS, uint256 yS, uint64 jm) = w.reservedInfo(rPtr);
        assertEq(inS, 3 * ONE);   // 2 (CTRL) + 1 (AL)
        assertEq(outS, 0);
        assertEq(yS,  0);
        assertEq(jm,  ONE);
    }

    /*──────── 3. receive() fallback deposit coverage ─────────*/
    function testReceiveDeposit() public {
        uint64 balBefore = w.balanceOf(address(this));

        vm.deal(address(this), WEI_ONE);
        /* empty-calldata send triggers WrappedQRL.receive() */
        (bool ok, ) = address(w).call{value: WEI_ONE}("");
        require(ok, "native send failed");

        assertEq(w.balanceOf(address(this)), balBefore + ONE);
    }

    /*──────── 4. unlimited-allowance branch in transferFrom ──*/
    function testUnlimitedAllowanceNotDecremented() public {
        /* Alice mints one token */
        vm.deal(AL, WEI_ONE);
        vm.prank(AL);
        w.deposit{value: WEI_ONE}();

        /* grant MAX allowance to this test contract */
        vm.prank(AL);
        w.approve(address(this), type(uint64).max);

        uint64 allowBefore = w.allowance(AL, address(this));

        /* pull half a token – allowance should stay MAX */
        w.transferFrom(AL, address(0xBEEF), ONE / 2);
        assertEq(w.allowance(AL, address(this)), allowBefore);
    }
}
