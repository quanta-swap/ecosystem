// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_future.sol"; // ← path to AmeriPeanFuturesDesk
import {MockZRC20} from "./mocks/MockZRC20.sol";

/* Remaining branches: validation reverts, batch settle/accept/reclaim,
   settle by maker, operator pledge, getters. */
contract FuturesDeskEdge3 is Test {
    AmeriPeanFuturesDesk desk;
    MockZRC20 base;
    MockZRC20 quote;
    MockZRC20 bad; // bad has code (passes _validateTokens)

    address maker = address(0xA0);
    address buyer = address(0xB0);
    address oper = address(0xC0);

    function one(uint64 v) internal pure returns (uint64[] memory a) {
        a = new uint64[](1);
        a[0] = v;
    }

    function setUp() public {
        desk = new AmeriPeanFuturesDesk();
        base = new MockZRC20("B", "B");
        quote = new MockZRC20("Q", "Q");
        bad = new MockZRC20("BAD", "X"); // has runtime code

        base.mint(maker, 1_000_000);
        quote.mint(buyer, 1_000_000);
    }

    /*────────────────────────────────────
      Validation REVERTS (amounts/expiry/tokens)
    ────────────────────────────────────*/
    function testRevert_PostFutureZeroAmounts() public {
        vm.prank(maker);
        base.approve(address(desk), 1);
        vm.expectRevert(); // zero
        desk.postFuture(base, quote, 0, 1, uint64(block.timestamp + 1));
    }

    function testRevert_PostFuturePastExpiry() public {
        vm.prank(maker);
        base.approve(address(desk), 1);
        vm.expectRevert("expPast");
        desk.postFuture(base, quote, 1, 1, uint64(block.timestamp - 1));
    }

    function testRevert_InvalidBaseTokenAddress() public {
        vm.expectRevert(); // base
        desk.postFuture(
            IZRC20(address(0)),
            quote,
            1,
            1,
            uint64(block.timestamp + 1)
        );
    }

    function testRevert_PostRequestZeroBase() public {
        vm.prank(buyer);
        vm.expectRevert(); // zero
        desk.postRequest(base, quote, 0, 1, uint64(block.timestamp + 1), 0);
    }

    function testRevert_PostRequestPastExpiry() public {
        vm.prank(buyer);
        vm.expectRevert(); // exp
        desk.postRequest(base, quote, 1, 1, uint64(block.timestamp - 1), 0);
    }

    /*────────────────────────────────────
      batch: settleFutures, acceptRequests, reclaimExpired
    ────────────────────────────────────*/
    function testBatchSettleFutures() public {
        uint64[] memory ids = new uint64[](3);

        /* post + buy three futures */
        vm.startPrank(maker);
        base.approve(address(desk), 300);
        for (uint64 i; i < 3; ++i) {
            ids[i] = desk.postFuture(
                base,
                quote,
                100,
                50,
                uint64(block.timestamp + 1 days)
            );
        }
        vm.stopPrank();

        vm.startPrank(buyer);
        quote.approve(address(desk), 150);
        desk.buyFutures(ids);
        vm.warp(block.timestamp + 2 days);
        desk.settleFutures(ids); // exercising batch path
        vm.stopPrank();

        assertEq(base.balanceOf(buyer), 300);
        assertEq(quote.balanceOf(maker), 150);
    }

    function testBatchAcceptRequests() public {
        uint64[] memory reqIds = new uint64[](3);

        vm.startPrank(buyer);
        quote.approve(address(desk), 300);
        for (uint64 i; i < 3; ++i) {
            reqIds[i] = desk.postRequest(
                base,
                quote,
                100,
                100,
                uint64(block.timestamp + 7 days),
                0
            );
        }
        vm.stopPrank();

        vm.startPrank(maker);
        base.approve(address(desk), 300);
        desk.acceptRequests(reqIds); // batch RFQ accept
        vm.stopPrank();

        assertEq(desk.futureCount(), 3);
    }

    function testBatchReclaimExpired() public {
        uint64[] memory ids = new uint64[](2);

        vm.startPrank(maker);
        base.approve(address(desk), 200);

        ids[0] = desk.postFuture(
            base,
            quote,
            100,
            50,
            uint64(block.timestamp + 1) // expires in 1 s
        );
        ids[1] = desk.postFuture(
            base,
            quote,
            100,
            50,
            uint64(block.timestamp + 1)
        );

        vm.warp(block.timestamp + 2); // just after expiry
        uint64 balBefore = base.balanceOf(maker);

        desk.reclaimExpired(ids); // maker reclaims both

        assertEq(base.balanceOf(maker), balBefore + 200);
        assertFalse(desk.exists(ids[0]));
        assertFalse(desk.exists(ids[1]));
        vm.stopPrank();
    }

    /*────────────────────────────────────
      settle by maker instead of holder
    ────────────────────────────────────*/
    function testSettleByMaker() public {
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

        vm.prank(maker);
        desk.settle(id); // maker can call
        assertFalse(desk.exists(id));
    }

    /*────────────────────────────────────
      pledge by approved OPERATOR
    ────────────────────────────────────*/
    function testPledgeByOperator() public {
        vm.startPrank(maker);
        base.approve(address(desk), 10);
        uint64 id = desk.postFuture(
            base,
            quote,
            10,
            5,
            uint64(block.timestamp + 1)
        );
        _approveOperator(id); // grant oper
        vm.stopPrank();

        vm.prank(oper);
        desk.pledgeFuture(id, true); // should succeed
    }

    function _approveOperator(uint64 id) internal {
        desk.setApprovalForAll(oper, true);
        assertTrue(desk.isApprovedForAll(maker, oper));
        // sanity: msg.sender==maker
    }

    /*────────────────────────────────────
      simple view getter sanity
    ────────────────────────────────────*/
    function testGetterFunctions() public {
        /* maker posts a tiny future */
        vm.startPrank(maker);
        base.approve(address(desk), 1);
        uint64 futId = desk.postFuture(
            base,  // base token
            quote, // quote token
            1,     // baseAmt
            1,     // quoteAmt
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        (
            ,                       /* maker   */
            ,                       /* holder  */
            ,                       /* base    */
            ,                       /* quote   */
            uint64 baseAmt,
            uint64 quoteAmt,
            ,                       /* expiry  */
            bool   purchased,
            ,                       /* settled */
            bool   pledged
        ) = desk.futureInfo(futId);

        assertEq(baseAmt, 1);
        assertEq(quoteAmt, 1);
        assertFalse(purchased);
        assertFalse(pledged);

        /* buyer files a request we can query */
        vm.startPrank(buyer);
        uint64 reqId = desk.postRequest(
            base,   quote,
            1,      1,
            uint64(block.timestamp + 2 days),
            0
        );
        vm.stopPrank();

        (address requester,,,,,,bool open) = desk.requestInfo(reqId);
        assertEq(requester, buyer);
        assertTrue(open);
    }
}
