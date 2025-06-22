// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "./IZRC20.sol";

contract TradesPerDayToken is IZRC20 {
    /*──────── token metadata (immutable) ────────*/
    string private _name;
    string private _symbol;
    uint8 public constant override decimals = 8;
    uint64 private constant ONE_TOKEN = 10 ** 8;

    /*──────── account storage: 160 bits per holder ────────
      struct Layout
       | uint64 balance | uint64 locked | uint32 window |
    ────────────────────────────────────────────────────*/
    struct Account {
        uint64 bal;
        uint64 locked;
        uint32 win;
    }
    mapping(address => Account) private _acct;

    /*──────── allowances ────────*/
    mapping(address => mapping(address => uint64)) private _allow;

    /*──────── supply & admin set ────────*/
    uint64 private _tot;
    mapping(address => bool) public isAdmin;
    uint16 private _adminCount;

    /*──────── constructor ────────*/
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
        isAdmin[msg.sender] = true;
        _adminCount = 1;
        emit AdminAdded(msg.sender);
    }

    /* "...but not everyone bowed to this power!" */
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=Xszx_9UPwV8";
    }

    /*──────── IZRC-20 view functions ────────*/
    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function totalSupply() external view override returns (uint64) {
        return _tot;
    }

    function balanceOf(address a) external view override returns (uint64) {
        return _acct[a].bal;
    }

    function allowance(
        address o,
        address s
    ) external view override returns (uint64) {
        return _allow[o][s];
    }

    /*──────── admin-only modifier ────────*/
    modifier onlyAdmin() {
        require(isAdmin[msg.sender], "not admin");
        _;
    }

    /*──────── transfer logic ────────*/
    function transfer(
        address to,
        uint64 value
    ) external override returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function approve(
        address spender,
        uint64 value
    ) external override returns (bool) {
        _allow[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint64 value
    ) external override returns (bool) {
        uint64 cur = _allow[from][msg.sender];
        if (cur != type(uint64).max) {
            require(cur >= value, "allow");
            unchecked {
                _allow[from][msg.sender] = cur - value;
            }
            emit Approval(from, msg.sender, cur - value);
        }
        _move(from, to, value);
        return true;
    }

    /* internal transfer with lock-check */
    function _move(address from, address to, uint64 value) internal {
        require(to != address(0), "zero");

        Account storage src = _acct[from];
        uint64 lockedNow = (src.win == _curWin()) ? src.locked : 0;
        require(src.bal - lockedNow >= value, "locked/balance");

        unchecked {
            src.bal -= value;
            _acct[to].bal += value;
        }
        emit Transfer(from, to, value);
    }

    /*──────── mint / burn ────────*/
    function mint(address to, uint64 value) external onlyAdmin {
        require(to != address(0), "zero");
        unchecked {
            uint64 ns = _tot + value;
            require(ns >= _tot, "overflow");
            _tot = ns;
            _acct[to].bal += value;
        }
        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint64 value) external onlyAdmin {
        Account storage a = _acct[from];
        require(a.bal >= value, "balance");
        unchecked {
            a.bal -= value;
            _tot -= value;
        }
        emit Transfer(from, address(0), value);
    }

    /*──────── daily additive lock ────────*/
    event Locked(
        address indexed account,
        uint64 totalLockedToday,
        uint32 window
    );

    /// Freeze `amount` more tokens of `acct` for the rest of the current UTC day
    function lock(address acct, uint64 amount) external onlyAdmin {
        require(acct != address(0), "zero");
        require(amount > 0 && amount <= ONE_TOKEN, ">1 token per call");

        Account storage a = _acct[acct];
        uint32 w = _curWin();

        // If we’re in a new day, previous lock evaporates
        uint64 currentLocked = (a.win == w) ? a.locked : 0;

        // Ensure the account has enough unlocked balance to cover this new lock
        require(a.bal - currentLocked >= amount, "not enough unlocked");

        unchecked {
            a.locked = currentLocked + amount; // may exceed ONE_TOKEN over multiple calls
        }
        a.win = w; // stamp today’s window

        emit Locked(acct, a.locked, w);
    }

    function lockedBalanceOf(address acct) external view returns (uint64) {
        Account storage a = _acct[acct];
        return (a.win == _curWin()) ? a.locked : 0;
    }

    /*──────── admin management ────────*/
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event AdminSwapped(address indexed oldAdmin, address indexed newAdmin);

    function addAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0) && !isAdmin[newAdmin], "bad");
        isAdmin[newAdmin] = true;
        _adminCount += 1;
        emit AdminAdded(newAdmin);
    }

    function removeAdmin(address admin) external onlyAdmin {
        require(isAdmin[admin], "not admin");
        require(_adminCount > 1, "last admin");
        isAdmin[admin] = false;
        _adminCount -= 1;
        emit AdminRemoved(admin);
    }

    function swapAdmin(address oldAdmin, address newAdmin) external onlyAdmin {
        require(isAdmin[oldAdmin], "old not admin");
        require(newAdmin != address(0) && !isAdmin[newAdmin], "bad new");
        isAdmin[oldAdmin] = false;
        isAdmin[newAdmin] = true;
        emit AdminSwapped(oldAdmin, newAdmin);
    }

    function getAdminCount() external view returns (uint256) {
        return _adminCount;
    }

    /*──────── utility ────────*/
    function _curWin() internal view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }
}
