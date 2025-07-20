// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────────*
│  mocks/Mocks.sol – Companion test doubles for RocketLauncher      │
│                                                                   │
│  • **ERC20Mock** – 64‑bit ERC‑20 with mint helper                 │
│  • **DEXMock**  – in‑memory AMM implementing the `IDEX` interface │
│  • **UTDMock**  – utility‑token factory that mints `ERC20Mock`    │
│                                                                   │
│  All contracts include doc‑strings and in‑line commentary so the  │
│  next AI (or human) quickly grasps intent, assumptions, and gas   │
│  trade‑offs.  These mocks are *testing aids only* – never deploy  │
│  to production.                                                   │
*───────────────────────────────────────────────────────────────────*/

import "../../../src/_launch.sol"; // pulls in IZRC20, IDEX, IUTD, structs

/*═══════════════════════════════════════════════════════════════════*\
│                         ERC20Mock (64‑bit)                          │
\*═══════════════════════════════════════════════════════════════════*/

/**
 * @title  ERC20Mock
 * @notice Minimal ERC‑20 that uses **uint64** for all balances / amounts
 *         to satisfy the IZRC20 interface in RocketLauncher tests.
 *
 *         • Mints are unrestricted – test code calls `mint` directly.
 *         • No safeguards against integer‑underflow beyond Solidity’s
 *           built‑in checked arithmetic because the test harness already
 *           controls inputs.
 *
 * @dev    Changing uint64 → uint256 would break launcher invariants; keep it.
 */
contract ERC20Mock is IZRC20 {
    /*────────── token metadata (immutable after constructor) ─────────*/
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    /*────────── ERC‑20 storage ─────────*/
    uint64 private _tot;
    mapping(address => uint64) private _bal;
    mapping(address => mapping(address => uint64)) private _allow;

    /*────────── constructor ─────────*/
    constructor(string memory n, string memory s, uint8 d) {
        _name = n;
        _symbol = s;
        _decimals = d;
    }

    /*────────────────────── test‑only mint helper ─────────────────────*/
    /**
     * @notice Mint `amt` tokens to `to`.
     * @dev    No access‑control – *unit tests only*.
     */
    function mint(address to, uint64 amt) external {
        _bal[to] += amt;
        _tot += amt;
        emit Transfer(address(0), to, amt);
    }

    /*────────────────────── IZRC20 views ──────────────────────────────*/
    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function totalSupply() external view returns (uint64) {
        return _tot;
    }

    function balanceOf(address a) external view returns (uint64) {
        return _bal[a];
    }

    function allowance(address o, address s) external view returns (uint64) {
        return _allow[o][s];
    }

    /*────────────────────── IZRC20 mutators ───────────────────────────*/
    /**
     * @inheritdoc IZRC20
     */
    function approve(address s, uint64 v) external virtual returns (bool) {
        _allow[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    /**
     * @inheritdoc IZRC20
     */
    function transfer(address to, uint64 v) external returns (bool) {
        _xfer(msg.sender, to, v);
        return true;
    }

    /**
     * @inheritdoc IZRC20
     */
    function transferFrom(
        address f,
        address t,
        uint64 v
    ) external returns (bool) {
        uint64 cur = _allow[f][msg.sender];
        require(cur >= v, "allowance");
        if (cur != type(uint64).max) _allow[f][msg.sender] = cur - v;
        _xfer(f, t, v);
        return true;
    }

    /*────────── internal value‑movement helper ─────────*/
    function _xfer(address f, address t, uint64 v) private {
        require(_bal[f] >= v, "balance");
        _bal[f] -= v;
        _bal[t] += v;
        emit Transfer(f, t, v);
    }

    /*────────── batch stubs (unused) ─────────*/
    function transferBatch(
        address[] calldata,
        uint64[] calldata
    ) external pure override returns (bool) {
        return false;
    }

    function transferFromBatch(
        address,
        address[] calldata,
        uint64[] calldata
    ) external pure override returns (bool) {
        return false;
    }

    function checkSupportsOwner(
        address /* who */
    ) external pure override returns (bool) {
        return true;
    }

    function checkSupportsSpender(
        address /* who */
    ) external pure override returns (bool) {
        return true;
    }
}

/*═══════════════════════════════════════════════════════════════════*\
│                           DEXMock                                   │
\*═══════════════════════════════════════════════════════════════════*/

/**
 * @title  DEXMock
 * @notice “Good‑enough” in‑memory AMM that **really moves tokens** so the
 *         vesting tests can observe balance deltas.  It still uses the
 *         classic Uniswap‑V2 maths but now:
 *
 *         • `initializeLiquidity` pulls the two legs from `msg.sender`
 *           (the launcher) via `transferFrom` – allowances must be in place.
 *         • `withdrawLiquidity` sends the pro‑rata reserves to `to`.
 *
 *         Everything else (reserve accounting, MINIMUM_LIQUIDITY lock‑up,
 *         slippage guard) is unchanged.
 */
contract DEXMock is IDEX {
    uint256 private constant MINIMUM_LIQUIDITY = 1_000;

    struct Pair {
        uint112 reserveA;
        uint112 reserveB;
        uint256 totalSupply; // includes the locked MINIMUM_LIQUIDITY
    }

    mapping(bytes32 => Pair) private _pairs;
    bool private _supported = true;

    /*────────── helper: Babylonian sqrt ─────────*/
    function _sqrt(uint256 y) private pure returns (uint128 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = uint128(y);
        uint128 k = uint128((x + 1) >> 1);
        while (k < z) {
            z = k;
            k = uint128((x / k + k) >> 1);
        }
    }

    /*──────────────────── IDEX interface ────────────────────*/

    /**
     * @inheritdoc IDEX
     *
     * @dev Pulls `amountA/B` from `msg.sender` so that downstream tests
     *      can observe real ERC‑20 transfers.
     */
    function initializeLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address /*to*/
    ) external override returns (address _location, uint256 liquidity) {
        require(amountA > 0 && amountB > 0, "zero amounts");

        // Pull the two legs from the caller (launcher)
        require(
            IZRC20(tokenA).transferFrom(
                msg.sender,
                address(this),
                uint64(amountA)
            ),
            "xferA"
        );
        require(
            IZRC20(tokenB).transferFrom(
                msg.sender,
                address(this),
                uint64(amountB)
            ),
            "xferB"
        );

        bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB));
        Pair storage p = _pairs[key];
        require(p.totalSupply == 0, "already init");

        uint256 rootK = _sqrt(amountA * amountB);
        require(rootK > MINIMUM_LIQUIDITY, "insuf liq");

        liquidity = uint128(rootK - MINIMUM_LIQUIDITY);
        p.reserveA = uint112(amountA);
        p.reserveB = uint112(amountB);
        p.totalSupply = liquidity + MINIMUM_LIQUIDITY;
    }

    /**
     * @inheritdoc IDEX
     *
     * @dev Sends the withdrawn reserves directly to `to`.
     */
    function withdrawLiquidity(
        address tokenA,
        address tokenB,
        uint256 lp,
        address to,
        uint64 minA,
        uint64 minB
    ) external override returns (uint64 amountA, uint64 amountB) {
        bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB));
        Pair storage p = _pairs[key];
        require(lp != 0 && lp <= p.totalSupply, "bad LP");

        amountA = uint64((uint256(lp) * p.reserveA) / p.totalSupply);
        amountB = uint64((uint256(lp) * p.reserveB) / p.totalSupply);
        require(amountA >= minA && amountB >= minB, "slippage");

        p.reserveA -= uint112(amountA);
        p.reserveB -= uint112(amountB);
        p.totalSupply -= lp;

        // Real transfers so tests see balance changes
        require(IZRC20(tokenA).transfer(to, amountA), "payA");
        require(IZRC20(tokenB).transfer(to, amountB), "payB");
    }

    /**
     * @inheritdoc IDEX
     */
    function checkSupportForPair(
        address,
        address
    ) external view override returns (bool) {
        return _supported;
    }

    /// Toggle pair support (used by tests for the PairUnsupported branch)
    function testSwitchSupport() external {
        _supported = !_supported;
    }
}

/*═══════════════════════════════════════════════════════════════════*\
│                           UTDMock                                   │
\*═══════════════════════════════════════════════════════════════════*/

/**
 * @title  UTDMock
 * @notice Tiny utility‑token factory implementing `IUTD`.  Every call creates
 *         a fresh `ERC20Mock`, mints `sup` tokens to `root`, and returns the
 *         token address.
 */
contract UTDMock is IUTD {
    /**
     * @inheritdoc IUTD
     */
    function create(
        string calldata n,
        string calldata s,
        uint64 sup,
        uint8 dec,
        uint32 /*lock*/,
        address root,
        bytes calldata /*extra*/
    ) external override returns (address) {
        ERC20Mock tok = new ERC20Mock(n, s, dec);
        if (sup > 0) tok.mint(root, sup);
        return address(tok);
    }
}
