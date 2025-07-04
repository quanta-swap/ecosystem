// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "./IZRC20.sol";   // adjust the relative path if needed
import {IZ156FlashBorrower, IZ156FlashLender} from "./IZ156Flash.sol"; // adjust the relative path if needed
/*───────────────────────────────────────────────────────────────
│  IZRC-20 + Z-Flash + Yield-Protocol (64-bit token amounts)
│  Wrapped QRL – revision “Z-ae”
│  8 decimals   •   MAX_SUPPLY = 2⁶⁴-1 units  (≈1.84e11 whole coins)
───────────────────────────────────────────────────────────────*/

/* ───────────────  Re-entrancy guard  ─────────────── */
abstract contract ReentrancyGuard {
    uint8 private constant _NOT = 1;
    uint8 private constant _ENT = 2;
    uint8 private _stat = _NOT;
    modifier nonReentrant() {
        require(_stat != _ENT, "re-enter");
        _stat = _ENT;
        _;
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
uint8 constant DECIMALS = 8;
uint64 constant MAX_BAL = type(uint64).max;
uint256 constant _SCALE = 1e10; // 18-dec wei → 8-dec token
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
struct Reserved {
    uint128 inStart;
    uint128 outStart;
    uint192 yStart;
    uint64 joinMin;
}
struct Account {
    uint64 bal;
    uint64 ptrA;
    uint64 ptrB;
    uint8 mask;
}

/*─────────────────────────────────────────────────────
│  WrappedQRL-Z implementation
└────────────────────────────────────────────────────*/
contract WrappedQRL is
    IYieldProtocol,
    IZRC20,
    IZ156FlashLender,
    ReentrancyGuard
{
    uint64 public constant MAX_LOCK_WIN = 2_628_000; // ≈ 1 year (Ethereum blocks)

    /*──────── Storage ────────*/
    mapping(address => Account) private _acct;
    mapping(address => mapping(address => uint64)) private _allow;

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

    // "I can see it... the rise of a digital nation!"
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=O8CsM96SEtM";
    }

    /*──────── Modifiers ────────*/
    modifier onlyController(uint64 pid) {
        require(msg.sender == _prot[pid].ctrl, "ctrl");
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
        _prot.push(Protocol(ctrl, minStake, lockWin, 0, 0, 0, 0, 0));
        emit ProtocolCreated(id, ctrl, lockWin, minStake);
    }

    function setMinStake(
        uint64 pid,
        uint64 newMin
    ) external override onlyController(pid) {
        _prot[pid].minStake = newMin;
        emit MinStakeUpdated(pid, newMin);
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

    function transfer(
        address to,
        uint64 v
    ) external override nonReentrant returns (bool) {
        _harvest(msg.sender);
        _harvest(to);
        _xfer(msg.sender, to, v);
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
    function maxFlashLoan(address /* _t*/) external view override returns (uint64) {
        return MAX_BAL - _tot;
    }

    function flashFee(
        address /*_t*/,
        uint64
    ) external pure override returns (uint64) {
        return 0;
    }

    function flashLoan(
        IZ156FlashBorrower r,
        address t,
        uint64 amt,
        bytes calldata d
    ) external override nonReentrant returns (bool) {
        require(t == address(this), "tok");
        require(!_hasMembership(address(r)), "member");
        address borrower = address(r);
        require(msg.sender == borrower, "receiver mismatch");
        uint64 balBefore = _acct[borrower].bal;
        require(_allow[borrower][address(this)] == 0, "pre-allow");
        require(amt <= MAX_BAL - _tot, "supply");
        _mint(borrower, amt);
        require(r.onFlashLoan(address(this), t, amt, 0, d) == _FLASH_OK, "cb");
        uint64 allow = _allow[borrower][address(this)];
        require(allow >= amt, "repay");
        _allow[borrower][address(this)] = allow - amt;
        emit Approval(borrower, address(this), allow - amt);
        _burn(borrower, amt);
        require(_acct[borrower].bal == balBefore, "bal-change");
        _refreshSnap(borrower);
        return true;
    }

    /*══════════════════════  Membership (unchanged logic)  ═════════════════════*/
    function setMembership(
        uint64[8] calldata addPids,
        uint8 stayMask
    ) external override nonReentrant {
        _harvest(msg.sender);

        Account storage a = _acct[msg.sender];
        uint256 tag = block.number; // scratch tag
        uint256 protLen = _prot.length;

        /* 1. handle current slots */
        for (uint8 s; s < MAX_SLOTS; ++s) {
            if ((a.mask & (1 << s)) != 0) {
                uint64 pid = _member(a, s).pid;
                if ((stayMask & (1 << s)) != 0) {
                    _mark[pid] = tag; // keep
                } else {
                    _leaveSlot(a, s); // drop
                }
            }
        }

        /* 2. mark add-list */
        for (uint8 i; i < MAX_SLOTS; ++i) {
            uint64 pid = addPids[i];
            if (pid != 0) {
                require(pid < protLen, "pid");
                require(_mark[pid] != tag, "dup");
                _mark[pid] = tag;
            }
        }

        /* 3. join new */
        uint8 cur = _countBits(a.mask);
        for (uint8 i; i < MAX_SLOTS && cur < MAX_SLOTS; ++i) {
            uint64 pid = addPids[i];
            if (pid != 0 && _mark[pid] == tag) {
                bool already;
                for (uint8 s; s < MAX_SLOTS; ++s) {
                    if ((a.mask & (1 << s)) != 0 && _member(a, s).pid == pid) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    _joinPid(a, pid);
                    ++cur;
                }
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
        uint64 unlock = uint64(block.number) + pr.lockWin;

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
        require(block.number >= m.unlock, "locked");
        p.inBal -= uint128(m.stake);
        _recycleRes(m.resPtr);
        _recycleMem(mPtr);
        _clearSlot(a, slot);
        a.mask &= ~uint8(1 << slot);
        emit Left(msg.sender, pid);
    }

    /* propagation */
    function _propagate(address who, int256 delta, uint64 skipPid) internal {
        if (delta == 0) return;
        Account storage a = _acct[who];
        for (uint8 s; s < MAX_SLOTS; ++s) {
            if ((a.mask & (1 << s)) == 0) continue;
            Member storage m = _member(a, s);
            Protocol storage p = _prot[m.pid];
            Reserved storage rs = _res[m.resPtr];
            bool skip = (m.pid == skipPid);
            if (delta > 0) {
                uint128 d = uint128(uint256(delta));
                if (!skip) {
                    p.inBal += d;
                    rs.inStart += d;
                }
                m.stake += uint64(d);
                if (skip) rs.inStart += d;
            } else {
                uint128 d = uint128(uint256(-delta));
                if (!skip) {
                    p.inBal -= d;
                    rs.inStart -= d;
                }
                m.stake -= uint64(d);
                if (skip) rs.inStart -= d;
            }
        }
    }

    /* harvest / snapshots */
    function _harvest(address who) internal {
        Account storage a = _acct[who];
        if (a.bal == 0) {
            _refreshSnap(who);
            return;
        }
        for (uint8 s; s < MAX_SLOTS; ++s) {
            if ((a.mask & (1 << s)) == 0) continue;
            Member storage m = _member(a, s);
            Protocol storage p = _prot[m.pid];
            Reserved storage rs = _res[m.resPtr];

            /* haircuts */
            if (p.outBal > rs.outStart) {
                uint256 delta = p.outBal - rs.outStart;
                uint256 base = rs.inStart > rs.outStart
                    ? rs.inStart - rs.outStart
                    : 0;
                uint256 cut = base > 0 ? (uint256(m.stake) * delta) / base : 0;
                if (cut > a.bal) cut = a.bal;
                if (cut > 0) {
                    a.bal -= uint64(cut);
                    p.inBal -= uint128(cut);
                    p.burned += uint128(cut);
                    _tot -= uint64(cut);
                    emit Transfer(who, address(0), uint64(cut));
                    _propagate(who, -int256(cut), m.pid);
                }
            }

            /* yield */
            if (p.yAcc > rs.yStart && a.bal > 0) {
                uint256 dy = p.yAcc - rs.yStart;
                uint256 owe = (uint256(m.stake) * dy) >> 64;
                uint64 pool = _acct[address(this)].bal;
                if (owe > pool) owe = pool;
                if (owe > 0) {
                    _subBal(address(this), uint64(owe));
                    _addBal(who, uint64(owe));
                    emit YieldPaid(m.pid, uint64(owe));
                }
            }

            /* refresh */
            rs.inStart = p.inBal;
            rs.outStart = p.outBal;
            rs.yStart = p.yAcc;
            m.stake = a.bal;
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
        for (uint8 s; s < MAX_SLOTS; ++s)
            if ((fa.mask & (1 << s)) != 0)
                require(block.number >= _member(fa, s).unlock, "locked");
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
