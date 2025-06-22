// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IZRC20} from "./IZRC20.sol";

/*──────── Reward token must expose a mint primitive ────────*/
interface IZRC2 is IZRC20 {
    function mint(address to, uint64 amount) external;
}
