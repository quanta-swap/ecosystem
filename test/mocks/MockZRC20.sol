// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "../../src/IZRC20.sol";   // adjust the relative path if needed

/// @notice Minimal in-memory token for Foundry tests.
///         • Unlimited minting via `mint()` (restricted to the test harness)  
///         • Plain balance / allowance maps (no overflow checks except require)  
///         • All amounts are uint64, matching IZRC20 semantics.
contract MockZRC20 is IZRC20 {
    /*─────────────────── metadata ───────────────────*/
    string  public override name;
    string  public override symbol;
    uint8   public constant override decimals = 8;

    /*──────────────── balances / allowances ─────────*/
    uint64 private _totalSupply;
    mapping(address => uint64)                    private _bal;
    mapping(address => mapping(address => uint64)) public override allowance;

    constructor(string memory n, string memory s) {
        name   = n;
        symbol = s;
    }

    /*────────────── testing helper ──────────────*/
    function mint(address to, uint64 amt) external {
        _totalSupply += amt;
        _bal[to]     += amt;
        emit Transfer(address(0), to, amt);
    }

    /*────────────── view functions ──────────────*/
    function totalSupply() external view override returns (uint64) {
        return _totalSupply;
    }

    function balanceOf(address a) external view override returns (uint64) {
        return _bal[a];
    }

    /*────────────── state-changing ──────────────*/
    function approve(address spender, uint64 amt) external override returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    function transfer(address to, uint64 amt) external override returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint64 amt
    ) external override returns (bool) {
        uint64 allowed = allowance[from][msg.sender];
        require(allowed >= amt, "allow");
        allowance[from][msg.sender] = allowed - amt;
        _move(from, to, amt);
        return true;
    }

    /*────────────── internal move ───────────────*/
    function _move(address from, address to, uint64 amt) private {
        require(to != address(0), "to0");
        require(_bal[from] >= amt, "bal");

        unchecked {
            _bal[from] -= amt;
            _bal[to]   += amt;
        }
        emit Transfer(from, to, amt);
    }
}
