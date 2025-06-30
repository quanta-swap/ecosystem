// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────────────────*
│ SplitOptimalNoFee64 – *gas-lean* analytic splitter for one 256-tick CLMM   │
│ window plus one fee-free V2 CPMM that start at the same spot price.        │
│                                                                           │
│ • Keeps the exact closed-form maths but removes every expendable mulDiv.  │
│ • Shifts replace all /·2⁹⁶ and ·2⁹⁶/ ops; custom errors drop revert text. │
*───────────────────────────────────────────────────────────────────────────*/
library SplitOptimalNoFee64 {
    /*──────────────  Custom errors  ─────────────*/
    error EmptyPool();           // zero L or reserves
    error LimitTooHigh();        // √Plim ≥ √P0 for 0→1, or ≤ for 1→0
    error Uint64Overflow();
    error ZeroDenominator();     // added: mulDiv denominator collapsed to 0

    /*──────────────  Public types  ─────────────*/
    struct Split {
        uint64 inV3;
        uint64 inV2;
        uint64 outV3;
        uint64 outV2;
    }

    uint256 private constant Q96 = 2 ** 96;

    /*═══════════════════  ENTRY  ═════════════════*/
    function split(
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
            uint256 sqrtStar;                          // √P★ (Q64.96)

            /*───────────────── Solve √P★ analytically ─────────────────*/
            if (zeroForOne) {
                // token0 → token1 : price must fall
                if (sqrtPlim_Q96 >= sqrtP0_Q96) revert LimitTooHigh();

                // 𝒦 = R0 + L/√P₀   (token0 units)
                uint256 K = uint256(R0) + ((uint256(L) << 96) / sqrtP0_Q96);

                // Δ  = dx / 𝒦      (Q96-scaled)
                uint256 delta_Q96 = (uint256(amountInMax) << 96) / K;

                // √P★ = √P₀ / (1 + Δ)
                sqrtStar = mulDiv(sqrtP0_Q96, Q96, Q96 + delta_Q96);

                if (sqrtStar < sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            } else {
                // token1 → token0 : price must rise
                if (sqrtPlim_Q96 <= sqrtP0_Q96) revert LimitTooHigh();

                // 𝒦 = R1 + L·√P₀/2⁹⁶   (token1 units)
                uint256 K = uint256(R1) + (uint256(L) * sqrtP0_Q96) >> 96;

                // Δ  = dx / 𝒦          (Q96-scaled)
                uint256 delta_Q96 = (uint256(amountInMax) << 96) / K;

                // √P★ = √P₀ · (1 + Δ)
                sqrtStar = mulDiv(sqrtP0_Q96, Q96 + delta_Q96, Q96);

                if (sqrtStar > sqrtPlim_Q96) sqrtStar = sqrtPlim_Q96;
            }

            /*──────────────── Back-solve exact inputs ────────────────*/
            uint256 dxV2;
            uint256 dxV3;

            if (zeroForOne) {
                // ratio_Q96 = √P₀ / √P★
                uint256 ratio_Q96 = mulDiv(sqrtP0_Q96, Q96, sqrtStar);

                // CPMM leg
                dxV2 = (uint256(R0) * (ratio_Q96 - Q96)) >> 96;

                // CLMM leg
                uint256 denom = (sqrtP0 * sqrtStar) >> 96;     // √P₀√P★ / 2⁹⁶
                if (denom == 0) revert ZeroDenominator();      // <<==== FIX #2
                dxV3 = mulDiv(L, sqrtP0 - sqrtStar, denom);
            } else {
                // ratio_Q96 = √P★ / √P₀
                uint256 ratio_Q96 = mulDiv(sqrtStar, Q96, sqrtP0_Q96);

                // CPMM leg
                dxV2 = (uint256(R1) * (ratio_Q96 - Q96)) >> 96;

                // CLMM leg
                dxV3 = mulDiv(L, sqrtStar - sqrtP0, Q96);      // denom = 2⁹⁶ (never 0)
            }

            /*────────── Clip 1-wei rounding overrun ──────────*/
            uint256 spent = dxV2 + dxV3;
            if (spent > amountInMax + 1) {
                uint256 excess = spent - amountInMax;
                if (excess <= dxV2) {
                    dxV2 -= excess;
                } else {
                    dxV3 -= (excess - dxV2);
                    dxV2 = 0;
                }
            }

            /*────────── Individual uint64 safety check ───────*/      // <<==== FIX #3
            if (dxV2 > type(uint64).max || dxV3 > type(uint64).max) revert Uint64Overflow();

            /*──────────────  Populate struct  ───────────────*/
            S.inV3  = _cast64(dxV3);
            S.inV2  = _cast64(dxV2);
            S.outV3 = _cast64(_outV3(dxV3, zeroForOne, L, sqrtP0_Q96));
            S.outV2 = _cast64(_outV2(dxV2, zeroForOne, R0, R1));
        }
    }

    /*══════════════════ Helpers  ══════════════════*/

    /// @dev 512-bit mul-div, unchanged
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

    /*───────────────── CPMM output ─────────────────*/
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

    /*───────────────── CLMM output ─────────────────*/
    function _outV3(
        uint256 dx,
        bool    z2o,
        uint128 L,
        uint160 sqrtP0_Q96
    ) private pure returns (uint256) {
        if (dx == 0) return 0;

        if (z2o) {
            // token0 → token1
            uint256 term   = (dx * uint256(sqrtP0_Q96)) >> 96; // dx·√P₀/2⁹⁶
            uint256 denom  = uint256(L) + term;
            uint256 sqrtP1 = (uint256(sqrtP0_Q96) * uint256(L)) / denom;
            uint256 delta  = uint256(sqrtP0_Q96) - sqrtP1;
            return (uint256(L) * delta) >> 96;                 // L·Δ/2⁹⁶
        } else {
            // token1 → token0
            uint256 sqrtP1 = uint256(sqrtP0_Q96) + ((dx << 96) / uint256(L));
            uint256 prod   = (sqrtP1 * uint256(sqrtP0_Q96)) >> 96;
            uint256 delta  = sqrtP1 - uint256(sqrtP0_Q96);
            return mulDiv(L, delta, prod);                     // L·Δ / (√P₁√P₀/2⁹⁶)
        }
    }

    /*───────────────── uint256 → uint64 ───────────────*/
    function _cast64(uint256 x) private pure returns (uint64 y) {
        assembly {
            if gt(x, 0xffffffffffffffff) {
                mstore(0x00, 0xd6dd71fd)      // Uint64Overflow()
                revert(0x00, 0x04)
            }
            y := x
        }
    }
}
