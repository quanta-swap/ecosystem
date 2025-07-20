// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "../../src/IZRC20.sol";

contract MockZRC20 is IZRC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 8; // pick whatever
    uint64 public totalSupply;

    mapping(address => uint64) public balanceOf;
    mapping(address => mapping(address => uint64)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint64 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
        emit Transfer(address(0), to, amt);
    }

    function transfer(address to, uint64 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint64 amt
    ) external returns (bool) {
        uint64 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
        return true;
    }

    function approve(address sp, uint64 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        emit Approval(msg.sender, sp, amt);
        return true;
    }

    /* internal */ function _move(address f, address t, uint64 amt) private {
        require(balanceOf[f] >= amt, "bal");
        unchecked {
            balanceOf[f] -= amt;
            balanceOf[t] += amt;
        }
        emit Transfer(f, t, amt);
    }

    function checkSupportsOwner(address /* who */) external pure returns (bool) {
        return true;
    }
    function checkSupportsMover(address /* who */) external pure returns (bool) {
        return true;
    }

    function transferBatch(
        address[] calldata dst,
        uint64[] calldata wad
    ) external override returns (bool success) {}

    function transferFromBatch(
        address src,
        address[] calldata dst,
        uint64[] calldata wad
    ) external override returns (bool success) {}
}
