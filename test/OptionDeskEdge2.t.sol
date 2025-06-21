// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

/* ERC-721 safeTransfer to receiver contract */
contract Receiver {
    bytes4 public lastSig;
    function onERC721Received(
        address, address, uint256, bytes calldata
    ) external returns (bytes4) {
        lastSig = IERC721Receiver.onERC721Received.selector;
        return lastSig;
    }
}

/* extra edge-cases that weren’t covered in the core suite */
contract OptionDeskEdge2 is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 r; MockZRC20 q; MockZRC20 f;

    address w = address(0xAAA);
    address b = address(0xBBB);

    /* helper */
    function one(uint64 v) internal pure returns (uint64[] memory a) {
        a = new uint64[](1);
        a[0] = v;
    }

    function setUp() public {
        desk = new AmeriPeanOptionDesk();
        r = new MockZRC20("R","R"); q = new MockZRC20("Q","Q"); f = new MockZRC20("F","F");
        r.mint(w, 1_000_000);
        q.mint(b, 1_000_000);
        f.mint(b, 1_000_000);
    }

    /* qty == 0 or > remaining must revert */
    function testRevert_ExerciseOvershoot() public {
        vm.startPrank(w);
        r.approve(address(desk), 100);
        uint64 id = desk.postOption(r,q,f,100,50,0,
                                    uint64(block.timestamp),
                                    uint64(block.timestamp+7 days));
        vm.stopPrank();

        vm.startPrank(b);
        desk.buyOptions(one(id));
        q.approve(address(desk), 100);

        vm.expectRevert();               // qty == 0
        desk.exercise(id, 0);

        vm.expectRevert();               // qty > remaining
        desk.exercise(id, 200);
        vm.stopPrank();
    }

    /* pledge toggle round-trip */
    function testPledgeToggle() public {
        vm.startPrank(w);
        r.approve(address(desk), 10);
        uint64 id = desk.postOption(r,q,f,10,5,0,
                                    uint64(block.timestamp),
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.startPrank(b);
        desk.buyOptions(one(id));

        desk.pledgeOption(id,true);
        vm.expectRevert(); desk.exercise(id,10);

        desk.pledgeOption(id,false);
        q.approve(address(desk),5);
        desk.exercise(id,10);            // now succeeds
        vm.stopPrank();
    }

    /* ERC-721 safeTransfer succeeds after re-entrancy fix */
    function testSafeTransfer() public {
        Receiver recv = new Receiver();

        vm.startPrank(w);
        r.approve(address(desk), 10);
        uint64 id = desk.postOption(
            r, q, f,
            10, 5, 0,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        vm.startPrank(b);
        desk.buyOptions(one(id));
        desk.safeTransferFrom(b, address(recv), id);  // no "reenter" revert now
        assertEq(desk.ownerOf(id), address(recv));
        assertEq(recv.lastSig(), IERC721Receiver.onERC721Received.selector);
        vm.stopPrank();
    }

    /* holder (not maker) can reclaim after expiry */
    function testHolderReclaimExpired() public {
        vm.startPrank(w);
        r.approve(address(desk), 20);
        uint64 id = desk.postOption(
            r, q, f,
            20, 10, 0,
            uint64(block.timestamp),                  // start now
            uint64(block.timestamp + 1 days)          // expires in a day
        );
        vm.stopPrank();

        vm.startPrank(b);
        desk.buyOptions(one(id));                     // holder = buyer
        vm.warp(block.timestamp + 2 days);            // after expiry
        uint64[] memory ids = one(id);
        desk.reclaimExpired(ids);                     // should succeed
        assertFalse(desk.exists(id));
        vm.stopPrank();
    }

    /* strike × qty hit uint64 max without overflow */
    function testRoundingEdge() public {
        uint64 max   = type(uint64).max;
        uint64 coll  = 1_000_000;
        uint64 strike = max / coll;                   // floor

        vm.startPrank(w);
        r.approve(address(desk), coll);
        uint64 id = desk.postOption(
            r, q, f,
            coll, strike, 0,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        /* mint exactly the remaining gap to uint64 max */
        vm.startPrank(b);
        uint64 gap = max - q.balanceOf(b);
        q.mint(b, gap);                               // will not overflow totalSupply
        q.approve(address(desk), max);
        desk.buyOptions(one(id));
        desk.exercise(id, coll);                      // must not overflow
        vm.stopPrank();
    }
}
