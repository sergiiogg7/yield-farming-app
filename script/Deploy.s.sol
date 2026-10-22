// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {YieldFarmingPool} from "../src/YieldFarmingPool.sol";

/// @notice Deploys YieldFarmingPool with the reward token read from the environment.
/// @dev Pools are created afterwards by the owner with `createPool`.
contract Deploy is Script {
    function run() external returns (YieldFarmingPool pool) {
        address rewardToken = vm.envAddress("REWARD_TOKEN");

        vm.startBroadcast();
        pool = new YieldFarmingPool(rewardToken);
        vm.stopBroadcast();

        console.log("YieldFarmingPool deployed at:", address(pool));
    }
}
