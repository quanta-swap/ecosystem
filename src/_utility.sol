// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*═══════════════════════════════════════════════════════════════════════*\
│                           IZRC-20 interface (64-bit)                   │
\*═══════════════════════════════════════════════════════════════════════*/
import {IZRC20} from "./IZRC20.sol";

/*══════════════════════════════ Custom errors ═════════════════════════*/
/// Zero address supplied where non-zero required.
error ZeroAddress(address addr);

/// Batch array lengths differ.
error LengthMismatch(uint256 lenA, uint256 lenB);

/// Batch aggregate would overflow 2⁶⁴-1.
error SumOverflow(uint256 sum);

/// Unlocked balance < needed.
error InsufficientUnlocked(uint64 unlocked, uint64 needed);

/// Allowance < needed.
error InsufficientAllowance(uint64 allowance, uint64 needed);

/// Caller is not an authorised locker for the holder.
error UnauthorizedLocker(address holder, address caller);

/// lockTime must be > 0.
error LockTimeZero();

/*──────── events ────────*/
event LockerSet(address indexed holder, address indexed locker, bool approved);
event TokensLocked(
    address indexed holder,
    address indexed locker,
    uint64 amount,
    uint64 epoch
);

/*═══════════════════════════════════════════════════════════════════════*\
│  StandardUtilityToken – fixed-supply IZRC-20 with epoch-locking ACL     │
\*═══════════════════════════════════════════════════════════════════════*/
contract StandardUtilityToken is IZRC20 {
    /*──────── metadata ────────*/
    uint8 private _decimals;
    string private _name;
    string private _symbol;

    /*──────── global constant ────────*/
    /// Seconds per lock window (immutable, > 0).
    uint32 public immutable lockTime;

    /*──────── locker registry ────────*/
    /// holder → (locker → approved)
    mapping(address => mapping(address => bool)) private _locker;

    /*──────── supply & accounts ────────*/
    uint64 private _tot; // fixed supply

    struct Account {
        uint64 balance; // total tokens
        uint64 locked; // still locked in *current* window
        uint64 window; // epoch number the locked figure refers to
    }
    mapping(address => Account) private _acct;

    /*──────────────────────── constructor ────────────────────────*/
    constructor(
        string memory name_,
        string memory symbol_,
        uint64 supply64,
        uint8 decs,
        uint32 lockTime_,
        address root
    ) {
        if (lockTime_ == 0) revert LockTimeZero();

        _name = name_;
        _symbol = symbol_;
        _decimals = decs;
        lockTime = lockTime_;

        _tot = supply64;
        _acct[root].balance = supply64;
        emit Transfer(address(0), msg.sender, supply64);
    }

    /*═══════════════  Locker administration  ══════════════*/
    function setLocker(address locker, bool approved) external {
        if (locker == address(0)) revert ZeroAddress(locker);
        _locker[msg.sender][locker] = approved;
        emit LockerSet(msg.sender, locker, approved);
    }

    function isLocker(
        address holder,
        address locker
    ) external view returns (bool) {
        return _locker[holder][locker];
    }

    /*════════════════  Lock routine  ═════════════════*/
    function lock(address holder, uint64 amount) external {
        if (!_locker[holder][msg.sender])
            revert UnauthorizedLocker(holder, msg.sender);

        Account storage acc = _acct[holder];
        uint64 epoch = uint64(block.timestamp / lockTime);

        if (epoch != acc.window) {
            // new window – reset
            acc.locked = 0;
            acc.window = epoch;
        }

        uint64 unlocked = acc.balance - acc.locked;
        if (unlocked < amount) revert InsufficientUnlocked(unlocked, amount);

        acc.locked += amount;
        emit TokensLocked(holder, msg.sender, amount, epoch);
    }

    /*═════════════ ERC-20 view getters ═════════════*/
    function totalSupply() external view override returns (uint64) {
        return _tot;
    }
    function balanceOf(address a) external view override returns (uint64) {
        return _acct[a].balance;
    }
    /**
     * @notice Current tokens that are still locked for `holder`.
     * @dev    The lock counter is scoped to the sender’s current
     *         epoch window. If the stored epoch is stale, the
     *         lock has implicitly expired and the function
     *         returns `0`.
     * @param  holder  Address to query.
     * @return amount  Locked tokens that cannot be transferred
     *                 until the next epoch starts.
     */
    function balanceOfLocked(address holder) external view returns (uint64 amount) {
        Account storage acc = _acct[holder];

        // Re‐compute the epoch that governs this lock
        uint64 epoch = uint64(block.timestamp / lockTime);

        // If the saved window is from a past epoch, the lock
        // has expired (treated as 0); otherwise return acc.locked
        return (epoch == acc.window) ? acc.locked : 0;
    }
    function allowance(
        address o,
        address s
    ) external view override returns (uint64) {
        return _allow[o][s];
    }
    function name() external view override returns (string memory) {
        return _name;
    }
    function symbol() external view override returns (string memory) {
        return _symbol;
    }
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /*──────── allowances ────────*/
    mapping(address => mapping(address => uint64)) private _allow;

    function approve(address s, uint64 v) external override returns (bool) {
        if (s == address(0)) revert ZeroAddress(s);
        _allow[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    /*──────── transfers ────────*/
    function transfer(address to, uint64 v) external override returns (bool) {
        _xfer(msg.sender, to, v);
        return true;
    }

    function transferFrom(
        address f,
        address t,
        uint64 v
    ) external override returns (bool) {
        _spendAllowance(f, v);
        _xfer(f, t, v);
        return true;
    }

    /*════════════ batch helpers ════════════*/
    function transferBatch(
        address[] calldata to,
        uint64[] calldata v
    ) external override returns (bool) {
        uint256 len = to.length;
        if (len != v.length) revert LengthMismatch(len, v.length);

        uint256 sum;
        for (uint256 i; i < len; ) {
            sum += v[i];
            unchecked {
                ++i;
            }
        }
        if (sum > type(uint64).max) revert SumOverflow(sum);

        _debited(msg.sender, uint64(sum));

        for (uint256 i; i < len; ) {
            _credited(to[i], v[i]);
            emit Transfer(msg.sender, to[i], v[i]);
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function transferFromBatch(
        address from,
        address[] calldata to,
        uint64[] calldata v
    ) external override returns (bool) {
        uint256 len = to.length;
        if (len != v.length) revert LengthMismatch(len, v.length);

        uint256 sum;
        for (uint256 i; i < len; ) {
            sum += v[i];
            unchecked {
                ++i;
            }
        }
        if (sum > type(uint64).max) revert SumOverflow(sum);

        uint64 spend = uint64(sum);
        _spendAllowance(from, spend);
        _debited(from, spend);

        for (uint256 i; i < len; ) {
            _credited(to[i], v[i]);
            emit Transfer(from, to[i], v[i]);
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /*────────────────── internal helpers ──────────────────*/
    function _currentUnlocked(
        Account storage acc
    ) private view returns (uint64) {
        uint64 epoch = uint64(block.timestamp / lockTime);
        return (epoch != acc.window) ? acc.balance : acc.balance - acc.locked;
    }

    function _debited(address from, uint64 amt) private {
        Account storage acc = _acct[from];
        uint64 unlocked = _currentUnlocked(acc);
        if (unlocked < amt) revert InsufficientUnlocked(unlocked, amt);
        unchecked {
            acc.balance -= amt;
        }
    }

    function _credited(address to, uint64 amt) private {
        if (to == address(0)) revert ZeroAddress(to);
        unchecked {
            _acct[to].balance += amt;
        }
    }

    function _xfer(address from, address to, uint64 amt) private {
        _debited(from, amt);
        _credited(to, amt);
        emit Transfer(from, to, amt);
    }

    function _spendAllowance(address owner_, uint64 amt) private {
        uint64 cur = _allow[owner_][msg.sender];
        if (cur < amt) revert InsufficientAllowance(cur, amt);
        if (cur != type(uint64).max) {
            _allow[owner_][msg.sender] = cur - amt;
            emit Approval(owner_, msg.sender, cur - amt);
        }
    }
}

/*═══════════════════════════════════════════════════════════════════════*\
│                        UtilityTokenDeployer (factory)                   │
\*═══════════════════════════════════════════════════════════════════════*/
contract UtilityTokenDeployer {
    /**
     * @notice Deploy a new `StandardUtilityToken`.
     * @dev    Reverts with `ZeroAddress` if `root` is zero; bubbles any error
     *         from the token constructor (e.g. `LockTimeZero`).
     *
     * @return addr  Address of the deployed token.
     */
    function create(
        string calldata name_,
        string calldata symbol_,
        uint64 supply64,
        uint8 decimals_,
        uint32 lockTime_,
        address root
    ) external returns (address addr) {
        if (root == address(0)) revert ZeroAddress(root);

        StandardUtilityToken token = new StandardUtilityToken(
            name_,
            symbol_,
            supply64,
            decimals_,
            lockTime_,
            root
        );
        addr = address(token);
    }
}
