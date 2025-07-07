// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────────────────*\
│  WrapperTokenAdmin – admin/controller regression tests for WrappedQRL      │
\*───────────────────────────────────────────────────────────────────────────*/

import "lib/forge-std/src/Test.sol";
import {WrappedQRL} from "../src/_native.sol";

uint64 constant ONE     = 1e9;          // 1 token (9-dec)
uint256 constant WEI_ONE = ONE * 1e9;   // 1 token in wei (18-dec)

contract WrapperTokenAdmin is Test {
    /* actors */
    address internal constant CTL  = address(0xC01); // bootstrap controller
    address internal constant BO   = address(0xB02); // random user
    address internal constant ALT1 = address(0xA51);
    address internal constant ALT2 = address(0xA52);
    address internal constant ALT3 = address(0xA53);

    WrappedQRL internal w;
    uint64      pid;

    /*──────────────────────── fixture ────────────────────────*/
    function setUp() external {
        vm.deal(CTL , 40 ether);
        vm.deal(ALT1, 40 ether);
        vm.deal(ALT2, 40 ether);
        vm.deal(ALT3, 40 ether);

        w   = new WrappedQRL();
        pid = w.createProtocol(CTL, 1, ONE);  // lockWin = 1 blk, minStake = 1
    }

    /*═════════════════════════════════════════════════════════════*/
    /*                     Controller management                   */
    /*═════════════════════════════════════════════════════════════*/

    /// Non-controller callers must be rejected.
    function testAddControllerAuth() external {
        vm.prank(BO);
        vm.expectRevert();               // default revert on auth fail
        w.addController(pid, ALT1);
    }

    /// Happy-path adds until MAX_CTRL, then reverts with "full".
    function testAddControllerUpToCap() external {
        uint8 max = w.MAX_CTRL();        // public constant getter

        vm.startPrank(CTL);
        // index 0 already taken by CTL – fill 1 … max-1
        for (uint8 i = 1; i < max; ++i) {
            address a = address(uint160(0xC000 + i));
            w.addController(pid, a);

            // adding the SAME address again must revert with "dupe"
            vm.expectRevert();
            w.addController(pid, a);
        }

        // next addition exceeds the cap → "full"
        vm.expectRevert();
        w.addController(pid, ALT1);
        vm.stopPrank();
    }

    /// Removing the *last* remaining controller is forbidden.
    /// Also checks that a removed controller really loses its powers.
    function testRemoveLastControllerGuard() external {
        /* step 1: add ALT1 so we have two controllers                 */
        vm.prank(CTL);
        w.addController(pid, ALT1);

        /* step 2: ALT1 kicks CTL out – should succeed                  */
        vm.prank(ALT1);
        w.removeController(pid, CTL);

        /* NEGATIVE ASSERTION: CTL is no longer able to call controller-gated fn */
        vm.prank(CTL);
        vm.expectRevert();
        w.setMinStake(pid, 2 * ONE);

        /* step 3: ALT1 now sole controller – trying to remove itself should fail */
        vm.prank(ALT1);
        vm.expectRevert();
        w.removeController(pid, ALT1);
    }

    /// swapController: atomic replacement & old controller loses rights.
    function testSwapController() external {
        /* Add ALT1 as second controller first */
        vm.prank(CTL);
        w.addController(pid, ALT1);

        /* CTL swaps ALT1 → ALT2 */
        vm.prank(CTL);
        w.swapController(pid, ALT1, ALT2);

        /* NEGATIVE ASSERTION: ALT1 can no longer call privileged fn     */
        vm.prank(ALT1);
        vm.expectRevert();
        w.setMinStake(pid, 3 * ONE);

        /* POSITIVE: ALT2 *can* */
        vm.prank(ALT2);
        w.setMinStake(pid, 4 * ONE);

        /* swap with non-member must revert "missing"                    */
        vm.prank(CTL);
        vm.expectRevert("missing");
        w.swapController(pid, ALT1, ALT3);
    }

    /*═════════════════════════════════════════════════════════════*/
    /*                          cfg setters                        */
    /*═════════════════════════════════════════════════════════════*/

    function testSetMinStake() external {
        uint64 newMin = 5 * ONE;

        /* controller can set */
        vm.prank(CTL);
        w.setMinStake(pid, newMin);

        (, uint64 minStake, , , , , ,) = w.protocolInfo(pid);
        assertEq(minStake, newMin, "minStake not updated");

        /* non-controller rejected */
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
