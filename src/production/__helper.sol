// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * SplitOptimalNoFee64 – cost-optimal, fee-agnostic splitter for
 * one 256-tick CLMM window + one V2 CPMM that start at the same spot.
 *
 *  • All maths in uint256; explicit 512-bit mul-div helpers prevent overflow.
 *  • Q-format discipline: Q64.96 for √P, Q128.128 for slopes; all helpers
 *    carry their scale in the variable name.
 */
library SplitOptimalNoFee64 {
    /* ─────────── Data structure ─────────── */
    struct Split {
        uint64 inV3;
        uint64 inV2;
        uint64 outV3;
        uint64 outV2;
    }

    /* ═══════════════════ ENTRY ═══════════════════ */
    function split(
        uint64 amountInMax, // dx max (tokenIn units)
        bool zeroForOne, // true = token0 → token1
        uint160 sqrtP0_Q96, // √P₀ (Q64.96)
        uint160 sqrtPlim_Q96, // √P limit (Q64.96, inside window)
        uint128 L, // CLMM liquidity (token0-token1 window)
        uint64 R0,
        uint64 R1 // CPMM reserves
    ) internal pure returns (Split memory S) {
        unchecked {
            /* ────── 0. Basic helpers ────── */
            uint256 sqrtP0 = uint256(sqrtP0_Q96);
            uint256 Rin = zeroForOne ? R0 : R1; // CPMM input reserve

            /* ────── 1. Which pool is cheaper at x = 0? ──────
             * CLMM marginal price slope at x=0 (tokenIn units):
             *   |dP/dx| = 2·√P₀³ / L
             * CPMM slope:
             *   |dP/dx| = √P₀² / Rin
             *
             * We compare them in the same units:
             *            CLMM cheaper  ⇔  2·√P₀·Rin < L
             * For token1→token0 we divide both sides by √P₀².
             */
            bool clmmCheaper = zeroForOne
                ? (2 * sqrtP0 * Rin < uint256(L))
                : (2 * Rin < uint256(L) * sqrtP0);

            /* ────── 2. Equal-marginal input for cheaper leg ────── */
            uint256 dxV3Star; // in tokenIn units
            uint256 dxV2Star;

            if (clmmCheaper) {
                /* Solve (1 + dx·√P₀ / L)³ = 2·√P₀·Rin / L  for dx. */
                uint256 ratio_Q96 = ((2 * sqrtP0 * Rin) << 96) / uint256(L); // Q64.96
                uint256 root_Q96 = _cbrt_Q96(ratio_Q96); // still Q64.96
                if (root_Q96 > (1 << 96)) {
                    dxV3Star = mulDiv(uint256(L), root_Q96 - (1 << 96), sqrtP0); // (L * (∛ratio − 1)) / √P₀
                }
            } else {
                /* Solve   dx + Rin = L / √P₀   (if positive). */
                uint256 target = mulDiv(uint256(L), 1 << 96, sqrtP0); // L / √P₀  (token0 units)
                if (target > Rin) dxV2Star = target - Rin;
            }

            /* ────── 3. Price-cap limits ────── */
            uint256 dxV3Limit = mulDiv(
                uint256(L),
                _absDiff(sqrtP0_Q96, sqrtPlim_Q96),
                sqrtP0 * uint256(sqrtPlim_Q96)
            );

            uint256 dxV2Limit;
            if (zeroForOne) {
                require(sqrtPlim_Q96 < sqrtP0_Q96, "lim>start");
                // dx ≤ Rin·(√P₀/√P_lim − 1)
                uint256 ratio_Q96 = mulDiv(sqrtP0, 1 << 96, sqrtPlim_Q96);
                dxV2Limit = mulDiv(
                    Rin,
                    _sqrt_Q96(ratio_Q96) - (1 << 96),
                    1 << 96
                );
            } else {
                require(sqrtPlim_Q96 > sqrtP0_Q96, "lim<start");
                // dx ≤ Rin·(√P_lim/√P₀ − 1)
                uint256 ratio_Q96 = mulDiv(
                    uint256(sqrtPlim_Q96),
                    1 << 96,
                    sqrtP0
                );
                dxV2Limit = mulDiv(
                    Rin,
                    _sqrt_Q96(ratio_Q96) - (1 << 96),
                    1 << 96
                );
            }

            /* ────── 4. Allocate input ────── */
            uint256 useV3;
            uint256 useV2;

            if (clmmCheaper) {
                useV3 = _min3(dxV3Star, dxV3Limit, amountInMax);
                uint256 rem = amountInMax - useV3;
                useV2 = rem > dxV2Limit ? dxV2Limit : rem;
            } else {
                useV2 = _min3(dxV2Star, dxV2Limit, amountInMax);
                uint256 rem = amountInMax - useV2;
                useV3 = rem > dxV3Limit ? dxV3Limit : rem;
            }

            /* ────── 5. Safe cast + outputs ────── */
            S.inV3 = _cast64(useV3);
            S.inV2 = _cast64(useV2);
            S.outV3 = _cast64(_outV3(useV3, L, sqrtP0_Q96));
            S.outV2 = _cast64(_outV2(useV2, zeroForOne, R0, R1));
        }
    }

    /* ═══════════════ INTERNAL HELPERS ═══════════════ */

    /* ---------------- Maths utils ---------------- */
    function _min3(
        uint256 a,
        uint256 b,
        uint256 c
    ) private pure returns (uint256) {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }

    function _absDiff(uint160 a, uint160 b) private pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }

    /* -------- Babylonian √ in Q64.96 -------- */
    function _sqrt_Q96(uint256 x_Q96) private pure returns (uint256 y_Q96) {
        if (x_Q96 == 0) return 0;
        uint256 z = (x_Q96 + 1) >> 1;
        y_Q96 = x_Q96;
        while (z < y_Q96) {
            y_Q96 = z;
            z = (x_Q96 / z + z) >> 1;
        }
    }

    /* -------- Integer ∛  in Q64.96 --------
     * Newton on Q-scaled values; converges ≤ 35 iterations.           */
    function _cbrt_Q96(uint256 x_Q96) private pure returns (uint256 y_Q96) {
        if (x_Q96 == 0) return 0;
        y_Q96 = 1 << 96; // 1.0 in Q64.96
        for (uint8 i = 0; i < 35; ++i) {
            uint256 y2 = mulDiv(y_Q96, y_Q96, 1 << 96); // y²
            uint256 num = (2 * y_Q96) + mulDiv(x_Q96, 1 << 96, y2);
            uint256 yPrev = y_Q96;
            y_Q96 = num / 3;
            if (y_Q96 >= yPrev ? y_Q96 - yPrev <= 1 : yPrev - y_Q96 <= 1) {
                // One final overshoot check
                if (
                    mulDiv(y_Q96, mulDiv(y_Q96, y_Q96, 1 << 96), 1 << 96) >
                    x_Q96
                ) --y_Q96;
                return y_Q96;
            }
        }
    }

    /* -------- 512-bit mul-div (FullMath, no import) -------- */
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 d
    ) internal pure returns (uint256 result) {
        unchecked {
            uint256 mm = mulmod(a, b, type(uint256).max);
            uint256 prod0 = a * b;
            uint256 prod1 = mm - prod0;
            if (mm < prod0) prod1 -= 1;

            if (prod1 == 0) return prod0 / d; // fits in 256-bits

            require(d > prod1, "mulDiv overflow");

            uint256 rem = mulmod(a, b, d);
            assembly {
                prod1 := sub(prod1, gt(rem, prod0))
                prod0 := sub(prod0, rem)
            }

            /* Factor powers of two out of denominator and compute modular inverse. */
            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos; // re-merge

            /* Newton–Raphson inverse */
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv; // 2
            inv *= 2 - d * inv; // 4
            inv *= 2 - d * inv; // 8
            inv *= 2 - d * inv; // 16
            inv *= 2 - d * inv; // 32
            inv *= 2 - d * inv; // 64

            result = prod0 * inv;
        }
    }

    /* ---------------- Safe cast ---------------- */
    function _cast64(uint256 x) private pure returns (uint64 y) {
        require(x <= type(uint64).max, "uint64 overflow");
        y = uint64(x);
    }

    /* -------- Fee-agnostic output maths -------- */
    function _outV2(
        uint256 dx,
        bool z2o,
        uint64 R0,
        uint64 R1
    ) private pure returns (uint256) {
        if (dx == 0) return 0;
        uint256 Rin = z2o ? R0 : R1;
        uint256 Rout = z2o ? R1 : R0;
        return mulDiv(dx, Rout, Rin + dx);
    }

    function _outV3(
        uint256 dx,
        uint128 L,
        uint160 sqrtP0_Q96
    ) private pure returns (uint256) {
        if (dx == 0) return 0;
        uint256 num1 = mulDiv(dx, sqrtP0_Q96, 1); // dx·√P₀ (Q64.96)
        uint256 num2 = mulDiv(num1, sqrtP0_Q96, 1 << 96); // dx·√P₀² (plain)
        return mulDiv(num2, L, uint256(L) + num1);
    }
}
