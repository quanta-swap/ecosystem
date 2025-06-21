// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

/*─────────────────────────────────────────────────────────────
│  Core behaviour: posting, buying, modifying, exercising,
│  pledging, expiry reclaim, and batch-limit guard.
└────────────────────────────────────────────────────────────*/
contract OptionDeskCore is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 reserve;
    MockZRC20 quote;
    MockZRC20 fee;

    address constant writer = address(0xBEEF);
    address constant buyer = address(0xCAFE);
    address constant other = address(0xD00D);

    /*──────────── utility: singleton uint64[] without `new` ────────────*/
    function one(uint64 v) internal pure returns (uint64[] memory a) {
        uint64[] memory one_ = new uint64[](1);
        one_[0] = v;
        return one_;
    }

    /*──────────── set-up ────────────*/
    function setUp() public {
        desk = new AmeriPeanOptionDesk();
        reserve = new MockZRC20("Reserve", "RSV");
        quote = new MockZRC20("Quote", "QTE");
        fee = new MockZRC20("Fee", "FEE");

        reserve.mint(writer, 1_000_000);
        quote.mint(buyer, 1_000_000);
        fee.mint(buyer, 1_000_000);
    }

    /*─────────────────────────────────────────────────────────────
    |  HAPPY PATH: post → buy → partial then full exercise
    |────────────────────────────────────────────────────────────*/
    /*─────────────────────────────────────────────────────────────
    |  post → buy → partial exercise → full exercise
    └────────────────────────────────────────────────────────────*/
    function testExerciseLifeCycle() public {
        /* writer posts */
        vm.startPrank(writer);
        reserve.approve(address(desk), 120);
        uint64 id = desk.postOption(
            reserve, quote, fee,
            120, 60, 1,
            uint64(block.timestamp),
            uint64(block.timestamp + 30 days)
        );
        vm.stopPrank();

        /* buyer does every subsequent step in a single prank */
        vm.startPrank(buyer);

        fee.approve(address(desk), 1);
        desk.buyOptions(one(id));
        assertEq(desk.ownerOf(id), buyer);

        /* partial exercise: 20 (strikePay = 10) */
        quote.approve(address(desk), 10);
        desk.exercise(id, 20);
        assertEq(reserve.balanceOf(buyer), 20);

        /* full exercise of remaining 100 (strikePay = 50) */
        quote.approve(address(desk), 50);
        desk.exercise(id, 100);

        /* token is burned, all collateral delivered */
        assertFalse(desk.exists(id));
        assertEq(reserve.balanceOf(buyer), 120);

        vm.stopPrank();
    }

    /*────────────────────────────────
    |  modifyOption can only INCREASE collateral
    ────────────────────────────────*/
    function testModifyOptionIncrease() public {
        vm.startPrank(writer);
        reserve.approve(address(desk), 150); // room for a top-up
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            100,
            50,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 7 days)
        );

        desk.modifyOption(
            id,
            120,
            50,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 14 days)
        );
        vm.stopPrank();

        AmeriPeanOptionDesk.Option memory o = desk.optionInfo(id);
        assertEq(o.reserveAmt, 120);
        assertEq(o.remainingAmt, 120);
    }

    function testModifyOptionHaircutReverts() public {
        vm.startPrank(writer);
        reserve.approve(address(desk), 100);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            100,
            50,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 7 days)
        );
        vm.expectRevert(); // any revert is fine
        desk.modifyOption(
            id,
            90,
            50,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 7 days)
        );
        vm.stopPrank();
    }

    /*────────────────────────────────
    |  cancelOption only before purchase
    ────────────────────────────────*/
    function testCancelOptionFlow() public {
        vm.startPrank(writer);
        reserve.approve(address(desk), 50);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            50,
            25,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 7 days)
        );
        desk.cancelOption(id);
        vm.stopPrank();

        assertFalse(desk.exists(id));
        assertEq(reserve.balanceOf(writer), 1_000_000); // full refund
    }

    function testCancelAfterPurchaseReverts() public {
        /* writer posts */
        vm.startPrank(writer);
        reserve.approve(address(desk), 50);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            50,
            25,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 7 days)
        );
        vm.stopPrank();

        /* buyer buys */
        vm.startPrank(buyer);
        desk.buyOptions(one(id));
        vm.stopPrank();

        /* writer tries to cancel */
        vm.startPrank(writer);
        vm.expectRevert();
        desk.cancelOption(id);
        vm.stopPrank();
    }

    /*────────────────────────────────
    |  pledge lock blocks transfers and exercise
    ────────────────────────────────*/
    function testPledgeLocksOption() public {
        vm.startPrank(writer);
        reserve.approve(address(desk), 30);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            30,
            15,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days)
        );
        vm.stopPrank();

        vm.startPrank(buyer);
        desk.buyOptions(one(id));
        desk.pledgeOption(id, true); // lock

        vm.expectRevert(); // transfer blocked
        desk.transferFrom(buyer, other, id);

        quote.approve(address(desk), 15);
        vm.expectRevert(); // exercise blocked
        desk.exercise(id, 30);
        vm.stopPrank();
    }

    /*────────────────────────────────
    |  exercise window guards
    ────────────────────────────────*/
    function testExerciseBeforeStartReverts() public {
        vm.startPrank(writer);
        reserve.approve(address(desk), 10);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            10,
            5,
            0,
            uint64(block.timestamp + 1 days), // starts tomorrow
            uint64(block.timestamp + 2 days)
        );
        vm.stopPrank();

        vm.startPrank(buyer);
        desk.buyOptions(one(id));
        quote.approve(address(desk), 5); // allowance irrelevant
        vm.expectRevert();
        desk.exercise(id, 10);
        vm.stopPrank();
    }

    function testExerciseAfterExpiryReverts() public {
        vm.startPrank(writer);
        reserve.approve(address(desk), 10);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            10,
            5,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        vm.startPrank(buyer);
        desk.buyOptions(one(id));
        vm.warp(block.timestamp + 2 days); // after expiry
        quote.approve(address(desk), 5);
        vm.expectRevert();
        desk.exercise(id, 10);
        vm.stopPrank();
    }

    /*────────────────────────────────
    |  reclaimExpired returns un-exercised collateral
    ────────────────────────────────*/
    function testReclaimExpired() public {
        vm.startPrank(writer);
        reserve.approve(address(desk), 40);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            40,
            20,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days); // jump past expiry

        uint64[] memory ids = one(id);
        vm.startPrank(writer);
        uint64 pre = reserve.balanceOf(writer);
        desk.reclaimExpired(ids);
        assertEq(reserve.balanceOf(writer), pre + 40);
        assertFalse(desk.exists(id));
        vm.stopPrank();
    }

    /*────────────────────────────────
    |  batch-size guard
    ────────────────────────────────*/
    function testBatchLimitReverts() public {
        uint64 len = uint64(desk.MAX_BATCH() + 1);
        uint64[] memory ids = new uint64[](len);

        vm.startPrank(buyer);
        vm.expectRevert();
        desk.buyOptions(ids);
        vm.stopPrank();
    }

    function testRFQFlow() public {
        /* requester posts */
        vm.startPrank(buyer);
        uint64 reqId = desk.postRequest(
            reserve, quote, fee,
            100, 50, 1,
            uint64(block.timestamp),
            uint64(block.timestamp + 7 days),
            0
        );
        fee.approve(address(desk), 1);   // ← allow desk to pull the premium
        vm.stopPrank();

        /* maker accepts */
        vm.startPrank(writer);
        reserve.approve(address(desk), 100);
        uint64 optId = desk.acceptRequest(reqId);
        vm.stopPrank();

        /* requester exercises … */
        vm.startPrank(buyer);
        quote.approve(address(desk), 50);
        desk.exercise(optId, 100);
        vm.stopPrank();
    }
}
