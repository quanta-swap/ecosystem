// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "./IZRC20.sol";

/*──────────────────────────────────────────────────────────────────────────────
│  FixedWindowTwapLib                                                           │
│                                                                              │
│  • Sliding-window TWAP with linear interpolation between observations.       │
│  • All arithmetic fits in 128 bits → no risk of overflow in 64-bit universe. │
│  • Ring-buffer keeps storage growth bounded by  window / blockTime  slots.   │
│  • NEW: Per-block TWAP cache slashes repeat-query gas to a single SLOAD.     │
└─────────────────────────────────────────────────────────────────────────────*/
library TWAP {
    /*━━━━━━━━━━━━━━━━━━━━━━━━━━━━ STRUCTS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━*/

    /// @dev A window contribution: price held constant for `duration` seconds.
    struct Contribution {
        uint64 price; // Q32.32 price sample
        uint64 duration; // Seconds the sample was in effect
    }

    /// @dev All oracle state – embed this in your host contract.
    struct State {
        /*── Config ──*/
        uint64 window; // TWAP horizon (seconds) – immutable post-init
        /*── Integration anchors ──*/
        uint64 lastPrice; // Price last confirmed active
        uint64 lastTimestamp; // When `lastPrice` began
        /*── Sliding-window aggregates ──*/
        uint64 totalDuration; // Σ duration inside window (≤ window)
        uint128 totalWeighted; // Σ price×duration (Q32.32 · s)
        /*── Ring buffer ──*/
        uint64 head; // Index of oldest live contribution
        uint64 tail; // Index for next write
        mapping(uint64 => Contribution) ring;
        /*── In-block VWAP accumulators ──*/
        uint128 blockPxVol; // Σ price×vol this block
        uint64 blockVol; // Σ volume    this block
        /*── NEW: per-block TWAP cache ──*/
        uint64 cachedTwap; // Last TWAP computed this block
        uint64 cachedAt; // block.timestamp at which it was computed
    }

    /*━━━━━━━━━━━━━━━━━━━━━━ INITIALISER ━━━━━━━━━━━━━━━━━━━━━━*/

    /// @param window_     Fixed window length in seconds (> 0).
    /// @param initPrice   Start-up price until first observation is pushed.
    function init(
        State storage self,
        uint64 window_,
        uint64 initPrice
    ) internal {
        require(window_ > 0, "zero-window");
        require(self.window == 0, "already-init"); // re-init guard

        self.window = window_;
        self.lastPrice = initPrice;
        self.lastTimestamp = uint64(block.timestamp);
        // Remaining fields default to zero.
    }

    /*━━━━━━━━━━━━━━ IN-BLOCK VWAP ACCUMULATION ━━━━━━━━━━━━━*/

    /// @notice Add a trade sample to the current-block VWAP bucket.
    /// @dev    Zero-volume notes are ignored to avoid div-by-zero.
    /// @param  price  Execution price (Q32.32).
    /// @param  volume Trade size (uint64).
    function recordNote(
        State storage self,
        uint64 price,
        uint64 volume
    ) internal {
        if (volume == 0) return; // nothing to do

        unchecked {
            // 64 × 64 → 128 fits comfortably.
            self.blockPxVol += uint128(price) * volume;
            self.blockVol += volume;
        }
    }

    /*━━━━━━━━━━━━━━━━━━ OBSERVATION PUSH ━━━━━━━━━━━━━━━━━*/

    /// @notice Commit the *previous* block’s VWAP and advance the window.
    /// @dev    Must run **once per block** before the first trade (keeper hook).
    ///         Re-entrancy within the same block is a cheap no-op (dt == 0 guard).
    function push(State storage self) internal {
        uint64 nowTs = uint64(block.timestamp); // A) wall-clock
        uint64 dt = nowTs - self.lastTimestamp; // B) time since last obs
        if (dt == 0) return; // already committed this block

        /* C) Integrate constant-price segment across [lastTimestamp, nowTs). */
        Contribution storage c = self.ring[self.tail];
        c.price = self.lastPrice;
        c.duration = dt;
        self.tail += 1;

        unchecked {
            self.totalDuration += dt;
            self.totalWeighted += uint128(self.lastPrice) * dt;
        }

        /* D) Trim expired contributions so Σduration ≤ window. */
        _trimWindow(self);

        /* E) Determine price for the *current* block. */
        uint64 vwap = self.lastPrice; // default: carry-over
        if (self.blockVol > 0) {
            vwap = uint64(self.blockPxVol / self.blockVol);
        }

        /* F) Update anchors for next block & clear aggregates. */
        self.lastPrice = vwap;
        self.lastTimestamp = nowTs;
        _resetBlockAgg(self);

        /* G) Invalidate the TWAP cache – next read will recompute. */
        self.cachedAt = 0;
    }

    /*━━━━━━━━━━━━━━━━━━━ TWAP CONSULTATION ━━━━━━━━━━━━━━━━━━━*/

    /// @notice Return the TWAP over the entire window ending *now*.
    ///         First call per block computes & caches; rest are O(1) SLOAD.
    /// @dev    This function **writes** to storage (cache), hence is non-view.
    /// @return price 64-bit Q32.32 average price.
    function twap(State storage self) internal returns (uint64 price) {
        uint64 nowTs = uint64(block.timestamp);

        /* Fast-path: cached value is still valid for this block. */
        if (self.cachedAt == nowTs) {
            return self.cachedTwap;
        }

        /* Slow-path: compute fresh TWAP and cache it. */
        uint64 sinceLast = nowTs - self.lastTimestamp;

        // Extend integrals to “now” under linear price assumption.
        uint128 weightedSum = self.totalWeighted +
            uint128(self.lastPrice) *
            sinceLast;
        uint64 durationSum = self.totalDuration + sinceLast;

        price = uint64(weightedSum / durationSum); // Q32.32 division

        /* Store for rest of block – single 128-bit slot load on repeat queries. */
        self.cachedTwap = price;
        self.cachedAt = nowTs;
    }

    /*━━━━━━━━━━━━━━━━━ INTERNAL UTILITIES ━━━━━━━━━━━━━━━━━*/

    /// @dev Trim head contribs until Σduration ≤ window (partial pop supported).
    function _trimWindow(State storage self) private {
        while (self.totalDuration > self.window) {
            Contribution storage headRef = self.ring[self.head];
            uint64 excess = self.totalDuration - self.window;

            if (excess >= headRef.duration) {
                // Full pop – drop the entire contribution.
                unchecked {
                    self.totalDuration -= headRef.duration;
                    self.totalWeighted -=
                        uint128(headRef.price) *
                        headRef.duration;
                }
                delete self.ring[self.head];
                self.head += 1;
            } else {
                // Partial pop – slice `excess` seconds off the head.
                unchecked {
                    self.totalDuration -= excess;
                    self.totalWeighted -= uint128(headRef.price) * excess;
                    headRef.duration -= excess;
                }
                break; // window satisfied
            }
        }
    }

    /// @dev Reset per-block VWAP accumulators to zero.
    function _resetBlockAgg(State storage self) private {
        self.blockPxVol = 0;
        self.blockVol = 0;
    }
}

/*──────────────────────────────────────────────────────────────────────────────
│  QuantaSwapV1Pool – 1‑h TWAP oracle w/ base‑volume weighting & O(1) read     │
│                                                                              │
│  • Off‑chain matcher calls `recordPrice()` after settling each block’s trades │
│    supplying: price (Q32.32) + base‑denominated volume.
│  • Multiple calls *within* the same block are volume‑aggregated to one entry. │
│  • A sliding‑window ring‑buffer maintains Σ(price×vol) and Σ(vol) over the    │
│    last 3 600 s.  `getPrice()` touches **≤2 SLOADs** thanks to cached totals. │
└─────────────────────────────────────────────────────────────────────────────*/
contract QuantaSwapV1Pool {
    /*─────────────────────────────────  Immutables  ─────────────────────────*/
    IZRC20 public immutable BASE;
    IZRC20 public immutable QUOTE;

    using TWAP for TWAP.State;
    TWAP.State private _twap; // the sole oracle state blob

    using UniV2PoolLib64 for UniV2PoolLib64.Pool;
    UniV2PoolLib64.Pool private _cp; // constant-product liquidity
    mapping(address => uint64) _lp;

    function addLiquidity(uint64 a0, uint64 a1) external {
        // Pull tokens **before** the mutate – CEI pattern
        BASE.transferFrom(msg.sender, address(this), a0);
        QUOTE.transferFrom(msg.sender, address(this), a1);
        uint64 lpMint = _cp.mint(a0, a1); // mutates _cp
        _lp[msg.sender] += lpMint; // your internal accounting
    }

    function removeLiquidity(uint64 lp) external {
        uint64 out0;
        uint64 out1;
        (out0, out1) = _cp.burn(lp); // mutates _cp
        _lp[msg.sender] -= lp;
        BASE.transfer(msg.sender, out0);
        QUOTE.transfer(msg.sender, out1);
    }

    /*━━━━━━━━━━━━━━━━━━━━━━━━━━━━ CONSTRUCTOR ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━*/
    /// @param base_       Base-token address (must implement IZRC20).
    /// @param quote_      Quote-token address (must implement IZRC20).
    /// @param bootstrapPx Starting price (Q32.32) until first real sample.
    constructor(IZRC20 base_, IZRC20 quote_, uint64 bootstrapPx) {
        BASE = base_;
        QUOTE = quote_;

        /* Initialise the TWAP oracle once; forever immutable afterwards.   */
        _twap.init(30 minutes, bootstrapPx);
    }

    /*───────────────────────  Events  ──────────────────────*/
    event OrderDestroyed(
        int64 indexed id,
        address indexed owner,
        uint64 refundBase,
        uint64 refundQuote
    );
    event OrderCreated(
        int64 indexed id,
        address indexed owner,
        uint64 baseReserve,
        uint64 quoteReserve,
        uint64 bpqQ32_32,
        uint64 qpbQ32_32
    );

    event FloatDestroyed(
        int64 indexed id,
        address indexed owner,
        uint64 refundBase,
        uint64 refundQuote
    );
    event FloatCreated(
        int64 indexed id,
        address indexed owner,
        uint64 baseReserve,
        uint64 quoteReserve,
        uint16 bpqScalarQ8_8,
        uint16 qpbScalarQ8_8
    );

    /* Placeholder arrays for future AMM functionality (unchanged) */
    struct Order {
        uint64 baseAmountReserve;
        uint64 quoteAmountReserve;
        uint64 basePerQuoteQ32_32;
        uint64 quotePerBaseQ32_32;
    }
    struct Float {
        uint64 baseAmountReserve;
        uint64 quoteAmountReserve;
        uint16 basePerQuotePriceScalarQ8_8;
        uint16 quotePerBasePriceScalarQ8_8;
    }
    Order[] public ordersNormal;
    Float[] public floatsNormal;
    mapping(int64 => address) public owners;

    /*━━━━━━━━━━━━━━━━━━━━━━━━ TRADE SETTLEMENT HOOK ━━━━━━━━━━━━━━━━━━━━━━━*/
    /// @notice Aggregates *all* trades executed *within this block* and
    ///         updates the in-block VWAP accumulator.
    /// @dev    Intended to be called by a matcher / order-book engine.
    ///         Assumes the engine has already transferred token balances.
    /// @param  priceQ32_32  Block-VWAP price for the batch (Q32.32).
    /// @param  baseVolume   Executed base volume in 64-bit units.
    function settleTrades(uint64 priceQ32_32, uint64 baseVolume) external {
        // recordNote is O(1) and safe against zero-volume noise
        _twap.recordNote(priceQ32_32, baseVolume);
    }

    /*━━━━━━━━━━━━━━━━━━━━──── ORACLE KEEPER ENTRY ────━━━━━━━━━━━━━━━━━━━━━*/
    /// @notice Keeper must call *exactly once* per block **before**
    ///         the first `settleTrades()` to roll the sliding window.
    /// @dev    Cheap no-op if accidentally called twice in the same block.
    function pushTwap() external {
        _twap.push(); // rolls window, integrates lastPrice segment,
        // seeds new anchor price, resets in-block accum.
    }

    /*━━━━━━━━━━━━━━━━━━━━━━━ TWAP READ APIs ━━━━━━━━━━━━━━━━━━━━━━━*/
    /// @notice Returns the 1-hour TWAP (Q32.32). Writes to the cache.
    /// @dev    Not marked `view` because the library writes `cachedAt`.
    function getTwap() external returns (uint64 priceQ32_32) {
        return _twap.twap(); // first call per block computes & caches
    }

    /*
        Any pool-mutating path that executes swaps should:
          1.  CALL pushTwap() *once at the very start* of the tx
              (gas-cost amortised over all fills in the block).
          2.  After netting the fills, call settleTrades() with the
              block-VWAP price and the total base volume for the block.

        Reads that depend on the oracle price should call getTwap() and
        tolerate the extra ~16 k gas if they are the first oracle read
        that block.
    */

    function claimPositions(int64[] calldata id) external {
        /* transfers the reserves of each position to the caller and deletes it */
        uint64 baseTotal;
        uint64 quoteTotal;
        for (uint i; i < id.length; i++) {
            int64 idx = id[i];
            require(owners[idx] == msg.sender, "QSP:!owner");
            owners[idx] = address(0);

            if (idx >= 0) {
                Order storage o = ordersNormal[uint64(idx)];
                baseTotal += o.baseAmountReserve;
                quoteTotal += o.quoteAmountReserve;
                emit OrderDestroyed(
                    idx,
                    msg.sender,
                    o.baseAmountReserve,
                    o.quoteAmountReserve
                );
                delete ordersNormal[uint64(idx)];
            } else {
                Float storage f = floatsNormal[uint64(-1 - idx)];
                baseTotal += f.baseAmountReserve;
                quoteTotal += f.quoteAmountReserve;
                emit FloatDestroyed(
                    idx,
                    msg.sender,
                    f.baseAmountReserve,
                    f.quoteAmountReserve
                );
                delete floatsNormal[uint64(-1 - idx)];
            }
        }
        if (baseTotal > 0) BASE.transfer(msg.sender, baseTotal);
        if (quoteTotal > 0) QUOTE.transfer(msg.sender, quoteTotal);
    }

    /**
     * @notice Invert a Q32.32 price, producing the reciprocal in Q32.32.
     *
     * @dev    Let `p = raw / 2^32`.  Then 1/p = (2^32 / raw).
     *         To store the result *also* in Q32.32 we multiply by 2^32:
     *             inv_raw = (2^32 / raw) * 2^32 = 2^64 / raw
     *
     *         • Numerator fits in uint128 (2^64 < 2^128).
     *         • Division by zero is guarded.
     *         • Result always fits in uint64 because:
     *             – raw ≥ 1  ⇒  inv_raw ≤ 2^64-1.
     *
     * @param priceQ32_32  The price to invert (must be > 0).
     * @return invQ32_32   The reciprocal, still in Q32.32.
     */
    function invertPrice(
        uint64 priceQ32_32
    ) internal pure returns (uint64 invQ32_32) {
        require(priceQ32_32 != 0, "TWAP:zero-price");

        // 2^64 numerator expressed as uint128 to avoid intermediate overflow
        invQ32_32 = uint64((uint128(1) << 64) / priceQ32_32);
    }

    /**
     * @notice Compute the execution price for a given float, scaled off the
     *         current TWAP.
     *
     * @dev    • TWAP comes in as Q32.32 (64-bit).
     *         • Each price-scalar in the `Float` struct is Q8.8 (16-bit).
     *         • Multiplying Q32.32 × Q8.8 → Q40.40. We then shift right
     *           8 bits to restore Q32.32 precision.
     *         • Worst-case product fits easily in 128 bits:
     *             maxTWAP (≈2⁶⁴) × maxScalar (≈2¹⁶) = 2⁸⁰ < 2¹²⁸.
     *         • Final cast to uint64 is safe provided you never feed in a
     *           TWAP larger than 2³² – 1 *after* scaling, which is the stated
     *           64-bit price universe invariant.
     *
     * @param float         The float being executed against.
     * @param twap          Current market TWAP in Q32.32.
     * @param baseForQuote  true  → user is paying BASE, receiving QUOTE
     *                      false → user is paying QUOTE, receiving BASE
     *
     * @return priceQ32_32  Scaled execution price in Q32.32.
     */
    function getExecutePriceFloat(
        Float memory float,
        bool baseForQuote,
        uint64 twap // the price in the appropriate direction (quote/base for baseForQuote)
    ) internal pure returns (uint64 priceQ32_32) {
        // 1. Select the direction-specific scalar (Q8.8).
        uint16 scalarQ8_8 = baseForQuote
            ? float.basePerQuotePriceScalarQ8_8 // BASE → QUOTE leg
            : float.quotePerBasePriceScalarQ8_8; // QUOTE → BASE leg

        if (scalarQ8_8 == 0) {
            return 0; // zero scalar means no liquidity in this direction
        }

        if (baseForQuote && float.quoteAmountReserve == 0) {
            return 0; // no QUOTE reserve means no liquidity in this direction
        } else if (!baseForQuote && float.baseAmountReserve == 0) {
            return 0; // no BASE reserve means no liquidity in this direction
        }

        // 2. Multiply TWAP by scalar in 128-bit space to avoid overflow.
        uint128 productQ40_40 = uint128(twap) * uint128(scalarQ8_8);

        // 3. Down-shift 8 fractional bits: Q40.40 → Q32.32. Cast back to 64-bit.
        priceQ32_32 = uint64(productQ40_40 >> 8);
    }

    function getExecutePriceOrder(
        Order memory order,
        bool baseForQuote
    ) internal pure returns (uint64 priceQ32_32) {
        if (baseForQuote && order.quoteAmountReserve == 0) {
            return 0; // no QUOTE reserve means no liquidity in this direction
        } else if (!baseForQuote && order.baseAmountReserve == 0) {
            return 0; // no BASE reserve means no liquidity in this direction
        }
        priceQ32_32 = baseForQuote
            ? order.basePerQuoteQ32_32 // BASE → QUOTE leg
            : order.quotePerBaseQ32_32; // QUOTE → BASE leg
    }

    function getBestExecute(
        Order memory order,
        Float memory float,
        bool baseForQuote,
        uint64 twap // the price in the appropriate direction (quote/base for baseForQuote)
    )
        internal
        pure
        returns (
            uint64 priceQ32_32,
            bool useOrder,
            bool useFloat,
            bool skipOrder, // if the order is not valid or is empty
            bool skipFloat // if the float is not valid or is empty
        )
    {
        // get the order price (0 if no liquidity in this direction)
        uint64 orderPriceQ32_32 = getExecutePriceOrder(order, baseForQuote);
        skipOrder = (priceQ32_32 == 0 ||
            (baseForQuote && order.quoteAmountReserve == 0) ||
            (!baseForQuote && order.baseAmountReserve == 0));

        // get the float price (0 if no liquidity in this direction)
        uint64 floatPriceQ32_32 = getExecutePriceFloat(
            float,
            baseForQuote,
            twap
        );
        skipFloat = (floatPriceQ32_32 == 0 ||
            (baseForQuote && float.quoteAmountReserve == 0) ||
            (!baseForQuote && float.baseAmountReserve == 0));

        if (skipOrder && skipFloat) {
            // neither valid: return zero price
            priceQ32_32 = 0;
            return (priceQ32_32, false, false, true, true);
        }

        if (skipOrder && !skipFloat) {
            // only float valid
            priceQ32_32 = floatPriceQ32_32;
            return (floatPriceQ32_32, false, true, true, false);
        }
        if (!skipOrder && skipFloat) {
            // only order valid
            return (orderPriceQ32_32, true, false, false, true);
        }

        // select the best price
        if (baseForQuote) {
            // user is paying BASE, receiving QUOTE: select the higher price
            if (orderPriceQ32_32 >= floatPriceQ32_32) {
                return (orderPriceQ32_32, true, false, false, false);
            } else {
                return (floatPriceQ32_32, false, true, false, false);
            }
        } else {
            // user is paying QUOTE, receiving BASE: select the lower price
            if (orderPriceQ32_32 <= floatPriceQ32_32) {
                return (orderPriceQ32_32, true, false, false, false);
            } else {
                return (floatPriceQ32_32, false, true, false, false);
            }
        }
    }

    function getPoolPrice(
        bool baseForQuote
    ) internal view returns (uint64 priceQ32_32) {
        if (baseForQuote) {
            return _cp.price0To1Q32_32();
        } else {
            return _cp.price1To0Q32_32();
        }
    }

    /*══════════════════════════════  O R D E R S  ═════════════════════════════*/

    /**
     * @notice Consume up to `remainingIn` of taker input against an Order.
     * @dev    Mutates `order.{base,quote}AmountReserve` in-place.
     *         Caller transfers tokens *after* this returns.
     *
     * @return inRemaining   Taker's input still unspent.
     * @return outGenerated  Output tokens the taker will receive.
     */
    function fillOrderForInput(
        Order storage order,
        bool baseForQuote,
        uint64 remainingIn
    ) internal returns (uint64 inRemaining, uint64 outGenerated) {
        if (remainingIn == 0) return (0, 0);

        if (baseForQuote) {
            // ───── BASE → QUOTE ─────
            if (order.quoteAmountReserve == 0) return (remainingIn, 0);

            // quoteOut = floor( baseIn * 2^32 / price )
            uint128 potentialOut = (uint128(remainingIn) << 32) /
                order.basePerQuoteQ32_32;

            // Cap by available reserve
            if (potentialOut > order.quoteAmountReserve)
                potentialOut = order.quoteAmountReserve;

            outGenerated = uint64(potentialOut);

            // baseUsed = out * price / 2^32   (floor)
            uint128 baseUsed = (uint128(outGenerated) *
                order.basePerQuoteQ32_32) >> 32;

            // ==== mutate reserves ====
            order.baseAmountReserve += uint64(baseUsed);
            order.quoteAmountReserve -= outGenerated;

            inRemaining = remainingIn - uint64(baseUsed);
        } else {
            // ───── QUOTE → BASE ─────
            if (order.baseAmountReserve == 0) return (remainingIn, 0);

            uint128 potentialOut = (uint128(remainingIn) << 32) /
                order.quotePerBaseQ32_32;

            if (potentialOut > order.baseAmountReserve)
                potentialOut = order.baseAmountReserve;

            outGenerated = uint64(potentialOut);

            uint128 quoteUsed = (uint128(outGenerated) *
                order.quotePerBaseQ32_32) >> 32;

            order.quoteAmountReserve += uint64(quoteUsed);
            order.baseAmountReserve -= outGenerated;

            inRemaining = remainingIn - uint64(quoteUsed);
        }
    }

    /**
     * @notice Draw up to `remainingOut` from an Order, returning the
     *         required taker input.  Mutates reserves in-place.
     *
     * @return outRemaining  Output still unsatisfied.
     * @return inRequired    Input tokens the taker must pay.
     */
    function fillOrderForOutput(
        Order storage order,
        bool baseForQuote,
        uint64 remainingOut
    ) internal returns (uint64 outRemaining, uint64 inRequired) {
        if (remainingOut == 0) return (0, 0);

        if (baseForQuote) {
            uint64 avail = order.quoteAmountReserve;
            uint64 outDelivered = remainingOut <= avail ? remainingOut : avail;
            if (outDelivered == 0) return (remainingOut, 0);

            // ceil division to ensure enough BASE is paid
            uint128 num = uint128(outDelivered) * order.basePerQuoteQ32_32;
            inRequired = uint64((num + (1 << 32) - 1) >> 32);

            order.baseAmountReserve += inRequired;
            order.quoteAmountReserve -= outDelivered;

            outRemaining = remainingOut - outDelivered;
        } else {
            uint64 avail = order.baseAmountReserve;
            uint64 outDelivered = remainingOut <= avail ? remainingOut : avail;
            if (outDelivered == 0) return (remainingOut, 0);

            uint128 num = uint128(outDelivered) * order.quotePerBaseQ32_32;
            inRequired = uint64((num + (1 << 32) - 1) >> 32);

            order.quoteAmountReserve += inRequired;
            order.baseAmountReserve -= outDelivered;

            outRemaining = remainingOut - outDelivered;
        }
    }

    /*══════════════════════════════  F L O A T S  ═════════════════════════════*/

    /**
     * @notice Fill a Float for an exact input.  Mutates reserves.
     *
     * @param  twapCached  Direction-appropriate TWAP (already inverted if needed).
     */
    function fillFloatForInput(
        Float storage float_,
        bool baseForQuote,
        uint64 remainingIn,
        uint64 twapCached
    ) internal returns (uint64 inRemaining, uint64 outGenerated) {
        if (remainingIn == 0) return (0, 0);

        uint64 px = getExecutePriceFloat(float_, baseForQuote, twapCached);
        if (px == 0) return (remainingIn, 0); // unusable

        if (baseForQuote) {
            if (float_.quoteAmountReserve == 0) return (remainingIn, 0);

            uint128 potentialOut = (uint128(remainingIn) << 32) / px;
            if (potentialOut > float_.quoteAmountReserve)
                potentialOut = float_.quoteAmountReserve;

            outGenerated = uint64(potentialOut);
            uint128 baseUsed = (uint128(outGenerated) * px) >> 32;

            float_.baseAmountReserve += uint64(baseUsed);
            float_.quoteAmountReserve -= outGenerated;

            inRemaining = remainingIn - uint64(baseUsed);
        } else {
            if (float_.baseAmountReserve == 0) return (remainingIn, 0);

            uint128 potentialOut = (uint128(remainingIn) << 32) / px;
            if (potentialOut > float_.baseAmountReserve)
                potentialOut = float_.baseAmountReserve;

            outGenerated = uint64(potentialOut);
            uint128 quoteUsed = (uint128(outGenerated) * px) >> 32;

            float_.quoteAmountReserve += uint64(quoteUsed);
            float_.baseAmountReserve -= outGenerated;

            inRemaining = remainingIn - uint64(quoteUsed);
        }
    }

    /**
     * @notice Fill a Float for an exact output.  Mutates reserves.
     */
    function fillFloatForOutput(
        Float storage float_,
        bool baseForQuote,
        uint64 remainingOut,
        uint64 twapCached
    ) internal returns (uint64 outRemaining, uint64 inRequired) {
        if (remainingOut == 0) return (0, 0);

        uint64 px = getExecutePriceFloat(float_, baseForQuote, twapCached);
        if (px == 0) return (remainingOut, 0);

        if (baseForQuote) {
            uint64 avail = float_.quoteAmountReserve;
            uint64 outDelivered = remainingOut <= avail ? remainingOut : avail;
            if (outDelivered == 0) return (remainingOut, 0);

            uint128 num = uint128(outDelivered) * px;
            inRequired = uint64((num + (1 << 32) - 1) >> 32);

            float_.baseAmountReserve += inRequired;
            float_.quoteAmountReserve -= outDelivered;

            outRemaining = remainingOut - outDelivered;
        } else {
            uint64 avail = float_.baseAmountReserve;
            uint64 outDelivered = remainingOut <= avail ? remainingOut : avail;
            if (outDelivered == 0) return (remainingOut, 0);

            uint128 num = uint128(outDelivered) * px;
            inRequired = uint64((num + (1 << 32) - 1) >> 32);

            float_.quoteAmountReserve += inRequired;
            float_.baseAmountReserve -= outDelivered;

            outRemaining = remainingOut - outDelivered;
        }
    }

    // ────────────────────────────  INTERNAL HELPERS  ────────────────────────────

    /**
     * @dev Consume up to `remainingIn` against the constant-product pool.
     *
     *      Direction legend (same as the rest of the file):
     *        baseForQuote = true   → taker PAYS  BASE (token-0), receives QUOTE (token-1)
     *                      = false → taker PAYS  QUOTE,           receives BASE.
     *
     *      All arithmetic lives in 128-bit space; reserves are 64-bit.
     *
     * @return inRemaining  Portion of `remainingIn` still unspent.
     * @return outGenerated Tokens the taker receives from the pool.
     */
    function _fillPoolForInput(
        bool baseForQuote,
        uint64 remainingIn
    ) private returns (uint64 inRemaining, uint64 outGenerated) {
        if (remainingIn == 0) return (0, 0);

        if (baseForQuote) {
            // Token-0 ➜ Token-1  (zeroForOne == true)
            outGenerated = UniV2PoolLib64.getAmountOut(
                remainingIn,
                _cp.reserve0,
                _cp.reserve1,
                _cp.feePpm
            );
            if (outGenerated == 0) return (remainingIn, 0);

            // mutate reserves
            _cp.reserve0 += remainingIn;
            _cp.reserve1 -= outGenerated;
        } else {
            // Token-1 ➜ Token-0  (zeroForOne == false)
            outGenerated = UniV2PoolLib64.getAmountOut(
                remainingIn,
                _cp.reserve1,
                _cp.reserve0,
                _cp.feePpm
            );
            if (outGenerated == 0) return (remainingIn, 0);

            _cp.reserve1 += remainingIn;
            _cp.reserve0 -= outGenerated;
        }

        inRemaining = 0; ///< everything was consumed
    }

    /**
     * @dev Exact-OUT leg against the pool (mirrors `_fillPoolForInput`).
     *
     * @return outRemaining  Portion of desired `remainingOut` still unfilled.
     * @return inRequired    Tokens the taker must pay the pool.
     */
    function _fillPoolForOutput(
        bool baseForQuote,
        uint64 remainingOut
    ) private returns (uint64 outRemaining, uint64 inRequired) {
        if (remainingOut == 0) return (0, 0);

        if (baseForQuote) {
            // Wants QUOTE, will pay BASE.
            inRequired = UniV2PoolLib64.getAmountIn(
                remainingOut,
                _cp.reserve0,
                _cp.reserve1,
                _cp.feePpm
            );
            if (inRequired == 0) return (remainingOut, 0);

            _cp.reserve0 += inRequired;
            _cp.reserve1 -= remainingOut;
        } else {
            // Wants BASE, will pay QUOTE.
            inRequired = UniV2PoolLib64.getAmountIn(
                remainingOut,
                _cp.reserve1,
                _cp.reserve0,
                _cp.feePpm
            );
            if (inRequired == 0) return (remainingOut, 0);

            _cp.reserve1 += inRequired;
            _cp.reserve0 -= remainingOut;
        }

        outRemaining = 0;
    }

    // ───────────────────────────  MAIN MERGE FUNCTION  ──────────────────────────

    /*══════════════════════════════════════════════════════════════════════════*\
    │                        P O O L   H E L P E R S                             │
    \*══════════════════════════════════════════════════════════════════════════*/

    function _poolFillExactIn(
        bool baseForQuote,
        uint64 amountIn,
        uint64 r0,
        uint64 r1
    ) private pure returns (uint64 outGenerated, uint64 newR0, uint64 newR1) {
        if (amountIn == 0) return (0, r0, r1);

        if (baseForQuote) {
            outGenerated = UniV2PoolLib64.getAmountOut(
                amountIn,
                r0,
                r1,
                0 // fee = 0 : all fee was up-front
            );
            if (outGenerated == 0) return (0, r0, r1);
            newR0 = r0 + amountIn;
            newR1 = r1 - outGenerated;
        } else {
            outGenerated = UniV2PoolLib64.getAmountOut(amountIn, r1, r0, 0);
            if (outGenerated == 0) return (0, r0, r1);
            newR1 = r1 + amountIn;
            newR0 = r0 - outGenerated;
        }
    }

    function _poolFillExactOut(
        bool baseForQuote,
        uint64 amountOut,
        uint64 r0,
        uint64 r1
    ) private pure returns (uint64 inRequired, uint64 newR0, uint64 newR1) {
        if (amountOut == 0) return (0, r0, r1);

        if (baseForQuote) {
            inRequired = UniV2PoolLib64.getAmountIn(amountOut, r0, r1, 0);
            if (inRequired == 0) return (0, r0, r1);
            newR0 = r0 + inRequired;
            newR1 = r1 - amountOut;
        } else {
            inRequired = UniV2PoolLib64.getAmountIn(amountOut, r1, r0, 0);
            if (inRequired == 0) return (0, r0, r1);
            newR1 = r1 + inRequired;
            newR0 = r0 - amountOut;
        }
    }

    /*══════════════════════════════════════════════════════════════════════════*\
    │                               execute                                      │
    \*══════════════════════════════════════════════════════════════════════════*/

    enum Src {
        NONE,
        ORD,
        FLT,
        POOL
    }

    /**
     * @notice Best-price matcher over Orders, Floats and the CP pool.
     * @dev    Forward-progress & corruption-hardened rewrite.
     *
     *         ────────────────────────────────────────────────────────────────
     *         Key invariants / design choices
     *         ────────────────────────────────────────────────────────────────
     *         • “Input” and “Output” are always from the taker’s perspective
     *           (input = what they pay, output = what they receive).
     *         • Fee is applied **once** on the side the taker pays and is
     *           credited to the pool reserves.  It is *not* considered traded
     *           volume and therefore excluded from the oracle note.
     *         • We only touch storage twice at the very end to flush `_cp`
     *           reserves back (r0, r1) — everything else lives in memory.
     *         • The main while-loop is guaranteed to make progress or exit:
     *           after every iteration `needIn` or `needOut` strictly decreases,
     *           otherwise we `break;` to avoid a DoS.
     *         • Access-control on maker liquidity *not* enforced here — if you
     *           do want ownership gating, add it to the fill helpers.
     */
    function execute(
        int64[] calldata orders,
        int64[] calldata floats,
        bool exactInput,      // true  = exact-in ; false = exact-out
        bool baseForQuote,    // true  = pay BASE, receive QUOTE
        uint64 amount,        // fixed input  (or output) amount
        uint64 limit          // min-out (exact-in) | max-in (exact-out)
    ) external returns (uint64 input, uint64 output)
    {
        /* ───────────────────────────── 1. Fee handling ──────────────────── */
        uint64 feePpm   = _cp.feePpm;
        uint64 feeAcc   = 0;          // tokens skimmed to the pool
        uint64 needIn   = 0;          // taker input still to source
        uint64 needOut  = 0;          // taker output still to provide

        if (exactInput) {
            // Caller pre-approves `amount`; we skim the fee upfront.
            uint128 fee = (uint128(amount) * feePpm + 999_999) / 1_000_000; // ceil
            feeAcc = uint64(fee);
            needIn = amount - feeAcc;      // net amount to be traded
            input  = amount;               // total pull later
        } else {
            // Fee applied once final net input is known (see step 7).
            needOut = amount;
        }

        /* ─────────────────────────── 2. Freshen TWAP  ───────────────────── */
        _twap.push();                      // commit prev-block slice
        uint64 twapDir = _twap.twap();     // quote / base
        if (!baseForQuote) twapDir = invertPrice(twapDir);

        /* ─────────────────────────── 3. Local reserves ─────────────────── */
        uint64 r0 = _cp.reserve0;
        uint64 r1 = _cp.reserve1;

        /* cursors into the user-supplied sorted ID lists */
        uint256 oPtr = 0;
        uint256 fPtr = 0;

        /* ─────────────────────────── 4. Fill loop  ──────────────────────── */
        while (exactInput ? needIn > 0 : needOut > 0) {

            /* 4-A: peek best executable price for each source (0 = unusable) */
            uint64 pxOrd = 0;
            while (oPtr < orders.length && pxOrd == 0) {
                Order storage o = ordersNormal[uint64(orders[oPtr])];
                pxOrd = getExecutePriceOrder(o, baseForQuote);
                if (pxOrd == 0) ++oPtr;            // empty side → skip
            }

            uint64 pxFlt = 0;
            while (fPtr < floats.length && pxFlt == 0) {
                Float storage f = floatsNormal[uint64(floats[fPtr])];
                pxFlt = getExecutePriceFloat(f, baseForQuote, twapDir);
                if (pxFlt == 0) ++fPtr;
            }

            uint64 pxPool = (r0 == 0 || r1 == 0)
                ? 0
                : baseForQuote
                    ? uint64((uint128(r1) << 32) / r0)  // quote / base
                    : uint64((uint128(r0) << 32) / r1); // quote / base

            if (pxOrd | pxFlt | pxPool == 0) break; // dead-end: no liquidity

            /* 4-B: select best price in taker’s favour */
            Src best = Src.NONE;
            uint64 bestPx;

            if (pxOrd != 0) { best = Src.ORD; bestPx = pxOrd; }
            if (pxFlt != 0 &&
                (best == Src.NONE ||
                 (baseForQuote ? pxFlt > bestPx : pxFlt < bestPx)))
            { best = Src.FLT; bestPx = pxFlt; }
            if (pxPool != 0 &&
                (best == Src.NONE ||
                 (baseForQuote ? pxPool > bestPx : pxPool < bestPx)))
            { best = Src.POOL; bestPx = pxPool; }

            /* 4-C: execute against chosen source */
            uint64 progress; // how much of need{In,Out} we satisfied this iter

            if (best == Src.ORD) {
                Order storage oFill = ordersNormal[uint64(orders[oPtr])];
                if (exactInput) {
                    uint64 got;
                    (needIn, got) = fillOrderForInput(oFill, baseForQuote, needIn);
                    output += got;
                    progress = got;
                } else {
                    uint64 req;
                    (needOut, req) = fillOrderForOutput(oFill, baseForQuote, needOut);
                    needIn += req;
                    progress = req;
                }
                if ((baseForQuote ? oFill.quoteAmountReserve : oFill.baseAmountReserve) == 0)
                    ++oPtr;

            } else if (best == Src.FLT) {
                Float storage fFill = floatsNormal[uint64(floats[fPtr])];
                if (exactInput) {
                    uint64 got;
                    (needIn, got) = fillFloatForInput(
                        fFill, baseForQuote, needIn, twapDir
                    );
                    output  += got;
                    progress = got;
                } else {
                    uint64 req;
                    (needOut, req) = fillFloatForOutput(
                        fFill, baseForQuote, needOut, twapDir
                    );
                    needIn  += req;
                    progress = req;
                }
                if ((baseForQuote ? fFill.quoteAmountReserve : fFill.baseAmountReserve) == 0)
                    ++fPtr;

            } else {
                /* Src.POOL – consistent return signature: (out, newR0, newR1) */
                if (exactInput) {
                    uint64 outGen;
                    (outGen, r0, r1) = _poolFillExactIn(baseForQuote, needIn, r0, r1);
                    needIn  = 0;              // all net input spent
                    output += outGen;
                    progress = outGen;
                } else {
                    uint64 inReq;
                    (inReq, r0, r1) = _poolFillExactOut(baseForQuote, needOut, r0, r1);
                    needOut  = 0;
                    needIn  += inReq;
                    progress = inReq;
                }
            }

            /* Guard: if nothing progressed we bail to avoid gas-death */
            if (progress == 0) break;
        }

        /* ─────────────────── 5. Finalise fee for exact-OUT path ─────────── */
        if (!exactInput) {
            uint128 fee = (uint128(needIn) * feePpm + 999_999) / 1_000_000;
            feeAcc = uint64(fee);
            input  = needIn + feeAcc;      // total pull
        }

        /* ─────────────────── 6. Slippage check - caller guarantees ─────── */
        if (exactInput) {
            require(output >= limit, "QSP:min-out");
        } else {
            require(input  <= limit, "QSP:max-in");
            output = amount;               // promised exact output
        }

        /* ─────────────────── 7. Credit protocol fee to reserves ─────────── */
        if (feeAcc != 0) {
            if (baseForQuote) r0 += feeAcc;
            else              r1 += feeAcc;
        }

        /* ─────────────────── 8. Flush pool reserves (2 SSTOREs) ─────────── */
        if (r0 != _cp.reserve0) _cp.reserve0 = r0;
        if (r1 != _cp.reserve1) _cp.reserve1 = r1;

        /* ─────────────────── 9. External token transfers (CEI) ─────────── */
        if (baseForQuote) {
            if (input  != 0) BASE.transferFrom(msg.sender, address(this), input);
            if (output != 0) QUOTE.transfer(msg.sender, output);
        } else {
            if (input  != 0) QUOTE.transferFrom(msg.sender, address(this), input);
            if (output != 0) BASE.transfer(msg.sender, output);
        }

        /* ─────────────────── 10. One oracle note on *net* trade ─────────── */
        uint64 netBaseVol = baseForQuote ? (input - feeAcc) : output;
        if (netBaseVol != 0) {
            uint64 pxQ32 = baseForQuote
                ? uint64((uint128(output) << 32) / netBaseVol)      // quote / base
                : uint64((uint128(input - feeAcc) << 32) / output); // quote / base
            _twap.recordNote(pxQ32, netBaseVol);
        }
    }

    /*════════════════════════════ BATCH ORDERS ═══════════════════════════*/
    struct OrderParams {
        uint64 baseAmountReserve;
        uint64 quoteAmountReserve;
        uint64 basePerQuoteQ32_32;
        uint64 quotePerBaseQ32_32;
    }

    function batchClaimCreateOrders(
        OrderParams[] calldata createParams,
        int64[] calldata destroyIds
    ) external {
        /* 1️⃣ 64-bit running totals (checked) */
        uint64 cBase;
        uint64 cQuote;
        for (uint i; i < createParams.length; ++i) {
            unchecked {
                uint64 nb = cBase + createParams[i].baseAmountReserve;
                uint64 nq = cQuote + createParams[i].quoteAmountReserve;
                require(nb >= cBase && nq >= cQuote, "sum overflow");
                cBase = nb;
                cQuote = nq;
            }
        }
        uint64 dBase;
        uint64 dQuote;
        for (uint j; j < destroyIds.length; ++j) {
            int64 id = destroyIds[j];
            require(id >= 0, "id<0:not-order");
            require(owners[id] == msg.sender, "not owner");
            Order storage od = ordersNormal[uint64(id)];
            unchecked {
                uint64 nb = dBase + od.baseAmountReserve;
                uint64 nq = dQuote + od.quoteAmountReserve;
                require(nb >= dBase && nq >= dQuote, "sum overflow");
                dBase = nb;
                dQuote = nq;
            }
        }

        /* 2️⃣ signed 128-bit net deltas */
        int128 netBase = int128(int64(cBase)) - int128(int64(dBase));
        int128 netQuote = int128(int64(cQuote)) - int128(int64(dQuote));

        /* 3️⃣ pull positive deltas before state changes */
        if (netBase > 0)
            BASE.transferFrom(
                msg.sender,
                address(this),
                uint64(uint128(netBase))
            );
        if (netQuote > 0)
            QUOTE.transferFrom(
                msg.sender,
                address(this),
                uint64(uint128(netQuote))
            );

        /* 4️⃣ CREATE new orders (eligible for later gas-refund deletes) */
        for (uint k; k < createParams.length; ++k) {
            OrderParams calldata p = createParams[k];
            ordersNormal.push(
                Order({
                    baseAmountReserve: p.baseAmountReserve,
                    quoteAmountReserve: p.quoteAmountReserve,
                    basePerQuoteQ32_32: p.basePerQuoteQ32_32,
                    quotePerBaseQ32_32: p.quotePerBaseQ32_32
                })
            );
            int64 newId = int64(int256(ordersNormal.length) - 1);
            owners[newId] = msg.sender;
            emit OrderCreated(
                newId,
                msg.sender,
                p.baseAmountReserve,
                p.quoteAmountReserve,
                p.basePerQuoteQ32_32,
                p.quotePerBaseQ32_32
            );
        }

        /* 5️⃣ DESTROY requested orders (SSTORE→0 refunds) */
        for (uint m; m < destroyIds.length; ++m) {
            int64 id = destroyIds[m];
            Order storage od2 = ordersNormal[uint64(id)];
            emit OrderDestroyed(
                id,
                msg.sender,
                od2.baseAmountReserve,
                od2.quoteAmountReserve
            );
            delete ordersNormal[uint64(id)];
            delete owners[id];
        }

        /* 6️⃣ refund negative deltas to caller */
        if (netBase < 0) BASE.transfer(msg.sender, uint64(uint128(-netBase)));
        if (netQuote < 0)
            QUOTE.transfer(msg.sender, uint64(uint128(-netQuote)));
    }

    /*════════════════════════════ BATCH FLOATS ═══════════════════════════*/
    struct FloatParams {
        uint64 baseAmountReserve;
        uint64 quoteAmountReserve;
        uint16 basePerQuoteScalarQ8_8;
        uint16 quotePerBaseScalarQ8_8;
    }

    function batchClaimCreateFloats(
        FloatParams[] calldata createParams,
        int64[] calldata destroyIds
    ) external {
        uint64 cBase;
        uint64 cQuote;
        for (uint i; i < createParams.length; ++i) {
            unchecked {
                uint64 nb = cBase + createParams[i].baseAmountReserve;
                uint64 nq = cQuote + createParams[i].quoteAmountReserve;
                require(nb >= cBase && nq >= cQuote, "sum overflow");
                cBase = nb;
                cQuote = nq;
            }
        }
        uint64 dBase;
        uint64 dQuote;
        for (uint j; j < destroyIds.length; ++j) {
            int64 id = destroyIds[j];
            require(id < 0, "id>0:not-float");
            require(owners[id] == msg.sender, "not owner");
            Float storage fl = floatsNormal[uint64(-1 - id)];
            unchecked {
                uint64 nb = dBase + fl.baseAmountReserve;
                uint64 nq = dQuote + fl.quoteAmountReserve;
                require(nb >= dBase && nq >= dQuote, "sum overflow");
                dBase = nb;
                dQuote = nq;
            }
        }

        int128 netBase = int128(int64(cBase)) - int128(int64(dBase));
        int128 netQuote = int128(int64(cQuote)) - int128(int64(dQuote));

        if (netBase > 0)
            BASE.transferFrom(
                msg.sender,
                address(this),
                uint64(uint128(netBase))
            );
        if (netQuote > 0)
            QUOTE.transferFrom(
                msg.sender,
                address(this),
                uint64(uint128(netQuote))
            );

        /* create floats */
        for (uint k; k < createParams.length; ++k) {
            FloatParams calldata p = createParams[k];
            floatsNormal.push(
                Float({
                    baseAmountReserve: p.baseAmountReserve,
                    quoteAmountReserve: p.quoteAmountReserve,
                    basePerQuotePriceScalarQ8_8: p.basePerQuoteScalarQ8_8,
                    quotePerBasePriceScalarQ8_8: p.quotePerBaseScalarQ8_8
                })
            );
            int64 newId = int64(-1 - int256(floatsNormal.length - 1));
            owners[newId] = msg.sender;
            emit FloatCreated(
                newId,
                msg.sender,
                p.baseAmountReserve,
                p.quoteAmountReserve,
                p.basePerQuoteScalarQ8_8,
                p.quotePerBaseScalarQ8_8
            );
        }

        /* destroy floats */
        for (uint m; m < destroyIds.length; ++m) {
            int64 id = destroyIds[m];
            Float storage fl2 = floatsNormal[uint64(-1 - id)];
            emit FloatDestroyed(
                id,
                msg.sender,
                fl2.baseAmountReserve,
                fl2.quoteAmountReserve
            );
            delete floatsNormal[uint64(-1 - id)];
            delete owners[id];
        }

        if (netBase < 0) BASE.transfer(msg.sender, uint64(uint128(-netBase)));
        if (netQuote < 0)
            QUOTE.transfer(msg.sender, uint64(uint128(-netQuote)));
    }

    event Released(int64 indexed id);

    /* sets the owner of the order to 0 */
    function release(int64 id) external {
        require(owners[id] == msg.sender, "owner");
        owners[id] = address(0);
        emit Released(id);
    }

    /* VIEWERS */
    /**
     * @dev   Return the direction-correct TWAP **without** writing to storage.
     *        If the cache is still fresh we use it; otherwise we recompute the
     *        integral on-the-fly exactly as TWAP.twap() would, but in memory.
     */
    function _peekTwapDir(bool baseForQuote) private view returns (uint64 px) {
        TWAP.State storage s = _twap;

        uint64 nowTs = uint64(block.timestamp);
        if (s.cachedAt == nowTs) {
            px = s.cachedTwap; // already quotePerBase
        } else {
            uint64 sinceLast = nowTs - s.lastTimestamp;
            uint128 weighted = s.totalWeighted +
                uint128(s.lastPrice) *
                sinceLast;
            uint64 duration = s.totalDuration + sinceLast;
            px = uint64(weighted / duration);
        }

        // If the caller wants BASE/QUOTE direction, invert once.
        if (!baseForQuote) {
            // 2^64 / px  – safe because px > 0 and universe is 64-bit
            px = uint64((uint128(1) << 64) / px);
        }
    }

    // Per-ID shadow reserves (loaded lazily)
    struct LOrder {
        uint64 b;
        uint64 q;
        uint64 bpq;
        uint64 qpb;
    }
    struct LFloat {
        uint64 b;
        uint64 q;
        uint16 sbpq;
        uint16 sqpb;
    }

    /**
     * @notice Purely simulates the execution path of `execute` without
     *         persisting any state or performing transfers.
     *
     * @param orders       IDs of limit orders to consider (best-price first).
     * @param floats       IDs of floats to consider   (best-price first).
     * @param exactInput   true  → caller fixes `amount` as INPUT (BASE or QUOTE)
     *                    false → caller fixes `amount` as OUTPUT.
     * @param baseForQuote true  → pay BASE, receive QUOTE
     *                    false → pay QUOTE, receive BASE
     * @param amount       Exact input (or output) amount in 64-bit units.
     *
     * @return inputUsed   BASE/QUOTE the taker would spend.
     * @return outputGot   QUOTE/BASE the taker would get.
     */
    function simulateExecute(
        int64[] calldata orders,
        int64[] calldata floats,
        bool exactInput,
        bool baseForQuote,
        uint64 amount
    ) external view returns (uint64 inputUsed, uint64 outputGot) {
        /*── 1. Take a snapshot of the TWAP (quotePerBase or inverted) ──*/
        uint64 twapDir = _peekTwapDir(baseForQuote);

        /*── 2. Local working copies so we never touch storage ─────────*/
        uint64 needIn = exactInput ? amount : 0;
        uint64 needOut = exactInput ? 0 : amount;

        // Cursor indices
        uint oPtr;
        uint fPtr;

        /*── 3. Main merge loop (identical to `execute`, but view-only) ───*/
        while (exactInput ? needIn > 0 : needOut > 0) {
            /* ── peek best order price ── */
            uint64 orderPrice = 0;
            LOrder memory ord;
            while (oPtr < orders.length && orderPrice == 0) {
                Order storage oStore = ordersNormal[uint64(orders[oPtr])];
                ord = LOrder(
                    oStore.baseAmountReserve,
                    oStore.quoteAmountReserve,
                    oStore.basePerQuoteQ32_32,
                    oStore.quotePerBaseQ32_32
                );
                orderPrice = getExecutePriceOrder(
                    Order(ord.b, ord.q, ord.bpq, ord.qpb),
                    baseForQuote
                );
                if (orderPrice == 0) ++oPtr;
            }

            /* ── peek best float price ── */
            uint64 floatPrice = 0;
            LFloat memory flt;
            while (fPtr < floats.length && floatPrice == 0) {
                Float storage fStore = floatsNormal[uint64(floats[fPtr])];
                flt = LFloat(
                    fStore.baseAmountReserve,
                    fStore.quoteAmountReserve,
                    fStore.basePerQuotePriceScalarQ8_8,
                    fStore.quotePerBasePriceScalarQ8_8
                );
                floatPrice = getExecutePriceFloat(
                    Float(flt.b, flt.q, flt.sbpq, flt.sqpb),
                    baseForQuote,
                    twapDir
                );
                if (floatPrice == 0) ++fPtr;
            }

            if (orderPrice == 0 && floatPrice == 0) break; // no liquidity

            bool takeOrder = (orderPrice == 0)
                ? false
                : (floatPrice == 0)
                    ? true
                    : baseForQuote
                        ? orderPrice >= floatPrice
                        : orderPrice <= floatPrice;

            if (takeOrder) {
                if (exactInput) {
                    uint64 got;
                    (, got) = _simFillOrderForInput(ord, baseForQuote, needIn);
                    needIn -= (uint64(needIn) - uint64(ord.b < 1 ? 0 : 0)); // dummy
                    outputGot += got;
                    needIn = needIn > got ? needIn - got : 0;
                    if (ord.q == 0 || ord.b == 0) ++oPtr;
                } else {
                    uint64 need;
                    (, need) = _simFillOrderForOutput(
                        ord,
                        baseForQuote,
                        needOut
                    );
                    needOut -= (uint64(needOut) - uint64(ord.q < 1 ? 0 : 0)); // dummy
                    inputUsed += need;
                    needOut = needOut > need ? needOut - need : 0;
                    if (ord.q == 0 || ord.b == 0) ++oPtr;
                }
            } else {
                if (exactInput) {
                    uint64 got;
                    (, got) = _simFillFloatForInput(
                        flt,
                        baseForQuote,
                        needIn,
                        twapDir
                    );
                    outputGot += got;
                    needIn = needIn > got ? needIn - got : 0;
                    if (flt.q == 0 || flt.b == 0) ++fPtr;
                } else {
                    uint64 need;
                    (, need) = _simFillFloatForOutput(
                        flt,
                        baseForQuote,
                        needOut,
                        twapDir
                    );
                    inputUsed += need;
                    needOut = needOut > need ? needOut - need : 0;
                    if (flt.q == 0 || flt.b == 0) ++fPtr;
                }
            }
        }

        if (exactInput) {
            inputUsed = amount;
        } else {
            outputGot = amount;
        }
    }

    /*─────────── tiny, pure helpers that act on local copies ───────────*/

    function _simFillOrderForInput(
        LOrder memory o,
        bool baseForQuote,
        uint64 remainingIn
    ) private pure returns (uint64, uint64) {
        if (remainingIn == 0) return (0, 0);
        uint64 outGenerated;
        if (baseForQuote) {
            uint128 potential = (uint128(remainingIn) << 32) / o.bpq;
            if (potential > o.q) potential = o.q;
            outGenerated = uint64(potential);
        } else {
            uint128 potential = (uint128(remainingIn) << 32) / o.qpb;
            if (potential > o.b) potential = o.b;
            outGenerated = uint64(potential);
        }
        return (0, outGenerated);
    }

    function _simFillOrderForOutput(
        LOrder memory o,
        bool baseForQuote,
        uint64 remainingOut
    ) private pure returns (uint64, uint64) {
        if (remainingOut == 0) return (0, 0);
        uint64 inRequired;
        if (baseForQuote) {
            uint64 avail = o.q;
            uint64 out = remainingOut <= avail ? remainingOut : avail;
            uint128 num = uint128(out) * o.bpq;
            inRequired = uint64((num + (1 << 32) - 1) >> 32);
        } else {
            uint64 avail = o.b;
            uint64 out = remainingOut <= avail ? remainingOut : avail;
            uint128 num = uint128(out) * o.qpb;
            inRequired = uint64((num + (1 << 32) - 1) >> 32);
        }
        return (0, inRequired);
    }

    function _simFillFloatForInput(
        LFloat memory f,
        bool baseForQuote,
        uint64 remainingIn,
        uint64 px
    ) private pure returns (uint64, uint64) {
        if (remainingIn == 0) return (0, 0);
        uint64 outGenerated;
        if (baseForQuote) {
            uint128 potential = (uint128(remainingIn) << 32) / px;
            if (potential > f.q) potential = f.q;
            outGenerated = uint64(potential);
        } else {
            uint128 potential = (uint128(remainingIn) << 32) / px;
            if (potential > f.b) potential = f.b;
            outGenerated = uint64(potential);
        }
        return (0, outGenerated);
    }

    function _simFillFloatForOutput(
        LFloat memory f,
        bool baseForQuote,
        uint64 remainingOut,
        uint64 px
    ) private pure returns (uint64, uint64) {
        if (remainingOut == 0) return (0, 0);
        uint64 inRequired;
        if (baseForQuote) {
            uint64 avail = f.q;
            uint64 out = remainingOut <= avail ? remainingOut : avail;
            uint128 num = uint128(out) * px;
            inRequired = uint64((num + (1 << 32) - 1) >> 32);
        } else {
            uint64 avail = f.b;
            uint64 out = remainingOut <= avail ? remainingOut : avail;
            uint128 num = uint128(out) * px;
            inRequired = uint64((num + (1 << 32) - 1) >> 32);
        }
        return (0, inRequired);
    }
}

/*──────────────────────────────────────────────────────────────────────────────
│  UniV2PoolLib64                                                             │
│                                                                              │
│  A lean, opinionated helper library for building Uniswap‑V2–style constant   │
│  product pools in a 64‑bit token‑balance universe.  Liquidity receipts are   │
│  *not* ERC‑20 tokens – the host contract is expected to account for them     │
│  internally (e.g. mapping(address ⇒ uint64)).                                │
│                                                                              │
│  Design invariants                                                          │
│  ────────────────────────────────────────────────────────────────────────────│
│    • All balances, liquidity, fees, etc. are **uint64**                     │
│      ( 2⁶⁴‑1 ≈ 1.8 × 10¹⁹ – more than enough head‑room ).                    │
│    • Prices are expressed as **√price** in **Q32.32** (a.k.a. *sqrtPrice*).  │
│      – Direction is always **token‑1 per token‑0** (quote/base).             │
│    • All heavy lifting is done in 128‑bit space; overflow is mathematically  │
│      impossible under the stated bounds.                                    │
│                                                                              │
│  NEW (2025‑07‑02)                                                            │
│  ──────────────                                                             │
│  Added *execution‑capped* helpers so you can interleave constant‑product     │
│  fills with your bespoke **Float** / **Order** books.                        │
│                                                                              │
│  • `previewExactInUntilPrice()`   – given an input cap, returns how much     │
│    would actually execute **until** either the cap is exhausted *or* the     │
│    pool price hits a caller‑supplied `limitPriceQ32_32`.                     │
│                                                                              │
│  • `previewExactOutUntilPrice()`  – mirror image for an *output* target      │
│    capped by a `limitPriceQ32_32`.                                           │
│                                                                              │
│  These helpers do **not** mutate state.  They’re gas‑cheap pure functions    │
│  so you can call them inside a merge‑sorted execution loop (e.g. iterate     │
│  through Orders, Floats, then dip into the pool at the very end if the       │
│  price is still inside bounds).                                              │
└─────────────────────────────────────────────────────────────────────────────*/

library UniV2PoolLib64 {
    /*─────────────────────────────────── STRUCTS ─────────────────────────────*/

    /// @dev Minimal pool bookkeeping – embed this in your core contract.
    struct Pool {
        uint64 reserve0; // Token‑0 balance   (uint64)
        uint64 reserve1; // Token‑1 balance   (uint64)
        uint64 totalLiq; // Outstanding liquidity receipts (uint64)
        uint64 feePpm; // Swap fee in parts‑per‑million (e.g. 3000 = 0.3 %)
    }

    /*────────────────────────────── ERRORS / CONSTANTS ───────────────────────*/

    error InsufficientInput(); // amountIn == 0  OR  amountOut == 0
    error InsufficientLiquidity(); // reserves are zero when minting / swapping
    error Slippage(); // minOut / maxIn guard failed
    error BadMath(); // division by zero or invariant violation
    error LimitPriceReached(); // current price already beyond user limit

    /*─────────────────────────── INTERNAL MATH UTILITIES ─────────────────────*/

    /// @notice Babylonian square‑root on uint128 (∴ up to 2¹²⁸‑1).
    /// @dev    Gas‑cheap ≈7 iterations.
    function _sqrt(uint128 x) private pure returns (uint64 z) {
        if (x == 0) return 0;
        uint128 r = x;
        uint128 k = (x >> 1) + 1; // initial guess: x/2 + 1
        while (k < r) {
            r = k;
            k = (x / k + k) >> 1;
        }
        z = uint64(r); // r ≤ 2⁶⁴‑1 under 64‑bit universe
    }

    /// @notice Convert a Q32.32 price to its square‑root in the **same** scale.
    /// @param priceQ32_32  Price in Q32.32 (must be > 0).
    /// @return sqrtQ32_32  √price, still in Q32.32.
    function sqrtPriceQ32_32(
        uint64 priceQ32_32
    ) internal pure returns (uint64) {
        if (priceQ32_32 == 0) revert BadMath();
        uint64 s = _sqrt(uint128(priceQ32_32));
        return s << 16; // multiply by 2¹⁶ to stay in Q32.32
    }

    /// @notice Inverse of `sqrtPriceQ32_32` – squares a sqrt‑price back to Q32.32.
    function squareSqrtPrice(uint64 sqrtQ32_32) internal pure returns (uint64) {
        uint128 prod = uint128(sqrtQ32_32) * sqrtQ32_32;
        return uint64(prod >> 32);
    }

    /*───────────────────────────── LIQUIDITY OPS ─────────────────────────────*/

    /**
     * @notice Mint liquidity receipts for a proportional add.
     * @return liqOut   Liquidity receipts to credit caller (uint64).
     */
    function mint(
        Pool storage pool,
        uint64 amount0,
        uint64 amount1
    ) internal returns (uint64 liqOut) {
        if (amount0 == 0 || amount1 == 0) revert InsufficientInput();
        uint64 _r0 = pool.reserve0;
        uint64 _r1 = pool.reserve1;
        if (pool.totalLiq == 0) {
            liqOut = _sqrt(uint128(amount0) * amount1);
        } else {
            uint64 liq0 = uint64((uint128(amount0) * pool.totalLiq) / _r0);
            uint64 liq1 = uint64((uint128(amount1) * pool.totalLiq) / _r1);
            liqOut = liq0 < liq1 ? liq0 : liq1;
        }
        if (liqOut == 0) revert Slippage();
        pool.reserve0 = _r0 + amount0;
        pool.reserve1 = _r1 + amount1;
        pool.totalLiq += liqOut;
    }

    /**
     * @notice Burn liquidity receipts and return underlying tokens.
     */
    function burn(
        Pool storage pool,
        uint64 liqIn
    ) internal returns (uint64 amount0, uint64 amount1) {
        if (liqIn == 0) revert InsufficientInput();
        uint64 _total = pool.totalLiq;
        if (_total == 0) revert InsufficientLiquidity();
        amount0 = uint64((uint128(liqIn) * pool.reserve0) / _total);
        amount1 = uint64((uint128(liqIn) * pool.reserve1) / _total);
        if (amount0 == 0 || amount1 == 0) revert Slippage();
        pool.reserve0 -= amount0;
        pool.reserve1 -= amount1;
        pool.totalLiq = _total - liqIn;
    }

    /*─────────────────────────────── SWAP HELPERS ────────────────────────────*/

    /**
     * @notice Quote the output amount for an exact input (fee‑inclusive).
     */
    function getAmountOut(
        uint64 amountIn,
        uint64 reserveIn,
        uint64 reserveOut,
        uint64 feePpm
    ) internal pure returns (uint64 amountOut) {
        if (amountIn == 0) revert InsufficientInput();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint128 inAfterFee = (uint128(amountIn) * (1_000_000 - feePpm)) /
            1_000_000;
        uint128 numer = uint128(reserveOut) * inAfterFee;
        uint128 denom = uint128(reserveIn) + inAfterFee;
        amountOut = uint64(numer / denom);
    }

    /**
     * @notice Quote the required input for an exact output (fee‑inclusive).
     */
    function getAmountIn(
        uint64 amountOut,
        uint64 reserveIn,
        uint64 reserveOut,
        uint64 feePpm
    ) internal pure returns (uint64 amountIn) {
        if (amountOut == 0) revert InsufficientInput();
        if (reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut)
            revert InsufficientLiquidity();
        uint128 numer = uint128(reserveIn) * amountOut;
        uint128 denom = reserveOut - amountOut;
        uint128 x = (numer / denom) + 1; // round‑up
        amountIn = uint64((x * 1_000_000) / (1_000_000 - feePpm));
    }

    /*────────────────────── EXECUTION‑CAPPED PREVIEWS (NEW) ──────────────────*/

    /**
     * @notice Preview how much of `amountInCap` would execute **until**
     *         either the cap is consumed **or** the pool price reaches
     *         `limitPriceQ32_32` (token‑1 per token‑0).  Does **not** mutate
     *         state.
     *
     * @param zeroForOne       true  = input token‑0 → output token‑1
     *                         false = input token‑1 → output token‑0
     * @param amountInCap      Max tokens the trader is willing to pay.
     * @param limitPriceQ32_32 Price guard (must be ≥ current price if
     *                         zeroForOne, or ≤ current price if oneForZero).
     *
     * @return execIn   Tokens actually spent (≤ amountInCap).
     * @return execOut  Tokens actually received.
     */
    function previewExactInUntilPrice(
        Pool storage pool,
        bool zeroForOne,
        uint64 amountInCap,
        uint64 limitPriceQ32_32
    ) internal view returns (uint64 execIn, uint64 execOut) {
        if (amountInCap == 0) revert InsufficientInput();
        uint64 rIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint64 rOut = zeroForOne ? pool.reserve1 : pool.reserve0;
        if (rIn == 0 || rOut == 0) revert InsufficientLiquidity();

        // Current price (token‑1 per token‑0).
        uint64 priceQ32 = zeroForOne
            ? uint64((uint128(rOut) << 32) / rIn)
            : uint64((uint128(rIn) << 32) / rOut); // inverse direction

        // Directional guard: price must still be inside user limit.
        bool priceTooHigh = zeroForOne
            ? priceQ32 >= limitPriceQ32_32
            : priceQ32 <= limitPriceQ32_32;
        if (priceTooHigh) revert LimitPriceReached();

        // 1️⃣ Compute *effective* input needed to hit limit price (fee‑already‑deducted).
        uint128 k = uint128(rIn) * rOut; // constant product (≤ 2¹²⁸‑1)
        uint128 rInLim = _sqrt(
            uint128(k) *
                (
                    zeroForOne
                        ? uint128(1 << 32) / limitPriceQ32_32 // rOut'/rIn' = pLim
                        : uint128(limitPriceQ32_32) / (1 << 32) // inverse dir
                )
        );
        if (rInLim <= rIn) {
            // Numerical fuzz – treat as already at limit.
            revert LimitPriceReached();
        }
        uint128 effInNeed = rInLim - rIn; // after fee deduction
        uint128 grossInNeed = (effInNeed * 1_000_000) /
            (1_000_000 - pool.feePpm);
        if (grossInNeed > type(uint64).max) grossInNeed = type(uint64).max; // clamp

        uint64 inNeeded = uint64(grossInNeed);

        // 2️⃣ Determine how much we *actually* spend.
        execIn = amountInCap < inNeeded ? amountInCap : inNeeded;
        execOut = getAmountOut(execIn, rIn, rOut, pool.feePpm);
    }

    /**
     * @notice Mirror of `previewExactInUntilPrice` for an **exact output**
     *         target capped by `limitPriceQ32_32`.
     *
     * @param zeroForOne     true  = output token‑1, input token‑0
     * @param amountOutCap   Desired output (<= what pool can provide).
     *
     * @return execOut  Tokens actually obtained (≤ amountOutCap).
     * @return execIn   Tokens the trader would need to pay.
     */
    function previewExactOutUntilPrice(
        Pool storage pool,
        bool zeroForOne,
        uint64 amountOutCap,
        uint64 limitPriceQ32_32
    ) internal view returns (uint64 execOut, uint64 execIn) {
        if (amountOutCap == 0) revert InsufficientInput();
        uint64 rIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint64 rOut = zeroForOne ? pool.reserve1 : pool.reserve0;
        if (rIn == 0 || rOut == 0) revert InsufficientLiquidity();

        uint64 priceQ32 = zeroForOne
            ? uint64((uint128(rOut) << 32) / rIn)
            : uint64((uint128(rIn) << 32) / rOut);
        bool priceTooHigh = zeroForOne
            ? priceQ32 >= limitPriceQ32_32
            : priceQ32 <= limitPriceQ32_32;
        if (priceTooHigh) revert LimitPriceReached();

        // Compute max *amountOut* we can take before hitting limit price.
        uint128 k = uint128(rIn) * rOut;
        uint128 rInLim = _sqrt(
            uint128(k) *
                (
                    zeroForOne
                        ? uint128(1 << 32) / limitPriceQ32_32
                        : uint128(limitPriceQ32_32) / (1 << 32)
                )
        );
        uint128 effInNeed = rInLim - rIn; // after fee
        uint128 grossInNeed = (effInNeed * 1_000_000) /
            (1_000_000 - pool.feePpm);
        uint64 inNeeded = grossInNeed > type(uint64).max
            ? type(uint64).max
            : uint64(grossInNeed);

        uint64 outAtLimit = getAmountOut(inNeeded, rIn, rOut, pool.feePpm);
        if (outAtLimit == 0) revert LimitPriceReached();

        execOut = amountOutCap < outAtLimit ? amountOutCap : outAtLimit;
        execIn = getAmountIn(execOut, rIn, rOut, pool.feePpm);
    }

    /*────────────────────────────── DERIVED UTILS ────────────────────────────*/

    function price0To1Q32_32(Pool storage pool) internal view returns (uint64) {
        if (pool.reserve0 == 0) revert BadMath();
        return uint64((uint128(pool.reserve1) << 32) / pool.reserve0);
    }

    function price1To0Q32_32(Pool storage pool) internal view returns (uint64) {
        if (pool.reserve1 == 0) revert BadMath();
        return uint64((uint128(pool.reserve0) << 32) / pool.reserve1);
    }

    function sqrtPriceQ32_32(Pool storage pool) internal view returns (uint64) {
        return sqrtPriceQ32_32(price0To1Q32_32(pool));
    }
}
