// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

contract OptionDeskCore is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 reserve;
    MockZRC20 quote;
    MockZRC20 fee;

    address writer = address(0xBEEF);
    address buyer = address(0xCAFE);
    address other = address(0xD00D);

    /*──────────────────────── set-up ────────────────────────*/
    function setUp() public {
        desk = new AmeriPeanOptionDesk();
        reserve = new MockZRC20("Reserve", "RSV");
        quote = new MockZRC20("Quote", "QTE");
        fee = new MockZRC20("Fee", "FEE");

        reserve.mint(writer, 1_000_000);
        quote.mint(buyer, 1_000_000);
        fee.mint(buyer, 1_000_000);
    }

    /* util: singleton uint64[] without `new` */
    function one(uint64 v) internal pure returns (uint64[] memory a) {
        assembly {
            a := mload(0x40)
            mstore(a, 1)
            mstore(add(a, 0x20), v)
            mstore(0x40, add(a, 0x40))
        }
    }

    /*──── happy-path post → buy → partial + full exercise ────*/
    function testExerciseLifeCycle() public {
        vm.prank(writer);
        reserve.approve(address(desk), 120);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            120,
            60,
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 30 days)
        );

        /* buyer purchases */
        vm.startPrank(buyer);
        fee.approve(address(desk), 1);
        desk.buyOptions(one(id));
        assertEq(desk.ownerOf(id), buyer);

        /* partial exercise: 20/120 -> strike 10 */
        quote.approve(address(desk), 10);
        desk.exercise(id, 20);
        assertEq(reserve.balanceOf(buyer), 20);

        /* full exercise remaining 100 -> token burned */
        quote.approve(address(desk), 50);
        desk.exercise(id, 100);
        assertEq(desk.exists(id), false);
        assertEq(reserve.balanceOf(buyer), 120);
    }

    /*──── modifyOption can only grow collateral ───*/
    function testModifyOptionIncrease() public {
        vm.startPrank(writer);
        reserve.approve(address(desk), 150);
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

        /* +20 collateral, strike stays */
        desk.modifyOption(
            id,
            120,
            50,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 14 days)
        );

        AmeriPeanOptionDesk.Option memory o = desk.optionInfo(id);
        assertEq(o.reserveAmt, 120);
        assertEq(o.remainingAmt, 120);
    }

    function testModifyOptionHaircutRevert() public {
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
        vm.expectRevert("haircut");
        desk.modifyOption(
            id,
            90,
            50,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 7 days)
        );
    }

    /*──── cancelOption only before purchase ───*/
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
        assertEq(desk.exists(id), false);
        assertEq(reserve.balanceOf(writer), 1_000_000); // full refund
    }

    function testCancelAfterPurchaseReverts() public {
        /* create & buy */
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

        vm.startPrank(buyer);
        fee.approve(address(desk), 0);
        desk.buyOptions(one(id));
        vm.stopPrank();

        vm.prank(writer);
        vm.expectRevert(bytes("sold"));
        desk.cancelOption(id);
    }

    /*──── pledge blocks transfers & exercise ───*/
    function testPledgeLocksOption() public {
        /* post + buy */
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

        /* lock it */
        desk.pledgeOption(id, true);

        /* transfer blocked */
        vm.expectRevert("pledged");
        desk.transferFrom(buyer, other, id);

        /* exercise blocked */
        quote.approve(address(desk), 15);
        vm.expectRevert("pledged");
        desk.exercise(id, 30);
    }

    /*──── exercise window guards ───*/
    function testExerciseBeforeStartReverts() public {
        vm.prank(writer);
        reserve.approve(address(desk), 10);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            10,
            5,
            0,
            uint64(block.timestamp + 1 days),
            uint64(block.timestamp + 2 days)
        );

        vm.prank(buyer);
        desk.buyOptions(one(id));

        vm.prank(buyer);
        vm.expectRevert("window");
        desk.exercise(id, 10);
    }

    function testExerciseAfterExpiryReverts() public {
        vm.prank(writer);
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

        vm.prank(buyer);
        desk.buyOptions(one(id));
        vm.warp(block.timestamp + 2 days);

        vm.prank(buyer);
        vm.expectRevert("window");
        desk.exercise(id, 10);
    }

    /*──── reclaimExpired returns collateral ───*/
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
        vm.warp(block.timestamp + 2 days);

        uint64 before = reserve.balanceOf(writer);
        vm.prank(writer);
        desk.reclaimExpired(one(id));
        assertEq(reserve.balanceOf(writer), before + 40);
        assertEq(desk.exists(id), false);
    }

    /*──── batch size guard ───*/
    function testBatchLimitReverts() public {
        uint64[] memory ids = new uint64[](0);
        vm.prank(buyer);
        vm.expectRevert("batch");
        desk.buyOptions(ids);
    }
}
