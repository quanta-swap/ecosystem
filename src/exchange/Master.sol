// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────────────────
│  External interfaces & helpers   │
└──────────────────────────────────*/
import "../_launch.sol"; // pulls in IDEX, IZRC20, custom errors
import "../IZRC20.sol";

/*══════════════════════════════════════
│          QuantaSwap Constant‑Product  │
╚══════════════════════════════════════*/

/*────────── errors ─────────*/
error UnsupportedReserve(address);
error UnsupportedPair(address, address);
error PairNotFound(address, address);
error NotEnoughLiquidity(uint128 have, uint256 need);
error Slippage(uint64 minA, uint64 amtA, uint64 minB, uint64 amtB);
error SlippageSwap(uint64 limit, uint64 actual);
/// Returned when the caller tries to swap a token against itself.
error IdenticalTokens(address token);

/// Caller asked for more output than the pool holds.
error InsufficientLiquidity(uint64 reserveOut, uint64 asked);

/**
 * This is primarily a limit order exchange, with functional liquidity.
 */
contract QuantaSwap is IDEX, ReentrancyGuard {
    using IZRC20Helper for address;

    /*────────── pool bookkeeping ─────────*/
    struct PoolState {
        uint64 reserve0; // token‑0 inside pool
        uint64 reserve1; // token‑1 inside pool
        uint128 depth; // total LP issued  (includes MIN_LIQUIDITY lock‑up)
    }

    mapping(address => mapping(address => PoolState)) public pairs; // token0 → token1 → state
    mapping(address => mapping(IZRC20 => mapping(IZRC20 => uint128)))
        public liquidity; // provider → pair → LP
    mapping(address => address) public routers; // reserved for future router whitelists

    uint256 private constant MINIMUM_LIQUIDITY = 1_000; // identical to Uniswap‑V2

    /*────────── misc view ─────────*/
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=tqOHiDKPxe0";
    }

    /*════════════════════════════════════════════════════
     *                    Compatibility probe             *
     *════════════════════════════════════════════════════*/
    function checkSupportForPair(
        address tokenA,
        address tokenB
    ) external view override returns (bool) {
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB)
            return false;
        return _isSupported(tokenA) && _isSupported(tokenB);
    }

    /// Best‑effort validation that `token` meets all QuantaSwap requirements.
    function _isSupported(address token) internal view returns (bool) {
        if (!token.isIZRC20()) return false; // 1. 64‑bit supply
        IZRC20 t = IZRC20(token);
        if (!t.checkSupportsMover(address(this))) return false; // 2. mover ACL
        if (!t.checkSupportsOwner(address(this))) return false; // 3. owner ACL
        return true;
    }

    /*════════════════════════════════════════════════════
     *                  Pool initialisation               *
     *════════════════════════════════════════════════════*/
    function initializeLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address to
    )
        external
        override
        nonReentrant
        returns (address location, uint256 liquidity_)
    {
        require(
            this.checkSupportForPair(tokenA, tokenB),
            UnsupportedPair(tokenA, tokenB)
        );

        // sort so tokenA < tokenB; swap amounts accordingly
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
            (amountA, amountB) = (amountB, amountA);
        }

        PoolState storage p = pairs[tokenA][tokenB];
        if (p.depth != 0) revert PairNotFound(tokenA, tokenB); // already initialised

        require(amountA > 0 && amountB > 0, "zero amounts");
        uint64 amountA64 = uint64(amountA);
        uint64 amountB64 = uint64(amountB);
        /*──── 2. pull reserves from caller ────*/
        require(
            IZRC20(tokenA).transferFrom(msg.sender, address(this), amountA64) &&
                IZRC20(tokenB).transferFrom(
                    msg.sender,
                    address(this),
                    amountB64
                ),
            "reserve transfer fail"
        );

        /*──── 3. liquidity maths ────*/
        uint256 product = uint256(amountA) * uint256(amountB); // cast ⇒ 256‑bit
        uint256 rootK256 = _sqrt(product);
        require(rootK256 > MINIMUM_LIQUIDITY, "insuf liq");

        liquidity_ = rootK256 - MINIMUM_LIQUIDITY; // LP minted to user
        uint128 depthAfter = uint128(liquidity_ + MINIMUM_LIQUIDITY);

        /*──── 4. state updates ────*/
        p.reserve0 = amountA64;
        p.reserve1 = amountB64;
        p.depth = depthAfter;

        liquidity[to][IZRC20(tokenA)][IZRC20(tokenB)] += uint128(liquidity_);

        return (address(this), liquidity_);
    }

    /*════════════════════════════════════════════════════
     *                   LP burn & withdraw               *
     *════════════════════════════════════════════════════*/
    function withdrawLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity_,
        address to,
        uint64 minA,
        uint64 minB
    ) external override nonReentrant returns (uint64 amountA, uint64 amountB) {
        /*──── canonical ordering ────*/
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
            (minA, minB) = (minB, minA);
        }

        PoolState storage p = pairs[tokenA][tokenB];
        if (p.depth == 0) revert PairNotFound(tokenA, tokenB);

        uint128 owned = liquidity[msg.sender][IZRC20(tokenA)][IZRC20(tokenB)];
        if (liquidity_ > owned) revert NotEnoughLiquidity(owned, liquidity_);

        /*──── proportional reserves ────*/
        amountA = uint64((uint256(p.reserve0) * liquidity_) / p.depth);
        amountB = uint64((uint256(p.reserve1) * liquidity_) / p.depth);
        if (amountA < minA || amountB < minB)
            revert Slippage(minA, amountA, minB, amountB);

        /*──── state mutation ────*/
        p.reserve0 -= amountA;
        p.reserve1 -= amountB;
        p.depth -= uint128(liquidity_);

        liquidity[msg.sender][IZRC20(tokenA)][IZRC20(tokenB)] =
            owned -
            uint128(liquidity_);

        /*──── transfers ────*/
        require(
            IZRC20(tokenA).transfer(to, amountA) &&
                IZRC20(tokenB).transfer(to, amountB),
            "transfer fail"
        );

        return (amountA, amountB);
    }

    /**
     * @notice Move `amount` LP units for the (`tokenA`, `tokenB`) pool
     *         from `msg.sender` to `to`.
     *
     * Requirements
     * ────────────
     * • Pair must already exist (i.e. liquidity was initialised).
     * • `to` cannot be the zero address.
     * • Caller must own **at least** `amount` LP.
     *
     * Post‑conditions (atomic on success)
     * ───────────────────────────────────
     * • Caller’s recorded LP ↓ by `amount`.
     * • Recipient’s recorded LP ↑ by `amount`.
     * • Pool reserves and depth are **unchanged**.
     *
     * @param tokenA  One reserve token of the pair.
     * @param tokenB  The other reserve token (order‑agnostic).
     * @param to      Recipient of the liquidity position.
     * @param amount  Exact LP units to transfer (must be > 0).
     *
     * @return ok  Always true on success.
     *
     * @custom:error ZeroAddress          `to` is the zero address.
     * @custom:error PairNotFound         Pair has not been initialised.
     * @custom:error NotEnoughLiquidity   Caller balance < `amount`.
     */
    function transferLiquidity(
        address tokenA,
        address tokenB,
        address to,
        uint128 amount
    ) external nonReentrant returns (bool ok) {
        /*─────────── 0. basic sanity ───────────*/
        if (to == address(0)) revert ZeroAddress(to); // cannot burn LP
        if (amount == 0) revert NotEnoughLiquidity(0, 0); // zero is nonsense

        /*─────────── 1. canonical ordering ─────*/
        // Ensure tokenA < tokenB for mapping consistency; flip amount stays
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        /*─────────── 2. pair existence check ───*/
        if (pairs[tokenA][tokenB].depth == 0)
            revert PairNotFound(tokenA, tokenB); // pool not live

        /*─────────── 3. balance checks ─────────*/
        IZRC20 t0 = IZRC20(tokenA);
        IZRC20 t1 = IZRC20(tokenB);

        uint128 owned = liquidity[msg.sender][t0][t1]; // caller’s LP
        if (amount > owned) revert NotEnoughLiquidity(owned, amount);

        /*─────────── 4. state updates ──────────*/
        unchecked {
            // • Decrement sender first to guard against self‑transfer corner‑cases
            liquidity[msg.sender][t0][t1] = owned - amount;
            // • Increment recipient
            liquidity[to][t0][t1] += amount;
        }

        return true; // everything OK
    }

    /*═══════════════════════════════════════════════════════════════*\
    │                           Swap Logic                            │
    \*═══════════════════════════════════════════════════════════════*/

    /**
     * @notice Swap between any two supported reserves.
     *
     * @param tokenIn   ERC‑20 address provided by the caller.
     * @param tokenOut  ERC‑20 address the caller wishes to receive.
     * @param amount    • exact‑in  → the *input*  amount the trader sends
     *                  • exact‑out → the *output* amount the trader wants
     * @param limit     • exact‑in  → minimum acceptable output (slippage guard)
     *                  • exact‑out → maximum input willing to pay   (slippage guard)
     * @param to        Recipient of `tokenOut`.
     * @param exactOut  `false` → exact‑in mode, `true` → exact‑out mode.
     *
     * @return inUsed   Actual input pulled from the caller.
     * @return outSent  Actual output sent to `to`.
     *
     * Assumptions & invariants
     * ────────────────────────
     * • Constant‑product formula:  (R₀ + Δx)(R₁ − Δy) = R₀R₁
     *   where a 0 .3 % fee is deducted *inside* Δx (exact‑in) or
     *   *outside* Δx (exact‑out) depending on trade direction.
     * • Fee units: 997 / 1000 multiplier → 0 .3 % taker fee.
     * • Re‑entrancy is blocked by the inherited guard.
     * • Function never leaves the pool in an invalid state: all state
     *   mutations occur *before* external transfers that could fail.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint64 amount,
        uint64 limit,
        address to,
        bool exactOut
    ) external nonReentrant returns (uint64 inUsed, uint64 outSent) {
        /*────────────────── 0. prelim sanity checks ──────────────────*/
        if (
            tokenIn == address(0) ||
            tokenOut == address(0) ||
            tokenIn == tokenOut
        ) revert UnsupportedPair(tokenIn, tokenOut);

        // Canonical ordering: mapping always stored as (lo, hi)
        bool flip;
        address lo;
        address hi;
        unchecked {
            if (tokenIn < tokenOut) {
                lo = tokenIn;
                hi = tokenOut;
            } else {
                lo = tokenOut;
                hi = tokenIn;
                flip = true;
            }
        }

        PoolState storage p = pairs[lo][hi];
        if (p.depth == 0) revert PairNotFound(tokenIn, tokenOut);

        /*──── 1. map reserves so that reserveIn / reserveOut track the caller view ───*/
        uint64 reserveIn = flip ? p.reserve1 : p.reserve0;
        uint64 reserveOut = flip ? p.reserve0 : p.reserve1;

        /*───────── 2. core maths (all uint256 intermediate for safety) ─────────*/

        // Constants for 0 .3 % fee
        uint256 FEE_DEN = 1000;
        uint256 FEE_IN = 997; // 100 % – 0 .3 %
        uint256 FEE_MUL = 3; // used for feeOutside = x * 0.003

        if (!exactOut) {
            /*──────────── exact‑in  (caller specifies Δx) ───────────*/
            uint256 amtIn = amount;
            uint256 amtInAfterFee = (amtIn * FEE_IN) / FEE_DEN; // Δxʹ

            // Δy = (Δxʹ · Rout) / (Rin + Δxʹ)
            uint256 numerator = amtInAfterFee * reserveOut;
            uint256 denominator = reserveIn + amtInAfterFee;
            uint256 amtOut = numerator / denominator;

            require(amtOut >= limit, SlippageSwap(limit, uint64(amtOut)));

            /*──────── state update BEFORE external calls ────────*/
            reserveIn += uint64(amtIn); // pool receives full input
            reserveOut -= uint64(amtOut);
            if (flip) {
                p.reserve1 = reserveIn;
                p.reserve0 = reserveOut;
            } else {
                p.reserve0 = reserveIn;
                p.reserve1 = reserveOut;
            }

            p.depth = uint128(uint256(p.depth)); // no change, just keep compiler quiet

            /*──────── token movements ─────────*/
            require(
                IZRC20(tokenIn).transferFrom(
                    msg.sender,
                    address(this),
                    uint64(amtIn)
                ) && IZRC20(tokenOut).transfer(to, uint64(amtOut)),
                "transfer fail"
            );

            inUsed = uint64(amtIn);
            outSent = uint64(amtOut);
        } else {
            /*──────────── exact‑out (caller specifies Δy) ───────────*/
            uint256 amtOut = amount;
            require(amtOut < reserveOut, "excessive out");

            // Base input (no fee yet): Δxʹ = (Rin · Δy) / (Rout − Δy)
            uint256 numerator = reserveIn * amtOut;
            uint256 denominator = reserveOut - amtOut;
            uint256 baseIn = (numerator + denominator - 1) / denominator; // round UP

            // Outside fee: trader supplies fee on top
            uint256 fee = (baseIn * FEE_MUL + 999) / FEE_DEN; // ceil( base *0.003 )
            uint256 amtInTotal = baseIn + fee;

            require(amtInTotal <= limit, SlippageSwap(limit, uint64(amtInTotal)));

            /*──────── state update BEFORE external calls ────────*/
            reserveIn += uint64(amtInTotal);
            reserveOut -= uint64(amtOut);
            if (flip) {
                p.reserve1 = reserveIn;
                p.reserve0 = reserveOut;
            } else {
                p.reserve0 = reserveIn;
                p.reserve1 = reserveOut;
            }

            /*──────── token movements ─────────*/
            require(
                IZRC20(tokenIn).transferFrom(
                    msg.sender,
                    address(this),
                    uint64(amtInTotal)
                ) && IZRC20(tokenOut).transfer(to, uint64(amtOut)),
                "transfer fail"
            );

            inUsed = uint64(amtInTotal);
            outSent = uint64(amtOut);
        }

        /*────────────── event (optional – add if you already emit one) ───────────
    emit Swap(
        msg.sender,
        tokenIn,
        tokenOut,
        inUsed,
        outSent,
        exactOut
    );
    */
    }

    /*════════════════════════════════════════════════════
     *                 Internal math helpers              *
     *════════════════════════════════════════════════════*/
    /// @dev Babylonian square‑root (uint256 → uint256, returns floor).
    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = y;
        uint256 k = (x + 1) >> 1;
        while (k < z) {
            z = k;
            k = (x / k + k) >> 1;
        }
    }
}
