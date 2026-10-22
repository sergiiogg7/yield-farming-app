// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {YieldFarmingPool} from "../src/YieldFarmingPool.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @notice Drives random stake, withdraw, claim, time and funding actions over two pools.
/// @dev Pool 0 stakes a separate token. Pool 1 stakes the reward token itself, so principal and
///      rewards share one balance.
contract FarmHandler is Test {
    YieldFarmingPool public pool;
    MockToken public rewardToken;
    MockToken public stakeToken;
    bytes32[2] public poolIds;
    address[3] public actors;

    uint256[2] public ghostTotalStaked;
    uint256[2] public lastRewardPerToken;

    constructor(YieldFarmingPool pool_, MockToken rewardToken_, MockToken stakeToken_, bytes32[2] memory poolIds_) {
        pool = pool_;
        rewardToken = rewardToken_;
        stakeToken = stakeToken_;
        poolIds = poolIds_;
        for (uint256 i = 0; i < 3; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            vm.startPrank(actors[i]);
            stakeToken.approve(address(pool), type(uint256).max);
            rewardToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _token(uint256 poolIndex_) internal view returns (MockToken) {
        return poolIndex_ == 0 ? stakeToken : rewardToken;
    }

    function actorsLength() external pure returns (uint256) {
        return 3;
    }

    function stake(uint256 poolSeed_, uint256 actorSeed_, uint256 amount_) external {
        uint256 p = poolSeed_ % 2;
        address actor = actors[actorSeed_ % 3];
        amount_ = bound(amount_, 1, 1000 ether);

        deal(address(_token(p)), actor, _token(p).balanceOf(actor) + amount_, false);
        vm.prank(actor);
        pool.stake(poolIds[p], amount_);

        ghostTotalStaked[p] += amount_;
        _snapshot(p);
    }

    function withdraw(uint256 poolSeed_, uint256 actorSeed_, uint256 amount_) external {
        uint256 p = poolSeed_ % 2;
        address actor = actors[actorSeed_ % 3];
        (uint256 staked,,,) = pool.userInfo(poolIds[p], actor);
        if (staked == 0) return;
        amount_ = bound(amount_, 1, staked);

        vm.prank(actor);
        pool.withdraw(poolIds[p], amount_);

        ghostTotalStaked[p] -= amount_;
        _snapshot(p);
    }

    function claim(uint256 poolSeed_, uint256 actorSeed_) external {
        uint256 p = poolSeed_ % 2;
        address actor = actors[actorSeed_ % 3];

        vm.prank(actor);
        try pool.claimRewards(poolIds[p]) {} catch {}
        _snapshot(p);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 30 days));
    }

    function fundRewards(uint256 amount_) external {
        amount_ = bound(amount_, 0, 10_000 ether);
        deal(address(rewardToken), address(pool), rewardToken.balanceOf(address(pool)) + amount_, false);
    }

    function _snapshot(uint256 p) internal {
        (,,,, uint256 rpt,) = pool.pools(poolIds[p]);
        if (rpt > lastRewardPerToken[p]) lastRewardPerToken[p] = rpt;
    }
}

contract YieldFarmingPoolInvariant is Test {
    YieldFarmingPool internal pool;
    MockToken internal rewardToken;
    MockToken internal stakeToken;
    FarmHandler internal handler;
    bytes32[2] internal poolIds;

    function setUp() external {
        rewardToken = new MockToken("Reward", "RWD", 1_000_000);
        stakeToken = new MockToken("Stake", "STK", 1_000_000);
        pool = new YieldFarmingPool(address(rewardToken));
        poolIds[0] = pool.createPool(address(stakeToken), 1e16);
        poolIds[1] = pool.createPool(address(rewardToken), 2e16);
        rewardToken.transfer(address(pool), 1000 ether);

        handler = new FarmHandler(pool, rewardToken, stakeToken, poolIds);
        targetContract(address(handler));
    }

    // Per-pool totalStaked equals the sum of the user positions and the handler's ghost accounting.
    function invariant_totalStakedMatchesUserPositions() external view {
        for (uint256 p = 0; p < 2; p++) {
            uint256 sum;
            for (uint256 i = 0; i < handler.actorsLength(); i++) {
                (uint256 amount,,,) = pool.userInfo(poolIds[p], handler.actors(i));
                sum += amount;
            }
            (, uint256 totalStaked,,,,) = pool.pools(poolIds[p]);
            assertEq(totalStaked, sum);
            assertEq(totalStaked, handler.ghostTotalStaked(p));
        }
    }

    // stakedByToken equals the totals of the pools that stake that token.
    function invariant_stakedByTokenMatchesPools() external view {
        (, uint256 total0,,,,) = pool.pools(poolIds[0]);
        (, uint256 total1,,,,) = pool.pools(poolIds[1]);
        assertEq(pool.stakedByToken(address(stakeToken)), total0);
        assertEq(pool.stakedByToken(address(rewardToken)), total1);
    }

    // The contract always holds at least all staked principal, for both tokens.
    function invariant_principalIsAlwaysCovered() external view {
        assertGe(stakeToken.balanceOf(address(pool)), pool.stakedByToken(address(stakeToken)));
        assertGe(rewardToken.balanceOf(address(pool)), pool.stakedByToken(address(rewardToken)));
    }

    // The reward accumulator of each pool never decreases.
    function invariant_rewardPerTokenNeverDecreases() external view {
        for (uint256 p = 0; p < 2; p++) {
            (,,,, uint256 rpt,) = pool.pools(poolIds[p]);
            assertGe(rpt, handler.lastRewardPerToken(p));
        }
    }
}
