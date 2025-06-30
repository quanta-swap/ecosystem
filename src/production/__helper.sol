// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * SplitOptimalNoFee64 – cost-optimal, fee-agnostic splitter for
 * a single 256-tick Uniswap-style CLMM window + a V2 CPMM which start
 * at the same price.
 *
 * • √P values are Q64.96 fixed-point.
 * • All intermediate maths promoted to uint256; custom 512-bit mul-div
 *   keeps every division exact without risk of overflow.
 * • Works for both directions (token0→token1 and the inverse).
 *
 * **NOT AUDITED.  Use at your own risk.**
 */
library SplitOptimalNoFee64 {
    /* ───────── Storage layout ───────── */
    struct Split {
        uint64 inV3;
        uint64 inV2;
        uint64 outV3;
        uint64 outV2;
    }

    uint256 private constant Q96 = 2 ** 96;

    /* ═════════ ENTRY ═════════ */
    function split(
        uint64  amountInMax,
        bool    zeroForOne,      // true  = token0 → token1
        uint160 sqrtP0_Q96,      // √P₀ (Q64.96)
        uint160 sqrtPlim_Q96,    // √P limit (Q64.96, inside the window)
        uint128 L,               // CLMM liquidity
        uint64  R0,              // V2 reserve of token0
        uint64  R1               // V2 reserve of token1
    ) internal pure returns (Split memory S) {
        unchecked {
            if (amountInMax == 0) return S;                      // trivial

            /* ───── 0. Common shorthands ───── */
            uint256 sqrtP0   = uint256(sqrtP0_Q96);
            uint256 Rin      = zeroForOne ? R0 : R1;             // V2 input reserve

            /* ───── 1. Cheaper pool at x = 0 ? ─────
             * token0→token1: 2·√P₀·Rin  ?  L
             * token1→token0: 2·Rin      ?  L·√P₀
             * Stay in Q64.96 throughout ⇒ shift the *other* side left by 96.
             */
            bool clmmCheaper = zeroForOne
                ? (2 * sqrtP0 * Rin < uint256(L) * Q96)          // token0 in
                : (2 * Rin * Q96     < uint256(L) * sqrtP0);     // token1 in

            /* ───── 2. Equal-margin chunk on cheaper leg ───── */
            uint256 dxV3Star;                                    // tokenIn units
            uint256 dxV2Star;

            if (clmmCheaper) {
                if (zeroForOne) {
                    /* 2·√P₀³ / L = √P₀² /(Rin+dx)  ⇒
                       (1 + dx·√P₀ / L)³ = 2·√P₀·Rin / L         */
                    uint256 rhs_Q96 = mulDiv(2 * sqrtP0, Rin, uint256(L)); // Q64.96
                    uint256 cbrt_Q96 = _cbrt_Q96(rhs_Q96);                 // Q64.96
                    if (cbrt_Q96 > Q96) {
                        dxV3Star = mulDiv(uint256(L), cbrt_Q96 - Q96, sqrtP0);
                    }
                }
                /* token1-in case: CLMM stays cheaper for the entire path, so
                             dxV3Star → 0 and we defer to the cap. */
            } else {
                /* V2 is cheaper at the start – give it just enough input to
                   equalise slopes.  Both directions collapse to
                     Rin + dx = L·√P₀ / 2                         */

                uint256 target = mulDiv(uint256(L), sqrtP0, 2 * Q96);      // plain
                if (target > Rin) dxV2Star = target - Rin;                 // else 0
            }

            /* ───── 3. Hard caps from user price-limit ───── */
            uint256 dxV3Cap;                                               // tokenIn
            if (zeroForOne) {
                require(sqrtPlim_Q96 < sqrtP0_Q96, "lim>start");
                dxV3Cap = mulDiv(
                    uint256(L),
                    sqrtP0 - uint256(sqrtPlim_Q96),
                    (sqrtP0 * uint256(sqrtPlim_Q96)) >> 96
                );
            } else {
                require(sqrtPlim_Q96 > sqrtP0_Q96, "lim<start");
                dxV3Cap = mulDiv(
                    uint256(L),
                    uint256(sqrtPlim_Q96) - sqrtP0,
                    Q96
                );
            }

            // V2 cap: Rin·(√P_ratio − 1)
            uint256 dxV2Cap;
            if (zeroForOne) {
                uint256 ratio_Q96 = mulDiv(sqrtP0, Q96, uint256(sqrtPlim_Q96));
                dxV2Cap = mulDiv(Rin, ratio_Q96 - Q96, Q96);
            } else {
                uint256 ratio_Q96 = mulDiv(
                    uint256(sqrtPlim_Q96),
                    Q96,
                    sqrtP0
                );
                dxV2Cap = mulDiv(Rin, ratio_Q96 - Q96, Q96);
            }

            /* ───── 4. Allocation ───── */
            uint256 useV3;
            uint256 useV2;

            if (clmmCheaper) {
                useV3 = _min3(dxV3Star == 0 ? dxV3Cap : dxV3Star, dxV3Cap, amountInMax);
                uint256 rem = amountInMax - useV3;
                useV2 = rem > dxV2Cap ? dxV2Cap : rem;
            } else {
                useV2 = _min3(dxV2Star, dxV2Cap, amountInMax);
                uint256 rem = amountInMax - useV2;
                useV3 = rem > dxV3Cap ? dxV3Cap : rem;
            }

            /* ───── 5. Return struct (safe-cast) ───── */
            S.inV3  = _cast64(useV3);
            S.inV2  = _cast64(useV2);
            S.outV3 = _cast64(_outV3(useV3, zeroForOne, L, sqrtP0_Q96));
            S.outV2 = _cast64(_outV2(useV2, zeroForOne, R0, R1));
        }
    }

    /* ═════════ Helper maths ═════════ */

    /* ---------- mul-div with full-precision ---------- */
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

            if (prod1 == 0) return prod0 / d;
            require(d > prod1, "mulDiv overflow");

            uint256 rem = mulmod(a, b, d);
            assembly {
                prod1 := sub(prod1, gt(rem, prod0))
                prod0 := sub(prod0, rem)
            }

            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;

            result = prod0 * inv;
        }
    }

    /* ---------- integer ∛ in Q64.96 ---------- */
    function _cbrt_Q96(uint256 x_Q96) private pure returns (uint256 y_Q96) {
        if (x_Q96 == 0) return 0;
        y_Q96 = Q96;                                           // 1.0
        for (uint8 i = 0; i < 35; ++i) {
            uint256 y2 = mulDiv(y_Q96, y_Q96, Q96);
            uint256 num = (2 * y_Q96) + mulDiv(x_Q96, Q96, y2);
            uint256 yPrev = y_Q96;
            y_Q96 = num / 3;
            if (y_Q96 >= yPrev ? y_Q96 - yPrev <= 1 : yPrev - y_Q96 <= 1) {
                if (mulDiv(y_Q96, mulDiv(y_Q96, y_Q96, Q96), Q96) > x_Q96)
                    --y_Q96;
                return y_Q96;
            }
        }
    }

    /* ---------- V2 output (fee-free) ---------- */
    function _outV2(
        uint256 dx,
        bool    z2o,
        uint64  R0,
        uint64  R1
    ) private pure returns (uint256) {
        if (dx == 0) return 0;
        uint256 Rin  = z2o ? R0 : R1;
        uint256 Rout = z2o ? R1 : R0;
        return mulDiv(dx, Rout, Rin + dx);
    }

    /* ---------- V3 output (fee-free) ---------- */
    function _outV3(
        uint256  dx,
        bool     z2o,
        uint128  L,
        uint160  sqrtP0_Q96
    ) private pure returns (uint256) {
        if (dx == 0) return 0;

        if (z2o) {
            /* token0 in → token1 out */
            uint256 term   = mulDiv(dx, sqrtP0_Q96, Q96);          // dx·√P₀ / Q96
            uint256 denom  = uint256(L) + term;
            uint256 sqrtP1 = mulDiv(uint256(sqrtP0_Q96), uint256(L), denom);
            uint256 delta  = uint256(sqrtP0_Q96) - sqrtP1;
            return mulDiv(uint256(L), delta, Q96);
        } else {
            /* token1 in → token0 out */
            uint256 sqrtP1 = uint256(sqrtP0_Q96) +
                mulDiv(dx, Q96, uint256(L));
            uint256 prod   = mulDiv(sqrtP1, uint256(sqrtP0_Q96), Q96);
            uint256 delta  = sqrtP1 - uint256(sqrtP0_Q96);
            return mulDiv(uint256(L), delta, prod);
        }
    }

    /* ---------- misc utils ---------- */
    function _min3(uint256 a, uint256 b, uint256 c) private pure returns (uint256) {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }

    function _cast64(uint256 x) private pure returns (uint64 y) {
        require(x <= type(uint64).max, "uint64 overflow");
        y = uint64(x);
    }
}
