// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRouter {

    struct SwapOrder {
        address tokenIn;
        address tokenOut;
        bool exactIn;
        uint64 amount;
        uint64 limit;
        address recipient;
        bool useCPMM;
        bool useCLMM;
        uint64[] orders;
    }


    /* Supports exactIn / exactOut */
    function swap(
        uint64 freeToken,
        SwapOrder[] calldata swaps
    ) external returns (uint64 amountCalculated);

}