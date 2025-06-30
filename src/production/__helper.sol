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
     * Return the maximum-output allocation that can **spend at most**
     * `amountInMax` without ever pushing the blended marginal price past
     * `sqrtPlim_Q96`.
     *
     * The closed-form solution works in three phases:
     *  (1)  Solve analytically for √P★ (equalised marginal price or the cap).
     *  (2)  Back-solve exact in-amounts for V2 and V3 that land on √P★.
     *  (3)  Compute the outputs and clip any 1-wei overshoot in the caller’s
     *       favour.
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

                /* DEFENSIVE FIX #1 mirror branch */
                uint256 MAX_D96 = type(uint160).max;
                if (d96 > MAX_D96) d96 = MAX_D96;

                /* √P★ = √P₀ · (1 + Δ) */
                sqrtStar = mulDiv(sqrtP0_Q96, Q96 + d96, Q96);
                if (sqrtStar > sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            }

            /*───────────────────────────────────────*
             * 2. Back-solve exact inputs             *
             *───────────────────────────────────────*/
            uint256 dxV2;
            uint256 dxV3;

            if (zeroForOne) {
                /* ratio96 = √P₀ / √P★ in Q96-fixed-point */
                uint256 ratio96 = (uint256(sqrtP0_Q96) << 96) / sqrtStar;

                /* dxV2 = R0 · (ratio − 1) / 2⁹⁶   (product fits 256b) */
                dxV2 = (uint256(R0) * (ratio96 - Q96)) >> 96;

                /* dxV3 = L · (√P₀ − √P★) / (√P₀√P★ / 2⁹⁶)  */
                uint256 denom = mulDiv(sqrtP0, sqrtStar, Q96);
                if (denom == 0) revert ZeroDenominator();
                dxV3 = mulDiv(L, sqrtP0 - sqrtStar, denom);
            } else {
                uint256 ratio96 = (uint256(sqrtStar) << 96) / sqrtP0_Q96;
                dxV2 = (uint256(R1) * (ratio96 - Q96)) >> 96;

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
     * Return the minimum-cost allocation that can **deliver up to**
     * `amountOutMax`, subject to the same marginal-price cap.
     *
     * If the requested output is unattainable before the cap bites the
     * function returns the cap-bound allocation and a smaller realised
     * output.  A 1-wei caller-favouring clip is applied symmetrically.
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

    /*──────── integer √ (Babylonian) ───*/
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = 1;
        uint256 xx = x;
        if (xx >> 128 > 0) {
            xx >>= 128;
            z <<= 64;
        }
        if (xx >> 64 > 0) {
            xx >>= 64;
            z <<= 32;
        }
        if (xx >> 32 > 0) {
            xx >>= 32;
            z <<= 16;
        }
        if (xx >> 16 > 0) {
            xx >>= 16;
            z <<= 8;
        }
        if (xx >> 8 > 0) {
            xx >>= 8;
            z <<= 4;
        }
        if (xx >> 4 > 0) {
            xx >>= 4;
            z <<= 2;
        }
        if (xx >> 2 > 0) {
            z <<= 1;
        }

        y = (z + x / z) >> 1;
        y = (y + x / y) >> 1;

        if (y * y > x) --y;
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
