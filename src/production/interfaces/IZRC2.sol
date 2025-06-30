// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC1.sol";

/// @title IYieldProtocol – 64-bit yield / haircut controller surface
/// @notice Stand-alone interface extracted from the Wrapped QRL-Z implementation.
/// @dev Revert-string literals were replaced by custom errors for ~70 gas savings each.
interface IYieldProtocol is IZRC1{
    /*━━━━━━━━━━━━━━━━━━━━━━━━━━ ERRORS ━━━━━━━━━━━━━━━━━━━━━━━━━*/

    /// Zero address supplied where a controller address was required.
    error ControllerZeroAddress();

    /// Caller is not the registered controller for the given protocol ID.
    error OnlyController(uint64 pid, address caller);

    /// lockWin parameter exceeds the implementation’s MAX_LOCK_WIN.
    error LockWindowTooLarge(uint64 lockWin, uint64 maxLockWin);

    /// A function received an amount of zero where a positive value is required.
    error ZeroAmount();

    /// Requested haircut would drive `outBal` past `inBal`.
    error ExcessHaircut(uint64 pid, uint64 inBal, uint64 outBal, uint64 haircut);

    /// No stake has been deposited for this protocol; yield cannot be added.
    error NoStake(uint64 pid);

    /// Mint or supply operation would overflow the 64-bit total-supply cap.
    error SupplyOverflow();

    /// The supplied protocol ID does not exist.
    error InvalidPid(uint64 pid);

    /// The supplied protocol ID appears more than once in the same call.
    error DuplicatePid(uint64 pid);

    /// Wallet already holds the maximum eight membership slots.
    error NoAvailableSlot(address wallet);

    /// Wallet attempts to leave a protocol before its lock window expires.
    error Locked(uint64 unlockBlock, uint64 currentBlock);

    /// Wallet balance would fall below that protocol’s minimum-stake requirement.
    error InsufficientStake(uint64 requiredMin, uint64 newBalance);

    /*━━━━━━━━━━━━━━━━━━━━━━━━━━ EVENTS ━━━━━━━━━━━━━━━━━━━━━━━━━*/

    event ProtocolCreated(
        uint64 indexed pid,
        address indexed controller,
        uint64 lockWin,
        uint64 minStake
    );

    event MinStakeUpdated(uint64 indexed pid, uint64 newMinStake);

    event Joined(address indexed wallet, uint64 pid);
    event Left(address indexed wallet, uint64 pid);

    event HaircutSignalled(uint64 indexed pid, uint64 amountTok);
    event HaircutCollected(uint64 indexed pid, uint64 amountTok);

    event YieldAdded(uint64 indexed pid, uint64 amountTok);
    event YieldPaid(uint64 indexed pid, uint64 amountTok);

    /*━━━━━━━━━━━━━━━━━━━━━━━━━ FUNCTIONS ━━━━━━━━━━━━━━━━━━━━━━━━━*/

    // — configuration —
    function createProtocol(
        address controller,
        uint64 lockWin,
        uint64 minStake
    ) external returns (uint64 pid);

    function addController(
        uint64 pid,
        address controller
    ) external returns (bool added);

    function removeController(
        uint64 pid,
        address controller
    ) external returns (bool removed);

    function swapController(
        uint64 pid,
        address oldController,
        address newController
    ) external returns (bool swapped);

    function setMinStake(uint64 pid, uint64 newMinStake) external;

    // — yield / haircuts —
    // Anyone can call this
    function addYield(uint64 pid, uint64 tok) external;
    function addYieldFrom(uint64 pid, address from, uint64 tok) external;

    function signalHaircut(
        uint64 pid,
        uint64 amt
    ) external returns (uint64 uncollected);

    // Off-chain helper
    function forceHarvest(
        address[] calldata wallets
    ) external;

    // Only controller may call this
    function collectHaircut(
        uint64 pid,
        address to
    ) external returns (uint64 mintedTok);

    // — membership —
    function setMembership(
        uint64[8] calldata addPids,
        uint8 stayMask
    ) external;

}
