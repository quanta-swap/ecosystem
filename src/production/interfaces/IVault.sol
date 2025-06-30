// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC4.sol";

/**
 * @title IVault
 * @notice Interface for the Initial Liquidity Vault (contract “BISMARCK”).
 *         The vault crowdsources wQRL deposits, deploys them once into the
 *         QSD liquidity-loan mechanism, then lets each participant perform a
 *         single proportional exit after a 365-day lock.  Reward tokens are
 *         linearly vested (25 % cliff + 75 % over the year).
 *
 *         All token amounts use 8-dec uint64 fixed-point precision.
 */
interface IVault {
    /* ─────────────────────────── Errors ─────────────────────────── */

    /// Caller is not the owner.
    error NotOwner();

    /// Function is only callable before `deploy()` executes.
    error VaultNotLive();

    /// Function is only callable after `deploy()` executes.
    error VaultLive();

    /// Deposit cap would be exceeded.
    error CapExceeded();

    /// Amount parameter must be strictly positive.
    error ZeroAmount();

    /// User has no deposit recorded.
    error NoDeposit();

    /// Liquidity lock (365 days) has not yet expired.
    error StillLocked();

    /// User has already withdrawn.
    error AlreadyExited();

    /// Minimum-out guard failed when burning LP shares.
    error Slippage(uint64 wantMin, uint64 got);

    /// Zero-address supplied where non-zero required.
    error ZeroAddress();

    /* ─────────────────────────── Events ─────────────────────────── */

    /// Ownership transferred to a new address.
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    /// wQRL successfully deposited.
    event Deposited(address indexed user, uint64 amount);

    /// Pre-deployment deposit cancelled and refunded.
    event Cancelled(address indexed user, uint64 amount);

    /// Vault liquidity deployed into QSD; vault goes live.
    event Deployed(uint64 wqrlIn, uint128 lpSharesMinted);

    /// Reward tokens minted (either stand-alone `claim()` or during exit).
    event Claimed(address indexed user, uint64 rewardMinted);

    /// Final exit: user receives underlying wQRL + QSD and any rewards.
    event Withdrawn(
        address indexed user,
        uint64  wqrlOut,
        uint64  qsdOut,
        uint64  rewardMinted,
        uint128 lpSharesBurned
    );

    /* ───────────────────────── View helpers ─────────────────────── */

    function wqrl() external view returns (IZRC1);   ///< Wrapped QRL token
    function qsd()  external view returns (address);   ///< QSD contract address
    function reward() external view returns (IZRC4);  ///< FREE reward token

    function owner() external view returns (address);
    function cap() external view returns (uint64);             ///< Hard-cap on deposits
    function live() external view returns (bool);               ///< True once deployed
    function liveAt() external view returns (uint256);          ///< Timestamp vault went live
    function totalDeposited() external view returns (uint64);   ///< Aggregate wQRL collected
    function totalShares() external view returns (uint128);     ///< LP shares minted by QSD

    function deposited(address user) external view returns (uint64);
    function claimed(address user)   external view returns (uint64);
    function exited(address user)    external view returns (bool);

    /**
     * @notice View helper: user’s proportional LP share count (zero if not live
     *         or already withdrawn).
     */
    function pendingShares(address user) external view returns (uint128);

    /* ─────────────────────── User actions ───────────────────────── */

    /**
     * @notice Contribute wQRL before the vault deploys.  Reverts once live.
     */
    function deposit(uint64 amount) external;

    /**
     * @notice Cancel part or all of an undeployed deposit.
     */
    function cancel(uint64 amount) external;

    /**
     * @notice Claim any vested FREE tokens without exiting the vault.
     */
    function claim() external;

    /**
     * @notice Single-shot exit after the 365-day lock: burns the user’s LP
     *         slice and transfers underlying wQRL + QSD plus any unclaimed
     *         rewards.  Can only be called once per wallet.
     *
     * @param minQsdOut  Slippage guard: minimum QSD expected.
     * @param minWqrlOut Slippage guard on wQRL side (0 = no check).
     */
    function withdrawUnderlying(uint64 minQsdOut, uint64 minWqrlOut) external;

    /* ─────────────────────── Owner actions ─────────────────────── */

    /**
     * @notice After deposits close, push pooled wQRL into QSD as liquidity.
     *
     * @param minShares Minimum LP share count expected (slippage guard).
     */
    function deploy(uint128 minShares) external;

    /**
     * @notice Transfer contract ownership.
     */
    function transferOwnership(address newOwner) external;
}
