// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";               // ← adjust path to your option desk
import {MockZRC20} from "./mocks/MockZRC20.sol";

contract OptionDeskTest is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 reserve;
    MockZRC20 quote;
    MockZRC20 fee;

    address writer = address(0xBEEF);
    address buyer  = address(0xCAFE);

    /*──────────────────────────── setup ────────────────────────────*/
    function setUp() public {
        desk    = new AmeriPeanOptionDesk();
        reserve = new MockZRC20("Reserve","RSV");
        quote   = new MockZRC20("Quote","QTE");
        fee     = new MockZRC20("Fee","FEE");

        reserve.mint(writer, 1_000_000);
        quote.mint(buyer,    1_000_000);
        fee.mint(buyer,      1_000_000);
    }

    /*───────────────────────── helpers ─────────────────────────────*/
    /// @dev Returns a one-element dynamic array containing `v` **without** using `new`.
    function one(uint64 v) internal pure returns (uint64[] memory out) {
        assembly {
            // ──────── Dynamic array memory layout ─────────
            // [0x00] length (uint256, here 1)
            // [0x20] element 0 (padded to 32 bytes)

            out := mload(0x40)          // grab the free-memory pointer
            mstore(out, 1)              // store length = 1
            mstore(add(out, 0x20), v)   // store the uint64 (rest is zero-padded)
            mstore(0x40, add(out, 0x40))// bump free-memory pointer past 2 words
        }
    }

    /*───────────────────────── tests ───────────────────────────────*/

    /// @notice happy-path: post → buy → partial exercise
    function testPostBuyExercise() public {
        /* writer posts */
        vm.startPrank(writer);
        reserve.approve(address(desk), 100);
        uint64 id = desk.postOption(
            reserve,
            quote,
            fee,
            100,                        // reserveAmt
            50,                         // strikeAmt
            1,                          // premium
            uint64(block.timestamp),    // start now
            uint64(block.timestamp + 30 days)
        );
        vm.stopPrank();

        /* buyer purchases */
        vm.startPrank(buyer);
        fee.approve(address(desk), 1);
        desk.buyOptions(one(id));               // ← dynamic array
        assertEq(desk.ownerOf(id), buyer);

        /* exercise 60 units */
        quote.approve(address(desk), 30);        // strikePay = 60*50/100 = 30
        desk.exercise(id, 60);
        vm.stopPrank();

        /* collateral transferred */
        assertEq(reserve.balanceOf(buyer), 60);
    }

    /// @notice should revert if option is pledged before purchase
    function testRevert_PledgedCannotBuy() public {
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
            uint64(block.timestamp + 7 days)
        );
        desk.pledgeOption(id, true);             // lock it
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert("pledged");
        desk.buyOptions(one(id));
    }
}
