// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

/*───────────────────────────────────────────────────────────
    bad receiver – safeTransfer must revert
───────────────────────────────────────────────────────────*/
contract BadReceiver {
    /* wrong selector */
    function onERC721Received(
        address, address, uint256, bytes calldata
    ) external pure returns (bytes4) {
        return 0x0;
    }
}

/*
 *  “Left-over” scenarios:
 *  • premium = 0 happy-path
 *  • premium > 0 flow – money really lands at maker
 *  • safeTransfer to bad receiver must revert
 *  • reclaimExpired called before expiry must revert
 *  • exercising EXACT remainingAmt burns & zero-collateral event
 */
contract OptionDeskExtra is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 r; MockZRC20 q; MockZRC20 f;
    address w = address(0xDEAD);
    address b = address(0xBEEF);

    function one(uint64 v) internal pure returns (uint64[] memory a) {
        a = new uint64[](1);
        a[0] = v;
    }

    function setUp() public {
        desk = new AmeriPeanOptionDesk();
        r = new MockZRC20("R","R"); q = new MockZRC20("Q","Q"); f = new MockZRC20("F","F");
        r.mint(w, 1_000);
        q.mint(b, 1_000);
        f.mint(b, 1_000);
    }

    /*───────────────────────────────────────────────────────────
      premium = 0 – buyer should succeed without f.approve()
    ───────────────────────────────────────────────────────────*/
    function testZeroPremiumBuyFlow() public {
        vm.startPrank(w);
        r.approve(address(desk), 100);
        uint64 id = desk.postOption(r,q,f,100,50,0,
                                    uint64(block.timestamp),
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.prank(b);
        desk.buyOptions(one(id));          // no approve, no revert
        assertEq(desk.ownerOf(id), b);
    }

    /*───────────────────────────────────────────────────────────
      premium > 0 – fee token really moves to maker
    ───────────────────────────────────────────────────────────*/
    function testPremiumDelivered() public {
        vm.startPrank(w);
        r.approve(address(desk), 10);
        uint64 id = desk.postOption(r,q,f,10,5,7,
                                    uint64(block.timestamp),
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        uint64 before = f.balanceOf(w);

        vm.startPrank(b);
        f.approve(address(desk), 7);
        desk.buyOptions(one(id));
        vm.stopPrank();

        assertEq(f.balanceOf(w), before + 7);
    }

    function testSafeTransferBadReceiverReverts() public {
        BadReceiver br = new BadReceiver();

        vm.startPrank(w);
        r.approve(address(desk), 10);
        uint64 id = desk.postOption(r,q,f,10,5,0,
                                    uint64(block.timestamp),
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.startPrank(b);
        desk.buyOptions(one(id));
        vm.expectRevert(); // rcv
        desk.safeTransferFrom(b, address(br), id);
        vm.stopPrank();
    }

    /*───────────────────────────────────────────────────────────
      reclaimExpired before expiry must revert
    ───────────────────────────────────────────────────────────*/
    function testReclaimTooEarlyReverts() public {
        vm.startPrank(w);
        r.approve(address(desk), 20);
        uint64 id = desk.postOption(r,q,f,20,10,0,
                                    uint64(block.timestamp),
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.prank(b);
        desk.buyOptions(one(id));

        uint64[] memory ids = one(id);
        vm.prank(w);
        vm.expectRevert(); // time
        desk.reclaimExpired(ids);
    }

    /*───────────────────────────────────────────────────────────
      exercise EXACT remainingAmt triggers burn & CollateralReturned(…,0)
    ───────────────────────────────────────────────────────────*/
    function testExerciseExactRemaining() public {
        /* set up */
        vm.startPrank(w);
        r.approve(address(desk), 30);
        uint64 id = desk.postOption(r,q,f,30,15,0,
                                    uint64(block.timestamp),
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.startPrank(b);
        desk.buyOptions(one(id));
        q.approve(address(desk), 15);
        vm.expectEmit(true,true,false,true);
        emit AmeriPeanOptionDesk.CollateralReturned(id, b, 0);
        desk.exercise(id, 30);            // entire chunk
        assertFalse(desk.exists(id));
        vm.stopPrank();
    }
}
