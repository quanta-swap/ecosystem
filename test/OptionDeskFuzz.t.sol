// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

/* fuzz: random partial exercises maintain invariant rem ≤ reserve */
contract OptionDeskFuzz is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 r; MockZRC20 q; MockZRC20 f;
    address w = address(0xA); address b = address(0xB);

    function setUp() public {
        desk = new AmeriPeanOptionDesk();
        r = new MockZRC20("R","R"); q = new MockZRC20("Q","Q"); f = new MockZRC20("F","F");
        r.mint(w, 1_000_000);
        q.mint(b, 1_000_000);
    }

    function invariant_RemainingNeverNegative() public view {
        uint n = desk.optionCount();
        for (uint64 i; i < n; ++i) {
            AmeriPeanOptionDesk.Option memory o = desk.optionInfo(i);
            assertLe(o.remainingAmt, o.reserveAmt);
        }
    }

    /* fuzz target */
    function testPartialExerciseFuzz(uint64 qty1, uint64 qty2) public {
        /* bound quantities: 1-500 each */
        qty1 = uint64(bound(qty1,1,500));
        qty2 = uint64(bound(qty2,1,500));

        vm.startPrank(w);
        r.approve(address(desk), 1000);
        uint64 id = desk.postOption(r,q,f,1000,500,0,
                                    uint64(block.timestamp),
                                    uint64(block.timestamp+7 days));
        vm.stopPrank();

        vm.startPrank(b);
        desk.buyOptions(one(id));
        q.approve(address(desk), 1000);

        if (qty1 <= 1000) desk.exercise(id, qty1);
        if (qty1 + qty2 <= 1000) desk.exercise(id, qty2);
        vm.stopPrank();
    }

    function one(uint64 v) internal pure returns (uint64[] memory a) {
        a = new uint64[](1);
        a[0] = v;
    }
}
