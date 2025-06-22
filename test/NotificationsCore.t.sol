// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_inform.sol";

/*────────────────────────── TEST SUITE ──────────────────────────*/
contract PushNotificationHub_Test is Test {
    PushNotificationHub hub;

    address alice   = address(0xA11);  // initial feed creator
    address bob     = address(0xB22);  // gets promoted to admin
    address charlie = address(0xC33);  // ordinary user
    address dave    = address(0xD44);  // for negative cases

    function setUp() public {
        hub = new PushNotificationHub();
    }

    /*──────────────────── FEED CREATION ───────────────────*/
    function testCreateFeed() public {
        vm.prank(alice);
        uint64 id = hub.createFeed(
            "News", "24/7 headline stream", "ipfs://icon", "https://news.com"
        );
        assertEq(id, 0);
        assertEq(hub.feedCount(), 1);

        (
            string memory title,
            string memory desc,
            string memory icon,
            string memory link,
            uint16 admins,
            uint32 subs
        ) = hub.feedInfo(0);

        assertEq(title, "News");
        assertEq(desc,  "24/7 headline stream");
        assertEq(icon,  "ipfs://icon");
        assertEq(link,  "https://news.com");
        assertEq(admins, 1);
        assertEq(subs,   0);
        assertTrue(hub.isAdmin(0, alice));
    }

    /*──────────────────── METADATA UPDATE ─────────────────*/
    function testUpdateFeed() public {
        uint64 id = _makeFeed();

        vm.prank(alice);
        hub.updateFeed(id, "Tech News", "", "", "");   // only title

        (string memory t,, , , , ) = hub.feedInfo(id);
        assertEq(t, "Tech News");
    }

    function testUpdateFeedByNonAdminReverts() public {
        uint64 id = _makeFeed();

        vm.prank(dave);
        vm.expectRevert("admin");
        hub.updateFeed(id, "x", "x", "x", "x");
    }

    /*──────────────────── ADMIN CYCLE ────────────────────*/
    function testAdminAddRemoveSwap() public {
        uint64 id = _makeFeed();

        /* add bob */
        vm.prank(alice);
        hub.addAdmin(id, bob);
        assertTrue(hub.isAdmin(id, bob));

        /* cannot add duplicate */
        vm.prank(alice);
        vm.expectRevert(); // dup
        hub.addAdmin(id, bob);

        /* swap bob → charlie */
        vm.prank(alice);
        hub.swapAdmin(id, bob, charlie);
        assertFalse(hub.isAdmin(id, bob));
        assertTrue( hub.isAdmin(id, charlie));

        /* remove alice (was first admin) */
        vm.prank(charlie);
        hub.removeAdmin(id, alice);
        assertFalse(hub.isAdmin(id, alice));

        /* removing last admin should revert */
        vm.prank(charlie);
        vm.expectRevert(); // last
        hub.removeAdmin(id, charlie);
    }

    /*──────────────────── SUBSCRIPTIONS ───────────────────*/
    function testManageSubscriptions() public {
        uint64 id1 = _makeFeed();
        uint64 id2 = _makeFeed();               // id 1

        /* charlie subscribes to both */
        uint64[] memory adds = new uint64[](2);
        adds[0] = id1;
        adds[1] = id2;
        vm.prank(charlie);
        uint64[] memory rem1 = new uint64[](0);
        hub.manageSubscriptions(rem1, adds);
        assertTrue(hub.subscribed(id1, charlie));
        assertTrue(hub.subscribed(id2, charlie));

        /* now remove id1 only */
        uint64[] memory rem2 = new uint64[](1);
        rem2[0] = id1;
        vm.prank(charlie);
        hub.manageSubscriptions(rem2, new uint64[](0));
        assertFalse(hub.subscribed(id1, charlie));
        assertTrue( hub.subscribed(id2, charlie));
    }

    function testManageSubscriptionsRevertsOnBadFeed() public {
        uint64[] memory bad = new uint64[](1);
        bad[0] = 42;                            // no such feed
        vm.prank(charlie);
        vm.expectRevert(); // feed
        hub.manageSubscriptions(bad, new uint64[](0));
    }

    /*──────────────────── PUSH NOTIFICATIONS ─────────────────*/
    function testPushNotificationMultiFeed() public {
        uint64 id0 = _makeFeed();
        uint64 id1 = _makeFeed();

        uint64[] memory ids = new uint64[](2);
        ids[0] = id0;
        ids[1] = id1;

        vm.prank(alice);
        hub.pushNotification(ids, "Alert", "Body", "https://l");

        /* non-admin must revert */
        vm.prank(dave);
        vm.expectRevert("admin");
        hub.pushNotification(ids, "x", "x", "x");
    }

    /*──────────────────── INTERNAL HELPER ──────────────────*/
    function _makeFeed() internal returns (uint64 id) {
        vm.prank(alice);
        id = hub.createFeed("T", "D", "", "");
    }
}
