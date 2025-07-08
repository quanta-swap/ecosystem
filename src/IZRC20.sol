// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IZRC20 – 64-bit ERC-20–compatible interface
/// @author  …
/**
 * @notice Identical to ERC-20 *semantics* but all observable balances,
 *         allowances, transfers and totalSupply are **uint64**.
 *
 *         • Saves 128 bits per SLOAD/SSTORE compared with uint256 tokens.  
 *         • Fits comfortably within 2⁶⁴-1 ≈ 1.84 e19 sub-units  
 *           (e.g. 18-decimals → 18 446 744 073 ETH worth of wei).  
 *
 *         Contracts interacting with an IZRC20 must assume:
 *         - `false` return values on {transfer}/{transferFrom} indicate FAILURE.
 *         - Implementations MAY revert instead of returning `false`.
 *         - A return value of `true` MUST mean the state change succeeded.
 *
 *         This keeps the interface drop-in compatible with OpenZeppelin-style
 *         safe-transfer wrappers that treat a blank return-data payload as
 *         success.
 */
interface IZRC20 {
    /*──────────────────────────────────
    │  ZRC-20 Events (uint64 amounts)  │
    └──────────────────────────────────*/
    event Transfer(
        address indexed from,
        address indexed to,
        uint64  value
    );

    event Approval(
        address indexed owner,
        address indexed spender,
        uint64  value
    );

    /*────────────────────────────
    │  Metadata (optional view)  │
    └────────────────────────────*/
    function name()        external view returns (string memory);
    function symbol()      external view returns (string memory);
    function decimals()    external view returns (uint8); // SHOULD return 8-18

    /*───────────────────────────────
    │  ZRC-20 Read-only Functions   │
    └───────────────────────────────*/
    function totalSupply() external view returns (uint64);
    function balanceOf(address account) external view returns (uint64);
    function allowance(address owner, address spender) external view returns (uint64);

    /*───────────────────────────────
    │  ZRC-20 State-changing Calls  │
    └───────────────────────────────*/
    function transfer(address to, uint64 amount) external returns (bool);
    function transferBatch(
        address[] calldata dst,
        uint64[] calldata wad
    ) external returns (bool success);

    function approve(address spender, uint64 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint64 amount
    ) external returns (bool);
    function transferFromBatch(
        address src,
        address[] calldata dst,
        uint64[] calldata wad
    ) external returns (bool success);

}
