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
    /**
     * @notice Add or remove a locker authorised to lock the caller’s tokens.
     * @dev    Emits a {LockerSet} event.
     * @param  locker   Address to approve or revoke.
     * @param  approved Pass true to grant rights, false to revoke.
     * @custom:error ZeroAddress locker is the zero address.
     */
    function setLocker(address locker, bool approved) external {
        if (locker == address(0)) revert ZeroAddress(locker);
        _locker[msg.sender][locker] = approved;
        emit LockerSet(msg.sender, locker, approved);
    }

    /**
     * @notice Query whether a locker is authorised for a given holder.
     * @param  holder  Token holder being checked.
     * @param  locker  Potential locker address.
     * @return authorised True if locker may call {lock} on behalf of holder.
     */
    function isLocker(
        address holder,
        address locker
    ) external view returns (bool) {
        return _locker[holder][locker];
    }

    /*════════════════  Lock routine  ═════════════════*/

    /**
     * @notice Lock `amount` tokens in `holder`’s account for the current epoch.
     * @dev    • Only authorised lockers may call.  
     *         • A new epoch automatically resets previous locks.  
     *         • Emits a {TokensLocked} event.
     * @param  holder  Account whose tokens will be locked.
     * @param  amount  Number of tokens to lock (must not exceed unlocked balance).
     * @custom:error UnauthorizedLocker  Caller is not an approved locker for holder.
     * @custom:error InsufficientUnlocked Unlocked balance is less than amount.
     */
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

    /**
     * @notice Fixed total token supply.
     */
    function totalSupply() external view override returns (uint64) {
        return _tot;
    }
    /**
     * @notice Total balance (locked + unlocked) of an account.
     * @param  account Address to query.
     * @return balance Current balance of the account.
     */
    function balanceOf(address account) external view override returns (uint64 balance) {
        return _acct[account].balance;
    }
    /**
     * @notice Tokens still locked for the current epoch.
     * @dev    If the stored window is stale, returns 0.
     * @param  holder Address to query.
     * @return locked Amount that remains locked until the epoch ends.
     */
    function balanceOfLocked(address holder) external view returns (uint64 locked) {
        Account storage acc = _acct[holder];

        // Re‐compute the epoch that governs this lock
        uint64 epoch = uint64(block.timestamp / lockTime);

        // If the saved window is from a past epoch, the lock
        // has expired (treated as 0); otherwise return acc.locked
        return (epoch == acc.window) ? acc.locked : 0;
    }

    /**
     * @notice Remaining allowance from owner to spender.
     * @param  owner    Address that granted the allowance.
     * @param  spender  Address that can spend the tokens.
     * @return rem      Remaining allowance amount.
     */
    function allowance(
        address owner,
        address spender
    ) external view override returns (uint64 rem) {
        return _allow[owner][spender];
    }

    /**
     * @notice Human-readable token name.
     */
    function name() external view override returns (string memory) {
        return _name;
    }

    /**
     * @notice Token symbol.
     */
    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    /**
     * @notice Number of display decimals.
     */
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /*──────── allowances ────────*/
    mapping(address => mapping(address => uint64)) private _allow;

    /**
     * @notice Set or overwrite an allowance.
     * @dev    Emits an {Approval} event.
     * @param  spender Address that will be allowed to spend.
     * @param  value   Allowance amount (use max uint64 for unlimited).
     * @return ok      Always true on success.
     * @custom:error ZeroAddress spender is the zero address.
     */
    function approve(address spender, uint64 value) external override returns (bool ok) {
        if (spender == address(0)) revert ZeroAddress(spender);
        _allow[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /*──────── transfers ────────*/

    /**
     * @notice Transfer tokens from caller to another address.
     * @dev    Emits a {Transfer} event.
     * @param  to     Recipient address.
     * @param  value  Amount to transfer.
     * @return ok     Always true on success.
     * @custom:error InsufficientUnlocked Unlocked balance is less than value.
     * @custom:error ZeroAddress         Recipient is the zero address.
     */
    function transfer(address to, uint64 value) external override returns (bool ok) {
        _xfer(msg.sender, to, value);
        return true;
    }

    /**
     * @notice Transfer tokens using an existing allowance.
     * @dev    Emits {Transfer} and possibly {Approval}.
     * @param  from   Source address.
     * @param  to     Destination address.
     * @param  value  Amount to transfer.
     * @return ok     Always true on success.
     * @custom:error InsufficientAllowance Allowance is less than value.
     * @custom:error InsufficientUnlocked  Source unlocked balance is insufficient.
     * @custom:error ZeroAddress           Recipient is the zero address.
     */
    function transferFrom(
        address from,
        address to,
        uint64 value
    ) external override returns (bool) {
        _spendAllowance(from, value);
        _xfer(from, to, value);
        return true;
    }

    /*════════════ batch helpers ════════════*/

    /**
     * @notice Send many transfers from the caller in one transaction.
     * @dev    Emits one {Transfer} per recipient.
     * @param  to  List of recipient addresses.
     * @param  v   List of token amounts (must match `to` length).
     * @return ok  Always true on success.
     * @custom:error LengthMismatch        Arrays have different lengths.
     * @custom:error SumOverflow           Aggregate exceeds uint64 max.
     * @custom:error InsufficientUnlocked  Caller’s unlocked balance is insufficient.
     * @custom:error ZeroAddress           One of the recipients is the zero address.
     */
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

    /**
     * @notice Execute multiple allowance-based transfers in one call.
     * @dev    Emits one {Transfer} per recipient and possibly {Approval}.
     * @param  from  Source address.
     * @param  to    List of recipient addresses.
     * @param  v     List of token amounts (must match `to` length).
     * @return ok    Always true on success.
     * @custom:error LengthMismatch        Arrays have different lengths.
     * @custom:error SumOverflow           Aggregate exceeds uint64 max.
     * @custom:error InsufficientAllowance Allowance is less than aggregate.
     * @custom:error InsufficientUnlocked  Source unlocked balance is insufficient.
     * @custom:error ZeroAddress           One of the recipients is the zero address.
     */
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
     * @notice Deploy a new {StandardUtilityToken} with a fixed supply.
     * @dev    • All tokens are minted to `root`.  
     *         • Bubbles any constructor error, e.g. {LockTimeZero}.  
     *         • Emits the token’s own {Transfer} event during deployment.
     * @param  name_      Token name.
     * @param  symbol_    Token symbol.
     * @param  supply64   Fixed supply (≤ 2⁶⁴−1).
     * @param  decimals_  Display decimals.
     * @param  lockTime_  Epoch duration in seconds (must be > 0).
     * @param  root       Address that will receive the full supply.
     * @return addr       Address of the deployed token.
     * @custom:error ZeroAddress  root is the zero address.
     * @custom:error LockTimeZero lockTime_ is zero (propagated from token).
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
