// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/YieldFarmingPool.sol";
import "../src/MockToken.sol";

contract YieldFarmingPoolFuzzTest is Test {
    YieldFarmingPool public yieldFarmingPool;
    MockToken public rewardToken;
    MockToken public stakingToken1;

    address public owner;
    address public user1;
    address public user2;

    bytes32 public poolId1;

    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e18;
    uint256 public constant REWARD_RATE    = 1e16;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        rewardToken   = new MockToken("Reward Token", "RWD", INITIAL_SUPPLY);
        stakingToken1 = new MockToken("Staking Token 1", "STK1", INITIAL_SUPPLY);

        yieldFarmingPool = new YieldFarmingPool(address(rewardToken));

        stakingToken1.transfer(user1, 10_000 * 1e18);
        stakingToken1.transfer(user2, 10_000 * 1e18);

        rewardToken.transfer(address(yieldFarmingPool), 500_000 * 1e18);

        poolId1 = yieldFarmingPool.createPool(address(stakingToken1), REWARD_RATE);

        vm.prank(user1);
        stakingToken1.approve(address(yieldFarmingPool), type(uint256).max);

        vm.prank(user2);
        stakingToken1.approve(address(yieldFarmingPool), type(uint256).max);
    }

    /// @dev Any valid stake amount is correctly recorded.
    function testFuzz_StakeAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, 10_000 * 1e18);

        uint256 balanceBefore = stakingToken1.balanceOf(user1);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount);

        (uint256 userAmount,,) = yieldFarmingPool.userInfo(poolId1, user1);
        (, uint256 totalStaked,,,,) = yieldFarmingPool.pools(poolId1);

        assertEq(userAmount, amount);
        assertEq(totalStaked, amount);
        assertEq(stakingToken1.balanceOf(user1), balanceBefore - amount);
        assertEq(stakingToken1.balanceOf(address(yieldFarmingPool)), amount);
    }

    /// @dev Partial withdraw leaves correct remaining amounts.
    function testFuzz_PartialWithdraw(uint256 stakeAmount, uint256 withdrawAmount) public {
        stakeAmount    = bound(stakeAmount, 1, 10_000 * 1e18);
        withdrawAmount = bound(withdrawAmount, 1, stakeAmount);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, stakeAmount);

        vm.warp(block.timestamp + 1);

        vm.prank(user1);
        yieldFarmingPool.withdraw(poolId1, withdrawAmount);

        (uint256 userAmount,,) = yieldFarmingPool.userInfo(poolId1, user1);
        (, uint256 totalStaked,,,,) = yieldFarmingPool.pools(poolId1);

        assertEq(userAmount, stakeAmount - withdrawAmount);
        assertEq(totalStaked, stakeAmount - withdrawAmount);
    }

    /// @dev A sole staker earns all rewards. Tolerance accounts for integer division
    ///      dust: floor(N*1e18/amount)*amount/1e18 can differ by up to amount/1e18 + 1.
    function testFuzz_SoloStakerGetsAllRewards(uint256 stakeAmount, uint256 timeElapsed) public {
        stakeAmount = bound(stakeAmount, 1 ether, 10_000 * 1e18);
        timeElapsed = bound(timeElapsed, 1, 365 days);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, stakeAmount);

        vm.warp(block.timestamp + timeElapsed);

        uint256 pending  = yieldFarmingPool.pendingRewards(poolId1, user1);
        uint256 expected = timeElapsed * REWARD_RATE;
        uint256 dust     = stakeAmount / 1e18 + 1;

        assertApproxEqAbs(pending, expected, dust);
        assertLe(pending, expected); // never overpay
    }

    /// @dev Two simultaneous stakers split rewards proportionally and their
    ///      rewards sum to the total generated.
    function testFuzz_TwoUsersRewardsProportional(
        uint256 amount1,
        uint256 amount2,
        uint256 timeElapsed
    ) public {
        amount1     = bound(amount1, 1 ether, 5_000 * 1e18);
        amount2     = bound(amount2, 1 ether, 5_000 * 1e18);
        timeElapsed = bound(timeElapsed, 1, 365 days);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount1);

        vm.prank(user2);
        yieldFarmingPool.stake(poolId1, amount2);

        vm.warp(block.timestamp + timeElapsed);

        uint256 pending1 = yieldFarmingPool.pendingRewards(poolId1, user1);
        uint256 pending2 = yieldFarmingPool.pendingRewards(poolId1, user2);
        uint256 total    = timeElapsed * REWARD_RATE;

        // Dust tolerance: each user's rounding can lose up to (totalStaked/1e18 + 1)
        uint256 dust = (amount1 + amount2) / 1e18 + 2;

        // Sum of rewards is within dust of total generated and never exceeds it
        assertApproxEqAbs(pending1 + pending2, total, dust);
        assertLe(pending1 + pending2, total);

        // Proportionality: larger staker earns more
        if (amount1 > amount2) assertGe(pending1, pending2);
        if (amount2 > amount1) assertGe(pending2, pending1);
    }

    /// @dev Re-staking auto-compounds: the second claim is larger than the first.
    function testFuzz_RewardsCompoundOverMultipleStakes(
        uint256 firstStake,
        uint256 addedStake,
        uint256 time1,
        uint256 time2
    ) public {
        firstStake = bound(firstStake, 1 ether, 5_000 * 1e18);
        addedStake = bound(addedStake, 1 ether, 5_000 * 1e18);
        time1      = bound(time1, 1, 90 days);
        time2      = bound(time2, 1, 90 days);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, firstStake);

        vm.warp(block.timestamp + time1);

        // Re-staking triggers auto-claim of first-period rewards
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, addedStake);

        uint256 firstClaim = rewardToken.balanceOf(user1);
        assertGt(firstClaim, 0);

        vm.warp(block.timestamp + time2);

        vm.prank(user1);
        yieldFarmingPool.claimRewards(poolId1);

        uint256 finalBalance = rewardToken.balanceOf(user1);
        assertGt(finalBalance, firstClaim);
    }
}
