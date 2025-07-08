// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

    /*──────────────────────── constructor ────────────────────────*/
    /**
     * @notice Deploys WrappedQRL.  If native QRL is sent along with the
     *         deployment it is wrapped at a 1 QRL (18 dec) → 1 WQ (9 dec) rate.
     *         Any dust that cannot be expressed as a whole-token unit is
     *         immediately refunded to the deployer.
     *
     * @dev    • Uses the same rounding logic as {deposit}.
     *         • Reverts if less than one full token’s worth is provided so that
     *           the deployment cannot silently mint zero.
     */
    constructor() payable {
        if (msg.value > 0) {
            deposit(); // reuse the tested path
        }
    }

    // For sanity testing purposes only.
    function theme() external pure returns (string memory s) {
        return "https://www.youtube.com/watch?v=pJvduG0E628";
    }

    /*════════════════════ wallet-lock API ══════════════════════*/
    /**
     * @notice Freeze caller’s balance for `duration` seconds.
     * @param duration  Seconds to lock. Must be > 0.
     *
     * Emits: {AccountLocked}.
     *
     * Self-locking MAY enhance security for non-zero holders.
     * Not by a tremendous amount, but every little bit counts!
     * It protects owners from "wrench attacks" and other forms
     * of coercive compromise. No maximum length on purpose.
     */
    function lock(uint32 duration) external nonReentrant {
        require(duration > 0, "dur0");
        Account storage acc = _accounts[msg.sender];
        uint64 lockTime = acc.unlockAt;
        if (lockTime > block.timestamp) {
            require(duration > lockTime - block.timestamp, "shorter");
        }

        uint64 until = uint64(block.timestamp + duration);
        acc.unlockAt = until;
        emit AccountLocked(msg.sender, until);
    }

    /// @notice UNIX timestamp when `who` unlocks. 0 means no lock.
    function unlocksAt(address who) external view returns (uint64) {
        return _accounts[who].unlockAt;
    }

    /*───────────────────────── deposit ───────────────────────────*/
    /**
     * @notice Wrap native QRL into WQ.
     *
     *         • Accepts **any** amount ≥ 1 WQ (1 × 10⁹ wei).
     *         • Mints `floor(msg.value / 1e9)` tokens.
     *         • Immediately refunds the leftover wei (if any) back to the caller,
     *           so no dust is ever trapped.
     *
     * Emits: {Transfer} from the zero address for the minted amount.
     *
     * @dev    Keeps the entire operation non-reentrant via the inherited guard.
     *         If the refund fails, the whole call reverts—user funds stay safe.
     */
    function deposit() public payable nonReentrant {
        // ── 0. Require at least one full token’s worth.
        require(msg.value >= _SCALE, "min1");

        // ── 1. Compute token amount (floor division).
        uint64 amt = uint64(msg.value / _SCALE);

        // ── 2. Mint (cap-checked inside _mint).
        _mint(msg.sender, amt);

        // ── 3. Refund remainder (if any). Keeps UX smooth for odd amounts.
        uint256 refund = msg.value - uint256(amt) * _SCALE;
        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            require(ok, "refund");
        }
    }

    receive() external payable {
        deposit();
    }

    function withdraw(uint64 tok) external nonReentrant {
        _assertUnlocked(msg.sender);
        require(tok > 0, "zero");
        Account storage acc = _accounts[msg.sender];
        require(acc.balance >= tok, "bal");

        _burn(msg.sender, tok);
        uint256 weiAmt = uint256(tok) * _SCALE;
        (bool ok, ) = payable(msg.sender).call{value: weiAmt}("");
        require(ok, "native send");
    }

    /*──────── IZRC-20 view ────────*/
    function name() external pure override returns (string memory) {
        return _NAME;
    }
    function symbol() external pure override returns (string memory) {
        return _SYMB;
    }
    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }
    function totalSupply() external view override returns (uint64) {
        return _tot;
    }
    function balanceOf(address a) external view override returns (uint64) {
        return _accounts[a].balance;
    }
    function allowance(
        address o,
        address s
    ) external view override returns (uint64) {
        return _allow[o][s];
    }

    /*──────── approvals ────────*/
    function approve(address s, uint64 v) external override returns (bool) {
        _allow[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    /*──────── transfers ────────*/
    function transfer(
        address to,
        uint64 v
    ) external override nonReentrant returns (bool) {
        _assertUnlocked(msg.sender);
        _xfer(msg.sender, to, v);
        return true;
    }

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
     * @notice Send `v[i]` tokens to `to[i]` in a single call.
     * @dev
     * 1. Verifies array length match (**O(1)**).
     * 2. Computes Σ v[i] once, reverting on:
     *      • sum > 2⁶⁴-1  (would not fit a token unit)
     *      • sender balance < Σ v[i]  (insufficient funds)
     * 3. Debits the sender **once**, then credits each recipient,
     *    guarding every credit against individual-balance overflow.
     * 4. Emits one `Transfer` event per leg.
     *
     * Gas notes:
     * • Storage hit on sender balance is now 1R/1W (was N+1).
     * • Loop index increments are unchecked.
     * • Length is cached to avoid an extra `calldataload`.
     */
    function transferBatch(
        address[] calldata to,
        uint64[] calldata v
    ) external nonReentrant returns (bool) {
        require(to.length == v.length, "len");
        _assertUnlocked(msg.sender);

        /*─────────────────────── pre-flight totals ───────────────────────*/
        uint256 len = v.length;
        uint256 total;
        for (uint256 i; i < len; ) {
            require(total + v[i] <= type(uint64).max, "sum-overflow");
            total += v[i];
            unchecked {
                ++i;
            }
        }
        uint64 total64 = uint64(total);

        Account storage senderAcc = _accounts[msg.sender];
        require(senderAcc.balance >= total, "bal");

        /*────────────────────── debit sender once ───────────────────────*/
        unchecked {
            senderAcc.balance -= total64;
        }

        /*───────────────────── credit recipients loop ───────────────────*/
        for (uint256 i; i < len; ) {
            address dst = to[i];
            uint64 amt = v[i];
            require(dst != address(0), "to0");

            Account storage dstAcc = _accounts[dst];
            unchecked {
                // this is always safe because the sum of all balances is
                // totalSupply, which is capped to 64 bits. the sum of two
                // parts can never exceed the sum of the whole; the whole
                // is always within 64 bits.
                dstAcc.balance += amt;
            }

            emit Transfer(msg.sender, dst, amt);
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /**
     * @notice Transfer tokens from `from` to many recipients in a single call.
     * @dev
     * • Identical flow to {transferBatch} plus an allowance spend.
     * • Reverts on allowance underrun **before** touching balances.
     * • Preserves sender’s unlimited-allowance shortcut.
     */
    function transferFromBatch(
        address from,
        address[] calldata to,
        uint64[] calldata v
    ) external nonReentrant returns (bool) {
        require(to.length == v.length, "len");
        _assertUnlocked(from);

        /*─────────────────────── pre-flight totals ───────────────────────*/
        uint256 len = v.length;
        uint256 total;
        for (uint256 i; i < len; ) {
            require(total + v[i] <= type(uint64).max, "sum-overflow");
            total += v[i];
            unchecked {
                ++i;
            }
        }

        uint64 total64 = uint64(total);
        _spendAllowance(from, total64);

        Account storage fromAcc = _accounts[from];
        require(fromAcc.balance >= total64, "bal");
        unchecked {
            fromAcc.balance -= total64;
        }

        /*───────────────────── credit recipients loop ───────────────────*/
        for (uint256 i; i < len; ) {
            address dst = to[i];
            uint64 amt = v[i];
            require(dst != address(0), "to0");

            Account storage dstAcc = _accounts[dst];
            unchecked {
                // this is always safe because the sum of all balances is
                // totalSupply, which is capped to 64 bits. the sum of two
                // parts can never exceed the sum of the whole; the whole
                // is always within 64 bits.
                dstAcc.balance += amt;
            }

            emit Transfer(from, dst, amt);
            unchecked {
                ++i;
            }
        }
        return true;
    }
    /*──────────────────────── internal helpers ────────────────────────*/
    function _xfer(address from, address to, uint64 v) internal {
        require(to != address(0), "to0");
        Account storage fromAcc = _accounts[from];
        require(fromAcc.balance >= v, "bal");
        unchecked {
            fromAcc.balance -= v;
            _accounts[to].balance += v;
        }
        emit Transfer(from, to, v);
    }

    function _spendAllowance(address from, uint64 v) internal {
        uint64 cur = _allow[from][msg.sender];
        require(cur >= v, "allow");
        if (cur != type(uint64).max) {
            // infinite allowance sentinel
            _allow[from][msg.sender] = cur - v;
            emit Approval(from, msg.sender, cur - v);
        }
    }

    function _mint(address to, uint64 v) internal {
        _checkCap(v);
        _accounts[to].balance += v;
        _tot += v;
        emit Transfer(address(0), to, v);
    }

    function _burn(address from, uint64 v) internal {
        Account storage acc = _accounts[from];
        require(acc.balance >= v, "bal");
        unchecked {
            acc.balance -= v;
            _tot -= v;
        }
        emit Transfer(from, address(0), v);
    }

    /*──────── lock guard ────────*/
    /// @dev Reverts if `who` is still locked.
    function _assertUnlocked(address who) internal view {
        uint64 t = _accounts[who].unlockAt;
        if (t != 0) require(block.timestamp >= t, "locked");
    }

    /*──────── cap guard ────────*/
    function _checkCap(uint64 inc) internal view {
        require(uint256(inc) <= uint256(MAX_BAL) - _tot, "cap");
    }

}
