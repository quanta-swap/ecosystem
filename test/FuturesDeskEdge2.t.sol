// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_future.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

/* Extra corner-cases for AmeriPeanFuturesDesk */
contract FuturesDeskEdge4 is Test {
    AmeriPeanFuturesDesk desk;
    MockZRC20 base;
    MockZRC20 quote;

    address maker = address(0xDD1);
    address buyer = address(0xDD2);

    function setUp() public {
        desk  = new AmeriPeanFuturesDesk();
        base  = new MockZRC20("B","B");
        quote = new MockZRC20("Q","Q");

        base.mint(maker,  100_000);
        quote.mint(buyer, 100_000);
    }

    function one(uint64 v) internal pure returns (uint64[] memory arr) {
        arr = new uint64[](1); arr[0] = v;
    }

    /*─────────────────────────────────────────────
      1. settle() reverts when unsold, and when settled twice
    ─────────────────────────────────────────────*/
    function testSettleRevertsUnsoldOrTwice() public {
        /* ── unsold ── */
        vm.startPrank(maker);
        base.approve(address(desk), 10);
        uint64 id = desk.postFuture(
            base,
            quote,
            10,
            5,
            uint64(block.timestamp + 1)
        );
        vm.stopPrank();

        vm.expectRevert("unsold");
        desk.settle(id);

        /* ── buy & settle once ── */
        vm.startPrank(buyer);
        quote.approve(address(desk), 5);
        desk.buyFutures(one(id));
        vm.warp(block.timestamp + 2);
        desk.settle(id);
        vm.stopPrank();

        /* settle again → any revert is fine (“done”/“unsold”) */
        vm.expectRevert();
        desk.settle(id);
    }

    /*─────────────────────────────────────────────
      2. MAX_BATCH + 1 array on buyFutures reverts
    ─────────────────────────────────────────────*/
    function testBatchBuyLimitReverts() public {
        uint64 len = uint64(desk.MAX_BATCH() + 1);
        uint64[] memory ids = new uint64[](len);
        vm.expectRevert("batch");
        desk.buyFutures(ids);
    }

    /*─────────────────────────────────────────────
      3. requester revokes allowance → acceptRequest reverts (safeTF)
    ─────────────────────────────────────────────*/
    function testAcceptRequestAllowanceRevoked() public {
        /* buyer files RFQ and then zeroes approval */
        vm.startPrank(buyer);
        uint64 req = desk.postRequest(base,quote,10,5,
                                      uint64(block.timestamp+1 days),0);
        quote.approve(address(desk),5);
        quote.approve(address(desk),0);          // revoke
        vm.stopPrank();

        vm.startPrank(maker);
        base.approve(address(desk),10);
        vm.expectRevert("safeTF");
        desk.acceptRequest(req);
        vm.stopPrank();
    }

    /*─────────────────────────────────────────────
      4. modifyRequest actually changes quoteAmt & expiry
    ─────────────────────────────────────────────*/
    function testModifyRequestUpdates() public {
        vm.prank(buyer);
        uint64 req = desk.postRequest(base,quote,10,5,
                                      uint64(block.timestamp+5 days),0);

        vm.prank(buyer);
        desk.modifyRequest(req, 7, uint64(block.timestamp+10 days));

        (,,,,uint64 qAmt,uint64 newExp,) = desk.requestInfo(req);
        assertEq(qAmt, 7);
        assertGt(newExp, block.timestamp + 5 days);
    }

    /*─────────────────────────────────────────────
      5. reclaimExpired: maker cannot reclaim if it was SOLD
         or if caller isn’t maker
    ─────────────────────────────────────────────*/
    function testReclaimExpiredRevertsForSoldOrNotMaker() public {
        /* create + buy (so it's sold) */
        vm.startPrank(maker);
        base.approve(address(desk), 10);
        uint64 id = desk.postFuture(
            base,
            quote,
            10,
            5,
            uint64(block.timestamp + 1)
        );
        vm.stopPrank();

        vm.startPrank(buyer);
        quote.approve(address(desk), 5);
        desk.buyFutures(one(id));
        vm.stopPrank();

        vm.warp(block.timestamp + 2);

        /* maker tries reclaim → "sold" */
        vm.startPrank(maker);
        vm.expectRevert();         // any revert is fine ("sold")
        desk.reclaimExpired(one(id));
        vm.stopPrank();

        /* unsold future, but caller != maker */
        vm.startPrank(maker);
        base.approve(address(desk), 10);
        uint64 unsold = desk.postFuture(
            base,
            quote,
            10,
            5,
            uint64(block.timestamp + 1)
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2);

        vm.startPrank(buyer);
        vm.expectRevert("maker");  // must fail with "maker"
        desk.reclaimExpired(one(unsold));
        vm.stopPrank();
    }
}
