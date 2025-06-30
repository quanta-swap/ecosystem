// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC1.sol";

interface IZRC4 is IZRC1 {
    function mint(address to, uint64 amount) external;
}