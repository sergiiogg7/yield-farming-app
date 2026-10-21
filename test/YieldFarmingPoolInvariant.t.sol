// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/YieldFarmingPool.sol";
import "../src/MockToken.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract Handler is Test {
    YieldFarmingPool public pool;
    IERC20 public stakingToken;
    bytes32 public poolId;

    address[] public actors;

    mapping(address => uint256) public ghost_userStaked;
    uint256 public ghost_totalStaked;
    uint256 public ghost_prevRewardPerToken;

    constructor(
        YieldFarmingPool _pool,
        address _stakingToken,
        bytes32 _poolId,
        address[] memory _actors
    ) {
        pool         = _pool;
        stakingToken = IERC20(_stakingToken);
        poolId       = _poolId;
        actors       = _actors;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal   = stakingToken.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        pool.stake(poolId, amount);

        ghost_userStaked[actor] += amount;
        ghost_totalStaked       += amount;

        _snapshotRewardPerToken();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        if (ghost_userStaked[actor] == 0) return;
        amount = bound(amount, 1, ghost_userStaked[actor]);

        vm.prank(actor);
        pool.withdraw(poolId, amount);

        ghost_userStaked[actor] -= amount;
        ghost_totalStaked       -= amount;

        _snapshotRewardPerToken();
    }

    function claimRewards(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (ghost_userStaked[actor] == 0) return;
        if (pool.pendingRewards(poolId, actor) == 0) return;

        vm.prank(actor);
        pool.claimRewards(poolId);

        _snapshotRewardPerToken();
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);
    }

    function _snapshotRewardPerToken() internal {
        (,,,, uint256 rpt,) = pool.pools(poolId);
        ghost_prevRewardPerToken = rpt;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}

contract YieldFarmingPoolInvariantTest is Test {
    YieldFarmingPool public yieldFarmingPool;
    MockToken public rewardToken;
    MockToken public stakingToken;
    bytes32 public poolId;
    Handler public handler;

    address[] internal actors;

    function setUp() public {
        rewardToken  = new MockToken("Reward", "RWD", 0);
        stakingToken = new MockToken("Stake",  "STK", 0);

        yieldFarmingPool = new YieldFarmingPool(address(rewardToken));

        rewardToken.mint(address(yieldFarmingPool), 10_000_000 ether);

        poolId = yieldFarmingPool.createPool(address(stakingToken), 1e16);

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));

        for (uint256 i = 0; i < actors.length; i++) {
            stakingToken.mint(actors[i], 1_000_000 ether);
            vm.prank(actors[i]);
            stakingToken.approve(address(yieldFarmingPool), type(uint256).max);
        }

        handler = new Handler(yieldFarmingPool, address(stakingToken), poolId, actors);

        targetContract(address(handler));
    }

    /// @dev pool.totalStaked always equals sum of ghost user amounts.
    function invariant_totalStakedConsistency() public view {
        (, uint256 totalStaked,,,,) = yieldFarmingPool.pools(poolId);
        assertEq(totalStaked, handler.ghost_totalStaked());
    }

    /// @dev Each user's on-chain amount matches ghost tracking and their sum equals totalStaked.
    function invariant_userAmountsConsistency() public view {
        address[] memory _actors = handler.getActors();
        uint256 sum = 0;
        for (uint256 i = 0; i < _actors.length; i++) {
            (uint256 onChainAmount,,) = yieldFarmingPool.userInfo(poolId, _actors[i]);
            assertEq(onChainAmount, handler.ghost_userStaked(_actors[i]));
            sum += onChainAmount;
        }
        (, uint256 totalStaked,,,,) = yieldFarmingPool.pools(poolId);
        assertEq(sum, totalStaked);
    }

    /// @dev Contract staking token balance always covers totalStaked.
    function invariant_contractSolvency() public view {
        (, uint256 totalStaked,,,,) = yieldFarmingPool.pools(poolId);
        assertGe(stakingToken.balanceOf(address(yieldFarmingPool)), totalStaked);
    }

    /// @dev rewardPerTokenStored never decreases.
    function invariant_rewardPerTokenNonDecreasing() public view {
        (,,,, uint256 rewardPerToken,) = yieldFarmingPool.pools(poolId);
        assertGe(rewardPerToken, handler.ghost_prevRewardPerToken());
    }
}
