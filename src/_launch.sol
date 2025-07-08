// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "./IZRC20.sol"; // adjust the relative path if needed

struct RocketConfig {
    address offerCreator;
    IZRC20 offeringToken;
    IZRC20 invitingToken;
    uint64 totalOfferingSupply;
    uint32 percentToLiquidity;
    uint32 percentOfLiquidityBurned;
    uint32 percentOfLiquidityCreator;
    uint64 liquidityLockedUpTime;
    uint64 liquidityDeployTime;
}

struct RocketState {
    uint64 totalContributed;

}

contract RocketLauncher {

    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=s73UYzaKuII";
    }

}