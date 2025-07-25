// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "../../src/IZRC20.sol";

contract MockZRC20 is IZRC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 8; // pick whatever
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += uint64(amt);
        totalSupply += uint64(amt);
        emit Transfer(address(0), to, uint64(amt));
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amt
    ) external returns (bool) {
        uint64 a = uint64(allowance[from][msg.sender]);
        require(a >= amt, "allow");
        allowance[from][msg.sender] = a - uint64(amt);
        _move(from, to, amt);
        return true;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = uint64(amt);
        emit Approval(msg.sender, sp, uint64(amt));
        return true;
    }

    /* internal */ function _move(address f, address t, uint256 amt) private {
        require(balanceOf[f] >= amt, "bal");
        unchecked {
            balanceOf[f] -= uint64(amt);
            balanceOf[t] += uint64(amt);
        }
        emit Transfer(f, t, uint64(amt));
    }

    function checkSupportsOwner(address /* who */) external pure returns (bool) {
        return true;
    }
    function checkSupportsMover(address /* who */) external pure returns (bool) {
        return true;
    }

    function transferBatch(
        address[] calldata dst,
        uint256[] calldata wad
    ) external override returns (bool success) {}

    function transferFromBatch(
        address src,
        address[] calldata dst,
        uint256[] calldata wad
    ) external override returns (bool success) {}
}
