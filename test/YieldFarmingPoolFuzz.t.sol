// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FarmBase} from "./utils/FarmBase.sol";
import "../src/YieldFarmingPool.sol";

contract YieldFarmingPoolFuzz is FarmBase {
    // Any stake amount within the user's balance is credited exactly and moves the tokens.
    function testFuzz_stake_anyAmount_creditsExactly(uint256 amount_) external {
        // Arrange
        amount_ = bound(amount_, 1, 10_000 ether);

        // Act
        _stake(alice, poolId1, amount_);

        // Assert
        (uint256 staked,,,) = pool.userInfo(poolId1, alice);
        assertEq(staked, amount_);
        assertEq(pool.stakedByToken(address(stakeToken1)), amount_);
        assertEq(stakeToken1.balanceOf(address(pool)), amount_);
    }

    // Withdrawing part of a position returns exactly that amount and leaves the rest staked.
    function testFuzz_withdraw_partial_returnsExactAmount(uint256 stakeAmount_, uint256 withdrawAmount_) external {
        // Arrange
        stakeAmount_ = bound(stakeAmount_, 2, 10_000 ether);
        withdrawAmount_ = bound(withdrawAmount_, 1, stakeAmount_);
        _stake(alice, poolId1, stakeAmount_);
        vm.warp(block.timestamp + 1 days);

        // Act
        vm.prank(alice);
        pool.withdraw(poolId1, withdrawAmount_);

        // Assert
        (uint256 staked,,,) = pool.userInfo(poolId1, alice);
        assertEq(staked, stakeAmount_ - withdrawAmount_);
        assertEq(stakeToken1.balanceOf(alice), 10_000 ether - stakeAmount_ + withdrawAmount_);
    }

    // A solo staker earns the full emission, up to integer rounding.
    function testFuzz_rewards_soloStaker_earnsFullEmission(uint256 stakeAmount_, uint256 elapsed_) external {
        // Arrange
        stakeAmount_ = bound(stakeAmount_, 1 ether, 10_000 ether);
        elapsed_ = bound(elapsed_, 1, 365 days);
        _stake(alice, poolId1, stakeAmount_);

        // Act
        vm.warp(block.timestamp + elapsed_);

        // Assert
        uint256 emitted = elapsed_ * REWARD_RATE;
        uint256 earned = pool.pendingRewards(poolId1, alice);
        assertLe(earned, emitted);
        assertApproxEqAbs(earned, emitted, stakeAmount_ / 1e18 + 1);
    }

    // The sum of what all stakers have earned never exceeds what the pool has emitted.
    function testFuzz_rewards_twoStakers_neverExceedEmission(uint256 aliceAmount_, uint256 bobAmount_, uint256 elapsed_)
        external
    {
        // Arrange
        aliceAmount_ = bound(aliceAmount_, 1 ether, 10_000 ether);
        bobAmount_ = bound(bobAmount_, 1 ether, 10_000 ether);
        elapsed_ = bound(elapsed_, 1, 365 days);
        _stake(alice, poolId1, aliceAmount_);
        _stake(bob, poolId1, bobAmount_);

        // Act
        vm.warp(block.timestamp + elapsed_);

        // Assert
        uint256 total = pool.pendingRewards(poolId1, alice) + pool.pendingRewards(poolId1, bob);
        assertLe(total, elapsed_ * REWARD_RATE);
    }

    // Rewards compound correctly across several stakes: claims plus pending equal the emission.
    function testFuzz_rewards_overMultipleStakes_matchEmission(uint256 first_, uint256 second_, uint256 elapsed_)
        external
    {
        // Arrange
        first_ = bound(first_, 1 ether, 5_000 ether);
        second_ = bound(second_, 1 ether, 5_000 ether);
        elapsed_ = bound(elapsed_, 1, 100 days);
        _stake(alice, poolId1, first_);
        vm.warp(block.timestamp + elapsed_);

        // Act
        _stake(alice, poolId1, second_);
        vm.warp(block.timestamp + elapsed_);

        // Assert
        uint256 total = rewardToken.balanceOf(alice) + pool.pendingRewards(poolId1, alice);
        assertLe(total, 2 * elapsed_ * REWARD_RATE);
        assertApproxEqAbs(total, 2 * elapsed_ * REWARD_RATE, 2 * (first_ + second_) / 1e18 + 4);
    }

    // When the contract is underfunded, paid plus unpaid always equals what was earned.
    function testFuzz_claimRewards_whenUnderfunded_paidPlusUnpaidEqualsEarned(uint256 funding_, uint256 elapsed_)
        external
    {
        // Arrange
        elapsed_ = bound(elapsed_, 1000, 30 days);
        YieldFarmingPool p = new YieldFarmingPool(address(rewardToken));
        bytes32 id = p.createPool(address(stakeToken1), REWARD_RATE);
        vm.startPrank(alice);
        stakeToken1.approve(address(p), type(uint256).max);
        p.stake(id, 1000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + elapsed_);
        uint256 earned = p.pendingRewards(id, alice);
        funding_ = bound(funding_, 1, earned - 1);
        rewardToken.transfer(address(p), funding_);

        // Act
        vm.prank(alice);
        p.claimRewards(id);

        // Assert
        assertEq(rewardToken.balanceOf(alice), funding_);
        assertEq(p.pendingRewards(id, alice), earned - funding_);
    }

    // The owner can never recover staked principal, whatever amount is requested.
    function testFuzz_emergencyWithdraw_neverTouchesStakedPrincipal(uint256 staked_, uint256 donated_, uint256 amount_)
        external
    {
        // Arrange
        staked_ = bound(staked_, 1, 10_000 ether);
        donated_ = bound(donated_, 0, 1000 ether);
        amount_ = bound(amount_, 0, 20_000 ether);
        _stake(alice, poolId1, staked_);
        assertTrue(stakeToken1.transfer(address(pool), donated_));

        // Act
        if (amount_ > donated_) {
            vm.expectRevert(abi.encodeWithSelector(AmountExceedsWithdrawable.selector, amount_, donated_));
        }
        pool.emergencyWithdraw(address(stakeToken1), amount_);

        // Assert
        assertGe(stakeToken1.balanceOf(address(pool)), staked_);
    }

    // Any reward rate above the maximum is rejected when creating a pool.
    function testFuzz_createPool_rateAboveMax_reverts(uint256 rate_) external {
        // Arrange
        rate_ = bound(rate_, pool.MAX_REWARD_RATE() + 1, type(uint256).max);

        // Act / Assert
        vm.expectRevert(abi.encodeWithSelector(RewardRateTooHigh.selector, rate_));
        pool.createPool(address(stakeToken1), rate_);
    }

    // Any in-range rate update is stored.
    function testFuzz_updatePoolRewardRate_inRange_storesRate(uint256 rate_) external {
        // Arrange
        rate_ = bound(rate_, 0, pool.MAX_REWARD_RATE());

        // Act
        pool.updatePoolRewardRate(poolId1, rate_);

        // Assert
        (,, uint256 stored,,,) = pool.pools(poolId1);
        assertEq(stored, rate_);
    }
}
