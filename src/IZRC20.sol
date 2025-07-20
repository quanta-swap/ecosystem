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

    // For tokens that have certain on-chain compliance requirements. This
    // allows callers to protect an intention to do something in the future.
    function checkSupportsOwner(address who) external view returns (bool);
    function checkSupportsSpender(address who) external view returns (bool);
    
}

/**
 * @title  IZRC20Helper
 * @notice   • “Does this address *look* like an IZRC20?”  
 *           • Checks a single, view‑only selector: `totalSupply()`.  
 *           • Returns **true / false** – never reverts.  
 *
 * Rationale ────────────────────────────────────────────────────────────
 *   IZRC20 guarantees that all externally visible balances use **uint64**.  
 *   A compliant `totalSupply()` therefore *must*:
 *     1. Exist (selector handled, call succeeds).  
 *     2. Return exactly 32 bytes.  
 *     3. Encode a value ≤ 2⁶⁴‑1.  
 *
 * Anything else (EOA, missing selector, revert, 256‑bit supply) => false.
 *
 * Limitations ─────────────────────────────────────────────────────────
 *   • A malicious contract can spoof the check (return a 64‑bit number now,  
 *     revert later). Wrap real interactions in `try/catch`.  
 *   • Proxies can upgrade after you probe. If certainty is mission‑critical,  
 *     maintain an allow‑list instead.  
 */
library IZRC20Helper {
    /**
     * @dev Best‑effort probe for IZRC20 compliance (64‑bit `totalSupply()`).
     *
     * @param token  Address under test.
     * @return ok    `true` iff all three assertions above hold.
     */
    function isIZRC20(address token) internal view returns (bool ok) {
        /* 1 ─ Reject externally‑owned accounts outright */
        if (token.code.length == 0) return false;

        /* 2 ─ Ask for totalSupply(); ignore any state‑changing side‑effects */
        (bool success, bytes memory ret) = token.staticcall(
            abi.encodeWithSelector(IZRC20.totalSupply.selector)
        );
        if (!(success && ret.length == 32)) return false; // selector missing or malformed

        /* 3 ─ Decode the returned word and confirm it fits in 64 bits */
        uint256 supply;
        // Load the 32‑byte word into `supply`
        assembly {
            supply := mload(add(ret, 0x20))
        }
        return supply <= type(uint64).max;
    }
}