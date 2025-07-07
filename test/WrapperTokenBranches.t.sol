// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_native.sol";

/*──────── Constants ───────*/
uint64  constant ONE      = 1e9;           // 1 token (8-dec)
uint256 constant WEI_ONE  = ONE * 1e9;    // 1 token in wei

contract WrappedQRLBranches is Test {
    address constant CTRL = address(0xC0FE);
    address constant AL   = address(0xA11);

    WrappedQRL w;

    function setUp() public {
        vm.deal(address(this), WEI_ONE);
        w = new WrappedQRL{value: WEI_ONE}();
    }

    /*──────── Deposit guards ───────*/
    /// Reverts because 1 wei is **not** a multiple of 1e10 wei per token
    function testDepositPrecisionRevert() public {
        bytes memory sig = abi.encodeWithSignature("deposit()");
        vm.expectRevert(bytes("precision"));
        // low-level call guarantees the revert is one frame below the cheatcode
        (bool success, ) = address(w).call{value: 1 wei}(sig);
        require(!success, "Expected revert but call succeeded");
    }

    /// Reverts on the explicit `"zero"` branch when no ETH is sent
    function testDepositZeroRevert() public {
        vm.expectRevert(); // zero
        w.deposit{value: 0}();
    }

    /*──────── Transfer guards ───────*/
    function testTransferZeroAddressReverts() public {
        vm.expectRevert(); // to0
        w.transfer(address(0), 1);
    }

    function testTransferFromAllowanceReverts() public {
        vm.prank(AL);
        w.approve(address(this), ONE / 2);            // too small
        vm.expectRevert("allow");
        w.transferFrom(AL, address(this), ONE);
    }

    /*──────── Min-stake join guard ───────*/
    function testJoinPidMinStakeReverts() public {
        uint64 pid = w.createProtocol(CTRL, 1, ONE * 2);

        vm.deal(AL, WEI_ONE);
        vm.prank(AL);
        w.deposit{value: WEI_ONE}();                  // only 1 token

        uint64[8] memory add; add[0] = pid;
        vm.prank(AL);
        vm.expectRevert("minStake");
        w.setMembership(add, 0);
    }

    /*──────── Duplicate-PID detection ───────*/
    function testSetMembershipDuplicatePidReverts() public {
        uint64 pid = w.createProtocol(CTRL, 1, ONE);

        /* controller stakes & joins */
        vm.deal(CTRL, WEI_ONE);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE}();
        uint64[8] memory arr; arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();

        vm.roll(block.number + 1);

        vm.deal(AL, WEI_ONE * 2);
        vm.prank(AL);
        w.deposit{value: WEI_ONE * 2}();

        uint64[8] memory dupArr;
        dupArr[0] = pid;
        dupArr[1] = pid;                             // duplicate
        vm.prank(AL);
        vm.expectRevert(); // dup
        w.setMembership(dupArr, 0);
    }

    /*──────── Yield branches ───────*/
    function testAddYieldNoStakeAndHappyPath() public {
        uint64 pid = w.createProtocol(CTRL, 1, ONE);

        /* (a) nobody staked → revert */
        vm.expectRevert("noStake");
        w.addYield(pid, ONE);

        /* (b) controller stakes 3 tokens, AL stakes 1 */
        vm.deal(CTRL, WEI_ONE * 3);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE * 3}();             // CTRL bal = 3
        uint64[8] memory arr; arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();

        vm.roll(block.number + 1);                   // new block for AL
        vm.deal(AL, WEI_ONE);
        vm.startPrank(AL);
        w.deposit{value: WEI_ONE}();
        w.setMembership(arr, 0);                     // AL joins
        vm.stopPrank();

        /* donate 1 token as yield (CTRL left with 2 – still ≥ minStake) */
        vm.prank(CTRL);
        w.addYield(pid, ONE);

        /* move past lock window so AL can harvest via transfer(0) */
        vm.roll(block.number + 2);
        vm.prank(AL);
        uint64 before = w.balanceOf(AL);
        w.transfer(AL, 0);                           // harvest
        assertGt(w.balanceOf(AL), before);           // AL gained yield
    }

    /*──────── Haircut branches ───────*/
    function _stakeTwo(uint64 pid) internal {
        vm.deal(CTRL, WEI_ONE * 2);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE * 2}();
        uint64[8] memory arr; arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();
    }

    function testHaircutSignalWrongCallerAndExcess() public {
        uint64 pid = w.createProtocol(CTRL, 1, ONE);
        _stakeTwo(pid);

        vm.expectRevert(); // ctrl
        w.signalHaircut(pid, ONE);                   // not controller

        vm.prank(CTRL);
        vm.expectRevert("excess");                   // ask > inBal (2)
        w.signalHaircut(pid, ONE * 3);
    }

    function testHaircutCollectFlow() public {
        uint64 pid = w.createProtocol(CTRL, 1, ONE);
        _stakeTwo(pid);                              // controller member

        vm.prank(CTRL);
        w.signalHaircut(pid, ONE);                   // schedule

        // vm.roll(block.number + 2);                   // out of lock
        vm.warp(block.timestamp + 1 hours);
        vm.prank(CTRL);
        w.transfer(CTRL, 0);                         // burn executes

        vm.prank(CTRL);
        uint64 minted = w.collectHaircut(pid, CTRL);
        assertGt(minted, 0);
        assertGe(w.balanceOf(CTRL), minted);         // balance grew
    }
}
