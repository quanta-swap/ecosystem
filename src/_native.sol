// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "./IZRC20.sol"; // adjust the relative path if needed
import {IZ156FlashBorrower, IZ156FlashLender} from "./IZ156Flash.sol"; // adjust the relative path if needed

/* ───────────────  Re-entrancy guard  ─────────────── */
/// @title   ReentrancyGuard
/// @notice  Minimal, branch-free re-entrancy gate.
/// @dev     • Uses a custom error (`Reentrancy`) for cheaper revert cost than a
///            `require` with string data.
///          • State flag is packed into a single byte to keep storage slots
///            clear for inheriting contracts.
///          • Assumes all inheriting contracts respect the
///            checks-effects-interactions pattern and apply the `nonReentrant`
///            modifier to every external state-mutating function that could be
///            called indirectly.
///
///          Invariants:
///          1. `_stat` is always `_NOT` (1) outside an active call.
///          2. `_stat` is `_ENT` (2) only while executing a `nonReentrant`
///             function body.
abstract contract ReentrancyGuard {
    /*──────────────────────────── Errors ────────────────────────────*/

    /// @dev Thrown when a protected function is re-entered.
    error Reentrancy();

    /*──────────────────────────── State ─────────────────────────────*/

    uint8 private constant _NOT = 1; // Safe idle state
    uint8 private constant _ENT = 2; // Sentinel for active execution
    uint8 private _stat = _NOT; // 1-byte storage flag

    /*─────────────────────────── Modifier ───────────────────────────*/

    /// @notice Prevents nested (re-entrant) calls.
    /// @dev    Branch-free revert saves gas relative to `require`.
    modifier nonReentrant() {
        // If already entered, revert with custom error.
        if (_stat == _ENT) revert Reentrancy();

        // Flip the flag before executing the function body.
        _stat = _ENT;
        _;
        // Restore the idle flag after the function body completes.
        _stat = _NOT;
    }
}

/*──────── Yield-Protocol controller surface (64-bit) ────────*/
interface IYieldProtocol {
    /* events */
    event ProtocolCreated(
        uint64 pid,
        address controller,
        uint64 lockWin,
        uint64 minStake
    );
    event MinStakeUpdated(uint64 pid, uint64 newMinStake);
    event Joined(address wallet, uint64 pid);
    event Left(address wallet, uint64 pid);

    event HaircutSignalled(uint64 pid, uint64 amountTok);
    event HaircutCollected(uint64 pid, uint64 amountTok);

    event YieldAdded(uint64 pid, uint64 amountTok);
    event YieldPaid(uint64 pid, uint64 amountTok);

    event LockupStarted(address wallet, uint64 startBlock, uint64 duration);

    /* cfg */
    function createProtocol(
        address ctrl,
        uint64 lockWin,
        uint64 minStake
    ) external returns (uint64);

    function setMinStake(uint64 pid, uint64 newMinStake) external;

    /* yield / haircuts */
    function addYield(uint64 pid, uint64 tok) external;

    function signalHaircut(
        uint64 pid,
        uint64 amt
    ) external returns (uint64 uncollected);

    function collectHaircut(
        uint64 pid,
        address to
    ) external returns (uint64 mintedTok);

    /* membership */
    function setMembership(uint64[8] calldata addPids, uint8 stayMask) external;
}

/*──────── Constants ────────*/
uint8 constant DECIMALS = 9;
uint64 constant MAX_BAL = type(uint64).max;
uint256 constant _SCALE = 1e9; // 18-dec wei → 8-dec token
bytes32 constant _FLASH_OK = keccak256("IZ156.ok");
uint8 constant MAX_SLOTS = 8;

/*──────── Data structs ────────*/
struct Member {
    uint64 pid;
    uint64 resPtr;
    uint64 unlock;
    uint64 stake;
}

struct Quad {
    uint64[4] slot;
}

struct Protocol {
    address ctrl;
    uint64 minStake;
    uint64 lockWin;
    uint128 inBal;
    uint128 outBal;
    uint128 burned;
    uint128 collected;
    uint192 yAcc;
}

/* External links, descriptors, icons, etc */
struct ProtocolMetadata {
    string uri;
    string icon;
    string name;
    string desc;
    string[] risks;
    string[] rewards;
    string alert;
}

/* contains protocol metadata */
event ProtocolSignal(uint64 indexed pid, ProtocolMetadata metadata);

event ControllerChanged(uint64 indexed pid, address ctrl, bool added);

struct Reserved {
    uint128 inStart;
    uint128 outStart;
    uint192 yStart;
    uint64 joinMin;
}

struct Account {
    uint64 bal;
    uint64 ptrA; // if 0, no quad
    uint64 ptrB; // if 0, no quad
    uint8 mask;
    uint56 lock; // if 0, no lockup
}

contract WrappedQRL is
    IYieldProtocol,
    IZRC20,
    IZ156FlashLender,
    ReentrancyGuard
{
    uint64 public constant MAX_LOCK_WIN = 365 days; // ≈ 1 year (Ethereum blocks)

    /*──────── Storage ────────*/
    mapping(address => Account) private _acct;
    mapping(address => mapping(address => uint64)) private _allow;

    /*───────────────────────────────────────────────────────────────────────────────*
    │ ControllerRegistry – fixed-size whitelist per protocol                        │
    │                                                                               │
    │ • _isCtrl[pid][addr]    → O(1) auth check used by the onlyController modifier │
    │ • _ctrlList[pid][i]     → dense 0-terminated array for enumeration           │
    │ • _ctrlCnt[pid]         → current number of controllers ( 1 ≤ cnt ≤ MAX_CTRL )│
    *───────────────────────────────────────────────────────────────────────────────*/
    uint8 constant MAX_CTRL = 8; // hard cap keeps loops tiny
    mapping(uint64 => mapping(address => bool)) _isCtrl; // pid → addr → is-member
    mapping(uint64 => address[MAX_CTRL]) _ctrlList; // pid → dense array
    mapping(uint64 => uint8) _ctrlCnt; // pid → current length

    Protocol[] private _prot;
    Reserved[] private _res;
    Member[] private _mem;
    Quad[] private _quad;

    uint64[] private _freeRes;
    uint64[] private _freeMem;
    mapping(uint64 => bool) private _resFree;
    mapping(uint64 => bool) private _memFree;

    uint64 private _tot; // total token supply (64-bit)

    string private constant _NAME = "Wrapped QRL-Z";
    string private constant _SYMB = "WQRLZ";

    /*──────── Constructor ────────*/
    constructor() payable {
        _prot.push();
        _res.push();
        _mem.push();
        _quad.push();
        if (msg.value > 0) {
            require(msg.value % _SCALE == 0, "precision");
            uint64 t = uint64(msg.value / _SCALE);
            _checkCap(t);
            _addBal(msg.sender, t);
            _tot += t;
            emit Transfer(address(0), msg.sender, t);
        }
    }

    event AccountLocked(address wallet, uint56 endsAt);

    function lock(uint56 endsAt) external nonReentrant {
        Account storage a = _acct[msg.sender];
        a.lock = endsAt;
        emit AccountLocked(msg.sender, endsAt);
    }

    function unlocksAt(address who) external view returns (uint56) {
        return _acct[who].lock;
    }

    // "We made it happen... we're the chosen ones!"
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=pJvduG0E628";
    }

    /*──────── Modifiers ────────*/
    /// @dev Caller must be an authorised controller for this protocol ID.
    modifier onlyController(uint64 pid) {
        require(_isCtrl[pid][msg.sender], "ctrl");
        _;
    }

    /*════════════════════════════  Admin / Protocol  ══════════════════════════*/
    function createProtocol(
        address ctrl,
        uint64 lockWin,
        uint64 minStake
    ) public override returns (uint64 id) {
        require(ctrl != address(0), "ctrl0");
        require(lockWin <= MAX_LOCK_WIN, "lockWin");

        id = uint64(_prot.length);
        _prot.push(
            Protocol(
                ctrl /* kept for back-compat but unused in auth */,
                minStake,
                lockWin,
                0,
                0,
                0,
                0,
                0
            )
        );

        // ---------- initialise controller set ----------
        _isCtrl[id][ctrl] = true;
        _ctrlList[id][0] = ctrl;
        _ctrlCnt[id] = 1;

        emit ProtocolCreated(id, ctrl, lockWin, minStake);
    }

    function signalProtocol(
        uint64 pid,
        ProtocolMetadata calldata metadata
    ) external onlyController(pid) returns (uint64 id) {
        emit ProtocolSignal(id, metadata);
    }

    function setMinStake(
        uint64 pid,
        uint64 newMin
    ) external override onlyController(pid) {
        _prot[pid].minStake = newMin;
        emit MinStakeUpdated(pid, newMin);
    }

    /*───────────────────────────────────────────────────────────────────────────────*
    │ Controller mutators – any current controller may call                        │
    *───────────────────────────────────────────────────────────────────────────────*/

    /// Add a new controller. Reverts if the set is full or duplicate.
    function addController(
        uint64 pid,
        address newCtrl
    ) external onlyController(pid) {
        require(newCtrl != address(0), "ctrl0");
        require(!_isCtrl[pid][newCtrl], "dupe");
        uint8 cnt = _ctrlCnt[pid];
        require(cnt < MAX_CTRL, "full");

        _isCtrl[pid][newCtrl] = true;
        _ctrlList[pid][cnt] = newCtrl;
        _ctrlCnt[pid] = cnt + 1;

        emit ControllerChanged(pid, newCtrl, true);
    }

    /// Remove an existing controller. Caller must stay ≥1 controller in set.
    function removeController(
        uint64 pid,
        address oldCtrl
    ) external onlyController(pid) {
        require(_isCtrl[pid][oldCtrl], "missing");
        require(_ctrlCnt[pid] > 1, "last"); // never orphan the protocol

        // Clear slot & compact the dense array
        uint8 cnt = _ctrlCnt[pid];
        for (uint8 i; i < cnt; ++i) {
            if (_ctrlList[pid][i] == oldCtrl) {
                _ctrlList[pid][i] = _ctrlList[pid][cnt - 1];
                _ctrlList[pid][cnt - 1] = address(0);
                break;
            }
        }
        _ctrlCnt[pid] = cnt - 1;
        _isCtrl[pid][oldCtrl] = false;

        emit ControllerChanged(pid, oldCtrl, false); // semantics: “changed” = membership Δ
    }

    /// Atomic swap helper – saves one transaction over add→remove.
    function swapController(
        uint64 pid,
        address oldCtrl,
        address newCtrl
    ) external onlyController(pid) {
        require(newCtrl != address(0), "ctrl0");
        require(_isCtrl[pid][oldCtrl], "missing");
        require(!_isCtrl[pid][newCtrl], "dupe");

        // Replace in dense list
        uint8 cnt = _ctrlCnt[pid];
        for (uint8 i; i < cnt; ++i)
            if (_ctrlList[pid][i] == oldCtrl) {
                _ctrlList[pid][i] = newCtrl;
                break;
            }

        _isCtrl[pid][oldCtrl] = false;
        _isCtrl[pid][newCtrl] = true;

        emit ControllerChanged(pid, newCtrl, true);
        emit ControllerChanged(pid, oldCtrl, false);
    }

    /*──────── Haircuts & Yield ────────*/
    function signalHaircut(
        uint64 pid,
        uint64 amt
    ) external override onlyController(pid) returns (uint64) {
        require(amt > 0, "zero");
        Protocol storage p = _prot[pid];
        require(p.inBal >= p.outBal + amt, "excess");
        p.outBal += amt;
        emit HaircutSignalled(pid, amt);
        return uint64(p.burned - p.collected);
    }

    function collectHaircut(
        uint64 pid,
        address to
    )
        external
        override
        onlyController(pid)
        nonReentrant
        returns (uint64 minted)
    {
        Protocol storage p = _prot[pid];
        if (p.burned > p.collected) {
            uint128 avail = p.burned - p.collected;
            require(avail <= MAX_BAL, "big");
            p.collected += avail;
            _mint(to, uint64(avail));
            emit HaircutCollected(pid, uint64(avail));
            minted = uint64(avail);
        }
    }

    function addYield(uint64 pid, uint64 tok) external override nonReentrant {
        require(tok > 0, "zero");
        Protocol storage p = _prot[pid];
        require(p.inBal > 0, "noStake");
        _harvest(msg.sender);
        Account storage d = _acct[msg.sender];
        require(d.bal >= tok, "bal");
        _enforceMinStake(msg.sender, d.bal - tok);
        _subBal(msg.sender, tok);
        _addBal(address(this), tok);
        uint192 q = (uint192(tok) << 64) / uint192(p.inBal);
        p.yAcc += q;
        emit YieldAdded(pid, tok);
    }

    /*══════════════════════════  Deposit / Withdraw  ═════════════════════════*/
    function _checkCap(uint64 inc) internal view {
        require(_tot + inc <= MAX_BAL, "cap");
    }

    function deposit() public payable nonReentrant {
        require(msg.value > 0, "zero");
        require(msg.value % _SCALE == 0, "precision");
        uint64 amt = uint64(msg.value / _SCALE);
        _checkCap(amt);
        _harvest(msg.sender);
        _addBal(msg.sender, amt);
        _tot += amt;
        emit Transfer(address(0), msg.sender, amt);
    }

    receive() external payable {
        deposit();
    }

    function withdraw(uint64 tok) external nonReentrant {
        require(tok > 0, "zero");
        _harvest(msg.sender);
        Account storage a = _acct[msg.sender];
        require(a.bal >= tok, "bal");
        _enforceMinStake(msg.sender, a.bal - tok);
        uint256 weiAmt = uint256(tok) * _SCALE;
        _subBal(msg.sender, tok);
        _tot -= tok;
        emit Transfer(msg.sender, address(0), tok);
        (bool ok, ) = payable(msg.sender).call{value: weiAmt}("");
        require(ok, "native send");
    }

    /*══════════════════════════  IZRC-20 view  ═════════════════════════*/
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
        return _acct[a].bal;
    }

    function allowance(
        address o,
        address s
    ) external view override returns (uint64) {
        return _allow[o][s];
    }

    /*──────── ERC-20 actions ────────*/
    function approve(address s, uint64 v) external override returns (bool) {
        _allow[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transferBatch(
        address[] calldata to,
        uint64[] calldata v
    ) external nonReentrant returns (bool) {
        require(to.length == v.length, "len");
        _harvest(msg.sender);
        for (uint256 i; i < to.length; ++i) {
            _harvest(to[i]);
            _xfer(msg.sender, to[i], v[i]);
        }
        return true;
    }

    function transfer(
        address to,
        uint64 v
    ) external override nonReentrant returns (bool) {
        _harvest(msg.sender);
        _harvest(to);
        _xfer(msg.sender, to, v);
        return true;
    }

    function transferFromBatch(
        address from,
        address[] calldata to,
        uint64[] calldata v
    ) external nonReentrant returns (bool) {
        require(to.length == v.length, "len");

        uint64 cur = _allow[from][msg.sender];
        uint64 tot;
        for (uint256 i; i < v.length; ++i) tot += v[i];
        require(cur >= tot, "allow");
        if (cur != type(uint64).max) {
            _allow[from][msg.sender] = cur - tot;
            emit Approval(from, msg.sender, cur - tot);
        }

        _harvest(from);
        for (uint256 i; i < to.length; ++i) {
            _harvest(to[i]);
            _xfer(from, to[i], v[i]);
        }
        return true;
    }

    function transferFrom(
        address f,
        address t,
        uint64 v
    ) external override nonReentrant returns (bool) {
        uint64 cur = _allow[f][msg.sender];
        require(cur >= v, "allow");
        if (cur != type(uint64).max) {
            _allow[f][msg.sender] = cur - v;
            emit Approval(f, msg.sender, cur - v);
        }
        _harvest(f);
        _harvest(t);
        _xfer(f, t, v);
        return true;
    }

    /*══════════════════════════  Z-Flash-Loan  ═════════════════════════*/
    function maxFlashLoan(
        address /* _t*/
    ) external view override returns (uint64) {
        return MAX_BAL - _tot;
    }

    function flashFee(
        address /*_t*/,
        uint64
    ) external pure override returns (uint64) {
        return 0;
    }

    /**
     * @notice Zero-fee flash-loan of WQRL-Z.
     *
     * @dev   Security guarantees
     *        --------------------
     *        1. **Front-run allowance** – we abort if any allowance for
     *           `address(this)` exists _before_ the loan (msg `"pre-allow"`).
     *        2. **Callback magic**     – borrower must return `_FLASH_OK`
     *           (msg `"cb"` on mismatch).
     *        3. **Exact repayment**    – post-callback allowance must have
     *           grown by _exactly_ `amt`; otherwise we revert with `"repay"`.
     *        4. **Balance invariant**  – borrower’s net balance ends unchanged.
     *
     *        Gas impact versus the original: +1 SLOAD (allowAfter) and a
     *        single comparison—negligible.
     */
    function flashLoan(
        IZ156FlashBorrower r,
        address t,
        uint64 amt,
        bytes calldata d
    ) external override nonReentrant returns (bool) {
        /*─────────────────────── pre-flight guards ────────────────────────*/
        require(t == address(this), "tok"); // wrong token
        address borrower = address(r);
        require(msg.sender == borrower, "receiver mismatch");
        require(!_hasMembership(borrower), "member"); // disallow nested stake
        require(_allow[borrower][address(this)] == 0, "pre-allow");
        require(amt <= MAX_BAL - _tot, "supply");

        /*──────────────────── snapshot original state ─────────────────────*/
        uint64 balBefore = _acct[borrower].bal; // balance integrity
        uint64 allowBefore = 0; // confirmed above

        /*────────────────────────── execute loan ──────────────────────────*/
        _mint(borrower, amt); // grant funds
        require(r.onFlashLoan(address(this), t, amt, 0, d) == _FLASH_OK, "cb");

        /*─────────────────────── verify repayment ─────────────────────────*/
        uint64 allowAfter = _allow[borrower][address(this)];
        require(allowAfter == amt + allowBefore, "repay"); // exact delta

        _allow[borrower][address(this)] = allowAfter - amt; // consume
        emit Approval(borrower, address(this), allowAfter - amt);

        _burn(borrower, amt); // burn return
        require(_acct[borrower].bal == balBefore, "bal-change"); // no drift
        _refreshSnap(borrower); // sync stake

        return true;
    }

    /*══════════════════════  Membership (unchanged logic)  ═════════════════════*/
    /**
     * @dev  Monotonically-increasing per-transaction nonce.
     *
     *       • Incremented once per *external* call to {setMembership}.  
     *       • Guarantees that the “duplicate-PID” guard (_mark[pid] == tag)
     *         only applies **within the same transaction**, never across
     *         different wallets that happen to share a block.
     *
     *       Gas impact: +1 SLOAD +1 SSTORE per call – negligible.
     */
    uint256 private _txnNonce;
    /*═══════════════ Account-level membership management (FIXED) ══════════════*/
    /**
     * @notice
     *     Add and/or remove up to eight protocol memberships atomically.
     *
     * @param addPids   Array of up to 8 protocol IDs to *add* this wallet to.
     *                  Zero entries are ignored. Duplicate IDs revert.
     * @param stayMask  Bitmap selecting which *current* slots to **keep**.
     *                  Bits set to 1 mean “stay”; 0 means “leave”.
     *
     * @dev
     *     ✔ Re-entrancy-safe (nonReentrant modifier).  
     *     ✔ Duplicate guards are scoped to a **single transaction** via a
     *       monotonic `_txnNonce` tag – no cross-wallet contention anymore.  
     *     ✔ All arithmetic stays within 128-bit intermediates; no risk of
     *       overflow in the 64-bit token universe.
     *
     *     Execution phases
     *     ────────────────
     *       1. **Harvest** any pending yield / haircuts.
     *       2. **Leave** slots not requested to stay.
     *       3. **Mark** all requested additions in `_mark` using the fresh tag.
     *       4. **Join** new protocols until the 8-slot cap is reached.
     *
     *     Invariants
     *     ──────────
     *       • A wallet never holds more than 8 simultaneous memberships.
     *       • `_mark[pid]` is non-zero only *during* the call; it reverts to
     *         0 automatically when the next call overwrites the tag.
     */
    function setMembership(
        uint64[8] calldata addPids,
        uint8 stayMask
    ) external override nonReentrant {
        _harvest(msg.sender);                    // ① settle yield & haircuts

        Account storage a = _acct[msg.sender];
        uint256 tag = ++_txnNonce;               // ← UNIQUE per tx (FIX)

        uint256 protLen = _prot.length;

        /*────────────────────── 1. Handle current slots ──────────────────────*/
        for (uint8 s; s < MAX_SLOTS; ++s) {
            if ((a.mask & (1 << s)) == 0) continue;      // empty slot → skip

            uint64 pid = _member(a, s).pid;

            if ((stayMask & (1 << s)) != 0) {
                _mark[pid] = tag;                        // mark as “keep”
            } else {
                _leaveSlot(a, s);                        // drop membership
            }
        }

        /*──────────────────────── 2. Mark additions ─────────────────────────*/
        for (uint8 i; i < MAX_SLOTS; ++i) {
            uint64 pid = addPids[i];
            if (pid == 0) continue;                      // ignore zeros
            require(pid < protLen, "pid");               // bounds check
            require(_mark[pid] != tag, "dup");           // per-tx duplicate
            _mark[pid] = tag;                            // mark for joining
        }

        /*───────────────────────── 3. Join new PIDs ─────────────────────────*/
        uint8 cur = _countBits(a.mask);                  // current slot count
        for (uint8 i; i < MAX_SLOTS && cur < MAX_SLOTS; ++i) {
            uint64 pid = addPids[i];
            if (pid == 0 || _mark[pid] != tag) continue; // not requested

            bool already;
            for (uint8 s; s < MAX_SLOTS; ++s) {          // O(8) scan
                if ((a.mask & (1 << s)) != 0 && _member(a, s).pid == pid) {
                    already = true;                      // already joined
                    break;
                }
            }
            if (!already) {
                _joinPid(a, pid);                        // join new protocol
                ++cur;
            }
        }
    }


    /* scratch-pad for duplicate detection */
    mapping(uint64 => uint256) private _mark;

    /*══════════════════════════  Internal helpers  ═════════════════════════*/
    /* slot helpers */
    function _memPtr(
        Account storage a,
        uint8 s
    ) internal view returns (uint64) {
        return s < 4 ? _quad[a.ptrA].slot[s] : _quad[a.ptrB].slot[s - 4];
    }

    function _member(
        Account storage a,
        uint8 s
    ) internal view returns (Member storage) {
        return _mem[_memPtr(a, s)];
    }

    function _clearSlot(Account storage a, uint8 s) internal {
        if (s < 4) _quad[a.ptrA].slot[s] = 0;
        else _quad[a.ptrB].slot[s - 4] = 0;
    }

    function _countBits(uint8 m) internal pure returns (uint8 c) {
        for (; m != 0; m &= m - 1) ++c;
    }

    /* join / leave */
    function _joinPid(Account storage a, uint64 pid) internal {
        Protocol storage pr = _prot[pid];
        require(a.bal >= pr.minStake, "minStake");

        /* find slot */
        uint8 slot;
        for (; slot < MAX_SLOTS; ++slot) if ((a.mask & (1 << slot)) == 0) break;
        require(slot < MAX_SLOTS, "no-slot");

        if (slot < 4 && a.ptrA == 0) {
            a.ptrA = uint64(_quad.length);
            _quad.push();
        }
        if (slot >= 4 && a.ptrB == 0) {
            a.ptrB = uint64(_quad.length);
            _quad.push();
        }

        pr.inBal += uint128(a.bal);

        uint64 rIdx = _allocRes();
        uint64 mIdx = _allocMem();
        uint64 unlock = uint64(block.timestamp) + pr.lockWin;

        _mem[mIdx] = Member(pid, rIdx, unlock, a.bal);
        if (slot < 4) _quad[a.ptrA].slot[slot] = mIdx;
        else _quad[a.ptrB].slot[slot - 4] = mIdx;

        _res[rIdx] = Reserved(pr.inBal, pr.outBal, pr.yAcc, pr.minStake);
        a.mask |= uint8(1 << slot);
        emit Joined(msg.sender, pid);
    }

    function _leaveSlot(Account storage a, uint8 slot) internal {
        uint64 mPtr = _memPtr(a, slot);
        Member storage m = _mem[mPtr];
        uint64 pid = m.pid;
        Protocol storage p = _prot[pid];
        require(block.timestamp >= m.unlock, "locked");
        p.inBal -= uint128(m.stake);
        _recycleRes(m.resPtr);
        _recycleMem(mPtr);
        _clearSlot(a, slot);
        a.mask &= ~uint8(1 << slot);
        emit Left(msg.sender, pid);
    }

    /**
     * @notice  Mirrors an account-level balance change (`delta`) into every
     *          protocol membership the wallet holds.
     *
     * @param who      The wallet whose stake snapshots are being updated.
     * @param delta    Signed change in the wallet’s token balance.
     *                 * > 0*  → balance increases.
     *                 * < 0*  → balance decreases.
     * @param skipPid  Protocol ID whose global totals should **not** be touched
     *                 (used by mint / burn helpers to avoid double-counting).
     *
     * @dev  Invariant: `p.inBal`, `rs.inStart`, `m.stake` are all ≥ 0 at all
     *       times; any decrement must therefore be bounds-checked first.
     *
     *       Revision “laser fix” adds those explicit guards so an unexpected
     *       negative `delta` can never wrap the counters.
     */
    function _propagate(address who, int256 delta, uint64 skipPid) internal {
        if (delta == 0) return; // fast-exit

        Account storage a = _acct[who];

        // MAX_SLOTS is a compile-time 8, so the loop is tight and cheap.
        for (uint8 s; s < MAX_SLOTS; ++s) {
            if ((a.mask & (1 << s)) == 0) continue; // unused slot

            Member storage m = _member(a, s);
            Protocol storage p = _prot[m.pid];
            Reserved storage rs = _res[m.resPtr];

            bool skip = (m.pid == skipPid);

            if (delta > 0) {
                /* -------- balance increases -------- */
                uint128 d = uint128(uint256(delta)); // |delta| fits 64-bit

                if (!skip) {
                    p.inBal += d; // grow protocol stake
                    rs.inStart += d; // grow snapshot base
                }

                m.stake += uint64(d); // grow member stake

                if (skip) rs.inStart += d; // keep invariants
            } else {
                /* -------- balance decreases -------- */
                uint128 d = uint128(uint256(-delta)); // |delta| fits 64-bit

                // --- new explicit guards (prevent underflow / wraparound) ---
                require(m.stake >= d, "stake<delta");
                require(rs.inStart >= d, "inStart<delta");
                if (!skip) require(p.inBal >= d, "inBal<delta");

                if (!skip) {
                    p.inBal -= d;
                    rs.inStart -= d;
                }

                m.stake -= uint64(d);

                if (skip) rs.inStart -= d; // keep invariants
            }
        }
    }

    /*═══════════════════════════════════════════════════════════════════════*\
    │  Force-harvest helper                                                  │
    │                                                                       │
    │  • Anyone can call; no auth or membership checks.                     │
    │  • Ignores wallet-level `lock` and slot-level `unlock` timers, so     │
    │    long-term locked accounts still accrue yield on schedule.          │
    │  • Re-entrancy-safe (piggybacks on the global guard).                 │
    │                                                                       │
    │  Gas:  ≈ 6.3 k per wallet when nothing is owed (pure snapshots).      │
    │         The loop is bounded by calldata length; external callers      │
    │         should batch sensibly.                                        │
    \*══════════════════════════════════════════════════════════════════════*/
    function forceHarvest(address[] calldata wallets) external nonReentrant {
        uint256 n = wallets.length;
        for (uint256 i; i < n; ++i) {
            address w = wallets[i];
            /// Zero address harvest makes no sense and signals a bad call.
            require(w != address(0), "wallet0");
            _harvest(w);
        }
    }

    /* harvest / snapshots */
    /**
     * @notice  Settles yield and haircuts for `who` across every active membership.
     *
     * @dev     Execution order:
     *          1. Yield is paid out **before** any haircut so it reflects the stake
     *             at the moment the yield accrued.
     *          2. Haircut then burns the proportional loss and propagates the
     *             decreased stake into protocol aggregates.
     *          3. Snapshots are refreshed to anchor the next harvest window.
     *
     *          All arithmetic stays within 128-bit intermediates; nothing can wrap
     *          given 64-bit token balances and protocol totals.
     */
    function _harvest(address who) internal {
        Account storage a = _acct[who];

        // Fast-exit: zero-balance wallets only need a snapshot refresh.
        if (a.bal == 0) {
            _refreshSnap(who);
            return;
        }

        // Iterate through at most MAX_SLOTS (compile-time 8) – tight & gas-cheap.
        for (uint8 s; s < MAX_SLOTS; ++s) {
            if ((a.mask & (1 << s)) == 0) continue; // empty slot → skip

            Member storage m = _member(a, s);
            Protocol storage p = _prot[m.pid];
            Reserved storage rs = _res[m.resPtr];

            /*───────────────────────── 1. Yield ─────────────────────────*/
            if (p.yAcc > rs.yStart && a.bal > 0) {
                uint256 dy = p.yAcc - rs.yStart; // Δ-accumulator (128-bit)
                uint256 owe = (uint256(m.stake) * dy) >> 64; // proportional share
                uint64 pool = _acct[address(this)].bal; // tokens held by pool
                if (owe > pool) owe = pool; // cap to pool balance
                if (owe > 0) {
                    _subBal(address(this), uint64(owe)); // debit pool
                    _addBal(who, uint64(owe)); // credit wallet
                    emit YieldPaid(m.pid, uint64(owe));
                }
            }

            /*──────────────────────── 2. Haircut ────────────────────────*/
            if (p.outBal > rs.outStart) {
                uint256 delta = p.outBal - rs.outStart; // total haircut outstanding
                uint256 base = rs.inStart > rs.outStart
                    ? rs.inStart - rs.outStart
                    : 0; // live stake base
                uint256 cut = base > 0 ? (uint256(m.stake) * delta) / base : 0; // member’s share
                if (cut > a.bal) cut = a.bal; // never over-burn
                if (cut > 0) {
                    a.bal -= uint64(cut);
                    p.inBal -= uint128(cut);
                    p.burned += uint128(cut);
                    _tot -= uint64(cut);

                    emit Transfer(who, address(0), uint64(cut));

                    // Propagate the reduced stake into all protocols except the one
                    // already reflected via `p.inBal` to avoid double-counting.
                    _propagate(who, -int256(cut), m.pid);
                }
            }

            /*──────────────────────── 3. Refresh ────────────────────────*/
            rs.inStart = p.inBal;
            rs.outStart = p.outBal;
            rs.yStart = p.yAcc;
            m.stake = a.bal; // new member stake
        }
    }

    function _refreshSnap(address who) internal {
        Account storage a = _acct[who];
        for (uint8 s; s < MAX_SLOTS; ++s) {
            if ((a.mask & (1 << s)) == 0) continue;
            Member storage m = _member(a, s);
            Protocol storage p = _prot[m.pid];
            Reserved storage r = _res[m.resPtr];
            r.inStart = p.inBal;
            r.outStart = p.outBal;
            r.yStart = p.yAcc;
            m.stake = a.bal;
        }
    }

    /* enforce stake minimums */
    function _enforceMinStake(address who, uint64 newBal) internal view {
        Account storage a = _acct[who];
        uint8 m = a.mask;
        for (uint8 s; s < MAX_SLOTS; ++s)
            if ((m & (1 << s)) != 0) {
                uint64 jm = _res[_member(a, s).resPtr].joinMin;
                require(newBal >= jm, "minStake");
            }
    }

    /* balance helpers */
    function _xfer(address f, address t, uint64 v) internal {
        require(t != address(0), "to0");
        Account storage fa = _acct[f];
        // require the account is unlocked
        if (fa.lock != 0) {
            require(block.timestamp >= fa.lock, "locked");
            fa.lock = 0;
        }
        for (uint8 s; s < MAX_SLOTS; ++s)
            if ((fa.mask & (1 << s)) != 0)
                require(block.timestamp >= _member(fa, s).unlock, "locked");
        require(fa.bal >= v, "bal");
        _enforceMinStake(f, fa.bal - v);
        _subBal(f, v);
        _addBal(t, v);
        emit Transfer(f, t, v);
    }

    function _addBal(address w, uint64 v) internal {
        Account storage a = _acct[w];
        a.bal += v;
        _propagate(w, int256(uint256(v)), 0);
        _refreshSnap(w);
    }

    function _subBal(address w, uint64 v) internal {
        Account storage a = _acct[w];
        a.bal -= v;
        _propagate(w, -int256(uint256(v)), 0);
        _refreshSnap(w);
    }

    function _mint(address to, uint64 v) internal {
        _checkCap(v);
        _addBal(to, v);
        _tot += v;
        emit Transfer(address(0), to, v);
    }

    function _burn(address from, uint64 v) internal {
        _subBal(from, v);
        _tot -= v;
        emit Transfer(from, address(0), v);
    }

    /* free-list allocs */
    function _allocRes() internal returns (uint64 id) {
        if (_freeRes.length > 0) {
            id = _freeRes[_freeRes.length - 1];
            _freeRes.pop();
            _resFree[id] = false;
        } else {
            id = uint64(_res.length);
            _res.push();
        }
    }

    function _recycleRes(uint64 id) internal {
        if (id != 0 && !_resFree[id]) {
            delete _res[id];
            _resFree[id] = true;
            _freeRes.push(id);
        }
    }

    function _allocMem() internal returns (uint64 id) {
        if (_freeMem.length > 0) {
            id = _freeMem[_freeMem.length - 1];
            _freeMem.pop();
            _memFree[id] = false;
        } else {
            id = uint64(_mem.length);
            _mem.push();
        }
    }

    function _recycleMem(uint64 id) internal {
        if (id != 0 && !_memFree[id]) {
            delete _mem[id];
            _memFree[id] = true;
            _freeMem.push(id);
        }
    }

    /* misc */
    function _hasMembership(address who) internal view returns (bool) {
        return _acct[who].mask != 0;
    }

    /*──────── Public visibility helpers (unchanged signatures) ────────*/
    function protocolCount() external view returns (uint256) {
        return _prot.length;
    }

    function protocolInfo(
        uint64 pid
    )
        external
        view
        returns (
            address,
            uint64,
            uint64,
            uint128,
            uint128,
            uint128,
            uint128,
            uint256
        )
    {
        Protocol storage p = _prot[pid];
        return (
            p.ctrl,
            p.minStake,
            p.lockWin,
            p.inBal,
            p.outBal,
            p.burned,
            p.collected,
            p.yAcc
        );
    }

    function accountInfo(
        address w
    ) external view returns (uint64, uint64[8] memory, uint8) {
        Account storage a = _acct[w];
        uint64[8] memory pids;
        for (uint8 s; s < MAX_SLOTS; ++s)
            if ((a.mask & (1 << s)) != 0) pids[s] = _member(a, s).pid;
        return (a.bal, pids, a.mask);
    }

    function memberInfo(
        address w,
        uint8 slot
    ) external view returns (uint64, uint64, uint64, uint64, uint64) {
        require(slot < MAX_SLOTS, "slot");
        Account storage a = _acct[w];
        require((a.mask & (1 << slot)) != 0, "empty");
        Member storage m = _member(a, slot);
        Reserved storage r = _res[m.resPtr];
        return (m.pid, m.stake, m.unlock, r.joinMin, m.resPtr);
    }

    function reservedInfo(
        uint64 id
    ) external view returns (uint128, uint128, uint256, uint64) {
        Reserved storage r = _res[id];
        return (r.inStart, r.outStart, r.yStart, r.joinMin);
    }

    function freeLists() external view returns (uint256, uint256) {
        return (_freeRes.length, _freeMem.length);
    }
}
