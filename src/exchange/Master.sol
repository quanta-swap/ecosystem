// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../_launch.sol";
import "../IZRC20.sol";

error UnsupportedPair(address, address);
error PairNotFound(address, address);

contract QuantaSwap is IDEX {
    using IZRC20Helper for address;

    mapping(address => mapping(address => address)) public pairs;
    mapping(address => address) public routers;

    /**
     * @notice Return `true` iff **both** tokens look like IZRC20 contracts.
     *
     * @param tokenA Candidate reserve token A.
     * @param tokenB Candidate reserve token B.
     *
     * @dev    • View (= side‑effect‑free) so upstream integrators can call
     *           this in a constructor or simulation.
     *         • Uses the helper’s `isIZRC20()` probe (totalSupply check).
     *         • NEVER reverts—always returns `false` on malformed input.
     */
    function checkSupportForPair(
        address tokenA,
        address tokenB
    ) external view override returns (bool supported) {
        // Early reject: identical or zero addresses make no sense.
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) {
            return false;
        }

        // Helper probes: true only when both pass the 64‑bit totalSupply test.
        return tokenA.isIZRC20() && tokenB.isIZRC20();
    }

    function initializeLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address to
    ) external override returns (address location, uint256 liquidity) {
        require(this.checkSupportForPair(tokenA, tokenB), UnsupportedPair(tokenA, tokenB));
    }

    function withdrawLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        address to,
        uint64 minA,
        uint64 minB
    ) external override returns (uint64 amountA, uint64 amountB) {
        require(pairs[tokenA][tokenB] != address(0), PairNotFound(tokenA, tokenB));
    }
}

interface IPair {
    function withdrawMaster(address auth, address to) external returns (uint64 amountA, uint64 amountB);
}