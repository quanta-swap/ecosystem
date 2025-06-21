// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────
│  QSD – Wrapped-QRL-backed **stablecoin** with the complete Yield-Protocol
│  engine from WrappedQRL-Z (uint64 ZRC-20, multi-protocol staking, haircuts,
│  flash loans, 8-slot quad layout, free-lists, etc.).
│
│  Collateral: wQRL (immutable). Supply arises only via `borrow()` (mint) and
│  shrinks via `repay()` (burn). All other behaviour is identical to the
│  wrapper reference implementation.
│
│  ***Experimental research code – audit before production.***
└──────────────────────────────────────────────────────────────*/

/*────────  Re-entrancy guard  ────────*/
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

/* ───────── ReserveDEX minimal interface (pair: wQRL ↔ QSD) ───────── */
interface IReserveDEX {
    function RESERVE() external view returns (IZRC20);

    /* liquidity */
    function addLiquidity(
        address token,
        uint64  reserveDesired,
        uint64  tokenDesired
    ) external returns (uint128 shares, uint64 reserveUsed, uint64 tokenUsed);

    function removeLiquidity(
        address token,
        uint128 shares
    ) external returns (uint64 reserveOut, uint64 tokenOut);

    /* swap: RESERVE → token (fee paid in RESERVE) */
    function swapReserveForToken(
        address token,
        uint64  amountIn,
        uint64  minOut,
        address to
    ) external returns (uint64 amountOut);

    /*──────────────────── VIEW-ONLY SIMULATION ───────────────────*/
    function simulateReserveForToken(
        address token,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 amountOut);

    function simulateTokenForReserve(
        address token,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 amountOut);

    function simulateTokenForToken(
        address tokenFrom,
        address tokenTo,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 amountOut);
}

/* ───────── Liquidity-loan bookkeeping ───────── */
struct LiquidityLoan {
    uint128 shares;     // LP shares held in ReserveDEX
    uint64  qsdMinted;  // QSD originally minted (must be burnt on exit)
}

/*────────  uint64 ZRC-20 interface  ────────*/
interface IZRC20 {
    event Transfer(address indexed from, address indexed to, uint64 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint64 value
    );

    function totalSupply() external view returns (uint64);

    function balanceOf(address) external view returns (uint64);

    function allowance(address, address) external view returns (uint64);

    function transfer(address, uint64) external returns (bool);

    function approve(address, uint64) external returns (bool);

    function transferFrom(address, address, uint64) external returns (bool);
}

/*────────  Flash-loan interfaces  ────────*/
interface IZ156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint64 amount,
        uint64 fee,
        bytes calldata data
    ) external returns (bytes32);
}

interface IZ156FlashLender {
    function maxFlashLoan(address) external view returns (uint64);

    function flashFee(address, uint64) external view returns (uint64);

    function flashLoan(
        IZ156FlashBorrower receiver,
        address token,
        uint64 amount,
        bytes calldata data
    ) external returns (bool);
}

/*────────  Yield-Protocol surface  ────────*/
interface IYieldProtocol {
    /* events */
    event ProtocolCreated(
        uint64 pid,
        address ctrl,
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

    function signalHaircut(uint64 pid, uint64 amt) external returns (uint64);

    function collectHaircut(uint64 pid, address to) external returns (uint64);

    /* membership */
    function setMembership(uint64[8] calldata addPids, uint8 stayMask) external;
}

/*────────  Constants  ────────*/
uint8 constant DECIMALS = 8;
uint64 constant MAX_BAL = type(uint64).max;
uint64 constant MAX_LOCK = 2_628_000; // ~1 year
uint8 constant MAX_SLOTS = 8;
uint64 constant RATE_SCALE = 1e9; // 9-dec fixed-point
uint64 constant PRICE_SCALE = 1e8; // price feed scale
bytes32 constant FLASH_OK = keccak256("IZ156.ok");

/*────────  Yield data structs  ────────*/
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
│  QSD implementation
└────────────────────────────────────────────────────*/
contract QSD is IYieldProtocol, IZRC20, IZ156FlashLender, ReentrancyGuard {
    /*────────  Metadata  ────────*/
    string public constant name = "QRL-Synthetic-Dollar";
    string public constant symbol = "QSD";
    uint8 public constant decimals = DECIMALS;
    uint64 constant LIQ_BONUS_BP   = 11_000;         // <── 10 % keeper bonus

    /*────────  Collateral  ────────*/
    IZRC20 public immutable wQRL;

    /*────────  Balances & supply  ────────*/
    // TODO: Soft default logic.
    uint64 private _deadpool; // for soft-default events with liquidity loans
    uint64 private _tot;
    mapping(address => Account) private _acct;
    mapping(address => mapping(address => uint64)) private _allow;

    IReserveDEX public immutable dex;                 // AMM instance
    mapping(address => LiquidityLoan) public liqLoan; // user → position

    /*────────  Borrowing vaults  ────────*/
    struct Vault {
        uint64 collateral;
        uint64 debt;
        uint64 lastAcc;
    }
    mapping(address => Vault) public vaults;
    uint64 public immutable MCR; // basis-points
    uint64 public immutable ratePerSec; // 1e9 scale
    uint64 public wqrlPrice; // ×1e8
    address public immutable oracle;

    /*────────  Yield storage  ────────*/
    Protocol[] private _prot;
    Reserved[] private _res;
    Member[] private _mem;
    Quad[] private _quad;

    uint64[] private _freeRes;
    uint64[] private _freeMem;
    mapping(uint64 => bool) private _resFree;
    mapping(uint64 => bool) private _memFree;
    mapping(uint64 => uint256) private _mark; // dup detection

    /*────────  Events  ────────*/
    event Deposit(address indexed user, uint64 amount);
    event Withdraw(address indexed user, uint64 amount);
    event Borrow(address indexed user, uint64 amount);
    event Repay(address indexed user, uint64 amount);
    event Liquidate(
        address indexed vault,
        address indexed liquidator,
        uint64 repaid,
        uint64 collateral
    );
    event InterestAccrued(address indexed vault, uint64 interest);
    event PriceUpdated(uint64 newPrice, address indexed oracle);

    /*────────  Constructor  ────────*/
    constructor(
        address _wqrl,
        uint64 _mcrBp,
        uint64 _initPrice,
        address _oracle,
        uint64 _annualRateBp,
        address _dex
    ) {
        require(
            _wqrl != address(0) &&
                _initPrice > 0 &&
                _mcrBp >= 12500 &&
                _annualRateBp < 10000,
            "cfg"
        );
        wQRL = IZRC20(_wqrl);
        MCR = _mcrBp;
        wqrlPrice = _initPrice;
        oracle = _oracle;
        ratePerSec = uint64(
            (uint256(_annualRateBp) * RATE_SCALE) / (10000 * 365 days)
        );

        // slot-0 dummies so index 0 is always blank
        _prot.push();
        _res.push();
        _mem.push();
        _quad.push();
        dex = IReserveDEX(_dex);
        require(dex.RESERVE() == wQRL, "dex!=wQRL");
    }

    function _approveDex(uint64 wqrlAmt, uint64 qsdAmt) private {
        /* wQRL allowance (external token) */
        wQRL.approve(address(dex), wqrlAmt);              // ignore bool-return; reverts on false

        /* QSD self-allowance so ReserveDEX can pull freshly minted QSD */
        _allow[address(this)][address(dex)] = qsdAmt;
        emit Approval(address(this), address(dex), qsdAmt);
    }

    /**
     * liquidityLoanIn() – lock `wqrlAmt` from caller, mint equal-value QSD,
     * provide both as LP in ReserveDEX (wQRL ↔ QSD), and record the loan.
     *
     * 100 % LTV:  mintedQSD = wqrlAmt * wqrlPrice / 1e8
     * No interest accrues because the QSD sits inside this contract.
     */
    function liquidityLoanIn(uint64 wqrlAmt, uint128 minShares)
        external
        nonReentrant
        returns (uint128 shares)
    {
        require(wqrlAmt > 0, "zero");
        LiquidityLoan storage L = liqLoan[msg.sender];
        require(L.shares == 0, "loan live");                 // one loan per user

        /* pull collateral from caller */
        require(wQRL.transferFrom(msg.sender, address(this), wqrlAmt), "xfer in");

        /* mint QSD at 100 % LTV (uint64-safe check) */
        uint256 mint = (uint256(wqrlAmt) * wqrlPrice) / PRICE_SCALE;
        require(mint <= type(uint64).max, "big");
        uint64 qsdMint = uint64(mint);
        _mint(address(this), qsdMint);

        /* approve DEX to pull both sides */
        _approveDex(wqrlAmt, qsdMint);

        /* add liquidity – any ratio mismatch refunds stay with contract for burn/return */
        (uint128 sharesCreated, uint64 rUsed, uint64 tUsed) =
            dex.addLiquidity(address(this), wqrlAmt, qsdMint);
        require(shares >= minShares, "slip shares");
        shares = sharesCreated;                              // shares created by DEX

        /* tidy leftovers */
        if (rUsed < wqrlAmt)
            require(wQRL.transfer(msg.sender, wqrlAmt - rUsed), "wQRL refund");
        if (tUsed < qsdMint)
            _burn(address(this), qsdMint - tUsed);            // destroy unused QSD

        /* record the position */
        L.shares    = shares;
        L.qsdMinted = tUsed;                                  // tUsed ≤ qsdMint

        emit Borrow(msg.sender, qsdMint);                     // reuse event
    }

    /**
     * liquidityLoanOut – **now detects soft-default**.
     * If—using the DEX simulator—the withdrawn wQRL still cannot buy
     * the missing QSD, the entire wQRL haul is swept into `_deadpool`
     * and the loan is written off.  Otherwise the original logic runs.
     */
    function liquidityLoanOut(
        uint128 minSharesOut,
        uint64  minQsdOut,
        uint64  minBuyOut
    ) external nonReentrant
    {
        LiquidityLoan storage L = liqLoan[msg.sender];
        uint128 shares = L.shares;
        require(shares >= minSharesOut && shares > 0, "no-loan/slip");

        uint64 qsdOwed = L.qsdMinted;
        delete liqLoan[msg.sender];               // close position early

        (uint64 wqrlGot, uint64 qsdGot) =
            dex.removeLiquidity(address(this), shares);
        require(qsdGot >= minQsdOut, "qsd-slip");

        /* Happy-path: already have enough QSD */
        if (qsdGot >= qsdOwed) {
            _burn(address(this), qsdOwed);
            if (qsdGot > qsdOwed)
                _xfer(address(this), msg.sender, qsdGot - qsdOwed);
            if (wqrlGot > 0)
                require(wQRL.transfer(msg.sender, wqrlGot), "xfer");
            emit Repay(msg.sender, qsdOwed);
            return;
        }

        /* Need to buy the gap – first *simulate* */
        uint64 gap = qsdOwed - qsdGot;
        uint64 simOut = dex.simulateReserveForToken(address(this), wqrlGot, 0);

        /* SOFT-DEFAULT: even max swap cannot cover the gap */
        if (simOut < gap) {
            _deadpool += wqrlGot;                 // quarantine collateral
            if (qsdGot > 0) _burn(address(this), qsdGot);   // burn what we did recover
            emit Repay(msg.sender, qsdGot);       // partial
            return;
        }

        /* Otherwise execute the real swap */
        _approveDex(wqrlGot, 0);
        uint64 bought =
            dex.swapReserveForToken(address(this), wqrlGot, gap, address(this));
        require(bought >= gap && bought >= minBuyOut, "swap-fail");

        _burn(address(this), qsdOwed);
        uint64 surplus = qsdGot + bought - qsdOwed;
        if (surplus > 0) _xfer(address(this), msg.sender, surplus);
        emit Repay(msg.sender, qsdOwed);
    }

    /**
     * claimDeadpool – redeem `wqrlOut` of the quarantined collateral.
     *
     * QSD burned  =  wqrlOut × wqrlPrice ÷ 1e8      (exact USD parity)
     *
     * Reverts if:
     *  • pool has insufficient wQRL
     *  • burn would exceed caller’s limit (`maxQsdBurn`)
     *  • caller’s QSD balance is too small
     *
     * The burn is performed first; transfer happens last.
     */
    function claimDeadpool(uint64 wqrlOut, uint64 maxQsdBurn)
        external
        nonReentrant
    {
        require(wqrlOut > 0,          "zero");
        uint64 pool = _deadpool;
        require(pool >= wqrlOut,      "insuff-pool");

        // USD-parity burn   (uint256 math; PRICE_SCALE = 1e8)
        uint256 burn = (uint256(wqrlOut) * wqrlPrice) / PRICE_SCALE;
        require(burn <= type(uint64).max, "ovf");
        uint64 burnQsd = uint64(burn);
        require(burnQsd <= maxQsdBurn,    "slip");
        require(_acct[msg.sender].bal >= burnQsd, "bal");

        _burn(msg.sender, burnQsd);       // shrinks supply first
        _deadpool -= wqrlOut;             // update pool
        require(wQRL.transfer(msg.sender, wqrlOut), "xfer");
    }


    /*═══════════════  Collateral & Debt  ═══════════════*/
    /**
     * Add `amt` wQRL collateral to `who`’s vault.
     * Caller (`msg.sender`) must have given this contract an allowance
     * on the wQRL token for at least `amt`.
     *
     * Flow:
     *   1. accrue interest on the target vault
     *   2. pull wQRL from caller
     *   3. credit collateral to the target vault
     */
    function deposit(address who, uint64 amt) external {
        require(amt > 0, "zero");
        Vault storage v = vaults[who];
        _accrue(who, v);

        // Pull collateral **from the caller** (not from the vault owner).
        // This works because the caller approves the contract via the
        // normal ZRC-20 allowance mechanism.
        require(wQRL.transferFrom(msg.sender, address(this), amt), "xfer");

        v.collateral += amt;
        emit Deposit(who, amt);
    }

    function withdraw(uint64 amt) external {
        Vault storage v = vaults[msg.sender];
        _accrue(msg.sender, v);
        require(v.collateral >= amt, "excess");
        v.collateral -= amt;
        require(_healthy(v), "MCR");
        require(wQRL.transfer(msg.sender, amt), "xfer");
        emit Withdraw(msg.sender, amt);
    }

    function borrow(uint64 amt) external {
        Vault storage v = vaults[msg.sender];
        _accrue(msg.sender, v);
        v.debt += amt;
        require(_healthy(v), "MCR");
        _mint(msg.sender, amt);
        emit Borrow(msg.sender, amt);
    }

    /**
     * Burn caller’s QSD to repay `who`’s debt.
     * Anyone can do this—it only reduces system risk.
     *
     * Caller must already hold the QSD they want to burn.
     */
    function repay(address who, uint64 amt) external {
        require(amt > 0, "zero");
        Vault storage v = vaults[who];
        _accrue(who, v);

        require(v.debt >= amt, ">debt");

        // Burn QSD held by the caller.
        // (Assumes `_burn` checks caller’s balance; no allowance needed.)
        _burn(msg.sender, amt);

        v.debt -= amt;
        emit Repay(who, amt);
    }

    /* interest */
    function _accrue(address who, Vault storage v) internal {
        uint64 d = v.debt;
        if (d == 0) {
            v.lastAcc = uint64(block.timestamp);
            return;
        }
        uint64 last = v.lastAcc;
        if (last == 0) {
            v.lastAcc = uint64(block.timestamp);
            return;
        }
        uint64 dt = uint64(block.timestamp) - last;
        if (dt == 0) return;
        uint256 interest = (uint256(d) * ratePerSec * dt) / RATE_SCALE;
        require(interest <= type(uint64).max, "ovf");
        uint64 i = uint64(interest);
        v.debt += i;
        v.lastAcc = uint64(block.timestamp);
        emit InterestAccrued(who, i);
    }

    function _healthy(Vault storage v) internal view returns (bool) {
        if (v.debt == 0) return true;
        uint256 valUsd = (uint256(v.collateral) * wqrlPrice) / PRICE_SCALE;
        return valUsd >= (uint256(v.debt) * MCR) / 10000;
    }

    /*───────────────────────────────────────────────────────────────
    │  Liquidation with 10 % keeper bonus
    └──────────────────────────────────────────────────────────────*/
    function liquidate(address vaultAddr, uint64 maxRepay)
        external
        nonReentrant
    {
        // Liquidity-loan positions must self-close via liquidityLoanOut()
        require(liqLoan[vaultAddr].shares == 0, "liq-loan");

        Vault storage v = vaults[vaultAddr];
        _accrue(vaultAddr, v);                         // update interest first
        require(!_healthy(v), "healthy");              // vault must be unsafe

        uint64 repayAmt = maxRepay > v.debt ? v.debt : maxRepay;

        // Liquidator burns QSD they already hold
        _burn(msg.sender, repayAmt);

        // Seize collateral: proportional share * (1 + 10 % bonus), capped by vault
        uint256 seize = (uint256(v.collateral) *
                        repayAmt *
                        LIQ_BONUS_BP) / (uint256(v.debt) * 10_000);

        if (seize > v.collateral) seize = v.collateral;   // never underflow
        uint64 seizeWqrl = uint64(seize);

        v.debt       -= repayAmt;
        v.collateral -= seizeWqrl;

        require(wQRL.transfer(msg.sender, seizeWqrl), "xfer");

        emit Liquidate(vaultAddr, msg.sender, repayAmt, seizeWqrl);
    }

    /* oracle */
    modifier onlyOracle() {
        require(msg.sender == oracle, "oracle");
        _;
    }

    function setPrice(uint64 p) external onlyOracle {
        require(p > 0, "p0");
        wqrlPrice = p;
        emit PriceUpdated(p, msg.sender);
    }

    /*═══════════════  Yield-Protocol (identical to WrappedQRL-Z)  ═════════════*/
    modifier onlyCtrl(uint64 pid) {
        require(msg.sender == _prot[pid].ctrl, "ctrl");
        _;
    }

    function createProtocol(
        address ctrl,
        uint64 lockWin,
        uint64 minStake
    ) external override returns (uint64 id) {
        require(ctrl != address(0) && lockWin <= MAX_LOCK, "cfg");
        id = uint64(_prot.length);
        _prot.push(Protocol(ctrl, minStake, lockWin, 0, 0, 0, 0, 0));
        emit ProtocolCreated(id, ctrl, lockWin, minStake);
    }

    function setMinStake(
        uint64 pid,
        uint64 newMin
    ) external override onlyCtrl(pid) {
        _prot[pid].minStake = newMin;
        emit MinStakeUpdated(pid, newMin);
    }

    function addYield(uint64 pid, uint64 tok) external override nonReentrant {
        require(tok > 0, "0");
        Protocol storage p = _prot[pid];
        require(p.inBal > 0, "noStake");
        _harvest(msg.sender);
        Account storage a = _acct[msg.sender];
        require(a.bal >= tok, "bal");
        _enforceMinStake(msg.sender, a.bal - tok);
        _subBal(msg.sender, tok);
        _addBal(address(this), tok);
        uint192 q = (uint192(tok) << 64) / uint192(p.inBal);
        p.yAcc += q;
        emit YieldAdded(pid, tok);
    }

    function signalHaircut(
        uint64 pid,
        uint64 amt
    ) external override onlyCtrl(pid) returns (uint64) {
        require(amt > 0, "0");
        Protocol storage p = _prot[pid];
        require(p.inBal >= p.outBal + amt, "ex");
        p.outBal += amt;
        emit HaircutSignalled(pid, amt);
        return uint64(p.burned - p.collected);
    }

    function collectHaircut(
        uint64 pid,
        address to
    ) external override onlyCtrl(pid) nonReentrant returns (uint64 minted) {
        Protocol storage p = _prot[pid];
        if (p.burned > p.collected) {
            uint128 avail = p.burned - p.collected;
            require(avail <= MAX_BAL, "big");
            p.collected += avail;
            _mint(to, uint64(avail));
            emit HaircutCollected(pid, uint64(avail));
            return uint64(avail);
        }
    }

    /*────────  Membership (quad/slot)  ────────*/
    function setMembership(
        uint64[8] calldata addPids,
        uint8 stayMask
    ) external override nonReentrant {
        _harvest(msg.sender);
        Account storage a = _acct[msg.sender];
        uint256 tag = block.number;
        uint256 plen = _prot.length;

        // 1. handle current slots
        for (uint8 s; s < MAX_SLOTS; ++s) {
            if ((a.mask & (1 << s)) != 0) {
                uint64 pid = _member(a, s).pid;
                if ((stayMask & (1 << s)) != 0) {
                    _mark[pid] = tag; // keep
                } else {
                    _leaveSlot(a, s);
                }
            }
        }

        // 2. mark add-list
        for (uint8 i; i < MAX_SLOTS; ++i) {
            uint64 pid = addPids[i];
            if (pid != 0) {
                require(pid < plen, "pid");
                require(_mark[pid] != tag, "dup");
                _mark[pid] = tag;
            }
        }

        // 3. join new
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

    /*────────  Flash-loan  ────────*/
    function maxFlashLoan(address) external view override returns (uint64) {
        return MAX_BAL - _tot;
    }

    function flashFee(address, uint64) external pure override returns (uint64) {
        return 0;
    }

    function flashLoan(
        IZ156FlashBorrower r,
        address t,
        uint64 amt,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        require(t == address(this), "tok");
        require(!_hasMembership(address(r)), "member");
        address borrower = address(r);
        require(msg.sender == borrower, "rcv");
        uint64 balBefore = _acct[borrower].bal;
        require(_allow[borrower][address(this)] == 0, "pre-allow");
        require(amt <= MAX_BAL - _tot, "supply");
        _mint(borrower, amt);
        require(
            r.onFlashLoan(address(this), t, amt, 0, data) == FLASH_OK,
            "cb"
        );
        uint64 allow = _allow[borrower][address(this)];
        require(allow >= amt, "repay");
        _allow[borrower][address(this)] = allow - amt;
        emit Approval(borrower, address(this), allow - amt);
        _burn(borrower, amt);
        require(_acct[borrower].bal == balBefore, "bal-change");
        _refreshSnap(borrower);
        return true;
    }

    /*═══════════════  Internal: quad/slot helpers  ═════════════*/
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

    /* join */
    function _joinPid(Account storage a, uint64 pid) internal {
        Protocol storage pr = _prot[pid];
        require(a.bal >= pr.minStake, "minStake");
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

    /* leave */
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

    /* propagate balance delta to stake snapshots */
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

    /* harvest yield & haircuts */
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
            // haircuts
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
            // yield
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
            // refresh snapshot
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

    function _enforceMinStake(address who, uint64 newBal) internal view {
        Account storage a = _acct[who];
        uint8 m = a.mask;
        for (uint8 s; s < MAX_SLOTS; ++s)
            if ((m & (1 << s)) != 0) {
                uint64 jm = _res[_member(a, s).resPtr].joinMin;
                require(newBal >= jm, "minStake");
            }
    }

    /* balances & ERC-20 core */
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

    function transfer(
        address to,
        uint64 v
    ) external override nonReentrant returns (bool) {
        _harvest(msg.sender);
        _harvest(to);
        _xfer(msg.sender, to, v);
        return true;
    }

    function approve(address s, uint64 v) external override returns (bool) {
        _allow[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
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
        _addBal(to, v);
        _tot += v;
        emit Transfer(address(0), to, v);
    }

    function _burn(address from, uint64 v) internal {
        _subBal(from, v);
        _tot -= v;
        emit Transfer(from, address(0), v);
    }

    /* allocs */
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

    function _hasMembership(address who) internal view returns (bool) {
        return _acct[who].mask != 0;
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

    /* yield view helpers */
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
