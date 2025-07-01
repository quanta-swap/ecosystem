// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC20.sol"; // Minimal ERC‑20‑compatible token interface (zero‑fee design)

/**
 * ╔════════════════════════════════════════════════════════════════════════════╗
 * ║                                   ░ I D E X ░                            ║
 * ║  Dual‑Mode Automated Market Maker – V2 Pair Pools ♦ V3 Concentrated Ranges║
 * ║  + Light‑Weight Limit‑Order Book (LOB) – Public Interface                 ║
 * ╚════════════════════════════════════════════════════════════════════════════╝
 *
 * @title IDEX
 * @author Quanta‑Swap Engineering
 * @notice Canonical interface for the Integrated Dual‑Mode Exchange (IDEX).
 *         It exposes every externally‑visible entry‑point while remaining
 *         implementation‑agnostic.  The exchange supports three liquidity
 *         primitives that may coexist for any unordered token pair:
 *
 *         1. **V2‑style constant‑product pool** – classic pair‑wide liquidity.
 *         2. **V3‑style concentrated liquidity ranges** – price‑bounded ticks.
 *         3. **Native limit‑order book** – deterministic maker‑taken orders.
 *
 *         DESIGN PRINCIPLES & ASSUMPTIONS
 *         --------------------------------
 *         • **Token Semantics** – All underlying assets are 64‑bit precision
 *           ( `uint64` ) ERC‑20 tokens that fulfil the zero‑royalty ZRC‑20
 *           wrapper defined in `IZRC20.sol`.  Amounts exceeding 2⁶⁴‑1 are
 *           considered overflow and revert via `LiquidityZero`.
 *
 *         • **Pair Identity** – Functions that take `(tokenA, tokenB)` treat the
 *           pair as unordered; the implementation MUST sort lexicographically
 *           before addressing storage.  Call‑site sorting is *not* required.
 *
 *         • **Ticks & Price Encoding** – Tick spacing and square‑root‑price
 *           encoding mirror Uniswap V3: `sqrtPriceX96` fixed‑point and signed
 *           `int24` ticks.
 *
 *         • **Re‑entrancy & Approvals** – All user‑visible state mutations are
 *           expected to use the checks‑effects‑interactions pattern.  Token
 *           transfers rely on pre‑granted allowances rather than in‑function
 *           approvals.
 */
interface IDEX {
    /* ─────────────────────────────  Custom Errors  ────────────────────────── */

    /// @notice Thrown when the realised output is below the caller‑supplied
    ///         minimum (exact‑in) or when the input required exceeds the
    ///         caller‑supplied maximum (exact‑out).
    error Slippage();

    /// @notice Thrown when an `id` is supplied to the wrong side of the limit
    ///         order book (e.g. trying to fill a *sell* order on the *buy*
    ///         side).
    /// @param id Offending order identifier.
    error WrongSide(uint64 id);

    /// @notice Thrown whenever a function attempts to act on a pool that lacks
    ///         any active liquidity.
    error EmptyPool();

    /// @notice Thrown when calldata array lengths must match for a 1:1 mapping
    ///         but do not (e.g. `swaps.length == 0`).
    error ArraysLengthMismatch();

    /// @notice Thrown when `tickLower >= tickUpper` or either tick lies outside
    ///         the implementation‑defined bounds.
    error InvalidTicks();

    /// @notice Thrown when a liquidity‑manipulating call specifies zero
    ///         liquidity or zero shares, where a strictly positive value is
    ///         mandatory.
    error LiquidityZero();

    /* ───────────────────────────────  Events  ─────────────────────────────── */

    /**
     * @notice Emitted when pair‑wide (V2) liquidity is added.
     * @param provider  Address that provided the assets.
     * @param tokenA    First token of the unordered pair.
     * @param tokenB    Second token of the unordered pair.
     * @param amountA   Actual amount of `tokenA` deposited.
     * @param amountB   Actual amount of `tokenB` deposited.
     * @param shares    ERC‑1155‑like shares minted to the provider.
     */
    event PairLiquidityAdded(
        address indexed provider,
        IZRC20 indexed tokenA,
        IZRC20 indexed tokenB,
        uint64 amountA,
        uint64 amountB,
        uint128 shares
    );

    /**
     * @notice Emitted when pair‑wide (V2) liquidity is removed.
     * @param provider  Address that removed liquidity.
     * @param tokenA    First token of the unordered pair.
     * @param tokenB    Second token of the unordered pair.
     * @param amountA   Amount of `tokenA` returned to the provider.
     * @param amountB   Amount of `tokenB` returned to the provider.
     * @param shares    Shares burned from the provider.
     */
    event PairLiquidityRemoved(
        address indexed provider,
        IZRC20 indexed tokenA,
        IZRC20 indexed tokenB,
        uint64 amountA,
        uint64 amountB,
        uint128 shares
    );

    /**
     * @notice Emitted when a new concentrated‑liquidity position is minted.
     * @param provider   Address that minted the position.
     * @param tokenA     First token of the unordered pair.
     * @param tokenB     Second token of the unordered pair.
     * @param tickLower  Lower tick of the range (inclusive).
     * @param tickUpper  Upper tick of the range (exclusive).
     * @param liquidity  Liquidity minted (Q128.128 fixed‑point).
     * @param amountA    Amount of `tokenA` supplied.
     * @param amountB    Amount of `tokenB` supplied.
     */
    event PositionMinted(
        address indexed provider,
        IZRC20 indexed tokenA,
        IZRC20 indexed tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint64 amountA,
        uint64 amountB
    );

    /**
     * @notice Emitted when a concentrated‑liquidity position is burned.
     * @param provider   Address that burned the position.
     * @param tokenA     First token of the unordered pair.
     * @param tokenB     Second token of the unordered pair.
     * @param tickLower  Lower tick of the range (inclusive).
     * @param tickUpper  Upper tick of the range (exclusive).
     * @param liquidity  Liquidity burned.
     * @param amountA    Amount of `tokenA` returned.
     * @param amountB    Amount of `tokenB` returned.
     */
    event PositionBurned(
        address indexed provider,
        IZRC20 indexed tokenA,
        IZRC20 indexed tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint64 amountA,
        uint64 amountB
    );

    /**
     * @notice Emitted when fees are collected from a concentrated‑liquidity
     *         position without altering liquidity.
     * @param provider   Owner of the position.
     * @param tokenA     First token of the unordered pair.
     * @param tokenB     Second token of the unordered pair.
     * @param tickLower  Lower tick of the range.
     * @param tickUpper  Upper tick of the range.
     * @param feesA      Fees paid out in `tokenA`.
     * @param feesB      Fees paid out in `tokenB`.
     * @param recipient  Address receiving the collected fees.
     */
    event FeesCollected(
        address indexed provider,
        IZRC20 indexed tokenA,
        IZRC20 indexed tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint64 feesA,
        uint64 feesB,
        address recipient
    );

    /**
     * @notice Emitted for *each individual* swap execution inside a batch.
     *         Provides granular execution traces for off‑chain sub‑accounting.
     * @param trader     Address that initiated the batch.
     * @param tokenIn    Token sent by the trader.
     * @param tokenOut   Token received by the trader.
     * @param amountIn   Exact amount of `tokenIn` debited.
     * @param amountOut  Exact amount of `tokenOut` credited.
     */
    event Swap(
        address indexed trader,
        IZRC20 indexed tokenIn,
        IZRC20 indexed tokenOut,
        uint64 amountIn,
        uint64 amountOut
    );

    /**
     * @notice Emitted by the TWAP oracle when a cumulative price snapshot is
     *         recorded.  Snapshots are rate‑limited and may be triggered by any
     *         mutative interaction with the pool.
     * @param tokenA      First token of the unordered pair.
     * @param tokenB      Second token of the unordered pair.
     * @param timestamp   Block.timestamp of the snapshot.
     * @param priceCumAtoB  Cumulative price (tokenA → tokenB) as a Q64.96‑fixed
     *                     sum of √P over time.
     */
    event OracleSnap(
        IZRC20 indexed tokenA,
        IZRC20 indexed tokenB,
        uint64 timestamp,
        uint256 priceCumAtoB
    );

    /* ──────────────────────────  Pool & Oracle Views  ─────────────────────── */

    /**
     * @notice Returns an *approximate* view of total reserves across **all**
     *         active liquidity primitives for `tokenA`/`tokenB`.
     * @dev    The implementation may sample concentrated ranges rather than
     *         performing an O(N) walk; therefore results are for UI display and
     *         should not be used for mission‑critical maths.
     * @return reserveA Aggregate reserve of `tokenA`.
     * @return reserveB Aggregate reserve of `tokenB`.
     */
    function getReserves(
        IZRC20 tokenA,
        IZRC20 tokenB
    ) external view returns (uint64 reserveA, uint64 reserveB);

    /* ---------- V2 Pair‑Pool Specific View ---------- */

    /**
     * @notice View a provider’s position in the pair‑wide V2 pool.
     * @param tokenA   First token of the unordered pair.
     * @param tokenB   Second token of the unordered pair.
     * @param provider Address whose share‑balance is queried.
     * @return amountA Share‑adjusted claim on `tokenA`.
     * @return amountB Share‑adjusted claim on `tokenB`.
     * @return shares  Total shares held by `provider`.
     */
    function getPairLiquidity(
        IZRC20 tokenA,
        IZRC20 tokenB,
        address provider
    ) external view returns (uint64 amountA, uint64 amountB, uint128 shares);

    /* ---------- V3 Position‑Specific View ---------- */

    /**
     * @notice Returns the current accounting state of a specific concentrated‑
     *         liquidity position (`owner`, `tickLower`, `tickUpper`).
     * @param owner      Address of the position owner.
     * @param tokenA     First token of the unordered pair.
     * @param tokenB     Second token of the unordered pair.
     * @param tickLower  Lower tick bound (inclusive).
     * @param tickUpper  Upper tick bound (exclusive).
     * @return liquidity                Current liquidity in the position.
     * @return feeGrowthInsideALast     Last fee‑growth snapshot for `tokenA`.
     * @return feeGrowthInsideBLast     Last fee‑growth snapshot for `tokenB`.
     * @return tokensOwedA              Pending fees in `tokenA`.
     * @return tokensOwedB              Pending fees in `tokenB`.
     */
    function getPosition(
        address owner,
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        returns (
            uint128 liquidity,
            uint64 feeGrowthInsideALast,
            uint64 feeGrowthInsideBLast,
            uint64 tokensOwedA,
            uint64 tokensOwedB
        );

    /**
     * @notice Consult the time‑weighted average price (TWAP) over `secsAgo` for
     *         `tokenA` → `tokenB`.  Reverts if cumulative volume falls below
     *         `minVolume` to protect against low‑liquidity manipulation.
     * @param tokenA    Base token.
     * @param tokenB    Quote token.
     * @param secsAgo   History window in seconds.
     * @param minVolume Minimum cumulative volume threshold.
     * @return priceQ64 Q64‑fixed‑point TWAP price.
     */
    function consultTWAP(
        IZRC20 tokenA,
        IZRC20 tokenB,
        uint32 secsAgo,
        uint128 minVolume
    ) external view returns (uint128 priceQ64);

    /* ─────────────────────  V2 Pair‑Style Liquidity Control  ───────────────── */

    /**
     * @notice Add liquidity to the pair‑wide constant‑product pool.
     * @dev    The function *may* clip `amountADesired/amountBDesired` to honour
     *         the current price without skewing it.  The actual used amounts
     *         are returned alongside the minted shares.
     * @param tokenA          First token of the unordered pair.
     * @param tokenB          Second token of the unordered pair.
     * @param amountADesired  Desired deposit of `tokenA`.
     * @param amountBDesired  Desired deposit of `tokenB`.
     * @return amountAUsed    Actual `tokenA` transferred from the caller.
     * @return amountBUsed    Actual `tokenB` transferred from the caller.
     * @return sharesMinted   Amount of liquidity shares minted to the caller.
     */
    function addLiquidity(
        IZRC20 tokenA,
        IZRC20 tokenB,
        uint64 amountADesired,
        uint64 amountBDesired
    )
        external
        returns (uint64 amountAUsed, uint64 amountBUsed, uint128 sharesMinted);

    /**
     * @notice Burn `shares` from the caller and withdraw the proportional share
     *         of the pair‑wide reserves.
     * @param tokenA    First token of the unordered pair.
     * @param tokenB    Second token of the unordered pair.
     * @param shares    Shares to burn.
     * @return amountAOut `tokenA` transferred to the caller.
     * @return amountBOut `tokenB` transferred to the caller.
     */
    function removeLiquidity(
        IZRC20 tokenA,
        IZRC20 tokenB,
        uint128 shares
    ) external returns (uint64 amountAOut, uint64 amountBOut);

    /* ──────────────────  V3 Concentrated‑Liquidity Control  ────────────────── */

    /**
     * @notice Mint a new concentrated‑liquidity position.
     * @dev    Providing either `amountADesired` or `amountBDesired` as zero lets
     *         the implementation derive the other amount from price.
     * @param tokenA          First token of the unordered pair.
     * @param tokenB          Second token of the unordered pair.
     * @param tickLower       Lower tick bound (inclusive).
     * @param tickUpper       Upper tick bound (exclusive).
     * @param amountADesired  Desired `tokenA` to deposit.
     * @param amountBDesired  Desired `tokenB` to deposit.
     * @return liquidityMinted Liquidity added to the range.
     * @return amountAUsed     Actual `tokenA` transferred.
     * @return amountBUsed     Actual `tokenB` transferred.
     */
    function mintPosition(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint64 amountADesired,
        uint64 amountBDesired
    )
        external
        returns (
            uint128 liquidityMinted,
            uint64 amountAUsed,
            uint64 amountBUsed
        );

    /**
     * @notice Burn all or part of a position’s liquidity.
     * @param tokenA     First token of the unordered pair.
     * @param tokenB     Second token of the unordered pair.
     * @param tickLower  Lower tick of the position.
     * @param tickUpper  Upper tick of the position.
     * @param liquidity  Amount of liquidity to burn.
     * @return amountAOut `tokenA` returned to the caller.
     * @return amountBOut `tokenB` returned to the caller.
     */
    function burnPosition(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external returns (uint64 amountAOut, uint64 amountBOut);

    /**
     * @notice Collect accumulated fees from a position *without* altering its
     *         liquidity balance.
     * @param tokenA        First token of the unordered pair.
     * @param tokenB        Second token of the unordered pair.
     * @param tickLower     Lower tick of the position.
     * @param tickUpper     Upper tick of the position.
     * @param recipient     Destination of the fees (`msg.sender` may pass
     *                      another address).
     * @param amountALimit  Maximum `tokenA` to collect (use max uint64 to pull
     *                      the full balance).
     * @param amountBLimit  Maximum `tokenB` to collect.
     * @return amountA      Fees in `tokenA` actually transferred.
     * @return amountB      Fees in `tokenB` actually transferred.
     */
    function collectFees(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint64 amountALimit,
        uint64 amountBLimit
    ) external returns (uint64 amountA, uint64 amountB);

    /* ──────────────────────  Mint‑Quotation Helper (V3)  ──────────────────── */

    /**
     * @notice Quote the *exact* token amounts required to mint `liquidityDesired`.
     * @param tokenA            First token of the unordered pair.
     * @param tokenB            Second token of the unordered pair.
     * @param tickLower         Lower tick of the desired range.
     * @param tickUpper         Upper tick of the desired range.
     * @param liquidityDesired  Target liquidity to mint.
     * @return amountARequired  Exact `tokenA` required.
     * @return amountBRequired  Exact `tokenB` required.
     */
    function quoteMintRequiredAmounts(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDesired
    ) external view returns (uint64 amountARequired, uint64 amountBRequired);

    /**
     * @notice Given a fixed `amountAIn`, quote the complementary `tokenB` and
     *         resulting liquidity.
     * @param tokenA    First token of the unordered pair.
     * @param tokenB    Second token of the unordered pair.
     * @param tickLower Lower tick of the desired range.
     * @param tickUpper Upper tick of the desired range.
     * @param amountAIn Exact `tokenA` budget.
     * @return amountBRequired `tokenB` needed alongside `amountAIn`.
     * @return liquidityOut    Liquidity that would be minted.
     */
    function quoteMintGivenAmountA(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint64 amountAIn
    ) external view returns (uint64 amountBRequired, uint128 liquidityOut);

    /**
     * @notice Given a fixed `amountBIn`, quote the complementary `tokenA` and
     *         resulting liquidity.
     * @param tokenA    First token of the unordered pair.
     * @param tokenB    Second token of the unordered pair.
     * @param tickLower Lower tick of the desired range.
     * @param tickUpper Upper tick of the desired range.
     * @param amountBIn Exact `tokenB` budget.
     * @return amountARequired `tokenA` needed alongside `amountBIn`.
     * @return liquidityOut    Liquidity that would be minted.
     */
    function quoteMintGivenAmountB(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint64 amountBIn
    ) external view returns (uint64 amountARequired, uint128 liquidityOut);

    /* ─────────────────────────  Limit‑Order Control  ──────────────────────── */

    /// @notice Struct describing a *new* limit order to be created.
    struct OrderCreate {
        IZRC20 tokenIn; // Asset the maker is selling.
        IZRC20 tokenOut; // Asset the maker is buying.
        uint64 amountIn; // Quantity of `tokenIn` to sell.
        uint64 amountOut; // Quantity of `tokenOut` desired.
    }

    /// @notice Struct describing a limit order cancellation request.
    struct OrderCancel {
        IZRC20 tokenIn; // Asset originally offered.
        IZRC20 tokenOut; // Asset originally requested.
        uint64 id; // Unique order identifier.
    }

    /**
     * @notice Atomically cancel and/or create multiple limit orders.
     * @dev    The function processes *all* cancellations before creations to
     *         avoid inadvertent self‑trading when re‑placing an order.
     * @param cancelOps Array of cancellations (may be empty).
     * @param createOps Array of creations (may be empty).
     * @return newIds   Array of arrays mirroring `createOps`, each containing
     *                  the IDs assigned to the creator (multi‑mint support).
     */
    function operateLimitOrders(
        OrderCancel[] calldata cancelOps,
        OrderCreate[] calldata createOps
    ) external returns (uint64[][] memory newIds);

    /* ─────────────────────────────  Batch Swap  ───────────────────────────── */

    /// @notice Per‑swap parameter bundle for `executeBatch`.
    struct SwapParams {
        IZRC20 tokenIn; // Asset sent by the trader.
        IZRC20 tokenOut; // Asset sought by the trader.
        address recipient; // Final recipient (may differ from msg.sender).
        uint64[] limitOrderIds; // Maker IDs that may be matched pre‑pool.
        uint64 amount; // >0 exact‑in, 0 exact‑out (see docs below).
        uint64 limit; // minOut (exact‑in) or maxIn (exact‑out).
    }

    /**
     * @notice Execute a heterogeneous batch of swaps in a *single* call.
     * @dev    Each `SwapParams` entry is processed in order.  If `amount > 0`
     *         the swap is treated as **exact‑in** with `amount` debited and a
     *         minimum output (`limit`) enforced.  If `amount == 0` the swap is
     *         **exact‑out** with `limit` acting as a strict input cap.
     *
     *         The function always attempts to match maker IDs before touching
     *         AMM liquidity, honouring price/time priority.
     *
     * @param free  Tokens attached to `msg.value` that may be used as fees or
     *              inline payments (non‑ETH chains may ignore).
     * @param swaps Array of per‑swap parameter bundles.
     * @return fills Array of output (exact‑in) or input (exact‑out) amounts per
     *               swap, aligned to `swaps`.
     */
    function executeBatch(
        uint64 free,
        SwapParams[] calldata swaps
    ) external returns (uint64[] memory fills);

    /* ════════════════  Simulators & Order Inspector  ════════════════ */

    /**
     * @notice Offline simulation helper: exact‑in path including given maker IDs.
     */
    function simulateWithOrdersExactIn(
        IZRC20 tokenIn,
        IZRC20 tokenOut,
        uint64 amountIn,
        uint64 freeAmt,
        uint64[] calldata ids
    ) external view returns (uint64 amountOut);

    /**
     * @notice Offline simulation helper: exact‑out path including given maker IDs.
     */
    function simulateWithOrdersExactOut(
        IZRC20 tokenIn,
        IZRC20 tokenOut,
        uint64 amountOut,
        uint64 freeAmt,
        uint64[] calldata ids
    ) external view returns (uint64 amountIn);

    /**
     * @notice Fetch a limit order’s current on‑chain accounting fields.
     */
    function getLimitOrder(
        IZRC20 tokenIn,
        IZRC20 tokenOut,
        uint64 id
    )
        external
        view
        returns (
            uint64 amountInTotal,
            uint64 amountOutTotal,
            uint64 amountInFilled,
            bool isActive
        );
}
