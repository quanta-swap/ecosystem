// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC2, IZRC20} from "./IZRC2.sol";

/*───────────────────────────────────────────────────────────────
│  InitialLiquidityVault – pooled wQRL → QSD LP with           │
│  single‑shot per‑user exits after a 365‑day lock.             │
│                                                               │
│  • Vault crowdsources wQRL up to a hard cap, deposits it via  │
│    QSD.liquidityLoanIn() once, and records the LP share count.│
│  • After the vesting period each user may **exactly once**    │
│    withdraw their proportional shares. The vault calls        │
│    QSD.liquidityLoanOut() for that slice, then transfers the  │
│    returned wQRL & QSD and mints any unclaimed reward tokens. │
│                                                               │
│  ***Production‑ready – audit before main‑net use***           │
└──────────────────────────────────────────────────────────────*/

/*──────── Re‑entrancy guard ────────*/
abstract contract ReentrancyGuard {
    uint256 private _status;

    constructor() {
        _status = 1;
    }

    modifier nonReentrant() {
        require(_status == 1, "reenter");
        _status = 2;
        _;
        _status = 1;
    }
}

/*──────── QSD interface (partial) ────────*/
interface IQSD {
    function liquidityLoanIn(
        uint64 wqrlAmt,
        uint128 minShares
    ) external returns (uint128 shares);

    function liquidityLoanOut(
        uint128 shares,
        uint64 minQsdOut,
        uint64 minBuyOut
    ) external returns (uint64 wqrlOut, uint64 qsdOut);
}

/*────────────────────────────────────────────────────────────*/
contract BISMARCK is ReentrancyGuard {
    /*──────── Constants ────────*/
    uint8 public constant DECIMALS = 8;
    uint32 private constant CLIFF_BP = 2_500; // 25 %
    uint32 private constant VEST_BP = 7_500; // 75 %
    uint32 private constant BP_DENOM = 10_000; // 100 %
    uint256 private constant VEST_SECS = 365 days;

    /*──────── External contracts ────────*/
    IZRC20 public immutable wqrl;
    IQSD public immutable qsd;
    IZRC2 public immutable reward;

    /*──────── Ownership (minimal) ────────*/
    address public owner;
    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }
    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );

    /*──────── Deposit state ────────*/
    uint64 public immutable cap; // hard cap
    uint64 public totalDeposited; // pooled wQRL
    mapping(address => uint64) public deposited;

    /*──────── Liquidity state ────────*/
    bool public live; // true after liquidityLoanIn
    uint256 public liveAt; // timestamp of deployment
    uint128 public totalShares; // total LP shares minted by QSD

    /*──────── Reward / withdrawal tracking ────────*/
    mapping(address => uint64) public claimed; // reward already claimed
    mapping(address => bool) public exited; // true once user has withdrawn

    /*──────── Events ────────*/
    event Deposited(address indexed user, uint64 amount);
    event Cancelled(address indexed user, uint64 amount);
    event Deployed(uint64 wqrlAmount, uint128 sharesMinted);
    event Claimed(address indexed user, uint64 amount);
    event Withdrawn(
        address indexed user,
        uint64 wqrlAmount,
        uint64 qsdAmount,
        uint64 rewardMinted,
        uint128 sharesBurned
    );

    /*──────── Constructor ────────*/
    constructor(address _w, address _q, address _r, uint64 _cap) {
        require(
            _w != address(0) && _q != address(0) && _r != address(0),
            "0x0"
        );
        require(_cap > 0, "cap");
        wqrl = IZRC20(_w);
        qsd = IQSD(_q);
        reward = IZRC2(_r);
        cap = _cap;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // "SO, DID YOU FIND THE BOAT?"
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=oVWEb-At8yc";
    }

    function transferOwnership(address n) external onlyOwner {
        require(n != address(0), "0x0");
        emit OwnershipTransferred(owner, n);
        owner = n;
    }

    /*════════ Phase 1: Deposits ════════*/
    function deposit(uint64 amt) external nonReentrant {
        require(!live, "closed");
        require(amt > 0, "amt");
        require(totalDeposited + amt <= cap, "cap");
        require(wqrl.transferFrom(msg.sender, address(this), amt), "xfer");
        deposited[msg.sender] += amt;
        totalDeposited += amt;
        emit Deposited(msg.sender, amt);
    }

    function cancel(uint64 amt) external nonReentrant {
        require(!live, "live");
        uint64 bal = deposited[msg.sender];
        require(amt > 0 && bal >= amt, "bad");
        deposited[msg.sender] = bal - amt;
        totalDeposited -= amt;
        require(wqrl.transfer(msg.sender, amt), "xfer");
        emit Cancelled(msg.sender, amt);
    }

    /*════════ Phase 2: Deploy LP ════════*/
    function deploy(uint128 minShares) external onlyOwner nonReentrant {
        require(!live, "done");
        require(totalDeposited > 0, "0");
        require(wqrl.approve(address(qsd), totalDeposited), "approve");
        uint128 minted = qsd.liquidityLoanIn(totalDeposited, minShares);
        require(minted >= minShares, "slippage");
        live = true;
        liveAt = block.timestamp;
        totalShares = minted;
        emit Deployed(totalDeposited, minted);
    }

    /*──────── Vesting maths ────────*/
    function _vested(address u) private view returns (uint64) {
        uint64 dep = deposited[u];
        if (dep == 0 || !live) return 0;
        uint32 bp;
        uint256 dt = block.timestamp - liveAt;
        if (dt >= VEST_SECS) bp = BP_DENOM;
        else bp = uint32(CLIFF_BP + (uint256(VEST_BP) * dt) / VEST_SECS);
        return uint64((uint256(dep) * bp) / BP_DENOM);
    }

    /* internal claim helper */
    function _autoClaim(address u) private returns (uint64 minted) {
        uint64 vested = _vested(u);
        uint64 due = vested - claimed[u];
        if (due > 0) {
            claimed[u] = vested;
            reward.mint(u, due);
            emit Claimed(u, due);
            minted = due;
        }
    }

    function claim() external nonReentrant {
        require(_autoClaim(msg.sender) > 0, "0");
    }

    /*════════ Phase 3: Single‑shot exit ════════*/
    function withdrawUnderlying(
        uint64 minQsdOut,
        uint64 minBuyOut
    ) external nonReentrant {
        require(live, "not live");
        require(block.timestamp >= liveAt + VEST_SECS, "locked");
        require(!exited[msg.sender], "already");

        uint64 dep = deposited[msg.sender];
        require(dep > 0, "none");

        /* compute this wallet's share of LP */
        uint128 userShares = uint128(
            (uint256(totalShares) * dep) / totalDeposited
        );
        require(userShares > 0, "0sh");

        exited[msg.sender] = true;

        /* burn the slice and receive tokens */
        (uint64 wqrlGot, uint64 qsdGot) = qsd.liquidityLoanOut(
            userShares,
            minQsdOut,
            minBuyOut
        );
        require(wqrlGot >= minQsdOut, "no wqrl");
        require(qsdGot >= minQsdOut, "no qsd");

        /* mint outstanding rewards */
        uint64 minted = _autoClaim(msg.sender);

        /* pay out */
        require(wqrl.transfer(msg.sender, wqrlGot), "wqrl xfer");
        if (qsdGot > 0)
            require(
                IZRC20(address(qsd)).transfer(msg.sender, qsdGot),
                "qsd xfer"
            );

        emit Withdrawn(msg.sender, wqrlGot, qsdGot, minted, userShares);
    }

    /*──────── View helper ────────*/
    function pendingShares(address u) external view returns (uint128) {
        if (!live || exited[u]) return 0;
        return uint128((uint256(totalShares) * deposited[u]) / totalDeposited);
    }
}
