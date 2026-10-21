// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/YieldFarmingPool.sol";
import "../src/MockToken.sol";

// OZ errors declared locally so they are in scope for expectRevert selectors
error OwnableUnauthorizedAccount(address account);
error EnforcedPause();

contract YieldFarmingPoolTest is Test {
    YieldFarmingPool public yieldFarmingPool;
    MockToken public rewardToken;
    MockToken public stakingToken1;
    MockToken public stakingToken2;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    bytes32 public poolId1;
    bytes32 public poolId2;

    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e18;
    uint256 public constant REWARD_RATE = 1e16;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        rewardToken   = new MockToken("Reward Token", "RWD", INITIAL_SUPPLY);
        stakingToken1 = new MockToken("Staking Token 1", "STK1", INITIAL_SUPPLY);
        stakingToken2 = new MockToken("Staking Token 2", "STK2", INITIAL_SUPPLY);

        yieldFarmingPool = new YieldFarmingPool(address(rewardToken));

        stakingToken1.transfer(user1, 10_000 * 1e18);
        stakingToken1.transfer(user2, 10_000 * 1e18);
        stakingToken2.transfer(user1, 10_000 * 1e18);
        stakingToken2.transfer(user3, 10_000 * 1e18);

        rewardToken.transfer(address(yieldFarmingPool), 500_000 * 1e18);

        poolId1 = yieldFarmingPool.createPool(address(stakingToken1), REWARD_RATE);
        poolId2 = yieldFarmingPool.createPool(address(stakingToken2), REWARD_RATE * 2);

        vm.startPrank(user1);
        stakingToken1.approve(address(yieldFarmingPool), type(uint256).max);
        stakingToken2.approve(address(yieldFarmingPool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        stakingToken1.approve(address(yieldFarmingPool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user3);
        stakingToken2.approve(address(yieldFarmingPool), type(uint256).max);
        vm.stopPrank();
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_RevertWhen_ConstructorZeroRewardToken() public {
        vm.expectRevert(InvalidRewardToken.selector);
        new YieldFarmingPool(address(0));
    }

    // ─── createPool ───────────────────────────────────────────────────────────

    function testCreatePool() public {
        (address token1,, uint256 rewardRate1,,, bool isActive1) = yieldFarmingPool.pools(poolId1);
        (address token2,, uint256 rewardRate2,,, bool isActive2) = yieldFarmingPool.pools(poolId2);

        assertTrue(isActive1);
        assertTrue(isActive2);
        assertEq(token1, address(stakingToken1));
        assertEq(token2, address(stakingToken2));
        assertEq(rewardRate1, REWARD_RATE);
        assertEq(rewardRate2, REWARD_RATE * 2);
    }

    function test_RevertWhen_CreatePoolZeroToken() public {
        vm.expectRevert(InvalidTokenAddress.selector);
        yieldFarmingPool.createPool(address(0), REWARD_RATE);
    }

    function test_RevertWhen_CreatePoolZeroRate() public {
        vm.expectRevert(RewardRateMustBePositive.selector);
        yieldFarmingPool.createPool(address(stakingToken1), 0);
    }

    function test_RevertWhen_CreatePoolNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        yieldFarmingPool.createPool(address(stakingToken1), REWARD_RATE);
    }

    function test_RevertWhen_CreatePoolAlreadyExists() public {
        // Same block.timestamp as setUp → same poolId
        bytes32 expectedId = keccak256(
            abi.encodePacked(address(stakingToken1), REWARD_RATE, block.timestamp, block.chainid)
        );
        vm.expectRevert(abi.encodeWithSelector(PoolAlreadyExists.selector, expectedId));
        yieldFarmingPool.createPool(address(stakingToken1), REWARD_RATE);
    }

    function testPoolIdUniqueness() public {
        assertTrue(poolId1 != poolId2);

        vm.warp(block.timestamp + 1);
        bytes32 poolId3 = yieldFarmingPool.createPool(address(stakingToken1), REWARD_RATE);
        assertTrue(poolId1 != poolId3);
    }

    // ─── Pause / Unpause ──────────────────────────────────────────────────────

    function testPauseUnpause() public {
        yieldFarmingPool.pause();
        assertTrue(yieldFarmingPool.paused());

        yieldFarmingPool.unpause();
        assertFalse(yieldFarmingPool.paused());
    }

    function test_RevertWhen_PauseNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        yieldFarmingPool.pause();
    }

    function test_RevertWhen_UnpauseNotOwner() public {
        yieldFarmingPool.pause();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        yieldFarmingPool.unpause();
    }

    // ─── Ownable2Step ─────────────────────────────────────────────────────────

    function testOwnershipTransfer2Step() public {
        yieldFarmingPool.transferOwnership(user1);

        assertEq(yieldFarmingPool.pendingOwner(), user1);
        assertEq(yieldFarmingPool.owner(), owner);

        vm.prank(user1);
        yieldFarmingPool.acceptOwnership();

        assertEq(yieldFarmingPool.owner(), user1);
    }

    // ─── updatePoolRewardRate ─────────────────────────────────────────────────

    function testUpdatePoolRewardRate() public {
        uint256 newRate = REWARD_RATE * 2;
        yieldFarmingPool.updatePoolRewardRate(poolId1, newRate);

        (,, uint256 rewardRate,,,) = yieldFarmingPool.pools(poolId1);
        assertEq(rewardRate, newRate);
    }

    function test_RevertWhen_UpdateRewardRateNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        yieldFarmingPool.updatePoolRewardRate(poolId1, REWARD_RATE * 2);
    }

    function test_RevertWhen_UpdateRewardRateInactivePool() public {
        bytes32 fakePoolId = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(PoolNotActive.selector, fakePoolId));
        yieldFarmingPool.updatePoolRewardRate(fakePoolId, REWARD_RATE);
    }

    // ─── stake ────────────────────────────────────────────────────────────────

    function testStake() public {
        uint256 amount = 1_000 * 1e18;

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount);

        (uint256 userAmount,,) = yieldFarmingPool.userInfo(poolId1, user1);
        (, uint256 totalStaked,,,,) = yieldFarmingPool.pools(poolId1);

        assertEq(userAmount, amount);
        assertEq(totalStaked, amount);
    }

    function test_RevertWhen_StakeInactivePool() public {
        bytes32 fakePoolId = bytes32(uint256(1));
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PoolNotActive.selector, fakePoolId));
        yieldFarmingPool.stake(fakePoolId, 1_000 * 1e18);
    }

    function test_RevertWhen_StakeZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(AmountMustBePositive.selector);
        yieldFarmingPool.stake(poolId1, 0);
    }

    function test_RevertWhen_StakeWhenPaused() public {
        yieldFarmingPool.pause();

        vm.prank(user1);
        vm.expectRevert(EnforcedPause.selector);
        yieldFarmingPool.stake(poolId1, 1_000 * 1e18);
    }

    function testRestakeWithExistingPosition() public {
        uint256 firstAmount  = 1_000 * 1e18;
        uint256 secondAmount = 500 * 1e18;

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, firstAmount);

        vm.warp(block.timestamp + 100);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, secondAmount);

        // Rewards auto-paid on re-stake
        assertGt(rewardToken.balanceOf(user1), 0);

        (uint256 userAmount,,) = yieldFarmingPool.userInfo(poolId1, user1);
        assertEq(userAmount, firstAmount + secondAmount);
    }

    // ─── withdraw ─────────────────────────────────────────────────────────────

    function testWithdrawPartial() public {
        uint256 stakeAmount    = 1_000 * 1e18;
        uint256 withdrawAmount = 500 * 1e18;

        vm.startPrank(user1);
        yieldFarmingPool.stake(poolId1, stakeAmount);
        vm.warp(block.timestamp + 100);
        yieldFarmingPool.withdraw(poolId1, withdrawAmount);
        vm.stopPrank();

        (uint256 userAmount,,) = yieldFarmingPool.userInfo(poolId1, user1);
        (, uint256 totalStaked,,,,) = yieldFarmingPool.pools(poolId1);

        assertEq(userAmount, stakeAmount - withdrawAmount);
        assertEq(totalStaked, stakeAmount - withdrawAmount);
        assertEq(stakingToken1.balanceOf(user1), 9_000 * 1e18 + withdrawAmount);
    }

    function testFullWithdrawDeletesUserInfo() public {
        uint256 amount = 1_000 * 1e18;

        vm.startPrank(user1);
        yieldFarmingPool.stake(poolId1, amount);
        vm.warp(block.timestamp + 100);
        yieldFarmingPool.withdraw(poolId1, amount);
        vm.stopPrank();

        (uint256 userAmount, uint256 rewardDebt, uint256 lastClaimTime) = yieldFarmingPool.userInfo(poolId1, user1);
        assertEq(userAmount, 0);
        assertEq(rewardDebt, 0);
        assertEq(lastClaimTime, 0);
    }

    function testWithdrawWorksWhenPaused() public {
        uint256 amount = 1_000 * 1e18;

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount);

        yieldFarmingPool.pause();

        uint256 balanceBefore = stakingToken1.balanceOf(user1);

        vm.prank(user1);
        yieldFarmingPool.withdraw(poolId1, amount);

        assertEq(stakingToken1.balanceOf(user1), balanceBefore + amount);
    }

    function test_RevertWhen_WithdrawZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(AmountMustBePositive.selector);
        yieldFarmingPool.withdraw(poolId1, 0);
    }

    function test_RevertWhen_WithdrawMoreThanStaked() public {
        uint256 stakeAmount = 1_000 * 1e18;

        vm.startPrank(user1);
        yieldFarmingPool.stake(poolId1, stakeAmount);
        vm.expectRevert(abi.encodeWithSelector(InsufficientStakedAmount.selector, stakeAmount, stakeAmount + 1));
        yieldFarmingPool.withdraw(poolId1, stakeAmount + 1);
        vm.stopPrank();
    }

    // ─── claimRewards ─────────────────────────────────────────────────────────

    function testStakeAndRewards() public {
        uint256 amount = 1_000 * 1e18;

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount);

        vm.warp(block.timestamp + 100);

        assertGt(yieldFarmingPool.pendingRewards(poolId1, user1), 0);

        vm.prank(user1);
        yieldFarmingPool.claimRewards(poolId1);

        assertGt(rewardToken.balanceOf(user1), 0);
    }

    function test_RevertWhen_ClaimNoRewards() public {
        vm.prank(user1);
        vm.expectRevert(NoRewardsToClaim.selector);
        yieldFarmingPool.claimRewards(poolId1);
    }

    function test_RevertWhen_ClaimWhenPaused() public {
        uint256 amount = 1_000 * 1e18;

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount);

        vm.warp(block.timestamp + 100);

        yieldFarmingPool.pause();

        vm.prank(user1);
        vm.expectRevert(EnforcedPause.selector);
        yieldFarmingPool.claimRewards(poolId1);
    }

    // ─── Exact math ───────────────────────────────────────────────────────────

    function testExactRewardCalculation() public {
        uint256 amount = 1_000 * 1e18;

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount);

        vm.warp(block.timestamp + 100);

        uint256 pending = yieldFarmingPool.pendingRewards(poolId1, user1);
        assertEq(pending, 100 * REWARD_RATE);
    }

    // ─── Reward cap ───────────────────────────────────────────────────────────

    function testSafeRewardTransferCap() public {
        MockToken tinyReward  = new MockToken("Tiny", "TRW", 0);
        MockToken tinyStaking = new MockToken("TinyStk", "TSK", 0);

        YieldFarmingPool tinyPool = new YieldFarmingPool(address(tinyReward));

        tinyReward.mint(address(tinyPool), 1);
        tinyStaking.mint(user1, 1_000 * 1e18);

        bytes32 pid = tinyPool.createPool(address(tinyStaking), REWARD_RATE);

        vm.prank(user1);
        tinyStaking.approve(address(tinyPool), type(uint256).max);

        vm.prank(user1);
        tinyPool.stake(pid, 1_000 * 1e18);

        vm.warp(block.timestamp + 365 days);

        vm.prank(user1);
        tinyPool.claimRewards(pid);

        assertEq(tinyReward.balanceOf(user1), 1);
    }

    // ─── Proportionality ──────────────────────────────────────────────────────

    function testRewardsProportionalToStake() public {
        uint256 amount1 = 1_000 * 1e18;
        uint256 amount2 = 2_000 * 1e18;

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount1);

        vm.prank(user2);
        yieldFarmingPool.stake(poolId1, amount2);

        vm.warp(block.timestamp + 100);

        uint256 pending1 = yieldFarmingPool.pendingRewards(poolId1, user1);
        uint256 pending2 = yieldFarmingPool.pendingRewards(poolId1, user2);

        assertApproxEqAbs(pending2, pending1 * 2, 1);
    }

    // ─── Multi-user ───────────────────────────────────────────────────────────

    function testMultipleUsers() public {
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1_000 * 1e18);

        vm.prank(user2);
        yieldFarmingPool.stake(poolId1, 2_000 * 1e18);

        vm.warp(block.timestamp + 100);

        uint256 pending1 = yieldFarmingPool.pendingRewards(poolId1, user1);
        uint256 pending2 = yieldFarmingPool.pendingRewards(poolId1, user2);

        assertGt(pending1, 0);
        assertGt(pending2, 0);
        assertGt(pending2, pending1);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function testGetPoolEncodedData() public view {
        bytes memory encodedData = yieldFarmingPool.getPoolEncodedData(poolId1);
        assertGt(encodedData.length, 0);
    }

    function testGetUserHash() public view {
        bytes32 h1 = yieldFarmingPool.getUserHash(poolId1, user1);
        bytes32 h2 = yieldFarmingPool.getUserHash(poolId1, user2);
        bytes32 h3 = yieldFarmingPool.getUserHash(poolId2, user1);

        assertTrue(h1 != h2);
        assertTrue(h1 != h3);
    }

    function testGetActivePools() public view {
        bytes32[] memory active = yieldFarmingPool.getActivePools();
        assertEq(active.length, 2);
        assertEq(active[0], poolId1);
        assertEq(active[1], poolId2);
        assertEq(yieldFarmingPool.getActivePoolsCount(), 2);
    }

    // ─── emergencyWithdraw ────────────────────────────────────────────────────

    function testEmergencyWithdraw() public {
        stakingToken1.transfer(address(yieldFarmingPool), 1_000 * 1e18);

        uint256 before = stakingToken1.balanceOf(owner);
        yieldFarmingPool.emergencyWithdraw(address(stakingToken1), 1_000 * 1e18);

        assertEq(stakingToken1.balanceOf(owner), before + 1_000 * 1e18);
    }

    function test_RevertWhen_EmergencyWithdrawNotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        yieldFarmingPool.emergencyWithdraw(address(rewardToken), 1);
    }
}
