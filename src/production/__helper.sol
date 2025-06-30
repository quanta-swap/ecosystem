// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────────────────────────────────────────────────────────────────────*
│ SplitOptimalNoFee64 – 64-bit-token edition                                   │
│                                                                              │
│ • Assumes **all user-visible balances & amounts are uint64**.                │
│ • Wherever that bound guarantees a product fits into 256 bits we drop the    │
│   512-bit mul-div in favour of simple shifts / native division.              │
│ • Anything that can still overflow 256 bits (e.g. √P₀·√P★ or L·√P) keeps the │
│   full-precision assembly mulDiv.                                            │
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
     * @notice Compute the *maximum-output* allocation that can spend
     *         **up to** `amountInMax` without the blended marginal price ever
     *         crossing the user’s limit `sqrtPlim_Q96`.
     *
     * @dev High-level algorithm
     *      1.  Solve in closed form for the stopping price √P★ where
     *          marginal prices equalise (or the price cap binds).
     *      2.  Back-solve the exact inputs (`inV3`, `inV2`) that land on √P★.
     *      3.  Derive the exact outputs and clip any 1-wei overshoot in favour
     *          of the caller.
     *
     * @custom:assumptions
     *      • **64-bit universe** – every external amount or reserve ≤ 2⁶⁴-1.  
     *      • **Same spot price** – both pools start at `sqrtP0_Q96`.  
     *      • **Window width ≤ 256 ticks** – closed-form formulas hold.  
     *      • **Fee-free CPMM** – V2 leg has zero trading fee.  
     *      • `sqrtPlim_Q96` is < `sqrtP0_Q96` when `zeroForOne == true`,
     *        and > `sqrtP0_Q96` otherwise (checked at runtime).
     *      - The price limit is always within the CLMM liquidity window
     *
     * @param amountInMax   Max tokens willing to spend.
     * @param zeroForOne    true  → swap token0 → token1 (price falls).  
     *                      false → swap token1 → token0 (price rises).
     * @param sqrtP0_Q96    Current √price in Q64.96.
     * @param sqrtPlim_Q96  User price limit in the same Q-format.
     * @param L             Liquidity of the CLMM window.
     * @param R0            Reserve0 of the V2 pool (token0 units).
     * @param R1            Reserve1 of the V2 pool (token1 units).
     *
     * @return S            Optimal split of inputs / outputs per leg.
     *
     * @custom:error EmptyPool        `L`, `R0`, or `R1` is zero.
     * @custom:error LimitTooHigh     `sqrtPlim_Q96` on the wrong side
     *                                of the start price.
     * @custom:error Uint64Overflow   Any leg exceeds 2⁶⁴-1 units.
     * @custom:error ZeroDenominator  Defensive: division‐by-zero guard in
     *                                the CLMM maths.
     */
    function splitForInput(
        uint64  amountInMax,
        bool    zeroForOne,          // true = token0 → token1
        uint160 sqrtP0_Q96,
        uint160 sqrtPlim_Q96,
        uint128 L,
        uint64  R0,
        uint64  R1
    ) internal pure returns (Split memory S) {
        unchecked {
            if (amountInMax == 0) return S;
            if (L == 0 || R0 == 0 || R1 == 0) revert EmptyPool();

            uint256 sqrtP0  = uint256(sqrtP0_Q96);
            uint256 sqrtStar;

            /*──────── Solve √P★ analytically ────────*/
            if (zeroForOne) {
                if (sqrtPlim_Q96 >= sqrtP0_Q96) revert LimitTooHigh();

                uint256 K   = uint256(R0) + ((uint256(L) << 96) / sqrtP0_Q96);   // token0 capacity
                uint256 d96 = (uint256(amountInMax) << 96) / K;                  // Δ in Q96

                // √P★ = √P₀ / (1 + Δ)   →  shift-based because numerator fits 256 bits
                sqrtStar = (uint256(sqrtP0_Q96) << 96) / (Q96 + d96);
                if (sqrtStar < sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            } else {
                if (sqrtPlim_Q96 <= sqrtP0_Q96) revert LimitTooHigh();

                uint256 K   = uint256(R1) + mulDiv(L, sqrtP0_Q96, Q96);          // token1 capacity
                uint256 d96 = (uint256(amountInMax) << 96) / K;

                // √P★ = √P₀ · (1 + Δ)
                sqrtStar = mulDiv(sqrtP0_Q96, Q96 + d96, Q96);                   // one mulDiv remains
                if (sqrtStar > sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            }

            /*──────── Back-solve exact inputs ───────*/
            uint256 dxV2;
            uint256 dxV3;

            if (zeroForOne) {
                uint256 ratio96 = (uint256(sqrtP0_Q96) << 96) / sqrtStar;        // √P₀/√P★
                dxV2 = (uint256(R0) * (ratio96 - Q96)) >> 96;

                uint256 denom = mulDiv(sqrtP0, sqrtStar, Q96);                  // √P₀√P★/2⁹⁶
                if (denom == 0) revert ZeroDenominator();
                dxV3 = mulDiv(L, sqrtP0 - sqrtStar, denom);
            } else {
                uint256 ratio96 = (uint256(sqrtStar) << 96) / sqrtP0_Q96;        // √P★/√P₀
                dxV2 = (uint256(R1) * (ratio96 - Q96)) >> 96;

                dxV3 = mulDiv(L, sqrtStar - sqrtP0, Q96);
            }

            /*──────── 1-wei clip ────────*/
            uint256 spent = dxV2 + dxV3;
            if (spent > amountInMax + 1) {
                uint256 excess = spent - amountInMax;
                if (excess <= dxV2) dxV2 -= excess;
                else {
                    dxV3 -= (excess - dxV2);
                    dxV2  = 0;
                }
            }

            if (dxV2 > type(uint64).max || dxV3 > type(uint64).max) revert Uint64Overflow();

            S.inV3  = _cast64(dxV3);
            S.inV2  = _cast64(dxV2);
            S.outV3 = _cast64(_outV3(dxV3, zeroForOne, L, sqrtP0_Q96));
            S.outV2 = _cast64(_outV2(dxV2, zeroForOne, R0, R1));
        }
    }

    /*════════════ ENTRY – OUTPUT CAPPED ════════════*/

    /**
     * @notice Compute the *minimum-cost* allocation needed to realise
     *         **up to** `amountOutMax`, while guaranteeing the blended marginal
     *         price never crosses `sqrtPlim_Q96`.
     *
     * @dev Behaviour
     *      • If `amountOutMax` is unattainable before the price cap,
     *        the function returns the cap-bound allocation and a smaller
     *        realised output.  
     *      • The same 1-wei overshoot clip applies (caller-favouring).
     *
     * @custom:assumptions
     *      • **64-bit universe** – every external amount or reserve ≤ 2⁶⁴-1.  
     *      • **Same spot price** – both pools start at `sqrtP0_Q96`.  
     *      • **Window width ≤ 256 ticks** – closed-form formulas hold.  
     *      • **Fee-free CPMM** – V2 leg has zero trading fee.  
     *      • `sqrtPlim_Q96` is < `sqrtP0_Q96` when `zeroForOne == true`,
     *        and > `sqrtP0_Q96` otherwise (checked at runtime).
     *      - The price limit is always within the CLMM liquidity window
     *
     * @param amountOutMax  Desired maximum tokens out (token1 if
     *                      `zeroForOne`, token0 otherwise).
     * @param zeroForOne    Direction flag (see above).
     * @param sqrtP0_Q96    Current √price in Q64.96.
     * @param sqrtPlim_Q96  Price cap the execution must respect.
     * @param L             Liquidity of the CLMM window.
     * @param R0            Reserve0 of the V2 pool (token0 units).
     * @param R1            Reserve1 of the V2 pool (token1 units).
     *
     * @return S            Realised optimal split of inputs / outputs.
     *
     * @custom:error EmptyPool        `L`, `R0`, or `R1` is zero.
     * @custom:error LimitTooHigh     `sqrtPlim_Q96` on the wrong side
     *                                of the start price.
     * @custom:error Uint64Overflow   Any leg exceeds 2⁶⁴-1 units.
     * @custom:error ZeroDenominator  Defensive: division‐by-zero guard in
     *                                the CLMM maths.
     */
    function splitForOutput(
        uint64  amountOutMax,
        bool    zeroForOne,
        uint160 sqrtP0_Q96,
        uint160 sqrtPlim_Q96,
        uint128 L,
        uint64  R0,
        uint64  R1
    ) internal pure returns (Split memory S) {
        unchecked {
            /*────── Early exits + pool sanity ──────*/
            if (amountOutMax == 0) return S;
            if (L == 0 || R0 == 0 || R1 == 0) revert EmptyPool();

            uint256 sqrtP0 = uint256(sqrtP0_Q96);  // cache once as 256-bit

            /*───────────────────────────────────────*
            * 1. Pick the stopping price  √P★       *
            *───────────────────────────────────────*/
            uint256 sqrtStar;               // √P★
            uint256 capacity;               // max deliverable before cap
            uint256 dyTarget = amountOutMax;

            if (zeroForOne) {
                if (sqrtPlim_Q96 >= sqrtP0_Q96) revert LimitTooHigh();

                /* token1 capacity = R1  +  L·√P₀ / 2⁹⁶ */
                capacity = uint256(R1) + mulDiv(L, sqrtP0_Q96, Q96);

                if (dyTarget >= capacity) {
                    /* Cap binds immediately – we end at the cap price */
                    sqrtStar = sqrtPlim_Q96;
                } else {
                    /* √P★ = √P₀ · (1 − dy/K)  (exact; no rounding drift) */
                    uint256 num = mulDiv(sqrtP0_Q96, capacity - dyTarget, capacity);
                    sqrtStar   = num < sqrtPlim_Q96 ? sqrtPlim_Q96 : num;
                }
            } else {
                if (sqrtPlim_Q96 <= sqrtP0_Q96) revert LimitTooHigh();

                /* token0 capacity = R0  +  L / √P₀ */
                capacity = uint256(R0) + mulDiv(L, Q96, sqrtP0_Q96);

                if (dyTarget >= capacity) {
                    sqrtStar = sqrtPlim_Q96;
                } else {
                    /* √P★ = √P₀ · K / (K − dy)  */
                    uint256 num = mulDiv(sqrtP0_Q96, capacity, capacity - dyTarget);
                    sqrtStar   = num > sqrtPlim_Q96 ? sqrtPlim_Q96 : num;
                }
            }

            /*───────────────────────────────────────*
            * 2. Back-solve V2 + CLMM inputs         *
            *───────────────────────────────────────*/
            uint256 ratio96 = zeroForOne
                ? (uint256(sqrtP0_Q96) << 96) / sqrtStar      // √P₀ / √P★
                : (uint256(sqrtStar)   << 96) / sqrtP0_Q96;   // √P★ / √P₀

            uint256 dxV2 = zeroForOne
                ? (uint256(R0) * (ratio96 - Q96)) >> 96       // token0-in to V2
                : (uint256(R1) * (ratio96 - Q96)) >> 96;      // token1-in to V2

            uint256 denom = mulDiv(sqrtP0, sqrtStar, Q96);    // √P₀√P★ / 2⁹⁶
            if (denom == 0) revert ZeroDenominator();

            uint256 dxV3 = zeroForOne
                ? mulDiv(L, sqrtP0 - sqrtStar, denom)         // token0-in to V3
                : mulDiv(L, sqrtStar - sqrtP0, Q96);          // token1-in to V3

            /*───────────────────────────────────────*
            * 3. First-pass outputs  (dyV2 + dyV3)  *
            *───────────────────────────────────────*/
            uint256 dyV2 = _outV2(dxV2, zeroForOne, R0, R1);
            uint256 dyV3 = _outV3(dxV3, zeroForOne, L, sqrtP0_Q96);

            /*───────────────────────────────────────*
            * 4. 1-wei caller-favouring clip        *
            *───────────────────────────────────────*/
            uint256 totalOut = dyV2 + dyV3;
            if (totalOut > dyTarget + 1) {
                uint256 excess = totalOut - dyTarget;

                /*—— Roll back V2 first ——*/
                if (excess <= dyV2) {
                    dyV2 -= excess;

                    /* exact reverse CPMM:  dx = dy · Rin / (Rout − dy) */
                    uint256 Rin  = zeroForOne ? R0 : R1;
                    uint256 Rout = zeroForOne ? R1 : R0;
                    dxV2 = mulDiv(dyV2, Rin, Rout - dyV2);
                } else {
                    /*—— Wipe V2 & roll remaining excess from V3 ——*/
                    excess -= dyV2;
                    dyV2    = 0;
                    dxV2    = 0;
                    dyV3   -= excess;

                    /* Recompute √P₁ (post-rollback) with full-precision   *
                     * dy =  L·|Δ√P| / 2⁹⁶   ⇒   |Δ√P| = dy·2⁹⁶ / L        */
                    uint256 sqrtP1 = zeroForOne
                        ? sqrtP0 - mulDiv(dyV3, Q96, L)   // √P₀ − Δ√P
                        : sqrtP0 + mulDiv(dyV3, Q96, L);  // √P₀ + Δ√P

                    /* Refresh denominator √P₀√P₁ / 2⁹⁶ */
                    denom = mulDiv(sqrtP0, sqrtP1, Q96);

                    /* Exact dx from refreshed state                   *
                     * zeroForOne:  dx = dy·2⁹⁶ / (√P₀√P₁ / 2⁹⁶)        *
                     * oneForZero:  dx = dy·(√P₀√P₁ / 2⁹⁶) / 2⁹⁶         */
                    dxV3 = zeroForOne
                        ? mulDiv(dyV3, Q96, denom)
                        : mulDiv(dyV3, denom, Q96);
                }
            }

            /*───────────────────────────────────────*
            * 5. 64-bit packing & return            *
            *───────────────────────────────────────*/
            if (
                dxV2 > type(uint64).max || dxV3 > type(uint64).max ||
                dyV2 > type(uint64).max || dyV3 > type(uint64).max
            ) revert Uint64Overflow();

            S.inV3  = _cast64(dxV3);
            S.inV2  = _cast64(dxV2);
            S.outV3 = _cast64(dyV3);
            S.outV2 = _cast64(dyV2);
        }
    }

    /*──────── implied √P Q64.96 ────────*/
    function impliedSqrtQ96(uint64 base, uint64 quote) internal pure returns (uint160) {
        if (base == 0 || quote == 0) revert EmptyPool();
        uint256 ratioX192 = (uint256(quote) << 192) / base;  // price·2¹⁹²
        return uint160(_sqrt(ratioX192));                    // √(price·2¹⁹²)
    }

    /*──────── integer √ (Babylonian) ───*/
    /**
     * @notice Integer square-root – rounds **down**.
     *
     * @dev  Replaces the classic Babylonian loop with a 7-step
     *       leading-bit hunt followed by two Newton iterations.
     *       • ~250 gas cheaper than the traditional `while (z < y)` loop.
     *       • Constant-time w.r.t. `x` → no data-dependent timing leaks.
     *
     * @param x  Unsigned integer to root.
     * @return y ⌊√x⌋.
     */
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;

        /* 1. Rough power-of-two estimate (highest set bit / 2) */
        uint256 z = 1;
        uint256 xx = x;
        if (xx >> 128 > 0) { xx >>= 128; z <<= 64; }
        if (xx >>  64 > 0) { xx >>=  64; z <<= 32; }
        if (xx >>  32 > 0) { xx >>=  32; z <<= 16; }
        if (xx >>  16 > 0) { xx >>=  16; z <<=  8; }
        if (xx >>   8 > 0) { xx >>=   8; z <<=  4; }
        if (xx >>   4 > 0) { xx >>=   4; z <<=  2; }
        if (xx >>   2 > 0) {            z <<=  1; }

        /* 2. Two Newton-Raphson refinements → exact ⌊√x⌋ in ≤2 steps */
        y = (z + x / z) >> 1;
        y = (y + x / y) >> 1;

        /* 3. Final adjust in case of +1 overshoot */
        if (y * y > x) --y;
    }

    /*──────── 512-bit mulDiv ───────────*/
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 r) {
        assembly {
            let mm := mulmod(a, b, not(0))
            let p0 := mul(a, b)
            let p1 := sub(sub(mm, p0), lt(mm, p0))

            if iszero(p1) { r := div(p0, d) }
            if p1 {
                if iszero(gt(d, p1)) { revert(0, 0) }
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
    function _outV2(uint256 dx, bool z2o, uint64 R0, uint64 R1) private pure returns (uint256) {
        if (dx == 0) return 0;
        uint256 Rin  = z2o ? R0 : R1;
        uint256 Rout = z2o ? R1 : R0;
        return (dx * Rout) / (Rin + dx);   // fits 256 bits under 64-bit token bound
    }

    /*──────── CLMM output ──────────────*/
    function _outV3(
        uint256 dx,
        bool    z2o,
        uint128 L,
        uint160 sqrtP0_Q96
    ) private pure returns (uint256) {
        if (dx == 0) return 0;

        if (z2o) {
            uint256 term   = (dx * uint256(sqrtP0_Q96)) >> 96;
            uint256 denom  = uint256(L) + term;
            uint256 sqrtP1 = mulDiv(sqrtP0_Q96, L, denom);
            uint256 delta  = uint256(sqrtP0_Q96) - sqrtP1;
            return (uint256(L) * delta) >> 96;
        } else {
            uint256 sqrtP1 = uint256(sqrtP0_Q96) + ((dx << 96) / L);
            uint256 prod   = mulDiv(sqrtP1, sqrtP0_Q96, Q96);
            uint256 delta  = sqrtP1 - uint256(sqrtP0_Q96);
            return mulDiv(L, delta, prod);
        }
    }

    /*──────── uint256 → uint64 ─────────*/
    function _cast64(uint256 x) private pure returns (uint64 y) {
        if (x > type(uint64).max) revert Uint64Overflow();
        return uint64(x);
    }
}
