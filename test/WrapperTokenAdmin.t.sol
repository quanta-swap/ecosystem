// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────────────────*\
│  WrapperTokenAdmin – admin/controller regression tests for WrappedQRL      │
\*───────────────────────────────────────────────────────────────────────────*/

import "lib/forge-std/src/Test.sol";
import {WrappedQRL} from "../src/_native.sol";

uint64 constant ONE = 1e9;          // 1 token (9-dec)
uint256 constant WEI_ONE = ONE * 1e9;

contract WrapperTokenAdmin is Test {
    /* actors */
    address internal constant CTL  = address(0xC01);  // bootstrap controller
    address internal constant BO   = address(0xB02);  // random user
    address internal constant ALT1 = address(0xA51);
    address internal constant ALT2 = address(0xA52);
    address internal constant ALT3 = address(0xA53);

    WrappedQRL internal w;
    uint64      pid;                     // protocol created in setUp()

    /*──────────────────── fixture ────────────────────*/
    function setUp() external {
        vm.deal(CTL , 40 ether);
        vm.deal(ALT1, 40 ether);
        vm.deal(ALT2, 40 ether);
        vm.deal(ALT3, 40 ether);

        w = new WrappedQRL();

        // controller boot-straps protocol #1 (lockWin = 1 blk, minStake = 1)
        pid = w.createProtocol(CTL, 1, ONE);
    }

    /*═════════════════════════════════════════════════════════════*/
    /*                  Controller-set manipulation                */
    /*═════════════════════════════════════════════════════════════*/

    /// Anyone *but* a controller should be rejected.
    function testAddControllerAuth() external {
        vm.prank(BO);
        vm.expectRevert();
        w.addController(pid, ALT1);
    }

    /// Happy-path add: set expands until MAX_CTRL then reverts with "full".
    function testAddControllerUpToCap() external {
        uint8 max = w.MAX_CTRL();           // getter via instance

        vm.startPrank(CTL);
        // Already have CTL in slot 0 – fill slots 1 … max-1
        for (uint8 i = 1; i < max; ++i) {
            address a = address(uint160(0xC000 + i));
            w.addController(pid, a);
            // duplicate add must revert with "dupe"
            vm.expectRevert();
            w.addController(pid, a);
        }

        // next add exceeds the cap → "full"
        vm.expectRevert();
        w.addController(pid, ALT1);
        vm.stopPrank();
    }

    /// Removing the last remaining controller must revert with "last".
    function testRemoveLastControllerGuard() external {
        // First, add ALT1 so CTL can safely leave.
        vm.prank(CTL);
        w.addController(pid, ALT1);

        // ALT1 removes CTL (allowed) …
        vm.prank(ALT1);
        w.removeController(pid, CTL);

        // … but now ALT1 is the *sole* member – removing it should fail.
        vm.prank(ALT1);
        vm.expectRevert();
        w.removeController(pid, ALT1);
    }

    /// swapController: atomic replacement keeps cardinality constant.
    function testSwapController() external {
        vm.prank(CTL);
        w.addController(pid, ALT1);

        vm.prank(CTL);
        w.swapController(pid, ALT1, ALT2);  // ALT1 → ALT2

        // ALT2 is a member, ALT1 is not.
        ( , , , uint128 inBal,, , ,) = w.protocolInfo(pid);  // dummy read
        assertTrue(w._isCtrl(pid, ALT2));   // internal mapping is public
        assertFalse(w._isCtrl(pid, ALT1));
        // Trying to swap a non-member should revert "missing".
        vm.prank(CTL);
        vm.expectRevert("missing");
        w.swapController(pid, ALT1, ALT3);
    }

    /*═════════════════════════════════════════════════════════════*/
    /*                        cfg setters                          */
    /*═════════════════════════════════════════════════════════════*/

    function testSetMinStake() external {
        uint64 newMin = 5 * ONE;
        vm.prank(CTL);
        w.setMinStake(pid, newMin);

        ( , uint64 minStake,, , , , , ) = w.protocolInfo(pid);
        assertEq(minStake, newMin, "minStake not updated");

        // Non-controller cannot call.
        vm.prank(BO);
        vm.expectRevert();
        w.setMinStake(pid, ONE);
    }

    /*═════════════════════════════════════════════════════════════*/
    /*                     createProtocol guards                   */
    /*═════════════════════════════════════════════════════════════*/

    function testCreateProtocolZeroController() external {
        vm.expectRevert("ctrl0");
        w.createProtocol(address(0), 1, ONE);
    }

    function testCreateProtocolLockWinGuard() external {
        uint64 tooLong = w.MAX_LOCK_WIN() + 1;
        vm.expectRevert("lockWin");
        w.createProtocol(ALT1, tooLong, ONE);
    }
}
