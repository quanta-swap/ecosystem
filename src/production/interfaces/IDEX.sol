// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC1} from "./IZRC1.sol";

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║                               ░ I D E X ░                            ║
 * ║  Dual-mode AMM: V2 Pair Pools ♦ V3 Concentrated Ranges ♦ ZRC-1       ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */
interface IDEX {
    /* ─────────── General Errors ─────────── */
    error Slippage();                 ///< aggregate or per-swap minOut violated
    error WrongSide(uint64 id);       ///< order ID is on opposite book
    error EmptyPool();                ///< requested pool empty / un-init
    error ArraysLengthMismatch();     ///< swaps.length == 0
    error InvalidTicks();             ///< tickLower ≥ tickUpper or out of range
    error LiquidityZero();            ///< zero liquidity / shares specified

    /* ─────────── Events ─────────── */

    /* … OrderOpened / OrderClosed / OrderFilled definitions unchanged … */

    /** V2-style pair-wide liquidity added */
    event PairLiquidityAdded(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint64 amountA,
        uint64 amountB,
        uint128 shares
    );

    /** V2-style pair-wide liquidity removed */
    event PairLiquidityRemoved(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint64 amountA,
        uint64 amountB,
        uint128 shares
    );

    /** V3 position minted (concentrated liquidity) */
    event PositionMinted(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        int24  tickLower,
        int24  tickUpper,
        uint128 liquidity,
        uint64 amountA,
        uint64 amountB
    );

    /** V3 position burned (liquidity withdrawn) */
    event PositionBurned(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        int24  tickLower,
        int24  tickUpper,
        uint128 liquidity,
        uint64 amountA,
        uint64 amountB
    );

    /** Fees collected from a V3 position */
    event FeesCollected(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        int24  tickLower,
        int24  tickUpper,
        uint64 feesA,
        uint64 feesB,
        address recipient
    );

    /** Emitted once per individual fill in a batch swap */
    event Swap(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint64 amountIn,
        uint64 amountOut
    );

    event OracleSnap(
        address indexed tokenA,
        address indexed tokenB,
        uint64 timestamp,
        uint256 priceCumAtoB
    );

    /* ─────────── Pool / Oracle Views ─────────── */

    /** Approx. global reserves (sum of all active ranges + pair pool, if any) */
    function getReserves(
        address tokenA,
        address tokenB
    ) external view returns (uint64 reserveA, uint64 reserveB);

    /* ---------- V2 pair-pool-specific view ---------- */
    function getPairLiquidity(
        address tokenA,
        address tokenB,
        address provider
    )
        external
        view
        returns (uint64 amountA, uint64 amountB, uint128 shares);

    /* ---------- V3 position-specific view ---------- */
    function getPosition(
        address owner,
        address tokenA,
        address tokenB,
        int24  tickLower,
        int24  tickUpper
    )
        external
        view
        returns (
            uint128 liquidity,
            uint64  feeGrowthInsideALast,
            uint64  feeGrowthInsideBLast,
            uint64  tokensOwedA,
            uint64  tokensOwedB
        );

    function consultTWAP(
        address tokenA,
        address tokenB,
        uint32 secsAgo,
        uint128 minVolume
    ) external view returns (uint128 priceQ64);

    /* ─────────── V2 Pair-Style Liquidity Control ─────────── */

    /**
     * @notice Add liquidity to the **pair-wide** constant-product pool.
     */
    function addLiquidityPair(
        address tokenA,
        address tokenB,
        uint64 amountADesired,
        uint64 amountBDesired
    )
        external
        returns (
            uint128 sharesMinted,
            uint64  amountAUsed,
            uint64  amountBUsed
        );

    /**
     * @notice Remove liquidity from the pair-wide pool.
     */
    function removeLiquidityPair(
        address tokenA,
        address tokenB,
        uint128 shares
    ) external returns (uint64 amountAOut, uint64 amountBOut);

    /* ─────────── V3 Concentrated-Liquidity Control ─────────── */

    function mintPosition(
        address tokenA,
        address tokenB,
        int24  tickLower,
        int24  tickUpper,
        uint64 amountADesired,
        uint64 amountBDesired
    )
        external
        returns (
            uint128 liquidityMinted,
            uint64  amountAUsed,
            uint64  amountBUsed
        );

    function burnPosition(
        address tokenA,
        address tokenB,
        int24  tickLower,
        int24  tickUpper,
        uint128 liquidity
    ) external returns (uint64 amountAOut, uint64 amountBOut);

    function collectFees(
        address tokenA,
        address tokenB,
        int24  tickLower,
        int24  tickUpper,
        address recipient,
        uint64 amountALimit,
        uint64 amountBLimit
    ) external returns (uint64 amountA, uint64 amountB);

    /* ─────────── Mint-quotation helpers (V3) ─────────── */

    function quoteMintRequiredAmounts(
        address tokenA,
        address tokenB,
        int24  tickLower,
        int24  tickUpper,
        uint128 liquidityDesired
    ) external view returns (uint64 amountARequired, uint64 amountBRequired);

    function quoteMintGivenAmountA(
        address tokenA,
        address tokenB,
        int24  tickLower,
        int24  tickUpper,
        uint64 amountAIn
    ) external view returns (uint64 amountBRequired, uint128 liquidityOut);

    function quoteMintGivenAmountB(
        address tokenA,
        address tokenB,
        int24  tickLower,
        int24  tickUpper,
        uint64 amountBIn
    ) external view returns (uint64 amountARequired, uint128 liquidityOut);

    /* ─────────── Limit-Order Control (unchanged) ─────────── */

    struct OrderCreate {
        address tokenIn;
        address tokenOut;
        uint64  amountIn;
        uint64  amountOut;
    }
    struct OrderCancel {
        address tokenIn;
        address tokenOut;
        uint64  id;
    }

    function operateLimitOrders(
        OrderCancel[] calldata cancelOps,
        OrderCreate[] calldata createOps
    ) external returns (uint64[][] memory newIds);

    /* ─────────── Batch Swap API (unchanged) ─────────── */

    struct SwapParams {
        address  tokenIn;
        address  tokenOut;
        address  recipient;
        uint64[] limitOrderIds;
        uint64   amount;   ///< >0 exact-in, 0 exact-out
        uint64   limit;    ///< minOut (in) or maxIn (out)
    }

    function executeBatch(
        uint64              free,
        SwapParams[] calldata swaps
    )
        external
        returns (uint64[] memory fills);

    /* ═══════════════  Simulators & Order Inspector  ═══════════════ */

    function simulateWithOrdersExactIn(
        address tokenIn,
        address tokenOut,
        uint64 amountIn,
        uint64 freeAmt,
        uint64[] calldata ids
    ) external view returns (uint64 amountOut);

    function simulateWithOrdersExactOut(
        address tokenIn,
        address tokenOut,
        uint64 amountOut,
        uint64 freeAmt,
        uint64[] calldata ids
    ) external view returns (uint64 amountIn);

    function getLimitOrder(
        address tokenIn,
        address tokenOut,
        uint64 id
    )
        external
        view
        returns (
            uint64 amountInTotal,
            uint64 amountOutTotal,
            uint64 amountInFilled,
            bool   isActive
        );
}
