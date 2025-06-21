// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_token.sol";

/*────────────────────────── TEST SUITE ──────────────────────────*/
contract TradesPerDayToken_Test is Test {
    TradesPerDayToken tok;

    address admin = address(0xA11);
    address alice = address(0xB22);
    address bob   = address(0xC33);

    uint64 constant ONE = 1e8; // 10^8 (decimals = 8)

    function setUp() public {
        vm.prank(admin);
        tok = new TradesPerDayToken("Trades/Day","FREE");
    }

    /*──────────────────── DEPLOY / METADATA ───────────────────*/
    function testMetadata() public view {
        assertEq(tok.name(),  "Trades/Day");
        assertEq(tok.symbol(),"FREE");
        assertEq(tok.decimals(), 8);
        assertEq(tok.totalSupply(), 0);
        assertEq(tok.getAdminCount(), 1);
        assertTrue(tok.isAdmin(admin));
    }

    /*──────────────────── ADMIN MANAGEMENT ───────────────────*/
    function testAddAndRemoveAdmin() public {
        vm.prank(admin);
        tok.addAdmin(alice);
        assertTrue(tok.isAdmin(alice));
        assertEq(tok.getAdminCount(), 2);

        /* remove second admin – allowed */
        vm.prank(admin);
        tok.removeAdmin(alice);
        assertFalse(tok.isAdmin(alice));
        assertEq(tok.getAdminCount(), 1);
    }

    function testRemoveLastAdminReverts() public {
        vm.prank(admin);
        vm.expectRevert("last admin");
        tok.removeAdmin(admin);
    }

    function testSwapAdmin() public {
        vm.prank(admin);
        tok.swapAdmin(admin, alice);
        assertFalse(tok.isAdmin(admin));
        assertTrue(tok.isAdmin(alice));
        assertEq(tok.getAdminCount(), 1);
    }

    /*──────────────────── MINT / BURN ───────────────────*/
    function testMintBurnByAdmin() public {
        vm.prank(admin);
        tok.mint(alice, 5 * ONE);
        assertEq(tok.balanceOf(alice), 5*ONE);
        assertEq(tok.totalSupply(),    5*ONE);

        vm.prank(admin);
        tok.burn(alice, 2 * ONE);
        assertEq(tok.balanceOf(alice), 3*ONE);
        assertEq(tok.totalSupply(),    3*ONE);
    }

    function testMintByNonAdminReverts() public {
        vm.prank(alice);
        vm.expectRevert("not admin");
        tok.mint(alice, ONE);
    }

    /*──────────────────── TRANSFERS ───────────────────*/
    function _mintToAlice(uint64 amt) internal {
        vm.prank(admin);
        tok.mint(alice, amt);
    }

    function testTransferBare() public {
        _mintToAlice(10*ONE);

        vm.prank(alice);
        tok.transfer(bob, 4*ONE);
        assertEq(tok.balanceOf(alice), 6*ONE);
        assertEq(tok.balanceOf(bob),   4*ONE);
    }

    function testApproveAndTransferFrom() public {
        _mintToAlice(3*ONE);

        vm.prank(alice);
        tok.approve(bob, 2*ONE);

        vm.prank(bob);
        tok.transferFrom(alice, bob, 2*ONE);

        assertEq(tok.balanceOf(alice), ONE);
        assertEq(tok.balanceOf(bob),   2*ONE);
        assertEq(tok.allowance(alice,bob), 0);
    }

    function testTransferFromInfiniteAllowance() public {
        _mintToAlice(5*ONE);

        vm.prank(alice);
        tok.approve(bob, type(uint64).max);

        vm.prank(bob);
        tok.transferFrom(alice, bob, 3*ONE);

        assertEq(tok.balanceOf(alice), 2*ONE);
        assertEq(tok.allowance(alice,bob), type(uint64).max); // unchanged
    }

    /*──────────────────── LOCK MECHANICS ───────────────────*/
    function testDailyLockBlocksTransferButResets() public {
        _mintToAlice(2*ONE);

        /* lock 1 token today */
        vm.prank(admin);
        tok.lock(alice, ONE);

        /* cannot move the locked amount */
        vm.startPrank(alice);
        vm.expectRevert("locked/balance");
        tok.transfer(bob, 2*ONE);
        /* but can move the unlocked remainder */
        tok.transfer(bob, ONE); // 1 left locked
        vm.stopPrank();

        /* warp to next UTC day ⇒ lock evaporates */
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        tok.transfer(bob, ONE); // now allowed
        assertEq(tok.balanceOf(bob), 2*ONE);
    }

    function testLockMultipleTimesSameDay() public {
        _mintToAlice(5 * ONE);

        /* first 1-token lock */
        vm.prank(admin);
        tok.lock(alice, ONE);

        /* second 1-token lock – still within per-call limit */
        vm.prank(admin);
        tok.lock(alice, ONE);

        assertEq(tok.lockedBalanceOf(alice), 2 * ONE, "cumulative lock wrong");

        /* alice now has 5-2 = 3 unlocked; transferring 4 should revert */
        vm.prank(alice);
        vm.expectRevert("locked/balance");
        tok.transfer(bob, 4 * ONE);

        /* transferring exactly the unlocked amount succeeds */
        vm.prank(alice);
        tok.transfer(bob, 3 * ONE);
        assertEq(tok.balanceOf(bob), 3 * ONE);
    }

    function testLockRevertsOnOverDailyAmount() public {
        vm.prank(admin);
        vm.expectRevert(">1 token per call");
        tok.lock(alice, ONE + 1);
    }

    function testLockRevertsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("not admin");
        tok.lock(alice, ONE);
    }

    function testLockRequiresEnoughUnlockedBalance() public {
        _mintToAlice(ONE); // exactly 1

        vm.prank(admin);
        tok.lock(alice, ONE);

        /* try to lock again – no unlocked balance left */
        vm.prank(admin);
        vm.expectRevert("not enough unlocked");
        tok.lock(alice, 1);
    }

    function testTransferRevertsToZero() public {
        _mintToAlice(ONE);
        vm.prank(alice);
        vm.expectRevert(); // zero
        tok.transfer(address(0), ONE);
    }
}
