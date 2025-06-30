// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SplitOptimalNoFee64 {
    struct Split {
        uint64 inV3;
        uint64 inV2;
        uint64 outV3;
        uint64 outV2;
    }

    uint256 private constant Q96 = 2 ** 96;

    /*══════════════════════  ENTRY  ══════════════════════*/
    function split(
        uint64  amountInMax,
        bool    zeroForOne,      // true = token0 → token1
        uint160 sqrtP0_Q96,
        uint160 sqrtPlim_Q96,
        uint128 L,
        uint64  R0,
        uint64  R1
    ) internal pure returns (Split memory S) {
        unchecked {
            if (amountInMax == 0) return S;

            uint256 sqrtP0 = uint256(sqrtP0_Q96);
            uint256 sqrtStar;                       // √P★ (Q64.96)

            /* ───────────────── Closed-form √P★ ───────────────── */
            if (zeroForOne) {
                require(sqrtPlim_Q96 < sqrtP0_Q96, "lim>start");

                // 𝒦 = R0 + L/√P₀       (token0 units)
                uint256 K = uint256(R0) + mulDiv(L, Q96, sqrtP0_Q96);  // ← add Q96 here

                // Δ = spend / 𝒦         (Q96-scaled)
                uint256 delta_Q96 = mulDiv(amountInMax, Q96, K);

                // x = 1 + Δ
                uint256 x_Q96 = Q96 + delta_Q96;

                // √P★ = √P₀ / x
                sqrtStar = mulDiv(sqrtP0_Q96, Q96, x_Q96);

                if (sqrtStar < sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            } else {
                require(sqrtPlim_Q96 > sqrtP0_Q96, "lim<start");

                // 𝒦 = R1 + L·√P₀/Q96    (token1 units)
                uint256 K = uint256(R1) + mulDiv(L, sqrtP0_Q96, Q96);

                // Δ = spend / 𝒦         (Q96-scaled)
                uint256 delta_Q96 = mulDiv(amountInMax, Q96, K);

                // y = 1 + Δ
                uint256 y_Q96 = Q96 + delta_Q96;

                // √P★ = √P₀ · y
                sqrtStar = mulDiv(sqrtP0_Q96, y_Q96, Q96);

                if (sqrtStar > sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            }

            /* ─────────────── Back-solve exact inputs ─────────── */
            uint256 dxV2;
            uint256 dxV3;

            if (zeroForOne) {
                uint256 ratio_Q96 = mulDiv(sqrtP0_Q96, Q96, sqrtStar);   // √P₀/√P★
                dxV2 = mulDiv(R0, ratio_Q96 - Q96, Q96);                 // CPMM leg
                uint256 denom = mulDiv(sqrtP0_Q96, sqrtStar, Q96);
                dxV3 = mulDiv(L, sqrtP0 - uint256(sqrtStar), denom);     // CLMM leg
            } else {
                uint256 ratio_Q96 = mulDiv(sqrtStar, Q96, sqrtP0_Q96);   // √P★/√P₀
                dxV2 = mulDiv(R1, ratio_Q96 - Q96, Q96);                 // CPMM leg
                dxV3 = mulDiv(L, uint256(sqrtStar) - sqrtP0, Q96);       // CLMM leg
            }

            /* ─────────── Safety clip for rounding excess ─────── */
            uint256 spent = dxV2 + dxV3;
            if (spent > amountInMax) {
                uint256 excess = spent - amountInMax;
                require(excess <= dxV2, "rounding overflow");
                dxV2 -= excess;
            }

            /* ─────────────────── Populate struct ─────────────── */
            S.inV3  = _cast64(dxV3);
            S.inV2  = _cast64(dxV2);
            S.outV3 = _cast64(_outV3(dxV3, zeroForOne, L, sqrtP0_Q96));
            S.outV2 = _cast64(_outV2(dxV2, zeroForOne, R0, R1));
        }
    }

    /*══════════════  Helpers (unchanged)  ══════════════*/

    uint256 private constant MASK = type(uint128).max;

    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 d
    ) internal pure returns (uint256 r) {
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

    function _outV2(uint256 dx, bool z2o, uint64 R0, uint64 R1) private pure returns (uint256) {
        if (dx == 0) return 0;
        uint256 Rin = z2o ? R0 : R1;
        uint256 Rout = z2o ? R1 : R0;
        return mulDiv(dx, Rout, Rin + dx);
    }

    /*────────────────────  V3 output  ────────────────────*/
    function _outV3(
        uint256 dx,
        bool z2o,
        uint128 L,
        uint160 sqrtP0_Q96
    ) private pure returns (uint256) {
        if (dx == 0) return 0;

        if (z2o) {                             // token0 → token1
            uint256 term   = mulDiv(dx, sqrtP0_Q96, Q96);
            uint256 denom  = uint256(L) + term;
            uint256 sqrtP1 = mulDiv(uint256(sqrtP0_Q96), uint256(L), denom);
            uint256 delta  = uint256(sqrtP0_Q96) - sqrtP1;
            return mulDiv(uint256(L), delta, Q96);
        } else {                               // token1 → token0
            uint256 sqrtP1 = uint256(sqrtP0_Q96) + mulDiv(dx, Q96, uint256(L));
            uint256 prod   = mulDiv(sqrtP1, uint256(sqrtP0_Q96), Q96);   // avoids overflow
            uint256 delta  = sqrtP1 - uint256(sqrtP0_Q96);
            return mulDiv(uint256(L), delta, prod);
        }
    }

    function _cast64(uint256 x) private pure returns (uint64 y) {
        require(x <= type(uint64).max, "uint64 overflow");
        y = uint64(x);
    }
}
