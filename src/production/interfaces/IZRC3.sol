// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC1.sol";

/*──────────── Z-Flash-Loan (64-bit amounts) ────────────*/
interface IZRC3FlashBorrower {
    /**
     * @dev Called by the lender after `flashLoan` transfers the tokens.
     * MUST return the selector below or the entire flash-loan call reverts.
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint64 amount,
        uint64 fee,
        bytes calldata data
    ) external returns (bytes32);
}

interface IZRC3FlashLender {
    /*━━━━━━━━━━━━━━━━━━━━ ERRORS ━━━━━━━━━━━━━━━━━━━━*/

    /// Unsupported token was requested.
    error UnsupportedToken(address token);

    /// `amount` parameter was zero.
    error FlashAmountZero();

    /// Requested `amount` exceeds `maxFlashLoan(token)`.
    error FlashAmountExceedsMax(uint64 requested, uint64 maxAvailable);

    /// Receiver failed to return the required hash from `onFlashLoan`.
    error FlashCallbackFailed();

    /// Loan plus fee was not repaid before function end.
    error FlashLoanNotRepaid();

    /*━━━━━━━━━━━━━━━━━━━━ EVENTS ━━━━━━━━━━━━━━━━━━━━*/

    /**
     * @dev Emitted when a flash loan completes successfully.
     *
     * @param receiver  Contract that executed the flash-loan callback.
     * @param initiator Original `msg.sender` that triggered the loan.
     * @param token     Address of the token lent.
     * @param amount    Amount borrowed.
     * @param fee       Fee charged (may be zero).
     */
    event FlashLoan(
        address indexed receiver,
        address indexed initiator,
        address indexed token,
        uint64 amount,
        uint64 fee
    );

    /*━━━━━━━━━━━━━━━━━━ FUNCTIONS ━━━━━━━━━━━━━━━━━━*/

    function maxFlashLoan(address token) external view returns (uint64);

    function flashFee(address token, uint64 amount)
        external
        view
        returns (uint64);

    function flashLoan(
        IZRC3FlashBorrower receiver,
        address token,
        uint64 amount,
        bytes calldata data
    ) external returns (bool);
}

/**
 * @title IZRC3
 * @dev Full interface for a ZRC-1 token with integrated Z-Flash lending/borrowing.
 */
interface IZRC3 is IZRC1, IZRC3FlashBorrower, IZRC3FlashLender {}
