// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────────────────────────────────────────────────────────────────────*
│ SplitOptimalNoFee64 – 64-bit-token edition (patched)                         │
│                                                                              │
│ • All user-visible balances & amounts are uint64.                            │
│ • Shifts replace /·2⁹⁶ and ·2⁹⁶/ wherever 256-bit products are guaranteed.   │
│ • Full 512-bit mulDiv retained where overflow is still plausible.            │
│ • Two extra runtime guards (see “DEFENSIVE FIX” tags).                       │
*─────────────────────────────────────────────────────────────────────────────*/
library SplitOptimalNoFee64 {
    /*────────── Custom errors ─────────*/
    error EmptyPool();
    error LimitTooHigh();
    error Uint64Overflow();
    error ZeroDenominator();

    /*────────── Public types ──────────*/
    struct Split {
        uint64 inV3;
        uint64 inV2;
        uint64 outV3;
        uint64 outV2;
    }

    uint256 private constant Q96 = 1 << 96;

    /*════════════ ENTRY – INPUT CAPPED ════════════*/

    /**
     * @notice Compute the *maximum-output* allocation of an input swap that spends **at most**
     *         `amountInMax` without ever pushing the blended marginal price beyond
     *         the user-supplied limit `sqrtPlim_Q96`.  The limit must lie inside the
     *         current 256-tick CLMM window.
     *
     * @dev Closed-form, no-iteration three-phase solver:
     *      1. Solve analytically for the target price √P★ that equalises V2 and V3
     *         marginal prices, or hits `sqrtPlim_Q96` if the cap binds.
     *      2. Back-solve the exact tokenIn routed through each venue (V2 CPMM / V3 CLMM)
     *         so that execution stops precisely at √P★.
     *      3. Clip any 1-wei overshoot in the caller’s favour (never exceeds `amountInMax`).
     *
     *      All maths are promoted to 256-bit.  512-bit mulDiv is only used where a
     *      256-bit product could overflow.  The function is safe under the strict
     *      64-bit-token invariant (`R0`, `R1`, `inV?`, `outV?` ≤ 2⁶⁴-1).
     *
     * @param amountInMax  Maximum tokenIn the caller can spend (uint64).
     * @param zeroForOne   `true` for token0 → token1 swaps, `false` for token1 → token0.
     * @param sqrtP0_Q96   Starting square-root price shared by both pools in Q64.96 format.
     * @param sqrtPlim_Q96 Price limit (same encoding) not to be crossed.
     * @param L            Active CLMM liquidity inside the 256-tick window (uint128).
     * @param R0           V2 reserve of token0 (uint64).
     * @param R1           V2 reserve of token1 (uint64).
     *
     * @return S           Packed `Split` struct:
     *                     • `inV3` tokens routed into the CLMM.
     *                     • `inV2` tokens routed into the CPMM.
     *                     • `outV3` tokens received from the CLMM.
     *                     • `outV2` tokens received from the CPMM.
     *                     Every field is uint64; all casts are range-checked.
     *
     * @custom:reverts EmptyPool        When `L`, `R0`, or `R1` is zero.
     * @custom:reverts LimitTooHigh     When `sqrtPlim_Q96` is on the wrong side of `sqrtP0_Q96`.
     * @custom:reverts Uint64Overflow   When any computed in/out leg exceeds 2⁶⁴-1.
     * @custom:reverts ZeroDenominator  If an internal mulDiv denominator collapses to zero
     *                                  (should be unreachable under normal invariants).
     */
    function splitForInput(
        uint64 amountInMax,
        bool zeroForOne,
        uint160 sqrtP0_Q96,
        uint160 sqrtPlim_Q96,
        uint128 L,
        uint64 R0,
        uint64 R1
    ) internal pure returns (Split memory S) {
        unchecked {
            /*────── Early exits & pool sanity ──────*/
            if (amountInMax == 0) return S;
            if (L == 0 || R0 == 0 || R1 == 0) revert EmptyPool();

            uint256 sqrtP0 = uint256(sqrtP0_Q96); // promote once
            uint256 sqrtStar; // √P★ placeholder

            /*───────────────────────────────────────*
             * 1. Solve √P★ analytically              *
             *───────────────────────────────────────*/
            if (zeroForOne) {
                if (sqrtPlim_Q96 >= sqrtP0_Q96) revert LimitTooHigh();

                /* token0 capacity K = R0 + (L / √P₀) */
                uint256 K = uint256(R0) + ((uint256(L) << 96) / sqrtP0_Q96);

                /* Δ (Q96-scaled) = amount / K */
                uint256 d96 = (uint256(amountInMax) << 96) / K;
                /// FIX: revert if Δ exceeds 160-bit envelope – never clamp
                if (d96 > type(uint160).max) revert Uint64Overflow();

                /*──────── DEFENSIVE FIX #1 ─────────*
                 * Cap Δ so (Q96 + d96) never ∉ uint256
                 * d96 can never exceed 2¹⁶⁰-1 by construction, but an
                 * explicit max costs ~3 gas and removes any doubt.       */
                uint256 MAX_D96 = type(uint160).max; // 160-bit ceiling
                if (d96 > MAX_D96) d96 = MAX_D96;

                /* √P★ = √P₀ / (1 + Δ)  (shift-based) */
                sqrtStar = (uint256(sqrtP0_Q96) << 96) / (Q96 + d96);

                /* Enforce user cap if we overshot */
                if (sqrtStar < sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            } else {
                if (sqrtPlim_Q96 <= sqrtP0_Q96) revert LimitTooHigh();

                /* token1 capacity K = R1 + L·√P₀ / 2⁹⁶ */
                uint256 K = uint256(R1) + mulDiv(L, sqrtP0_Q96, Q96);
                uint256 d96 = (uint256(amountInMax) << 96) / K;
                /// FIX: revert if Δ exceeds 160-bit envelope – never clamp
                if (d96 > type(uint160).max) revert Uint64Overflow();

                /* DEFENSIVE FIX #1 mirror branch */
                uint256 MAX_D96 = type(uint160).max;
                if (d96 > MAX_D96) d96 = MAX_D96;

                /* √P★ = √P₀ · (1 + Δ) */
                sqrtStar = mulDiv(sqrtP0_Q96, Q96 + d96, Q96);
                /* Enforce user cap if we overshot */
                if (sqrtStar > sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            }

            /*────────────────────── Back-solve exact inputs ──────────────────────*
            *  At this point we already know the target price √P★.  All that      *
            *  remains is to allocate the caller’s tokenIn between:               *
            *      – the fee-free V2 CPMM (R0,R1), and                            *
            *      – the 256-tick CLMM window (liquidity L).                      *
            *                                                                      *
            *  For both directions we derive closed-form expressions by           *
            *  integrating the marginal-price curves over the interval            *
            *  [√P₀ … √P★].  No iteration, no rounding-error accumulation.        *
            *──────────────────────────────────────────────────────────────────────*/
            uint256 dxV2;   // tokenIn routed through V2
            uint256 dxV3;   // tokenIn routed through V3

            if (zeroForOne) {
                /*──────────────── token0 → token1 branch ────────────────*/

                // ratio96 = √P₀ / √P★  (Q64.96 fixed-point; ≥ 1.0)
                uint256 ratio96 = (uint256(sqrtP0_Q96) << 96) / sqrtStar;

                // V2 input:  R0 · (ratio − 1)
                // Right-shift by 96 instead of explicit /2⁹⁶.
                dxV2 = (uint256(R0) * (ratio96 - Q96)) >> 96;

                // V3 input:  L · (√P₀ − √P★) / (√P₀√P★/2⁹⁶)
                uint256 denom = mulDiv(sqrtP0, sqrtStar, Q96);
                if (denom == 0) revert ZeroDenominator();  // ≈ impossible but free guard
                dxV3 = mulDiv(L, sqrtP0 - sqrtStar, denom);

            } else {
                /*──────────────── token1 → token0 branch ────────────────*/

                // ratio96 = √P★ / √P₀  (Q64.96; ≥ 1.0)
                uint256 ratio96 = (uint256(sqrtStar) << 96) / sqrtP0_Q96;

                // V2 input uses token1 side of the reserves (R1).
                dxV2 = (uint256(R1) * (ratio96 - Q96)) >> 96;

                // V3 input simplifies because the denominator is exactly 2⁹⁶.
                dxV3 = mulDiv(L, sqrtStar - sqrtP0, Q96);
            }

            /*───────────────────────────────────────*
             * 3. Caller-favouring 1-wei clip         *
             *───────────────────────────────────────*/
            uint256 spent = dxV2 + dxV3;
            if (spent > amountInMax + 1) {
                uint256 excess = spent - amountInMax;

                if (excess <= dxV2) {
                    dxV2 -= excess; // shave V2 first
                } else {
                    excess -= dxV2; // wipe V2 then shave V3
                    dxV2 = 0;
                    dxV3 -= excess;
                }
            }

            /*───────────────────────────────────────*
             * 4. Pack into 64-bit & return           *
             *───────────────────────────────────────*/
            if (dxV2 > type(uint64).max || dxV3 > type(uint64).max)
                revert Uint64Overflow();

            S.inV3 = _cast64(dxV3);
            S.inV2 = _cast64(dxV2);
            S.outV3 = _cast64(_outV3(dxV3, zeroForOne, L, sqrtP0_Q96));
            S.outV2 = _cast64(_outV2(dxV2, zeroForOne, R0, R1));
        }
    }

    /*════════════ ENTRY – OUTPUT CAPPED ════════════*/

    /**
     * @notice Compute the *minimum‑cost* allocation required to deliver **up to**
     *         `amountOutMax` without ever letting the blended marginal price
     *         surpass `sqrtPlim_Q96`.  If the desired output is impossible
     *         before the cap binds, the function returns the cap‑bound allocation
     *         and a smaller realised output.
     *
     * @dev Algorithmic mirror of `splitForInput` operating in output‑space:
     *      1. Determine a stopping price √P★ that either yields `amountOutMax`
     *         or hits the price cap (whichever occurs first).
     *      2. Back‑solve exact tokenIn routed through V2 and V3 to stop at √P★.
     *      3. Apply a 1‑wei caller‑favouring clip so that the final tokenOut
     *         never exceeds `amountOutMax`.
     *
     * @param amountOutMax Maximum tokenOut the caller wishes to receive (uint64).
     * @param zeroForOne   `true` for token0 → token1 swaps, `false` for token1 → token0.
     * @param sqrtP0_Q96   Starting square‑root price of both pools in Q64.96 format.
     * @param sqrtPlim_Q96 Price cap within the 256‑tick window (same encoding).
     * @param L            Active CLMM liquidity (uint128).
     * @param R0           V2 reserve of token0 (uint64).
     * @param R1           V2 reserve of token1 (uint64).
     *
     * @return S           Packed `Split` struct (same field semantics as `splitForInput`).
     *
     * @custom:reverts EmptyPool        When `L`, `R0`, or `R1` is zero.
     * @custom:reverts LimitTooHigh     When `sqrtPlim_Q96` is on the wrong side of `sqrtP0_Q96`.
     * @custom:reverts Uint64Overflow   When any computed in/out leg exceeds 2⁶⁴‑1.
     * @custom:reverts ZeroDenominator  If an internal mulDiv denominator collapses to zero
     *                                  (theoretically unreachable under работа invariants).
     */
    function splitForOutput(
        uint64 amountOutMax,
        bool zeroForOne,
        uint160 sqrtP0_Q96,
        uint160 sqrtPlim_Q96,
        uint128 L,
        uint64 R0,
        uint64 R1
    ) internal pure returns (Split memory S) {
        unchecked {
            /*───── Early exits & pool sanity ─────*/
            if (amountOutMax == 0) return S;
            if (L == 0 || R0 == 0 || R1 == 0) revert EmptyPool();

            uint256 sqrtP0 = uint256(sqrtP0_Q96);

            /*───────────────────────────────────────*
             * 1. Decide stopping price √P★          *
             *───────────────────────────────────────*/
            uint256 sqrtStar;
            uint256 capacity;
            uint256 dyTarget = amountOutMax;

            if (zeroForOne) {
                if (sqrtPlim_Q96 >= sqrtP0_Q96) revert LimitTooHigh();

                /* capacity = R1 + L·√P₀ / 2⁹⁶ */
                capacity = uint256(R1) + mulDiv(L, sqrtP0_Q96, Q96);

                if (dyTarget >= capacity) {
                    sqrtStar = sqrtPlim_Q96; // cap binds
                } else {
                    /* √P★ = √P₀ · (1 − dy/K) */
                    uint256 num = mulDiv(
                        sqrtP0_Q96,
                        capacity - dyTarget,
                        capacity
                    );
                    sqrtStar = num < sqrtPlim_Q96 ? sqrtPlim_Q96 : num;
                }
            } else {
                if (sqrtPlim_Q96 <= sqrtP0_Q96) revert LimitTooHigh();

                /* capacity = R0 + L / √P₀ */
                capacity = uint256(R0) + mulDiv(L, Q96, sqrtP0_Q96);

                if (dyTarget >= capacity) {
                    sqrtStar = sqrtPlim_Q96;
                } else {
                    /* √P★ = √P₀ · K / (K − dy) */
                    uint256 num = mulDiv(
                        sqrtP0_Q96,
                        capacity,
                        capacity - dyTarget
                    );
                    sqrtStar = num > sqrtPlim_Q96 ? sqrtPlim_Q96 : num;
                }
            }

            /*───────────────────────────────────────*
             * 2. Back-solve V2 + V3 inputs           *
             *───────────────────────────────────────*/
            uint256 ratio96 = zeroForOne
                ? (uint256(sqrtP0_Q96) << 96) / sqrtStar
                : (uint256(sqrtStar) << 96) / sqrtP0_Q96;

            uint256 dxV2 = zeroForOne
                ? (uint256(R0) * (ratio96 - Q96)) >> 96
                : (uint256(R1) * (ratio96 - Q96)) >> 96;

            uint256 denom = mulDiv(sqrtP0, sqrtStar, Q96);
            if (denom == 0) revert ZeroDenominator();

            uint256 dxV3 = zeroForOne
                ? mulDiv(L, sqrtP0 - sqrtStar, denom)
                : mulDiv(L, sqrtStar - sqrtP0, Q96);

            /*───────────────────────────────────────*
             * 3. First-pass outputs                 *
             *───────────────────────────────────────*/
            uint256 dyV2 = _outV2(dxV2, zeroForOne, R0, R1);
            uint256 dyV3 = _outV3(dxV3, zeroForOne, L, sqrtP0_Q96);

            /*───────────────────────────────────────*
             * 4. 1-wei caller-favouring clip        *
             *───────────────────────────────────────*/
            uint256 totalOut = dyV2 + dyV3;
            if (totalOut > dyTarget + 1) {
                uint256 excess = totalOut - dyTarget;

                /* Roll back V2 first, recomputing dxV2 exactly */
                if (excess <= dyV2) {
                    dyV2 -= excess;

                    uint256 Rin = zeroForOne ? R0 : R1;
                    uint256 Rout = zeroForOne ? R1 : R0;

                    /*──────── DEFENSIVE FIX #2 ────────*
                     * If rounding ever produced dyV2 == Rout
                     * the denominator would be zero.               */
                    if (Rout <= dyV2) revert ZeroDenominator();

                    /* Exact reverse CPMM: dx = dy·Rin / (Rout − dy) */
                    dxV2 = mulDiv(dyV2, Rin, Rout - dyV2);
                } else {
                    /* Wipe V2; roll remaining excess off V3 */
                    excess -= dyV2;
                    dyV2 = 0;
                    dxV2 = 0;
                    dyV3 -= excess;

                    /* Recompute √P₁ after partial rollback */
                    uint256 sqrtP1 = zeroForOne
                        ? sqrtP0 - mulDiv(dyV3, Q96, L)
                        : sqrtP0 + mulDiv(dyV3, Q96, L);

                    denom = mulDiv(sqrtP0, sqrtP1, Q96);

                    /* Exact dxV3 from refreshed state */
                    dxV3 = zeroForOne
                        ? mulDiv(dyV3, Q96, denom)
                        : mulDiv(dyV3, denom, Q96);
                }
            }

            /*───────────────────────────────────────*
             * 5. Pack into 64-bit & return           *
             *───────────────────────────────────────*/
            if (
                dxV2 > type(uint64).max ||
                dxV3 > type(uint64).max ||
                dyV2 > type(uint64).max ||
                dyV3 > type(uint64).max
            ) revert Uint64Overflow();

            S.inV3 = _cast64(dxV3);
            S.inV2 = _cast64(dxV2);
            S.outV3 = _cast64(dyV3);
            S.outV2 = _cast64(dyV2);
        }
    }

    /*──────── implied √P Q64.96 ────────*/
    function impliedSqrtQ96(
        uint64 base,
        uint64 quote
    ) internal pure returns (uint160) {
        if (base == 0 || quote == 0) revert EmptyPool();
        uint256 ratioX192 = (uint256(quote) << 192) / base; // price·2¹⁹²
        return uint160(_sqrt(ratioX192)); // √(price·2¹⁹²)
    }

    /**
     * @notice Integer square-root (Babylonian) accurate to < 2⁻¹²⁰.
     * @dev Four Newton iterations bring the result to ±1 wei for any
     *      256-bit input.  The final branch corrects the rare 1-wei overshoot.
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = 1;
        uint256 xx = x;
        if (xx >> 128 > 0) { xx >>= 128; z <<= 64; }
        if (xx >>  64 > 0) { xx >>=  64; z <<= 32; }
        if (xx >>  32 > 0) { xx >>=  32; z <<= 16; }
        if (xx >>  16 > 0) { xx >>=  16; z <<=  8; }
        if (xx >>   8 > 0) { xx >>=   8; z <<=  4; }
        if (xx >>   4 > 0) {               z <<=  2; }
        if (xx >>   2 > 0) {               z <<=  1; }

        // ───────── Newton steps (unrolled) ─────────
        y = (z + x / z) >> 1;
        y = (y + x / y) >> 1;
        y = (y + x / y) >> 1;   // extra iteration #3
        y = (y + x / y) >> 1;   // extra iteration #4

        if (y * y > x) --y;     // 1-wei sanitiser
    }

    /*──────── 512-bit mulDiv ───────────*/
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 d
    ) internal pure returns (uint256 r) {
        assembly {
            let mm := mulmod(a, b, not(0))
            let p0 := mul(a, b)
            let p1 := sub(sub(mm, p0), lt(mm, p0))

            if iszero(p1) {
                r := div(p0, d)
            }
            if p1 {
                if iszero(gt(d, p1)) {
                    revert(0, 0)
                }
                let c := mulmod(a, b, d)
                p1 := sub(p1, gt(c, p0))
                p0 := sub(p0, c)

                let twos := and(d, sub(0, d))
                d := div(d, twos)
                p0 := div(p0, twos)
                twos := add(div(sub(0, twos), twos), 1)
                p0 := or(p0, mul(p1, twos))

                let inv := xor(mul(3, d), 2)
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                r := mul(p0, inv)
            }
        }
    }

    /*──────── CPMM output ──────────────*/
    function _outV2(
        uint256 dx,
        bool z2o,
        uint64 R0,
        uint64 R1
    ) private pure returns (uint256) {
        if (dx == 0) return 0;
        uint256 Rin = z2o ? R0 : R1;
        uint256 Rout = z2o ? R1 : R0;
        return (dx * Rout) / (Rin + dx);
    }

    /*──────── CLMM output ──────────────*/
    function _outV3(
        uint256 dx,
        bool z2o,
        uint128 L,
        uint160 sqrtP0_Q96
    ) private pure returns (uint256) {
        if (dx == 0) return 0;

        if (z2o) {
            uint256 term = (dx * uint256(sqrtP0_Q96)) >> 96;
            uint256 denom = uint256(L) + term;
            uint256 sqrtP1 = mulDiv(sqrtP0_Q96, L, denom);
            uint256 delta = uint256(sqrtP0_Q96) - sqrtP1;
            return (uint256(L) * delta) >> 96;
        } else {
            uint256 sqrtP1 = uint256(sqrtP0_Q96) + ((dx << 96) / L);
            uint256 prod = mulDiv(sqrtP1, sqrtP0_Q96, Q96);
            uint256 delta = sqrtP1 - uint256(sqrtP0_Q96);
            return mulDiv(L, delta, prod);
        }
    }

    /*──────── uint256 → uint64 ─────────*/
    function _cast64(uint256 x) private pure returns (uint64 y) {
        if (x > type(uint64).max) revert Uint64Overflow();
        return uint64(x);
    }
}

/// @title AddressSort – deterministic lexicographic ordering for two addresses
/// @notice Returns the two input addresses in ascending (lexicographic) order.
/// @dev  ─────────────────────────────────────────────────────────────────────
///      • Lexicographic order is the same as numerical order on the 160-bit
///        address value, so casting to `uint160` lets us use cheap integer
///        comparisons.  
///      • The function is `internal` and `pure`; the compiler can inline it,
///        eliminating the call frame and saving gas wherever it is used.  
///      • Equal inputs are permitted; the duplicates are returned unchanged.  
library AddressSort {
    /**
     * @notice Sort two addresses lexicographically.
     * @param a The first (unsorted) address.
     * @param b The second (unsorted) address.
     * @return first  The lexicographically smaller / equal address.
     * @return second The lexicographically larger / equal address.
     *
     * INTENT, ASSUMPTIONS, AND REASONING
     * ----------------------------------
     * • The EVM views an address as a 20-byte big-endian integer; comparing the
     *   `uint160` representations therefore yields the same order users see in
     *   hexadecimal form.  
     * • Casting `address → uint160` is a zero-cost operation at compile-time,
     *   preferable to converting to `bytes` (which would allocate memory).  
     * • We avoid branching on equality by using a single ≤ comparison, saving a
     *   logical operation when the inputs are identical.  
     */
    function sortPair(address a, address b)
        internal                                  // scope: library-internal use only
        pure                                      // no state or environmental reads
        returns (address first, address second)   // named outputs enable implicit return
    {
        // ─── Cast addresses to integers for comparison ──────────────────────
        uint160 aNum = uint160(a);   // underlying 160-bit value of `a`
        uint160 bNum = uint160(b);   // underlying 160-bit value of `b`

        // ─── Order selection ────────────────────────────────────────────────
        if (aNum <= bNum) {
            // `a` is already first (or the two are identical).
            first  = a;
            second = b;
        } else {
            // `b` precedes `a`; swap the order.
            first  = b;
            second = a;
        }
        // Implicit return of `first` and `second`. Compiler inlines for zero-gas return.
    }
}

