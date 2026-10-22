// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {YieldFarmingPool} from "../../src/YieldFarmingPool.sol";
import {MockToken} from "../mocks/MockToken.sol";

/// @dev Shared deployment and helpers for the YieldFarmingPool test suites.
abstract contract FarmBase is Test {
    uint256 internal constant SUPPLY = 1_000_000;
    uint256 internal constant REWARD_RATE = 1e16;
    uint256 internal constant FUNDING = 500_000 ether;

    YieldFarmingPool internal pool;
    MockToken internal rewardToken;
    MockToken internal stakeToken1;
    MockToken internal stakeToken2;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    bytes32 internal poolId1;
    bytes32 internal poolId2;

    function setUp() public virtual {
        rewardToken = new MockToken("Reward", "RWD", SUPPLY);
        stakeToken1 = new MockToken("Stake 1", "STK1", SUPPLY);
        stakeToken2 = new MockToken("Stake 2", "STK2", SUPPLY);
        pool = new YieldFarmingPool(address(rewardToken));

        rewardToken.transfer(address(pool), FUNDING);
        poolId1 = pool.createPool(address(stakeToken1), REWARD_RATE);
        poolId2 = pool.createPool(address(stakeToken2), REWARD_RATE * 2);

        _fund(stakeToken1, alice, 10_000 ether);
        _fund(stakeToken1, bob, 10_000 ether);
        _fund(stakeToken2, alice, 10_000 ether);
        _fund(stakeToken2, carol, 10_000 ether);
    }

    function _fund(MockToken token_, address user_, uint256 amount_) internal {
        assertTrue(token_.transfer(user_, amount_));
        vm.prank(user_);
        token_.approve(address(pool), type(uint256).max);
    }

    function _stake(address user_, bytes32 poolId_, uint256 amount_) internal {
        vm.prank(user_);
        pool.stake(poolId_, amount_);
    }
}
