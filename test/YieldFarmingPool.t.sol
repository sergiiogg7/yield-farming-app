// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FarmBase} from "./utils/FarmBase.sol";
import {MockToken} from "./mocks/MockToken.sol";
import "../src/YieldFarmingPool.sol";

/// @dev Staking token that re-enters `stake` from inside `transferFrom`.
contract ReentrantStakeToken is ERC20 {
    YieldFarmingPool public pool;
    bytes32 public poolId;

    constructor() ERC20("Evil", "EVIL") {}

    function setTarget(YieldFarmingPool pool_, bytes32 poolId_) external {
        pool = pool_;
        poolId = poolId_;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function transferFrom(address from_, address to_, uint256 amount_) public override returns (bool) {
        pool.stake(poolId, 1);
        return super.transferFrom(from_, to_, amount_);
    }
}

contract YieldFarmingPoolTest is FarmBase {
    // -------------------------------------------------------------------------
    // constructor
    // -------------------------------------------------------------------------

    function test_constructor_withZeroRewardToken_revertsWithInvalidRewardToken() external {
        // Arrange / Act / Assert
        vm.expectRevert(InvalidRewardToken.selector);
        new YieldFarmingPool(address(0));
    }

    function test_constructor_setsRewardTokenAndOwner() external view {
        // Assert
        assertEq(address(pool.rewardToken()), address(rewardToken));
        assertEq(pool.owner(), address(this));
    }

    // -------------------------------------------------------------------------
    // createPool
    // -------------------------------------------------------------------------

    function test_createPool_storesPoolAndEmits() external {
        // Arrange
        MockToken token = new MockToken("T", "T", 1);
        bytes32 expectedId = keccak256(abi.encodePacked(address(token), uint256(5), block.timestamp, block.chainid));
        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.PoolCreated(expectedId, address(token), 5);

        // Act
        bytes32 id = pool.createPool(address(token), 5);

        // Assert
        assertEq(id, expectedId);
        (address t, uint256 totalStaked, uint256 rate, uint256 last, uint256 rpt, bool active) = pool.pools(id);
        assertEq(t, address(token));
        assertEq(totalStaked, 0);
        assertEq(rate, 5);
        assertEq(last, block.timestamp);
        assertEq(rpt, 0);
        assertTrue(active);
        assertEq(pool.getActivePoolsCount(), 3);
        assertEq(pool.activePools(2), id);
    }

    function test_createPool_withZeroToken_revertsWithInvalidTokenAddress() external {
        // Arrange / Act / Assert
        vm.expectRevert(InvalidTokenAddress.selector);
        pool.createPool(address(0), 1);
    }

    function test_createPool_withZeroRate_revertsWithRewardRateMustBePositive() external {
        // Arrange / Act / Assert
        vm.expectRevert(RewardRateMustBePositive.selector);
        pool.createPool(address(stakeToken1), 0);
    }

    function test_createPool_withRateAboveMax_revertsWithRewardRateTooHigh() external {
        // Arrange
        uint256 tooHigh = pool.MAX_REWARD_RATE() + 1;

        // Act / Assert
        vm.expectRevert(abi.encodeWithSelector(RewardRateTooHigh.selector, tooHigh));
        pool.createPool(address(stakeToken1), tooHigh);
    }

    function test_createPool_byNonOwner_reverts() external {
        // Arrange / Act / Assert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.createPool(address(stakeToken1), 1);
    }

    function test_createPool_withSameParametersInSameBlock_revertsWithPoolAlreadyExists() external {
        // Arrange / Act / Assert
        vm.expectRevert(abi.encodeWithSelector(PoolAlreadyExists.selector, poolId1));
        pool.createPool(address(stakeToken1), REWARD_RATE);
    }

    function test_createPool_withSameParametersLater_createsDistinctPool() external {
        // Arrange
        vm.warp(block.timestamp + 1);

        // Act
        bytes32 later = pool.createPool(address(stakeToken1), REWARD_RATE);

        // Assert
        assertTrue(later != poolId1);
    }

    // -------------------------------------------------------------------------
    // updatePoolRewardRate
    // -------------------------------------------------------------------------

    function test_updatePoolRewardRate_settlesBeforeChangingRate() external {
        // Arrange: 1000 tokens staked for 100s at the old rate
        _stake(alice, poolId1, 1000 ether);
        vm.warp(block.timestamp + 100);

        // Act
        vm.expectEmit(true, false, false, true);
        emit YieldFarmingPool.PoolUpdated(poolId1, 5e16);
        pool.updatePoolRewardRate(poolId1, 5e16);
        vm.warp(block.timestamp + 100);

        // Assert: 100s at 1e16 plus 100s at 5e16
        assertEq(pool.pendingRewards(poolId1, alice), 100 * REWARD_RATE + 100 * 5e16);
    }

    function test_updatePoolRewardRate_toZero_stopsEmission() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        pool.updatePoolRewardRate(poolId1, 0);

        // Act
        vm.warp(block.timestamp + 1 days);

        // Assert
        assertEq(pool.pendingRewards(poolId1, alice), 0);
    }

    function test_updatePoolRewardRate_byNonOwner_reverts() external {
        // Arrange / Act / Assert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.updatePoolRewardRate(poolId1, 1);
    }

    function test_updatePoolRewardRate_onUnknownPool_revertsWithPoolNotActive() external {
        // Arrange
        bytes32 unknown = keccak256("unknown");

        // Act / Assert
        vm.expectRevert(abi.encodeWithSelector(PoolNotActive.selector, unknown));
        pool.updatePoolRewardRate(unknown, 1);
    }

    function test_updatePoolRewardRate_aboveMax_revertsWithRewardRateTooHigh() external {
        // Arrange
        uint256 tooHigh = pool.MAX_REWARD_RATE() + 1;

        // Act / Assert
        vm.expectRevert(abi.encodeWithSelector(RewardRateTooHigh.selector, tooHigh));
        pool.updatePoolRewardRate(poolId1, tooHigh);
    }

    // -------------------------------------------------------------------------
    // pause and ownership
    // -------------------------------------------------------------------------

    function test_pause_andUnpause_toggleState() external {
        // Arrange / Act
        pool.pause();

        // Assert
        assertTrue(pool.paused());
        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_pause_byNonOwner_reverts() external {
        // Arrange / Act / Assert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.pause();
    }

    function test_unpause_byNonOwner_reverts() external {
        // Arrange
        pool.pause();

        // Act / Assert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.unpause();
    }

    function test_transferOwnership_isTwoStep() external {
        // Arrange / Act
        pool.transferOwnership(alice);

        // Assert
        assertEq(pool.owner(), address(this));
        assertEq(pool.pendingOwner(), alice);
        vm.prank(alice);
        pool.acceptOwnership();
        assertEq(pool.owner(), alice);
    }

    // -------------------------------------------------------------------------
    // stake
    // -------------------------------------------------------------------------

    function test_stake_updatesStateAndMovesTokens() external {
        // Arrange
        uint256 balanceBefore = stakeToken1.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.Staked(poolId1, alice, 100 ether);

        // Act
        _stake(alice, poolId1, 100 ether);

        // Assert
        (uint256 amount,, uint256 lastClaim, uint256 unpaid) = pool.userInfo(poolId1, alice);
        (, uint256 totalStaked,,,,) = pool.pools(poolId1);
        assertEq(amount, 100 ether);
        assertEq(lastClaim, block.timestamp);
        assertEq(unpaid, 0);
        assertEq(totalStaked, 100 ether);
        assertEq(pool.stakedByToken(address(stakeToken1)), 100 ether);
        assertEq(stakeToken1.balanceOf(alice), balanceBefore - 100 ether);
        assertEq(stakeToken1.balanceOf(address(pool)), 100 ether);
    }

    function test_stake_onUnknownPool_revertsWithPoolNotActive() external {
        // Arrange
        bytes32 unknown = keccak256("unknown");

        // Act / Assert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolNotActive.selector, unknown));
        pool.stake(unknown, 1 ether);
    }

    function test_stake_withZeroAmount_revertsWithAmountMustBePositive() external {
        // Arrange / Act / Assert
        vm.prank(alice);
        vm.expectRevert(AmountMustBePositive.selector);
        pool.stake(poolId1, 0);
    }

    function test_stake_whenPaused_reverts() external {
        // Arrange
        pool.pause();

        // Act / Assert
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.stake(poolId1, 1 ether);
    }

    function test_stake_withExistingPosition_paysPendingRewards() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        vm.warp(block.timestamp + 100);
        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.RewardClaimed(poolId1, alice, 100 * REWARD_RATE);

        // Act
        _stake(alice, poolId1, 500 ether);

        // Assert
        assertEq(rewardToken.balanceOf(alice), 100 * REWARD_RATE);
        (uint256 amount,,,) = pool.userInfo(poolId1, alice);
        assertEq(amount, 1500 ether);
        assertEq(pool.pendingRewards(poolId1, alice), 0);
    }

    function test_stake_inTwoPools_keepsPositionsIndependent() external {
        // Arrange / Act
        _stake(alice, poolId1, 100 ether);
        _stake(alice, poolId2, 300 ether);

        // Assert
        (uint256 a1,,,) = pool.userInfo(poolId1, alice);
        (uint256 a2,,,) = pool.userInfo(poolId2, alice);
        assertEq(a1, 100 ether);
        assertEq(a2, 300 ether);
        assertEq(pool.stakedByToken(address(stakeToken1)), 100 ether);
        assertEq(pool.stakedByToken(address(stakeToken2)), 300 ether);
    }

    function test_stake_withReentrantToken_revertsWithReentrancyGuard() external {
        // Arrange
        ReentrantStakeToken evil = new ReentrantStakeToken();
        bytes32 evilPool = pool.createPool(address(evil), 1e16);
        evil.setTarget(pool, evilPool);
        evil.mint(alice, 10 ether);
        vm.startPrank(alice);
        evil.approve(address(pool), type(uint256).max);

        // Act / Assert
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pool.stake(evilPool, 5 ether);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // withdraw
    // -------------------------------------------------------------------------

    function test_withdraw_partial_paysRewardsAndKeepsPosition() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        vm.warp(block.timestamp + 100);

        // Act
        vm.prank(alice);
        pool.withdraw(poolId1, 400 ether);

        // Assert
        (uint256 amount,,,) = pool.userInfo(poolId1, alice);
        assertEq(amount, 600 ether);
        assertEq(rewardToken.balanceOf(alice), 100 * REWARD_RATE);
        assertEq(stakeToken1.balanceOf(alice), 10_000 ether - 600 ether);
        assertEq(pool.stakedByToken(address(stakeToken1)), 600 ether);
    }

    function test_withdraw_full_deletesUserInfo() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        vm.warp(block.timestamp + 100);
        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.Withdrawn(poolId1, alice, 1000 ether);

        // Act
        vm.prank(alice);
        pool.withdraw(poolId1, 1000 ether);

        // Assert
        (uint256 amount, uint256 debt, uint256 lastClaim, uint256 unpaid) = pool.userInfo(poolId1, alice);
        assertEq(amount, 0);
        assertEq(debt, 0);
        assertEq(lastClaim, 0);
        assertEq(unpaid, 0);
        assertEq(stakeToken1.balanceOf(alice), 10_000 ether);
    }

    function test_withdraw_whenPaused_stillWorks() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        pool.pause();

        // Act
        vm.prank(alice);
        pool.withdraw(poolId1, 1000 ether);

        // Assert
        assertEq(stakeToken1.balanceOf(alice), 10_000 ether);
    }

    function test_withdraw_withZeroAmount_revertsWithAmountMustBePositive() external {
        // Arrange / Act / Assert
        vm.prank(alice);
        vm.expectRevert(AmountMustBePositive.selector);
        pool.withdraw(poolId1, 0);
    }

    function test_withdraw_moreThanStaked_revertsWithInsufficientStakedAmount() external {
        // Arrange
        _stake(alice, poolId1, 100 ether);

        // Act / Assert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientStakedAmount.selector, 100 ether, 101 ether));
        pool.withdraw(poolId1, 101 ether);
    }

    function test_withdraw_fromPoolWithoutPosition_revertsWithInsufficientStakedAmount() external {
        // Arrange / Act / Assert
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientStakedAmount.selector, 0, 1 ether));
        pool.withdraw(poolId1, 1 ether);
    }

    // -------------------------------------------------------------------------
    // claimRewards and reward math
    // -------------------------------------------------------------------------

    function test_claimRewards_afterTime_paysExactRewards() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        vm.warp(block.timestamp + 100);
        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.RewardClaimed(poolId1, alice, 100 * REWARD_RATE);

        // Act
        vm.prank(alice);
        pool.claimRewards(poolId1);

        // Assert
        assertEq(rewardToken.balanceOf(alice), 100 * REWARD_RATE);
        assertEq(pool.pendingRewards(poolId1, alice), 0);
    }

    function test_claimRewards_twiceInSameBlock_revertsWithNoRewardsToClaim() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        vm.warp(block.timestamp + 100);
        vm.startPrank(alice);
        pool.claimRewards(poolId1);

        // Act / Assert
        vm.expectRevert(NoRewardsToClaim.selector);
        pool.claimRewards(poolId1);
        vm.stopPrank();
    }

    function test_claimRewards_withoutPosition_revertsWithNoRewardsToClaim() external {
        // Arrange / Act / Assert
        vm.prank(alice);
        vm.expectRevert(NoRewardsToClaim.selector);
        pool.claimRewards(poolId1);
    }

    function test_claimRewards_onUnknownPool_revertsWithPoolNotActive() external {
        // Arrange
        bytes32 unknown = keccak256("unknown");

        // Act / Assert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolNotActive.selector, unknown));
        pool.claimRewards(unknown);
    }

    function test_claimRewards_whenPaused_reverts() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        vm.warp(block.timestamp + 100);
        pool.pause();

        // Act / Assert
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.claimRewards(poolId1);
    }

    function test_rewards_areProportionalToStake() external {
        // Arrange: Alice stakes 3x Bob's amount at the same time
        _stake(alice, poolId1, 3000 ether);
        _stake(bob, poolId1, 1000 ether);

        // Act
        vm.warp(block.timestamp + 400);

        // Assert
        assertEq(pool.pendingRewards(poolId1, alice), 3 * 100 * REWARD_RATE);
        assertEq(pool.pendingRewards(poolId1, bob), 1 * 100 * REWARD_RATE);
    }

    function test_rewards_whileNobodyStaked_areNotAccrued() external {
        // Arrange
        vm.warp(block.timestamp + 10 days);

        // Act
        _stake(alice, poolId1, 1000 ether);
        vm.warp(block.timestamp + 100);

        // Assert
        assertEq(pool.pendingRewards(poolId1, alice), 100 * REWARD_RATE);
    }

    function test_rewards_inDifferentPools_useTheirOwnRates() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);
        _stake(alice, poolId2, 1000 ether);

        // Act
        vm.warp(block.timestamp + 100);

        // Assert
        assertEq(pool.pendingRewards(poolId1, alice), 100 * REWARD_RATE);
        assertEq(pool.pendingRewards(poolId2, alice), 100 * REWARD_RATE * 2);
    }

    // -------------------------------------------------------------------------
    // underfunded reward balance
    // -------------------------------------------------------------------------

    function _underfundedPool(uint256 funding_) internal returns (YieldFarmingPool p, bytes32 id) {
        p = new YieldFarmingPool(address(rewardToken));
        id = p.createPool(address(stakeToken1), REWARD_RATE);
        rewardToken.transfer(address(p), funding_);
        vm.prank(alice);
        stakeToken1.approve(address(p), type(uint256).max);
        vm.prank(alice);
        p.stake(id, 1000 ether);
    }

    function test_claimRewards_whenUnderfunded_paysAvailableAndKeepsUnpaid() external {
        // Arrange: 1000s at 1e16/s earns 10 tokens but only 4 are available
        (YieldFarmingPool p, bytes32 id) = _underfundedPool(4 ether);
        vm.warp(block.timestamp + 1000);

        // Act
        vm.prank(alice);
        p.claimRewards(id);

        // Assert
        assertEq(rewardToken.balanceOf(alice), 4 ether);
        assertEq(p.pendingRewards(id, alice), 6 ether);
    }

    function test_claimRewards_afterTopUp_paysRemainingUnpaidRewards() external {
        // Arrange
        (YieldFarmingPool p, bytes32 id) = _underfundedPool(4 ether);
        vm.warp(block.timestamp + 1000);
        vm.prank(alice);
        p.claimRewards(id);
        rewardToken.transfer(address(p), 100 ether);

        // Act
        vm.prank(alice);
        p.claimRewards(id);

        // Assert
        assertEq(rewardToken.balanceOf(alice), 10 ether);
        assertEq(p.pendingRewards(id, alice), 0);
    }

    function test_claimRewards_whenNoRewardBalance_revertsWithRewardBalanceDepleted() external {
        // Arrange
        (YieldFarmingPool p, bytes32 id) = _underfundedPool(0);
        vm.warp(block.timestamp + 1000);

        // Act / Assert
        vm.prank(alice);
        vm.expectRevert(RewardBalanceDepleted.selector);
        p.claimRewards(id);
        assertEq(p.pendingRewards(id, alice), 10 ether);
    }

    function test_withdraw_whenUnderfunded_returnsPrincipalAndKeepsUnpaidRewards() external {
        // Arrange
        (YieldFarmingPool p, bytes32 id) = _underfundedPool(0);
        vm.warp(block.timestamp + 1000);

        // Act
        vm.prank(alice);
        p.withdraw(id, 1000 ether);

        // Assert: principal returned, rewards owed are preserved and claimable after funding
        assertEq(stakeToken1.balanceOf(alice), 10_000 ether);
        (uint256 amount,,, uint256 unpaid) = p.userInfo(id, alice);
        assertEq(amount, 0);
        assertEq(unpaid, 10 ether);
        rewardToken.transfer(address(p), 10 ether);
        vm.prank(alice);
        p.claimRewards(id);
        assertEq(rewardToken.balanceOf(alice), 10 ether);
    }

    function test_stake_whenUnderfunded_keepsUnpaidRewardsForLater() external {
        // Arrange
        (YieldFarmingPool p, bytes32 id) = _underfundedPool(0);
        vm.warp(block.timestamp + 1000);

        // Act
        vm.prank(alice);
        p.stake(id, 1 ether);

        // Assert
        assertEq(p.pendingRewards(id, alice), 10 ether);
    }

    // -------------------------------------------------------------------------
    // pool that stakes the reward token
    // -------------------------------------------------------------------------

    function test_rewards_whenStakingTokenIsRewardToken_neverPaidFromPrincipal() external {
        // Arrange: pool stakes the reward token and holds no reward surplus
        YieldFarmingPool p = new YieldFarmingPool(address(rewardToken));
        bytes32 id = p.createPool(address(rewardToken), REWARD_RATE);
        rewardToken.transfer(alice, 1000 ether);
        vm.startPrank(alice);
        rewardToken.approve(address(p), type(uint256).max);
        p.stake(id, 1000 ether);
        vm.warp(block.timestamp + 1000);

        // Act / Assert: no surplus, so the claim reverts instead of paying out of staked tokens
        vm.expectRevert(RewardBalanceDepleted.selector);
        p.claimRewards(id);
        vm.stopPrank();
        assertEq(rewardToken.balanceOf(address(p)), 1000 ether);
    }

    function test_withdraw_whenStakingTokenIsRewardToken_paysOnlySurplusAsRewards() external {
        // Arrange: 3 tokens of surplus on top of the principal
        YieldFarmingPool p = new YieldFarmingPool(address(rewardToken));
        bytes32 id = p.createPool(address(rewardToken), REWARD_RATE);
        rewardToken.transfer(alice, 1000 ether);
        rewardToken.transfer(address(p), 3 ether);
        vm.startPrank(alice);
        rewardToken.approve(address(p), type(uint256).max);
        p.stake(id, 1000 ether);
        vm.warp(block.timestamp + 1000);

        // Act
        p.withdraw(id, 1000 ether);
        vm.stopPrank();

        // Assert: principal back plus only the 3 tokens of surplus, 7 remain unpaid
        assertEq(rewardToken.balanceOf(alice), 1003 ether);
        assertEq(rewardToken.balanceOf(address(p)), 0);
        (,,, uint256 unpaid) = p.userInfo(id, alice);
        assertEq(unpaid, 7 ether);
    }

    // -------------------------------------------------------------------------
    // emergencyWithdraw
    // -------------------------------------------------------------------------

    function test_emergencyWithdraw_ofUnrelatedToken_sendsToOwnerAndEmits() external {
        // Arrange
        MockToken stray = new MockToken("Stray", "STR", 10);
        assertTrue(stray.transfer(address(pool), 5 ether));
        vm.expectEmit(true, false, false, true);
        emit YieldFarmingPool.EmergencyWithdrawn(address(stray), 5 ether);

        // Act
        pool.emergencyWithdraw(address(stray), 5 ether);

        // Assert
        assertEq(stray.balanceOf(address(pool)), 0);
    }

    function test_emergencyWithdraw_ofUnspentRewards_succeeds() external {
        // Arrange
        uint256 ownerBefore = rewardToken.balanceOf(address(this));

        // Act
        pool.emergencyWithdraw(address(rewardToken), FUNDING);

        // Assert
        assertEq(rewardToken.balanceOf(address(this)), ownerBefore + FUNDING);
    }

    function test_emergencyWithdraw_ofStakedTokens_revertsWithAmountExceedsWithdrawable() external {
        // Arrange
        _stake(alice, poolId1, 1000 ether);

        // Act / Assert
        vm.expectRevert(abi.encodeWithSelector(AmountExceedsWithdrawable.selector, 1, 0));
        pool.emergencyWithdraw(address(stakeToken1), 1);
    }

    function test_emergencyWithdraw_ofStakedTokensSurplus_onlyAllowsDonatedAmount() external {
        // Arrange: someone donates 10 tokens on top of the staked principal
        _stake(alice, poolId1, 1000 ether);
        assertTrue(stakeToken1.transfer(address(pool), 10 ether));

        // Act
        pool.emergencyWithdraw(address(stakeToken1), 10 ether);

        // Assert
        assertEq(stakeToken1.balanceOf(address(pool)), 1000 ether);
        vm.expectRevert(abi.encodeWithSelector(AmountExceedsWithdrawable.selector, 1, 0));
        pool.emergencyWithdraw(address(stakeToken1), 1);
    }

    function test_emergencyWithdraw_byNonOwner_reverts() external {
        // Arrange / Act / Assert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.emergencyWithdraw(address(rewardToken), 1);
    }

    // -------------------------------------------------------------------------
    // views
    // -------------------------------------------------------------------------

    function test_getPoolEncodedData_returnsPackedFields() external view {
        // Arrange
        (address t, uint256 total, uint256 rate, uint256 last, uint256 rpt, bool active) = pool.pools(poolId1);

        // Act / Assert
        assertEq(pool.getPoolEncodedData(poolId1), abi.encodePacked(t, total, rate, last, rpt, active));
    }

    function test_getUserHash_matchesDomainSeparatedHash() external view {
        // Assert
        assertEq(pool.getUserHash(poolId1, alice), keccak256(abi.encodePacked(poolId1, alice, "YIELD_FARMING_USER")));
    }

    function test_getActivePools_returnsAllPoolIds() external view {
        // Arrange
        bytes32[] memory ids = pool.getActivePools();

        // Assert
        assertEq(ids.length, 2);
        assertEq(ids[0], poolId1);
        assertEq(ids[1], poolId2);
    }
}
