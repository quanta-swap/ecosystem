// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_future.sol";              // ← adjust if the filename differs
import {MockZRC20} from "./mocks/MockZRC20.sol";

/*─────────────────────────────────────────────────────────────
│  Core flow: post, modify, cancel, buy, pledge, settle,
│  reclaimExpired, batch-limit, and early-settle guard.
└────────────────────────────────────────────────────────────*/
contract FuturesDeskCore is Test {
    AmeriPeanFuturesDesk desk;
    MockZRC20 base;      // short locks this
    MockZRC20 quote;     // long posts this
    address constant maker = address(0xA11A);
    address constant buyer = address(0xB22B);
    address constant other = address(0xC33C);

    function setUp() public {
        desk  = new AmeriPeanFuturesDesk();
        base  = new MockZRC20("BASE","B");
        quote = new MockZRC20("Q","Q");

        base.mint(maker,  1_000_000);
        quote.mint(buyer, 1_000_000);
    }

    /* tiny helper */
    function one(uint64 v) internal pure returns (uint64[] memory a) {
        a = new uint64[](1); a[0] = v;
    }

    /*─────────────────────────────────────────────────────────
      happy-path: post → buy → settle after expiry
    ─────────────────────────────────────────────────────────*/
    function testBuyAndSettle() public {
        vm.startPrank(maker);
        base.approve(address(desk), 100);
        uint64 id = desk.postFuture(
            base, quote,
            100,    // baseAmt
            50,     // quoteAmt
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        vm.startPrank(buyer);
        quote.approve(address(desk), 50);
        desk.buyFutures(one(id));
        assertEq(desk.ownerOf(id), buyer);

        vm.warp(block.timestamp + 2 days);
        desk.settle(id);
        vm.stopPrank();

        /* token burned and payouts correct */
        assertFalse(desk.exists(id));
        assertEq(base.balanceOf(buyer), 100);
        assertEq(quote.balanceOf(maker), 50);
    }

    /*─────────────────────────────────────────────────────────
      modifyFuture can grow OR shrink collateral when unsold
    ─────────────────────────────────────────────────────────*/
    function testModifyIncreaseThenDecrease() public {
        /* post 80-> 100 */
        vm.startPrank(maker);
        base.approve(address(desk), 100);
        uint64 id = desk.postFuture(base,quote,80,40,
                                    uint64(block.timestamp+1 days));

        desk.modifyFuture(id, 100, 40, uint64(block.timestamp+2 days));
        assertEq(base.balanceOf(maker), 1_000_000 - 100);   // sent +20

        /* now shrink back 60  (desk must refund 40) */
        desk.modifyFuture(id, 60, 30, uint64(block.timestamp+3 days));
        assertEq(base.balanceOf(maker), 1_000_000 - 60);    // got 40 back
        vm.stopPrank();
    }

    function testModifyAfterPurchaseReverts() public {
        vm.startPrank(maker);
        base.approve(address(desk), 50);
        uint64 id = desk.postFuture(base,quote,50,25,
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.startPrank(buyer);
        quote.approve(address(desk),25);
        desk.buyFutures(one(id));
        vm.stopPrank();

        vm.prank(maker);
        vm.expectRevert(); // sold
        desk.modifyFuture(id, 60,30,uint64(block.timestamp+2 days));
    }

    /*─────────────────────────────────────────────────────────
      cancel unsold future refunds collateral
    ─────────────────────────────────────────────────────────*/
    function testCancelFlow() public {
        vm.startPrank(maker);
        base.approve(address(desk),10);
        uint64 id = desk.postFuture(base,quote,10,5,
                                    uint64(block.timestamp+1 days));
        desk.cancelFuture(id);
        vm.stopPrank();

        assertFalse(desk.exists(id));
        assertEq(base.balanceOf(maker), 1_000_000); // full refund
    }

    function testCancelAfterPurchaseReverts() public {
        vm.startPrank(maker);
        base.approve(address(desk),10);
        uint64 id = desk.postFuture(base,quote,10,5,
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.startPrank(buyer);
        quote.approve(address(desk),5);
        desk.buyFutures(one(id));
        vm.stopPrank();

        vm.prank(maker);
        vm.expectRevert(); // sold
        desk.cancelFuture(id);
    }

    /*─────────────────────────────────────────────────────────
      pledge lock blocks transfers
    ─────────────────────────────────────────────────────────*/
    function testPledgeBlocksTransfer() public {
        vm.startPrank(maker);
        base.approve(address(desk),10);
        uint64 id = desk.postFuture(base,quote,10,5,
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.startPrank(buyer);
        quote.approve(address(desk),5);
        desk.buyFutures(one(id));
        desk.pledgeFuture(id,true);

        vm.expectRevert("pledged");
        desk.transferFrom(buyer,other,id);

        desk.pledgeFuture(id,false);
        desk.transferFrom(buyer,other,id);   // succeeds
        vm.stopPrank();
    }

    /*─────────────────────────────────────────────────────────
      settle early reverts
    ─────────────────────────────────────────────────────────*/
    function testSettleEarlyReverts() public {
        vm.startPrank(maker);
        base.approve(address(desk),10);
        uint64 id = desk.postFuture(base,quote,10,5,
                                    uint64(block.timestamp+1 days));
        vm.stopPrank();

        vm.startPrank(buyer);
        quote.approve(address(desk),5);
        desk.buyFutures(one(id));
        vm.expectRevert("early");
        desk.settle(id);
        vm.stopPrank();
    }

    /*─────────────────────────────────────────────────────────
      maker can reclaim unsold futures after expiry
    ─────────────────────────────────────────────────────────*/
    function testReclaimExpired() public {
        vm.startPrank(maker);
        base.approve(address(desk),20);
        uint64 id = desk.postFuture(base,quote,20,10,
                                    uint64(block.timestamp+1 days));
        vm.warp(block.timestamp + 2 days);          // after expiry
        uint64[] memory ids = one(id);
        uint64 pre = base.balanceOf(maker);
        desk.reclaimExpired(ids);
        vm.stopPrank();

        assertEq(base.balanceOf(maker), pre + 20);
        assertFalse(desk.exists(id));
    }

    /* batch guard */
    function testBatchLimitReverts() public {
        uint64 len = uint64(desk.MAX_BATCH() + 1);
        uint64[] memory ids = new uint64[](len);
        vm.expectRevert("batch");
        desk.buyFutures(ids);
    }
}
