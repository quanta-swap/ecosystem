pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

contract OptionDeskRFQEdge is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 reserve; MockZRC20 quote; MockZRC20 fee;
    address buyer = address(0xB00);
    address maker = address(0xC00);

    function setUp() public {
        desk    = new AmeriPeanOptionDesk();
        reserve = new MockZRC20("RSV","RSV");
        quote   = new MockZRC20("Q","Q");
        fee     = new MockZRC20("F","F");

        reserve.mint(maker, 100);
        fee.mint(buyer,    10);
    }

    function testRevert_RequesterRevokesPremiumAllowance() public {
        /* requester posts and approves, then revokes */
        vm.startPrank(buyer);
        uint64 req = desk.postRequest(reserve, quote, fee,
                                      100, 50, 5,
                                      uint64(block.timestamp),
                                      uint64(block.timestamp+1 days),
                                      0);
        fee.approve(address(desk), 5);
        fee.approve(address(desk), 0);          // revoke
        vm.stopPrank();

        /* maker tries to accept */
        vm.startPrank(maker);
        reserve.approve(address(desk), 100);
        vm.expectRevert("safeTF");
        desk.acceptRequest(req);
    }
}