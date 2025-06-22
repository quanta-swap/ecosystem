// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


/*──────── Z-Flash-Loan (64-bit amounts) ────────*/
interface IZ156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint64 amount,
        uint64 fee,
        bytes calldata data
    ) external returns (bytes32);
}

interface IZ156FlashLender {
    function maxFlashLoan(address token) external view returns (uint64);

    function flashFee(
        address token,
        uint64 amount
    ) external view returns (uint64);

    function flashLoan(
        IZ156FlashBorrower receiver,
        address token,
        uint64 amount,
        bytes calldata data
    ) external returns (bool);
}