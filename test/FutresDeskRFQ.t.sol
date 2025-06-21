// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_future.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

/* request / RFQ workflow */
contract FuturesDeskRFQ is Test {
    AmeriPeanFuturesDesk desk;
    MockZRC20 base; MockZRC20 quote;
    address constant requester = address(0xAAA);
    address constant writer    = address(0xBBB);

    function setUp() public {
        desk = new AmeriPeanFuturesDesk();
        base  = new MockZRC20("B","B");
        quote = new MockZRC20("Q","Q");

        base.mint(writer,     10_000);
        quote.mint(requester, 10_000);
    }

    function one(uint64 v) internal pure returns (uint64[] memory a) {
        a = new uint64[](1); a[0] = v;
    }

    /* happy-path RFQ */
    function testRFQFlow() public {
        vm.startPrank(requester);
        quote.approve(address(desk), 500);
        uint64 reqId = desk.postRequest(
            base, quote,
            100, 500,
            uint64(block.timestamp + 4 days),
            0
        );
        vm.stopPrank();

        vm.startPrank(writer);
        base.approve(address(desk), 100);
        uint64 futId = desk.acceptRequest(reqId);
        vm.stopPrank();

        /* fast-forward to settlement */
        vm.prank(requester);
        vm.warp(block.timestamp + 5 days);
        desk.settle(futId);

        assertFalse(desk.exists(futId));
        assertEq(base.balanceOf(requester), 100);
        assertEq(quote.balanceOf(writer),   500);
    }

    /* requester cancels – accept must revert */
    function testAcceptClosedReverts() public {
        vm.startPrank(requester);
        uint64 req = desk.postRequest(base,quote,10,50,
                                      uint64(block.timestamp+1 days),0);
        desk.cancelRequests(one(req));
        vm.stopPrank();

        vm.startPrank(writer);
        base.approve(address(desk),10);
        vm.expectRevert("closed");
        desk.acceptRequest(req);
    }
}
