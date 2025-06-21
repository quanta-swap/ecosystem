// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

contract OptionDeskRFQ is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 reserve; MockZRC20 quote; MockZRC20 fee;
    address constant buyer = address(0xB00);
    address constant maker = address(0xC00);

    function setUp() public {
        desk    = new AmeriPeanOptionDesk();
        reserve = new MockZRC20("RSV", "RSV");
        quote   = new MockZRC20("Q",   "Q");
        fee     = new MockZRC20("F",   "F");

        reserve.mint(maker, 1000);
        fee.mint(buyer,     100);
        quote.mint(buyer,   100);   // ← add this line
    }

    /* happy-path RFQ end-to-end */
    function testRFQFlow() public {
        vm.startPrank(buyer);
        uint64 req = desk.postRequest(
            reserve, quote, fee,
            100, 50, 1,
            uint64(block.timestamp),
            uint64(block.timestamp + 7 days),
            0
        );
        fee.approve(address(desk), 1);       // allow premium pull
        vm.stopPrank();

        vm.startPrank(maker);
        reserve.approve(address(desk), 100);
        uint64 optId = desk.acceptRequest(req);
        vm.stopPrank();

        vm.startPrank(buyer);
        quote.approve(address(desk), 50);
        desk.exercise(optId, 100);
        vm.stopPrank();

        assertFalse(desk.exists(optId));
    }

    /* requester revokes premium allowance → accept reverts */
    function testRevert_AllowanceRevoked() public {
        vm.startPrank(buyer);
        uint64 req = desk.postRequest(reserve,quote,fee,100,50,5,
                                      uint64(block.timestamp),
                                      uint64(block.timestamp+3 days),
                                      0);
        fee.approve(address(desk),5);
        fee.approve(address(desk),0);        // revoke
        vm.stopPrank();

        vm.startPrank(maker);
        reserve.approve(address(desk),100);
        vm.expectRevert("safeTF");
        desk.acceptRequest(req);
        vm.stopPrank();
    }

    /* maker tries to accept after expiry → reverts */
    function testRevert_AcceptAfterExpiry() public {
        vm.prank(buyer);
        uint64 req = desk.postRequest(reserve,quote,fee,10,5,0,
                                      uint64(block.timestamp),
                                      uint64(block.timestamp+1),
                                      0);

        vm.warp(block.timestamp + 2);        // past expiry

        vm.prank(maker);
        reserve.approve(address(desk),10);
        vm.expectRevert();
        desk.acceptRequest(req);
    }
}
