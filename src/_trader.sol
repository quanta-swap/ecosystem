// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IDEX.sol";
import "./IZRC20.sol";
import "./_helper.sol";

abstract contract ReentrancyGuard {
    uint8 private constant _NOT = 1;
    uint8 private constant _ENT = 2;
    uint8 private _stat = _NOT;
    modifier nonReentrant() {
        require(_stat != _ENT, "re-enter");
        _stat = _ENT;
        _;
        _stat = _NOT;
    }
}

contract QuantaSwap is IDEX {

    function getReserves(
        IZRC20 tokenA,
        IZRC20 tokenB
    ) external view override returns (uint64 reserveA, uint64 reserveB) {}

    function getPairLiquidity(
        IZRC20 tokenA,
        IZRC20 tokenB,
        address provider
    )
        external
        view
        override
        returns (uint64 amountA, uint64 amountB, uint128 shares)
    {}

    function getPosition(
        address owner,
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        override
        returns (
            uint128 liquidity,
            uint64 feeGrowthInsideALast,
            uint64 feeGrowthInsideBLast,
            uint64 tokensOwedA,
            uint64 tokensOwedB
        )
    {}

    function consultTWAP(
        IZRC20 tokenA,
        IZRC20 tokenB,
        uint32 secsAgo,
        uint128 minVolume
    ) external view override returns (uint128 priceQ64) {}

    function addLiquidityPair(
        IZRC20 tokenA,
        IZRC20 tokenB,
        uint64 amountADesired,
        uint64 amountBDesired
    )
        external
        override
        returns (uint128 sharesMinted, uint64 amountAUsed, uint64 amountBUsed)
    {}

    function removeLiquidityPair(
        IZRC20 tokenA,
        IZRC20 tokenB,
        uint128 shares
    ) external override returns (uint64 amountAOut, uint64 amountBOut) {}

    function mintPosition(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint64 amountADesired,
        uint64 amountBDesired
    )
        external
        override
        returns (
            uint128 liquidityMinted,
            uint64 amountAUsed,
            uint64 amountBUsed
        )
    {}

    function burnPosition(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external override returns (uint64 amountAOut, uint64 amountBOut) {}

    function collectFees(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        address recipient,
        uint64 amountALimit,
        uint64 amountBLimit
    ) external override returns (uint64 amountA, uint64 amountB) {}

    function quoteMintRequiredAmounts(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDesired
    )
        external
        view
        override
        returns (uint64 amountARequired, uint64 amountBRequired)
    {}

    function quoteMintGivenAmountA(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint64 amountAIn
    )
        external
        view
        override
        returns (uint64 amountBRequired, uint128 liquidityOut)
    {}

    function quoteMintGivenAmountB(
        IZRC20 tokenA,
        IZRC20 tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint64 amountBIn
    )
        external
        view
        override
        returns (uint64 amountARequired, uint128 liquidityOut)
    {}

    function operateLimitOrders(
        OrderCancel[] calldata cancelOps,
        OrderCreate[] calldata createOps
    ) external override returns (uint64[][] memory newIds) {}

    function executeBatch(
        uint64 free,
        SwapParams[] calldata swaps
    ) external override returns (uint64[] memory fills) {}

    function simulateWithOrdersExactIn(
        IZRC20 tokenIn,
        IZRC20 tokenOut,
        uint64 amountIn,
        uint64 freeAmt,
        uint64[] calldata ids
    ) external view override returns (uint64 amountOut) {}

    function simulateWithOrdersExactOut(
        IZRC20 tokenIn,
        IZRC20 tokenOut,
        uint64 amountOut,
        uint64 freeAmt,
        uint64[] calldata ids
    ) external view override returns (uint64 amountIn) {}

    function getLimitOrder(
        IZRC20 tokenIn,
        IZRC20 tokenOut,
        uint64 id
    )
        external
        view
        override
        returns (
            uint64 amountInTotal,
            uint64 amountOutTotal,
            uint64 amountInFilled,
            bool isActive
        )
    {}
}