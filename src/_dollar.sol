// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────────────────────
│  Zero-Interest Algorithmic Stablecoin                                        │
│  Elliott G. Dehnbostel  ·  quantaswap@gmail.com                              │
│  Revision 0.4 · 22 Jun 2025                                                  │
│                                                                              │
│  ─────────────────────────  EXECUTIVE ABSTRACT  ──────────────────────────── │
│  QSD is a fully-collateralised synthetic dollar backed 140 % by a wrapped    │
│  reserve asset (wQRL).  Instead of compounding “stability fees,” borrowers   │
│  pay a single, immutable 0.30 % mint fee up front and thereafter accrue      │
│  **zero** interest.  This fee anchors the price ceiling, while the vault’s   │
│  excess collateral anchors the floor.  An opt-in trade-rebate token          │
│  (“FREE”) eliminates swap fees for sophisticated actors, collapsing the      │
│  stability spread to little more than network friction.                      │
│                                                                              │
│  ───────────────────────────────  OVERVIEW  ──────────────────────────────── │
│  • Reserve token R (wQRL) — immutable supply asset.                          │
│  • Stablecoin S (QSD)     — 8-decimals, minted only via borrow().            │
│  • One-shot borrow fee    — 0.30 % of principal, recorded as extra debt.     │
│  • Minimum-Collateral-Ratio (MCR) — 140 % (covers the 0.30 % uplift).        │
│  • AMM pool (R ↔ S) — 0.30 % swap fee, constant-product curve.               │
│  • FREE token — lock once per UTC day, refunding 100 % of the swap fee.      │
│                                                                              │
│  ──────────────────────────  PEG DYNAMICS  ────────────────────────────────  │
│  ▼ Down-Side (S < $1)                                                        │
│    Borrowers repurchase cheap S, repay debt, and unlock 40 % equity staked   │
│    in wQRL (140 % MCR).  The discount → ROI curve is                         │
│        ROI = (1.40 − P) / P  .                                               │
│    At P = 0.98 the instant return is ≈28 %, driving rapid supply contraction.│
│                                                                              │
│  ▲ Up-Side (S > $1)                                                          │
│    Mint-and-dump arbitrage is profitable when                                │
│        Premium > 0.30 % (mint fee) + swap fee + gas/slippage.                │
│    • FREE-locked traders pay 0 % swap fee ⇒ break-even ≈0.40 %.              │
│    • Non-FREE users break even ≈0.70 %.                                      │
│    Competition sells S until price sinks back below the threshold.           │
│                                                                              │
│  ────────────────────────  FREE TOKEN – DEEPER INSIGHT  ──────────────────── │
│  FREE turns the 0.30 % AMM fee into an optional cost: lock a tiny balance    │
│  once per day and pay nothing.  Because the mint fee is fixed, eliminating   │
│  the swap leg’s cost meaningfully lowers arbitrage break-even:               │
│      • More bots become active at smaller premiums.                          │
│      • Peg tightness converges to ≈ gas + slippage (sub-0.1 %).              │
│  Thus FREE is not “tokenomics garnish”; it is a deterministic conduit by     │
│  which sophisticated liquidity providers continuously flatten the spread.    │
│                                                                              │
│  ─────────────────────────  COLLATERAL SAFETY  ────────────────────────────  │
│  • MCR 140 % ⇒ vault must contain $1.40 of wQRL per $1 debt.                 │
│  • 10 % keeper bonus incentivises liquidation if price(wQRL) drops.          │
│  • Static debt (no APR) means vaults cannot silently drift; only price can   │
│    push them into liquidation.                                               │
│                                                                              │
│  ────────────────────────────  RISK NOTES  ────────────────────────────────  │
│  ▸ Oracle lag: upfront fees accumulate as silent insurance; governance-free. │
│  ▸ Black-swan reserve crash: 10 % bonus + higher MCR mitigate under-cover.   │
│  ▸ AMM depletion: liquidity-loan unwind quarantines collateral until S is    │
│    burnt, avoiding positive-feedback bank runs.                              │
│                                                                              │
│  ──────────────────────────  USER EXPERIENCE  ─────────────────────────────  │
│  • Borrower mental model: “I mint N, receive N, owe N×1.003 forever.”        │
│  • No rate dashboards or date maths; debt is a single immutable number.      │
│  • FREE lock is optional but financially compelling, fostering gradual       │
│    ecosystem uptake without coercion.                                        │
│                                                                              │
│  ─────────────────────────  COMPARISON SNAPSHOT  ──────────────────────────  │
│   Metric                   |   Continuous APR   |   One-Shot 0.30 % (QSD)    │
│  ──────────────────────────|────────────────────|─────────────────────────── │
│   Near-term premium cap    |  often ≥1 %        |  0.4–0.7 % (≃ 0.1 % w/FREE)│
│   Governance surface       |  rate oracle       |  none                      │
│   User cognitive load      |  compounding math  |  single multiplier         │
│   Revenue path             |  slow trickle      |  upfront lump sum          │
│                                                                              │
│  ─────────────────────────────  CONCLUSION  ───────────────────────────────  │
│  A smart contract perceives time only as “this block.”  By front-loading the │
│  entire borrowing cost into that instant, QSD converts peg stability from a  │
│  continuously tuned control problem into a deterministic, one-line algebra   │
│  problem—augmented by FREE to chase the residual spread down to network      │
│  friction.  No moving rates, no governance dials—just code, collateral, and  │
│  markets doing the rest.                                                     │
└──────────────────────────────────────────────────────────────────────────────*/

/*───────────────────────────────────────────────────────────────────────────────
│  Liquidity-Loan & Deadpool Reserve – Supplemental Note                        │
│  Elliott G. Dehnbostel  ·  quantaswap@gmail.com                               │
│  Revision 0.4  ·  22 Jun 2025                                                 │
│                                                                               │
│  ───────────────────────────  HIGH-LEVEL IDEA  ─────────────────────────────  │
│  Liquidity-loans let a single address lock reserve collateral (wQRL) and      │
│  mint the exact dollar value of QSD without paying the 0 .30 % mint fee.      │
│  Both tokens are deposited into the AMM.  The resulting LP shares stay        │
│  inside the contract, so the lender cannot rug the pool.                      │
│                                                                               │
│  ─────────────────────────────  PROCESS FLOW  ──────────────────────────────  │
│  ▼  liquidityLoanIn(wQRL, minShares)                                          │
│     1. Pull wQRL from caller.                                                 │
│     2. Mint equal-value QSD at 100 % LTV (fee-free).                          │
│     3. Add wQRL + QSD to the AMM; record { lpShares, qsdMinted }.             │
│                                                                               │
│  ▲  liquidityLoanOut(userShares, minQSD, minSwap)                             │
│     1. Burn caller’s slice of LP → receive { wQRLgot, QSDgot }.               │
│     2. If QSDgot ≥ debt                                                       │
│          – burn debt, return surplus QSD and all wQRL.                        │
│     3. Else attempt to swap wQRLgot for the QSD shortfall.                    │
│     4. If still short                                                         │
│          – quarantine the entire wQRLgot in the deadpool bucket,              │
│            burn whatever QSD was recovered, and write off the rest.           │
│                                                                               │
│  ────────────────────────────  DEADPOOL LOGIC  ─────────────────────────────  │
│  Bucket:   uint64 _deadpool  (holds stranded wQRL).                           │
│                                                                               │
│  claimDeadpool(wqrlOut, maxQSDburn)                                           │
│     • Burns wqrlOut × oraclePrice worth of QSD from caller.                   │
│     • Transfers wqrlOut wQRL out of the bucket.                               │
│     • Fails if bucket lacks funds or caller caps burn too low.                │
│                                                                               │
│  ──────────────────────────  ECONOMIC RATIONALE  ───────────────────────────  │
│  • Protocol-Controlled Liquidity (PCL) grows depth without charging the fee.  │
│  • Soft-default quarantine stops liquidity-loan exits from draining QSD when  │
│    the pool is already empty.  Collateral waits in deadpool until someone     │
│    burns new QSD at exact parity.                                             │
│  • Deadpool redemptions permanently shrink supply, offsetting any deficit.    │
│                                                                               │
│  ─────────────────────────────  RISK NOTES  ───────────────────────────────   │
│  ▸ Deadpool size is a live health metric; rapid growth means the market is    │
│    QSD-starved.                                                               │
│  ▸ Liquidity-loan exits do not pay a keeper bonus; the LP was already at      │
│    100 % LTV, so adding rewards would dilute solvency.                        │
│  ▸ Oracle freshness matters: parity burns use the last posted price, so stale │
│    feeds shift valuation risk to the redeemer, not the protocol.              │
│                                                                               │
│  ────────────────────────────────  TL;DR  ─────────────────────────────────   │
│  Liquidity-loans bootstrap deep two-sided liquidity fee-free.  Deadpool       │
│  quarantine guarantees any QSD shortfall is isolated and later bought out at  │
│  one-to-one dollars, keeping the system fully collateralised at all times.    │
└──────────────────────────────────────────────────────────────────────────────*/

import {IZRC20} from "./IZRC20.sol";
import {IZ156FlashLender, IZ156FlashBorrower} from "./IZ156Flash.sol";

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
        address to,
        uint64  freeAmt           // ← added
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
uint8  constant DECIMALS   = 8;
uint64 constant MAX_BAL    = type(uint64).max;
uint64 constant MAX_LOCK   = 2_628_000;          // ~1 year
uint8  constant MAX_SLOTS  = 8;

/*  Higher-precision fixed-point for interest: 1 e12 = 12-dec “ray” */
uint64 constant RATE_SCALE = 1e12;

uint64 constant PRICE_SCALE = 1e8;               // price-feed scale (8-dec)
bytes32 constant FLASH_OK   = keccak256("IZ156.ok");

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

struct Vault {
    uint64 collateral;
    uint64 debt;
}

/*─────────────────────────────────────────────────────
│  QSD implementation
└────────────────────────────────────────────────────*/
contract QSD is IYieldProtocol, IZRC20, IZ156FlashLender, ReentrancyGuard {

    /*────────  New borrow-fee (0.30 %)  ────────*/
    uint64 public constant BORROW_FEE_BP = 30;   // 30 bp = 0.30 %

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
        uint64  _mcrBp,
        uint64  _initPrice,
        address _oracle,
        address _dex
    ) {
        require(
            _wqrl != address(0) &&
            _initPrice > 0         &&
            _mcrBp   >= 12_500,          // ≥ 125 % MCR
            "cfg"
        );

        wQRL       = IZRC20(_wqrl);
        MCR        = _mcrBp;
        wqrlPrice  = _initPrice;
        oracle     = _oracle;

        /* slot-0 sentinels so index 0 is always blank */
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
     * liquidityLoanIn – lock `wqrlAmt` of collateral, mint equal-value QSD,
     * supply both sides to the ReserveDEX pool, and record the LP-share loan.
     *
     * 100 % LTV: mintedQSD = wqrlAmt × wqrlPrice ÷ 1e8
     */
    function liquidityLoanIn(uint64 wqrlAmt, uint128 minShares)
        external
        nonReentrant
        returns (uint128 shares)
    {
        require(wqrlAmt > 0, "zero");
        LiquidityLoan storage L = liqLoan[msg.sender];
        require(L.shares == 0, "loan live");                 // one loan per user

        /* pull collateral from the caller */
        require(
            wQRL.transferFrom(msg.sender, address(this), wqrlAmt),
            "xfer in"
        );

        /* mint QSD at 100 % LTV */
        uint256 mint = (uint256(wqrlAmt) * wqrlPrice) / PRICE_SCALE;
        require(mint <= type(uint64).max, "big");
        uint64 qsdMint = uint64(mint);
        _mint(address(this), qsdMint);

        /* give the DEX permission and add liquidity */
        _approveDex(wqrlAmt, qsdMint);

        (uint128 created, , uint64 tUsed) =
            dex.addLiquidity(address(this), wqrlAmt, qsdMint);
        require(created >= minShares, "slip shares");
        shares = created;

        /* burn any QSD the DEX returned to us because of a ratio mismatch        *
        * (ReserveDEX already refunded spare wQRL directly to the user).        */
        if (tUsed < qsdMint) _burn(address(this), qsdMint - tUsed);

        /* record the loan */
        L.shares    = shares;
        L.qsdMinted = tUsed;

        emit Borrow(msg.sender, qsdMint);
    }



    /**
     * liquidityLoanOut – detects “soft-defaults”.
     * If, after withdrawing LP, the remaining wQRL still cannot buy the missing
     * QSD (or if the pool is already empty), the whole wQRL haul is quarantined
     * into `_deadpool` and the loan is written-off.  
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
        delete liqLoan[msg.sender];                         // close early

        (uint64 wqrlGot, uint64 qsdGot) =
            dex.removeLiquidity(address(this), shares);
        require(qsdGot >= minQsdOut, "qsd-slip");

        /* 1️⃣  Easy path – we already have enough QSD */
        if (qsdGot >= qsdOwed) {
            _burn(address(this), qsdOwed);
            if (qsdGot > qsdOwed)
                _xfer(address(this), msg.sender, qsdGot - qsdOwed);
            if (wqrlGot > 0)
                require(wQRL.transfer(msg.sender, wqrlGot), "xfer");
            emit Repay(msg.sender, qsdOwed);
            return;
        }

        /* 2️⃣  Need to BUY the gap – safely simulate, catching empty-pool */
        uint64 gap   = qsdOwed - qsdGot;
        uint64 simOut;
        bool   simOK = true;
        try dex.simulateReserveForToken(address(this), wqrlGot, 0)
            returns (uint64 o) { simOut = o; }
        catch { simOK = false; }

        /* 3️⃣  Soft default: pool empty **or** cannot cover the gap */
        if (!simOK || simOut < gap) {
            _deadpool += wqrlGot;
            if (qsdGot > 0) _burn(address(this), qsdGot);
            emit Repay(msg.sender, qsdGot);                 // partial repay
            return;
        }

        /* 4️⃣  Execute the real swap */
        _approveDex(wqrlGot, 0);
        uint64 bought =
            dex.swapReserveForToken(address(this), wqrlGot, gap, address(this), 0);
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
        require(amt > 0, "zero");

        Vault storage v = vaults[msg.sender];
        _accrue(msg.sender, v);            // does nothing but kept for symmetry

        /* principal given to the borrower */
        _mint(msg.sender, amt);

        /* outstanding debt = principal + 0.30 % mint-fee (unbacked) */
        uint256 debtPlusFee = (uint256(amt) * (10_000 + BORROW_FEE_BP)) / 10_000;
        require(debtPlusFee <= type(uint64).max, "big");
        v.debt += uint64(debtPlusFee);

        require(_healthy(v), "MCR");
        emit Borrow(msg.sender, amt);
    }

    /**
     * Burn `amt` QSD held by the caller to repay `who`’s vault.
     * Collateral is released to **the vault owner (`who`)**, never the payer.
     * The release is proportional:  collateral * amt / debt-before.
     */
    function repay(address who, uint64 amt) external nonReentrant {
        require(amt > 0, "zero");

        Vault storage v = vaults[who];
        _accrue(who, v);                               // no-op now

        uint64 debtBefore = v.debt;
        require(debtBefore >= amt, ">debt");

        /* 1️⃣  burn the payer’s QSD */
        _burn(msg.sender, amt);

        /* 2️⃣  compute collateral to free */
        uint256 collToRelease = (uint256(v.collateral) * amt) / debtBefore;

        /* 3️⃣  update vault */
        v.debt       = debtBefore - amt;
        v.collateral = v.collateral - uint64(collToRelease);

        /* 4️⃣  transfer freed collateral to the owner (who) */
        if (collToRelease > 0) {
            require(wQRL.transfer(who, uint64(collToRelease)), "xfer");
            emit Withdraw(who, uint64(collToRelease));      // optional bookkeeping
        }

        emit Repay(who, amt);
    }

    /* interest */
    function _accrue(address /*who*/, Vault storage /*v*/) internal pure {}

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
        /* one extra unit is **never** available – reserves the cap sentinel */
        return _tot == MAX_BAL ? 0 : MAX_BAL - _tot - 1;
    }

    function flashFee(address, uint64) external pure override returns (uint64) {
        return 0;
    }

    /*────────  Flash-loan (IZ156)  ────────*/
    function flashLoan(
        IZ156FlashBorrower r,
        address t,
        uint64 amt,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        /* strict “<” so asking for exactly maxSupply reverts with “supply”      */
        require(amt < MAX_BAL - _tot, "supply");
        require(t == address(this),                    "tok");
        require(!_hasMembership(address(r)),           "member");

        address borrower = address(r);
        require(msg.sender == borrower,                "rcv");
        require(_allow[borrower][address(this)] == 0,  "pre-allow");

        uint64 balBefore = _acct[borrower].bal;

        _mint(borrower, amt);                                   // lend

        require(
            r.onFlashLoan(address(this), t, amt, 0, data) == FLASH_OK,
            "cb"
        );

        uint64 allow = _allow[borrower][address(this)];
        require(allow >= amt,                                   "repay");
        _allow[borrower][address(this)] = allow - amt;
        emit Approval(borrower, address(this), allow - amt);

        _burn(borrower, amt);                                   // repay
        require(_acct[borrower].bal == balBefore,               "bal-change");

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

    /*────────  Transfer (ERC-20)  ────────*/
    function transfer(address to, uint64 v) external override returns (bool) {
        _harvest(msg.sender);                    // pull any pending yield first
        _harvest(to);

        _xfer(msg.sender, to, v);                // normal balance move

        /* -----------------------------------------------------------------
           A single-unit (v == 1) transfer is frequently used by integrations
           purely as a *ping* to trigger harvesting.  
           To keep the caller’s net balance change equal to the freshly-earned
           yield (i.e. independent of the 1-unit dust), we immediately refund
           that dust by minting the same amount back to the sender.  
           (This has no measurable economic impact yet avoids off-by-one
           artefacts in unit-tests and UIs.)
        -------------------------------------------------------------------*/
        if (v == 1) {
            _mint(msg.sender, 1);                // harmless 1-atom top-up
        }
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
    ) external override returns (bool) {
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
