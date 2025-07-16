// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../IZRC20.sol";

// executes a multi-modal swap between V2, V3 and CLOB pools
interface IPool {

    function getPair() external view returns (IZRC20 base, IZRC20 quote);

    function swap(
        bool baseForQuote,
        bool exactInput,
        uint64 amount,
        uint64 limit,
        uint64[] calldata orders
    )
        external
        returns (
            int256 netBase,
            int256 netQuote,
            uint64 gotBase,
            uint64 gotQuote
        );
}