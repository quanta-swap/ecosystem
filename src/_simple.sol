// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*═══════════════════════════════════════════════════════════════════════════════*\
│                           IZRC-20 interface (64-bit)                           │
\*═══════════════════════════════════════════════════════════════════════════════*/

/**
 * 64-bit ERC-20 interface plus batch transfers for simulated signature aggregation.
 * Standardizing tokens to 64-bits greatly improves the efficiency of all downstream
 * contracts. It's always possible to scale a larger token to fit into 64-bits, safe.
 */
interface IZRC20 {
    /* view */
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint64);
    function balanceOf(address a) external view returns (uint64);
    function allowance(address o, address s) external view returns (uint64);

    /* actions */
    function approve(address s, uint64 v) external returns (bool);
    function transfer(address to, uint64 v) external returns (bool);
    function transferFrom(
        address f,
        address t,
        uint64 v
    ) external returns (bool);

    // Added in light of quantum resistant signatures being quite large.
    function transferBatch(
        address[] calldata to,
        uint64[] calldata v
    ) external returns (bool);

    // Added in light of quantum resistant signatures being quite large.
    function transferFromBatch(
        address from,
        address[] calldata to,
        uint64[] calldata v
    ) external returns (bool);

    /* events */
    event Transfer(address indexed from, address indexed to, uint64 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint64 value
    );
}

/*═══════════════════════════════════════════════════════════════════════════════*\
│  ReentrancyGuard – one-byte, branch-free                                         │
\*═══════════════════════════════════════════════════════════════════════════════*/
abstract contract ReentrancyGuard {
    /// @dev Thrown on nested entry.
    error Reentrancy();

    uint8 private constant _NOT = 1;
    uint8 private constant _ENT = 2;
    uint8 private _stat = _NOT;

    modifier nonReentrant() {
        if (_stat == _ENT) revert Reentrancy();
        _stat = _ENT;
        _;
        _stat = _NOT;
    }
}

/*═══════════════════════════════════════════════════════════════════════════════*\
│  WrappedQRL – plain IZRC-20 wrapper (9-dec, 64-bit)                             │
│                                                                                 │
│  • 1 native QRL (18-dec)  ↔  1 WQ (9-dec)                                       │
│  • Self-imposed wallet lock to freeze spending for N seconds.                   │
│  • Batch helpers + one-byte re-entrancy gate.                                   │
\*═══════════════════════════════════════════════════════════════════════════════*/

/**
 * @title Wrapped Quanta
 * @author Elliott G. Dehnbostel
 * @notice 64-bits for efficient on-chain operations (sized to the old "shor" unit)
 *
 * This is not a 100% minimal contract. It features account locking to prevent some
 * wrench attacks.
 */
contract WrappedQRL is IZRC20, ReentrancyGuard {
    /*═══════════════════════════════════════════════════════════════════════════════*\
    │  Typed Errors – canonicalised replacements for string-based reverts            │
    │  Each error is documented and, where useful, carries contextual parameters     │
    │  to aid off-chain decoding and debugging.                                      │
    \*═══════════════════════════════════════════════════════════════════════════════*/

    /*──────────────────────── wallet-lock errors ────────────────────────*/
    /// @notice `lock()` called with a zero duration.
    /// @param  duration Seconds supplied by the caller (always 0 here).
    error DurationZero(uint32 duration);

    /// @notice Requested lock would shorten or equal the current lock.
    /// @param  requestedUntil The timestamp the caller is trying to extend to.
    /// @param  currentUntil   The caller’s existing `unlocksAt` timestamp.
    error LockShorter(uint64 requestedUntil, uint64 currentUntil);

    /// @notice Wallet is still time-locked.
    /// @param  unlockAt UNIX timestamp when the caller becomes unlocked.
    error WalletLocked(uint64 unlockAt);

    /*──────────────────────── deposit / withdraw errors ─────────────────*/
    /// @notice Native value sent is below one full token (1 × 10⁹ wei).
    /// @param  value Wei supplied with the transaction.
    error MinDepositOneToken(uint256 value);

    /// @notice Low-level ETH refund of deposit dust failed.
    /// @param  to     Address that was to receive the refund.
    /// @param  amount Wei that failed to send.
    error RefundFailed(address to, uint256 amount);

    /// @notice Zero amount specified where a positive value is required.
    error ZeroAmount();

    /// @notice Account balance is smaller than the requested amount.
    /// @param  balance Current balance.
    /// @param  needed  Amount required to proceed.
    error InsufficientBalance(uint256 balance, uint256 needed);

    /// @notice Native token transfer in `withdraw()` failed.
    /// @param  to     Withdrawal recipient.
    /// @param  amount Wei attempted to send.
    error NativeTransferFailed(address to, uint256 amount);

    /*──────────────────────── allowance errors ──────────────────────────*/
    /// @notice Allowance is insufficient for the attempted spend.
    /// @param  allowance Remaining allowance.
    /// @param  needed    Amount that was attempted to spend.
    error InsufficientAllowance(uint256 allowance, uint256 needed);

    /*──────────────────────── batch / transfer errors ───────────────────*/
    /// @notice The zero address was supplied where a non-zero address is required.
    error ZeroAddress();

    /// @notice Calldata array lengths do not match.
    /// @param  lenA Length of the `to` array.
    /// @param  lenB Length of the `amount` array.
    error LengthMismatch(uint256 lenA, uint256 lenB);

    /// @notice Sum of batch amounts would overflow 64-bit token units.
    /// @param  attemptedSum The aggregate amount that exceeded 2⁶⁴−1.
    error SumOverflow(uint256 attemptedSum);

    /*──────────────────────── mint / cap errors ────────────────────────*/
    /// @notice Mint would exceed the 64-bit total supply cap.
    /// @param  totalSupply Current total supply before mint.
    /// @param  mintAmount  Amount attempted to mint.
    error CapExceeded(uint256 totalSupply, uint256 mintAmount);

    /*──────── constants ────────*/
    uint8 public constant DECIMALS = 9;
    uint64 public constant MAX_BAL = type(uint64).max; // 2⁶⁴−1
    uint256 private constant _SCALE = 1e9; // 18-dec → 9-dec

    string private constant _NAME = "Wrapped Quanta";
    string private constant _SYMB = "WQ";

    /*──────── storage ────────*/
    uint64 private _tot; // total supply
    struct Account {
        uint64 balance;
        uint64 unlockAt;
    }
    mapping(address => Account) private _accounts;
    mapping(address => mapping(address => uint64)) private _allow; // allowances

    /*──────── events ────────*/
    event AccountLocked(address indexed wallet, uint64 unlocksAt);
    event Deposited(address indexed account, uint64 amount);
    event Withdrawn(address indexed account, uint64 amount);

    /*──────────────────────── constructor ────────────────────────*/
    /**
     * @notice Deploys Wrapped QRL and optionally wraps the native QRL sent
     *         alongside the deployment transaction.
     * @dev    - Reuses {deposit} to mint, thereby exercising its
     *           validations and rounding logic.
     *         - Reverts if `msg.value` is non-zero yet smaller than
     *           one full token (1 × 10^9 wei); prevents silent zero-mints.
     */
    constructor() payable {
        if (msg.value > 0) {
            deposit(); // reuse the tested path
        }
    }

    /**
     * @notice Returns a specific link for test sanity checks.
     * @dev    Pure vanity helper; has no on-chain effect.
     * @return s The link.
     */
    function theme() external pure returns (string memory s) {
        return "https://www.youtube.com/watch?v=pJvduG0E628";
    }

    /*════════════════════ wallet-lock API ══════════════════════*/
    /**
     * @notice Locks the caller’s balance for `duration` seconds.
     * @dev    Reverts with:
     *         - `DurationZero(duration)`         when `duration == 0`.
     *         - `LockShorter(newUntil, oldUntil)` when the new lock would not
     *           extend the current lock window.
     * @param  duration  Seconds to remain locked (must be > 0 and strictly extend any
     *                   existing lock).
     */
    function lock(uint32 duration) external nonReentrant {
        // ──────────────────── sanity check ─────────────────────
        // A zero-second lock is a no-op and almost certainly a user error.
        if (duration == 0) revert DurationZero(duration);

        // ──────────────────── fetch account ────────────────────
        Account storage acc = _accounts[msg.sender];
        uint64 currentUntil = acc.unlockAt; // 0 when not locked

        // ──────────────────── extension logic ──────────────────
        if (currentUntil > block.timestamp) {
            // Wallet is already locked; new lock must push the edge forward.
            uint64 newUntil = uint64(block.timestamp + duration);
            if (newUntil <= currentUntil) {
                revert LockShorter(newUntil, currentUntil);
            }
            acc.unlockAt = newUntil;
            emit AccountLocked(msg.sender, newUntil);
        } else {
            // Wallet is currently unlocked; establish a fresh lock window.
            uint64 until = uint64(block.timestamp + duration);
            acc.unlockAt = until;
            emit AccountLocked(msg.sender, until);
        }
    }

    /**
     * @notice Returns the UNIX timestamp at which `who` unlocks.
     * @dev    `0` means the wallet is currently unlocked.
     * @param  who The address being queried.
     * @return The lock expiry timestamp.
     */
    function unlocksAt(address who) external view returns (uint64) {
        return _accounts[who].unlockAt;
    }

    /*───────────────────────── deposit ───────────────────────────*/
    /**
     * @notice Wrap native QRL into WQ at a 1 QRL → 1 WQ rate.
     *
     * Detail
     * ------
     * • Accepts any amount ≥ 1 × 10⁹ wei (1 wrapped token).
     * • Mints `floor(msg.value / 1e9)` tokens.
     * • Refunds leftover wei in the same transaction.
     * • Emits {Deposited} and an ERC-20 {Transfer} from the zero address.
     *
     * Custom Errors
     * -------------
     * • `MinDepositOneToken(value)` — `msg.value` is smaller than 1 × 10⁹ wei.
     * • `RefundFailed(to, amount)` — native-asset refund (dust) could not be sent.
     *
     * Events
     * ------
     * • `Deposited(caller, mintedAmount)` on success.
     *
     * Reentrancy
     * ----------
     * Protected by the {nonReentrant} modifier from {ReentrancyGuard}.
     */
    function deposit() public payable nonReentrant {
        /* Dust guard — underfunded call is a user mistake.            */
        if (msg.value < _SCALE) revert MinDepositOneToken(msg.value);

        /* Wei → token conversion (floor division guarantees no over-
                minting).                                                  */
        uint64 amt = uint64(msg.value / _SCALE);

        /* Mint under the 64-bit total-supply cap.                     */
        _mint(msg.sender, amt);

        /* Refund leftover wei; propagate failure with a typed error.  */
        uint256 refund = msg.value - uint256(amt) * _SCALE;
        if (refund != 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed(msg.sender, refund);
        }

        /* Surface-level acknowledgement for indexers & explorers.     */
        emit Deposited(msg.sender, amt);
    }

    /**
     * @notice Fallback that converts bare QRL transfers into a deposit.
     * @dev    Executes {deposit}; therefore it inherits all its checks,
     *         events, and side-effects.
     */
    receive() external payable {
        deposit();
    }

    /**
     * @notice Burn `tok` WQ and return the equivalent amount of native QRL
     *         to the caller at a 1 WQ → 1 QRL rate.
     *
     * Detail
     * ------
     * • Caller must be unlocked (see {_assertUnlocked}).
     * • Caller must hold at least `tok` wrapped units.
     * • Sends `tok × 1e9` wei back to the caller.
     * • Emits {Withdrawn} and an ERC-20 {Transfer} to the zero address.
     *
     * Parameters
     * ----------
     * @param tok  Amount of WQ to burn (must be > 0).
     *
     * Custom Errors
     * -------------
     * • `ZeroAmount()`                             — `tok == 0`
     * • `InsufficientBalance(balance, needed)`     — caller balance < `tok`
     * • `NativeTransferFailed(to, amount)`         — low-level ETH transfer failed
     * • `WalletLocked(unlockAt)`                   — caller is still locked
     *
     * Events
     * ------
     * • `Withdrawn(caller, tok)` on success.
     *
     * Reentrancy
     * ----------
     * Protected by the {nonReentrant} modifier from {ReentrancyGuard}.
     */
    function withdraw(uint64 tok) external nonReentrant {
        /* Lock guard — protects against wrench-attack freezes.         */
        _assertUnlocked(msg.sender);

        /* Zero-value guard.                                             */
        if (tok == 0) revert ZeroAmount();

        /* Balance check with rich context.                             */
        Account storage acc = _accounts[msg.sender];
        if (acc.balance < tok) revert InsufficientBalance(acc.balance, tok);

        /* Burn the wrapped tokens.                                      */
        _burn(msg.sender, tok);

        /* Release native QRL; bubble up any failure.                   */
        uint256 weiAmt = uint256(tok) * _SCALE;
        (bool ok, ) = payable(msg.sender).call{value: weiAmt}("");
        if (!ok) revert NativeTransferFailed(msg.sender, weiAmt);

        /* Event for indexers & explorers.                              */
        emit Withdrawn(msg.sender, tok);
    }

    /*──────── IZRC-20 view ────────*/
    /// @notice ZRC-20 name.
    function name() external pure override returns (string memory) {
        return _NAME;
    }
    /// @notice ZRC-20 symbol.
    function symbol() external pure override returns (string memory) {
        return _SYMB;
    }
    /// @notice Number of decimals (always 9).
    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }
    /// @notice Current total supply (64-bit domain).
    function totalSupply() external view override returns (uint64) {
        return _tot;
    }

    /**
     * @notice Reads the WQ balance of `a`.
     * @param  a Account address.
     * @return Current balance in 64-bit units.
     */
    function balanceOf(address a) external view override returns (uint64) {
        return _accounts[a].balance;
    }

    /**
     * @notice Reads the remaining allowance from `o` to `s`.
     * @param  o Owner address.
     * @param  s Spender address.
     * @return Remaining allowance.
     */
    function allowance(
        address o,
        address s
    ) external view override returns (uint64) {
        return _allow[o][s];
    }

    /*──────── approvals ────────*/

    /**
     * @notice Sets the allowance for `s`.
     * @dev    Fully overwrites any existing value.
     * @param  s Spender address.
     * @param  v New allowance (use `type(uint64).max` for unlimited).
     * @return Always true on success.
     */
    function approve(address s, uint64 v) external override returns (bool) {
        _allow[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    /*──────── transfers ────────*/

    /**
     * @notice Transfer `v` WQ from the caller to `to`.
     *
     * Detail
     * ------
     * • Caller must be unlocked (see {_assertUnlocked}).
     * • Caller must hold at least `v` wrapped units.
     * • Recipient address must be non-zero.
     * • Emits an ERC-20 {Transfer} event on success.
     *
     * Parameters
     * ----------
     * @param to  Recipient address (must not be `address(0)`).
     * @param v   Amount of WQ to transfer.
     * @return    Always `true` when the transfer succeeds.
     *
     * Custom Errors
     * -------------
     * • `ZeroAddress()`                           — `to == address(0)`
     * • `InsufficientBalance(balance, needed)`    — caller balance < `v`
     * • `WalletLocked(unlockAt)`                  — caller is still time-locked
     *
     * Reentrancy
     * ----------
     * Protected by the {nonReentrant} modifier from {ReentrancyGuard}.
     */
    function transfer(
        address to,
        uint64 v
    ) external override nonReentrant returns (bool) {
        _assertUnlocked(msg.sender);
        _xfer(msg.sender, to, v);
        return true;
    }

    /**
     * @notice Transfer `v` WQ from address `f` to address `t` using an existing
     *         allowance set by `f` for the caller (`msg.sender`).
     *
     * Detail
     * ------
     * • Consumes allowance unless it equals `type(uint64).max`
     *   (treated as infinite and left unchanged).  
     * • Fails early if `f` is wallet-locked.  
     * • Emits one ERC-20 {Transfer} event on success; may emit an
     *   {Approval} event if the allowance ticks down.
     *
     * Parameters
     * ----------
     * @param f  Source (owner) address.
     * @param t  Destination address (must not be `address(0)`).
     * @param v  Amount of WQ to transfer.
     * @return   Always `true` when the transfer succeeds.
     *
     * Custom Errors
     * -------------
     * • `InsufficientAllowance(allowance, needed)` — current allowance < `v`  
     * • `InsufficientBalance(balance, needed)`     — balance of `f` < `v`  
     * • `ZeroAddress()`                            — `t == address(0)`  
     * • `WalletLocked(unlockAt)`                   — `f` is still time-locked
     *
     * Reentrancy
     * ----------
     * Guarded by the {nonReentrant} modifier from {ReentrancyGuard}.
     */
    function transferFrom(
        address f,
        address t,
        uint64 v
    ) external override nonReentrant returns (bool) {
        _assertUnlocked(f);
        _spendAllowance(f, v);
        _xfer(f, t, v);
        return true;
    }

    /*═══════════════════════════════════════════════════════════════════════════════*\
    │  Gas-tight batch helpers                                                       │
    \*═══════════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Send multiple transfers from the caller in a single transaction.
     *
     * Behaviour
     * ---------
     * 1. Arrays must be equal length – otherwise `LengthMismatch` reverts.
     * 2. Caller must be unlocked – enforced upstream by `_assertUnlocked`.
     * 3. Pre-compute the aggregate amount; revert with `SumOverflow`
     *    if it exceeds the 64-bit domain.
     * 4. Ensure the caller’s balance can cover the total; otherwise
     *    `InsufficientBalance`.
     * 5. Debit the sender once, then credit each recipient in a loop,
     *    reverting with `ZeroAddress` on any `address(0)`.
     * 6. Emit a standard ERC-20 `Transfer` event for every leg.
     *
     * Custom Errors
     * -------------
     * • LengthMismatch(lenA, lenB)       — `to.length != v.length`
     * • SumOverflow(attemptedSum)        — Σ v[i] > 2⁶⁴−1
     * • InsufficientBalance(balance, needed)
     * • ZeroAddress()                    — recipient is the zero address
     */
    function transferBatch(
        address[] calldata to,
        uint64[] calldata v
    ) external nonReentrant returns (bool) {
        // 1. Array-length parity check
        if (to.length != v.length) revert LengthMismatch(to.length, v.length);

        // 2. Time-lock guard
        _assertUnlocked(msg.sender);

        // 3. Aggregate sum with overflow protection
        uint256 len = v.length;
        uint256 total = 0;
        for (uint256 i; i < len; ) {
            uint256 newSum = total + v[i];
            if (newSum > type(uint64).max) revert SumOverflow(newSum);
            total = newSum;
            unchecked {
                ++i;
            }
        }
        uint64 total64 = uint64(total);

        // 4. Balance check
        Account storage senderAcc = _accounts[msg.sender];
        if (senderAcc.balance < total64)
            revert InsufficientBalance(senderAcc.balance, total64);

        // 5. Debit sender once
        unchecked {
            senderAcc.balance -= total64;
        }

        // 6. Credit recipients
        for (uint256 i; i < len; ) {
            address dst = to[i];
            uint64 amt = v[i];
            if (dst == address(0)) revert ZeroAddress();

            unchecked {
                _accounts[dst].balance += amt;
            }

            emit Transfer(msg.sender, dst, amt);
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /**
     * @notice Move tokens from `from` to many recipients in a single call.
     *
     * Behaviour
     * ---------
     * 1. Arrays must be equal length – otherwise `LengthMismatch`.
     * 2. `from` must be unlocked – enforced via `_assertUnlocked`.
     * 3. Pre-compute the aggregate amount; revert with `SumOverflow`
     *    if it exceeds the 64-bit token domain.
     * 4. Consume allowance in one shot via `_spendAllowance`.
     * 5. Ensure `from` has sufficient balance – otherwise
     *    `InsufficientBalance`.
     * 6. Debit `from` once, then credit each recipient, reverting with
     *    `ZeroAddress` on any `address(0)`.
     * 7. Emit an ERC-20 `Transfer` event for every leg.
     *
     * Custom Errors
     * -------------
     * • LengthMismatch(lenA, lenB)         — `to.length != v.length`
     * • SumOverflow(attemptedSum)          — Σ v[i] > 2⁶⁴−1
     * • InsufficientBalance(balance, need)
     * • ZeroAddress()                      — recipient is the zero address
     * • InsufficientAllowance(allowance, need)
     *   (bubbled up from `_spendAllowance`)
     */
    function transferFromBatch(
        address from,
        address[] calldata to,
        uint64[] calldata v
    ) external nonReentrant returns (bool) {
        /* 1. Array-length parity check */
        if (to.length != v.length) revert LengthMismatch(to.length, v.length);

        /* 2. Time-lock guard */
        _assertUnlocked(from);

        /* 3. Aggregate amount with overflow protection */
        uint256 len = v.length;
        uint256 total = 0;
        for (uint256 i; i < len; ) {
            uint256 newSum = total + v[i];
            if (newSum > type(uint64).max) revert SumOverflow(newSum);
            total = newSum;
            unchecked {
                ++i;
            }
        }
        uint64 total64 = uint64(total);

        /* 4. Spend allowance (may revert with InsufficientAllowance) */
        _spendAllowance(from, total64);

        /* 5. Balance check */
        Account storage fromAcc = _accounts[from];
        if (fromAcc.balance < total64)
            revert InsufficientBalance(fromAcc.balance, total64);

        /* 6. Debit sender once */
        unchecked {
            fromAcc.balance -= total64;
        }

        /* 7. Credit recipients */
        for (uint256 i; i < len; ) {
            address dst = to[i];
            uint64 amt = v[i];
            if (dst == address(0)) revert ZeroAddress();

            unchecked {
                _accounts[dst].balance += amt;
            }
            emit Transfer(from, dst, amt);
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /*──────────────────────── internal helpers – typed-error versions ─────────────*/

    /**
     * @dev Move `v` tokens from `from` to `to`.
     *
     * Reverts
     * -------
     * • ZeroAddress()                            – `to == address(0)`
     * • InsufficientBalance(balance, needed)     – balance < v
     *
     * Emits
     * -----
     * • Transfer(from, to, v)
     */
    function _xfer(address from, address to, uint64 v) internal {
        if (to == address(0)) revert ZeroAddress();

        Account storage fromAcc = _accounts[from];
        if (fromAcc.balance < v) revert InsufficientBalance(fromAcc.balance, v);

        unchecked {
            fromAcc.balance -= v;
            _accounts[to].balance += v;
        }
        emit Transfer(from, to, v);
    }

    /**
     * @dev Consume `v` allowance units from `from->msg.sender`.
     *
     * Reverts
     * -------
     * • InsufficientAllowance(allowance, needed) – cur < v
     *
     * Special Case
     * ------------
     * • When `cur == type(uint64).max` the allowance is considered infinite
     *   and is left unchanged.
     *
     * Emits
     * -----
     * • Approval(from, spender, newAllowance)    – only when allowance ticks down
     */
    function _spendAllowance(address from, uint64 v) internal {
        uint64 cur = _allow[from][msg.sender];
        if (cur < v) revert InsufficientAllowance(cur, v);

        // Infinite allowance sentinel (uint64.max) leaves storage untouched
        if (cur != type(uint64).max) {
            uint64 newAllow = cur - v;
            _allow[from][msg.sender] = newAllow;
            emit Approval(from, msg.sender, newAllow);
        }
    }

    /**
     * @dev Mint `v` tokens to `to` after total-supply cap check.
     *
     * Reverts
     * -------
     * • CapExceeded(totalSupply, mintAmount) – via _checkCap
     *
     * Emits
     * -----
     * • Transfer(0x0, to, v)
     */
    function _mint(address to, uint64 v) internal {
        _checkCap(v); // total-supply guard
        uint64 bal = _accounts[to].balance;
        _accounts[to].balance = bal + v;
        _tot += v;
        emit Transfer(address(0), to, v);
    }

    /**
     * @dev Burn `v` tokens from `from`.
     *
     * Reverts
     * -------
     * • InsufficientBalance(balance, needed)
     *
     * Emits
     * -----
     * • Transfer(from, 0x0, v)
     */
    function _burn(address from, uint64 v) internal {
        Account storage acc = _accounts[from];
        if (acc.balance < v) revert InsufficientBalance(acc.balance, v);
        unchecked {
            acc.balance -= v;
            _tot -= v;
        }
        emit Transfer(from, address(0), v);
    }

    /*────────── guards ──────────*/

    /**
     * @dev Ensure `who` is not currently locked.
     *
     * Reverts
     * -------
     * • WalletLocked(unlockAt) – when `block.timestamp < unlockAt`
     */
    function _assertUnlocked(address who) internal view {
        uint64 t = _accounts[who].unlockAt;
        if (t != 0 && block.timestamp < t) revert WalletLocked(t);
    }

    /**
     * @dev Enforce 2⁶⁴-1 total-supply cap before minting `inc` tokens.
     *
     * Reverts
     * -------
     * • CapExceeded(totalSupply, mintAmount)
     */
    function _checkCap(uint64 inc) internal view {
        if (uint256(inc) > uint256(MAX_BAL) - _tot)
            revert CapExceeded(_tot, inc);
    }
}
