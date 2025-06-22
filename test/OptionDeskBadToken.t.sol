// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";

interface IZRC20Bad is IZRC20 { function setFail(bool) external; }

contract BadToken is IZRC20Bad {
    bool fail;

    function setFail(bool b) external override {
        fail = b;
    }

    function transfer(address, uint64) external view override returns (bool) {
        return !fail;
    }

    function transferFrom(
        address,
        address,
        uint64
    ) external view override returns (bool) {
        return !fail;
    }

    function name() external pure override returns (string memory) {
        return "BadToken";
    }

    function symbol() external pure override returns (string memory) {
        return "BAD";
    }

    function decimals() external pure override returns (uint8) {
        return 8; // 10^8 (decimals = 8)
    }

    function totalSupply() external pure override returns (uint64) {
        return 0; // no supply, just a mock
    }

    function balanceOf(
        address /* account */
    ) external pure override returns (uint64) {
        return 0; // no balance, just a mock
    }

    function allowance(
        address /* owner */,
        address /* spender */
    ) external pure override returns (uint64) {
        return 0; // no allowance, just a mock
    }

    function approve(
        address spender,
        uint64 amount
    ) external override returns (bool) {
        require(!fail, "safeAP");
        emit Approval(msg.sender, spender, amount);
        return true; // always succeed
    }
}

contract OptionDeskBadToken is Test {
    AmeriPeanOptionDesk desk;
    BadToken bad; BadToken quote; BadToken fee;

    function setUp() public {
        desk   = new AmeriPeanOptionDesk();
        bad    = new BadToken();
        quote  = new BadToken();
        fee    = new BadToken();
        bad.setFail(true);                   // make reserve fail early
    }

    function testRevert_WhenReserveFailsTransfer() public {
        vm.expectRevert("safeTF");
        desk.postOption(
            bad, quote, fee,
            1,1,0,
            uint64(block.timestamp),
            uint64(block.timestamp+1)
        );
    }
}
