// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// ─── Errors ───────────────────────────────────────────────────────────────────

/// @notice Thrown when the reward token address is the zero address.
error InvalidRewardToken();

/// @notice Thrown when the staking token address is the zero address.
error InvalidTokenAddress();

/// @notice Thrown when a pool is created with a zero reward rate.
error RewardRateMustBePositive();

/// @notice Thrown when a reward rate exceeds the allowed maximum.
/// @param provided The rejected reward rate.
error RewardRateTooHigh(uint256 provided);

/// @notice Thrown when trying to create a pool that already exists.
/// @param poolId The identifier of the duplicate pool.
error PoolAlreadyExists(bytes32 poolId);

/// @notice Thrown when interacting with a pool that is not active.
/// @param poolId The identifier of the inactive pool.
error PoolNotActive(bytes32 poolId);

/// @notice Thrown when staking or withdrawing a zero amount.
error AmountMustBePositive();

/// @notice Thrown when a user tries to withdraw more than their staked balance.
/// @param available The user's current staked balance.
/// @param requested The amount the user attempted to withdraw.
error InsufficientStakedAmount(uint256 available, uint256 requested);

/// @notice Thrown when a user calls claimRewards with no pending rewards.
error NoRewardsToClaim();

/// @notice Thrown when the contract holds no reward tokens that are not user principal.
error RewardBalanceDepleted();

/// @notice Thrown when the owner tries to recover tokens that belong to stakers.
/// @param requested The requested amount.
/// @param withdrawable The maximum amount that can be recovered.
error AmountExceedsWithdrawable(uint256 requested, uint256 withdrawable);

// ─── Contract ─────────────────────────────────────────────────────────────────

/// @title YieldFarmingPool
/// @notice Multi-pool yield farming protocol. Users stake ERC20 tokens and earn
///         a reward token distributed continuously via a per-token accumulator model.
///         Each pool is identified by a unique keccak256 hash of its parameters.
/// @dev Uses a rewardPerTokenStored accumulator so reward calculation is O(1) per user
///      regardless of how many stakers are in the pool. Staked principal is tracked per token
///      (`stakedByToken`) so neither reward payouts nor owner recoveries can touch it, even when a
///      pool stakes the reward token itself. Rewards that cannot be paid because the contract is
///      underfunded are kept as `unpaidRewards` and paid once the owner tops up the balance.
contract YieldFarmingPool is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ─── Structs ──────────────────────────────────────────────────────────────

    /// @notice Stores the configuration and state of a staking pool.
    /// @param token Staking token of the pool.
    /// @param totalStaked Total amount currently staked.
    /// @param rewardRate Reward tokens distributed per second across all stakers.
    /// @param lastUpdateTime Timestamp of the last accumulator update.
    /// @param rewardPerTokenStored Cumulative reward per staked token, scaled by 1e18.
    /// @param isActive Whether the pool accepts stakes and claims.
    struct Pool {
        address token;
        uint256 totalStaked;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        bool isActive;
    }

    /// @notice Stores an individual user's position within a pool.
    /// @param amount Staked token amount.
    /// @param rewardDebt Rewards already accounted for at the last interaction.
    /// @param lastClaimTime Timestamp of the last stake or claim.
    /// @param unpaidRewards Earned rewards that could not be paid yet because of an underfunded balance.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastClaimTime;
        uint256 unpaidRewards;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Highest reward rate (tokens per second, with token decimals) a pool may use.
    uint256 public constant MAX_REWARD_RATE = 1e24;

    /// @notice The token paid out as staking rewards.
    IERC20 public immutable rewardToken;

    /// @notice Pool state keyed by pool identifier.
    mapping(bytes32 => Pool) public pools;

    /// @notice User position keyed by pool identifier then user address.
    mapping(bytes32 => mapping(address => UserInfo)) public userInfo;

    /// @notice Total staked principal per token across all pools.
    mapping(address => uint256) public stakedByToken;

    /// @notice Ordered list of all created pool identifiers.
    bytes32[] public activePools;

    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a new pool is created.
    /// @param poolId Unique identifier of the pool.
    /// @param token Address of the staking token.
    /// @param rewardRate Reward tokens distributed per second across all stakers.
    event PoolCreated(bytes32 indexed poolId, address indexed token, uint256 rewardRate);

    /// @notice Emitted when a user stakes tokens.
    /// @param poolId Pool the user staked into.
    /// @param user Address of the staker.
    /// @param amount Token amount staked.
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws staked tokens.
    /// @param poolId Pool the user withdrew from.
    /// @param user Address of the withdrawer.
    /// @param amount Token amount withdrawn.
    event Withdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);

    /// @notice Emitted when rewards are paid to a user. The amount is what was actually transferred.
    /// @param poolId Pool from which rewards were claimed.
    /// @param user Address of the recipient.
    /// @param amount Reward token amount transferred.
    event RewardClaimed(bytes32 indexed poolId, address indexed user, uint256 amount);

    /// @notice Emitted when the owner updates a pool's reward rate.
    /// @param poolId Pool whose rate was updated.
    /// @param newRewardRate The new reward rate per second.
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate);

    /// @notice Emitted when the owner recovers tokens that do not belong to stakers.
    /// @param token Recovered token.
    /// @param amount Amount transferred to the owner.
    event EmergencyWithdrawn(address indexed token, uint256 amount);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @notice Deploys the contract and sets the reward token.
    /// @param rewardToken_ Address of the ERC20 token paid out as rewards.
    constructor(address rewardToken_) Ownable(msg.sender) {
        if (rewardToken_ == address(0)) revert InvalidRewardToken();
        rewardToken = IERC20(rewardToken_);
    }

    // ─── Owner functions ──────────────────────────────────────────────────────

    /// @notice Pauses staking and reward claims. Withdrawals remain available.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling staking and reward claims.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Creates a new staking pool.
    /// @dev Pool ID is derived from keccak256(token, rewardRate, timestamp, chainId)
    ///      to guarantee uniqueness across chains and time.
    /// @param token Address of the ERC20 token users will stake.
    /// @param rewardRate Reward tokens distributed per second across all stakers (at most `MAX_REWARD_RATE`).
    /// @return poolId Unique identifier for the created pool.
    function createPool(address token, uint256 rewardRate) external onlyOwner returns (bytes32 poolId) {
        if (token == address(0)) revert InvalidTokenAddress();
        if (rewardRate == 0) revert RewardRateMustBePositive();
        if (rewardRate > MAX_REWARD_RATE) revert RewardRateTooHigh(rewardRate);

        poolId = keccak256(abi.encodePacked(token, rewardRate, block.timestamp, block.chainid));

        if (pools[poolId].token != address(0)) revert PoolAlreadyExists(poolId);

        pools[poolId] = Pool({
            token: token,
            totalStaked: 0,
            rewardRate: rewardRate,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            isActive: true
        });

        activePools.push(poolId);

        emit PoolCreated(poolId, token, rewardRate);
    }

    /// @notice Updates the reward rate of an existing pool.
    /// @dev Settles accumulated rewards up to this point before changing the rate.
    ///      A rate of zero stops the emission of the pool without closing it.
    /// @param poolId Identifier of the pool to update.
    /// @param newRewardRate New reward tokens distributed per second (at most `MAX_REWARD_RATE`).
    function updatePoolRewardRate(bytes32 poolId, uint256 newRewardRate) external onlyOwner {
        if (!pools[poolId].isActive) revert PoolNotActive(poolId);
        if (newRewardRate > MAX_REWARD_RATE) revert RewardRateTooHigh(newRewardRate);

        _updatePool(poolId);
        pools[poolId].rewardRate = newRewardRate;

        emit PoolUpdated(poolId, newRewardRate);
    }

    /// @notice Recovers tokens held by this contract that are not staked principal.
    /// @dev Staked tokens can never be recovered. For the reward token this means the unspent reward
    ///      balance can be reclaimed, so the owner is trusted to keep the contract funded.
    /// @param token Address of the token to recover.
    /// @param amount Amount to transfer to the owner.
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        uint256 withdrawable = IERC20(token).balanceOf(address(this)) - stakedByToken[token];
        if (amount > withdrawable) revert AmountExceedsWithdrawable(amount, withdrawable);

        IERC20(token).safeTransfer(owner(), amount);

        emit EmergencyWithdrawn(token, amount);
    }

    // ─── User functions ───────────────────────────────────────────────────────

    /// @notice Stakes tokens into a pool.
    /// @dev Pending rewards are settled and paid in the same call so that rewardDebt can be reset
    ///      against the new balance. State is fully updated before any external transfer.
    /// @param poolId Identifier of the pool to stake into.
    /// @param amount Token amount to stake.
    function stake(bytes32 poolId, uint256 amount) external nonReentrant whenNotPaused {
        if (!pools[poolId].isActive) revert PoolNotActive(poolId);
        if (amount == 0) revert AmountMustBePositive();

        _updatePool(poolId);

        Pool storage pool = pools[poolId];
        UserInfo storage user = userInfo[poolId][msg.sender];

        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        uint256 paid = _settlePayout(user, pending);

        user.amount += amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;
        pool.totalStaked += amount;
        stakedByToken[pool.token] += amount;

        if (paid > 0) {
            rewardToken.safeTransfer(msg.sender, paid);
            emit RewardClaimed(poolId, msg.sender, paid);
        }
        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(poolId, msg.sender, amount);
    }

    /// @notice Withdraws staked tokens from a pool.
    /// @dev Always available even when paused so users can never be locked in.
    ///      Pending rewards are paid alongside the withdrawal, capped at the available reward balance
    ///      (the rest stays as `unpaidRewards`). If the position is fully withdrawn and nothing is
    ///      owed, the UserInfo slot is deleted.
    /// @param poolId Identifier of the pool to withdraw from.
    /// @param amount Token amount to withdraw.
    function withdraw(bytes32 poolId, uint256 amount) external nonReentrant {
        UserInfo storage user = userInfo[poolId][msg.sender];

        if (amount == 0) revert AmountMustBePositive();
        if (user.amount < amount) revert InsufficientStakedAmount(user.amount, amount);

        _updatePool(poolId);

        Pool storage pool = pools[poolId];
        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        uint256 paid = _settlePayout(user, pending);

        user.amount -= amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;
        pool.totalStaked -= amount;
        stakedByToken[pool.token] -= amount;

        if (user.amount == 0 && user.unpaidRewards == 0) delete userInfo[poolId][msg.sender];

        if (paid > 0) {
            rewardToken.safeTransfer(msg.sender, paid);
            emit RewardClaimed(poolId, msg.sender, paid);
        }
        IERC20(pool.token).safeTransfer(msg.sender, amount);

        emit Withdrawn(poolId, msg.sender, amount);
    }

    /// @notice Claims all pending rewards for the caller in a given pool.
    /// @dev Reverts with {RewardBalanceDepleted} when nothing can be paid, so no rewards are lost.
    /// @param poolId Identifier of the pool to claim from.
    function claimRewards(bytes32 poolId) external nonReentrant whenNotPaused {
        if (!pools[poolId].isActive) revert PoolNotActive(poolId);

        _updatePool(poolId);

        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        if (pending == 0) revert NoRewardsToClaim();

        UserInfo storage user = userInfo[poolId][msg.sender];
        user.rewardDebt = user.amount * pools[poolId].rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;

        uint256 paid = _settlePayout(user, pending);
        if (paid == 0) revert RewardBalanceDepleted();

        rewardToken.safeTransfer(msg.sender, paid);

        emit RewardClaimed(poolId, msg.sender, paid);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /// @notice Returns the pending reward amount for a user in a pool.
    /// @param poolId Identifier of the pool.
    /// @param user Address of the user.
    /// @return Reward token amount earned, including any previously unpaid rewards.
    function pendingRewards(bytes32 poolId, address user) external view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserInfo storage userInfoData = userInfo[poolId][user];

        uint256 rewardPerTokenStored = pool.rewardPerTokenStored;

        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            rewardPerTokenStored += timeElapsed * pool.rewardRate * 1e18 / pool.totalStaked;
        }

        return userInfoData.amount * rewardPerTokenStored / 1e18 - userInfoData.rewardDebt + userInfoData.unpaidRewards;
    }

    /// @notice Returns the number of pools that have been created.
    /// @return Length of the pool list.
    function getActivePoolsCount() external view returns (uint256) {
        return activePools.length;
    }

    /// @notice Returns all pool identifiers.
    /// @return All pool identifiers in creation order.
    function getActivePools() external view returns (bytes32[] memory) {
        return activePools;
    }

    /// @notice Returns ABI-packed pool data for off-chain or cross-contract use.
    /// @param poolId Identifier of the pool.
    /// @return encodedData Packed encoding of all pool fields.
    function getPoolEncodedData(bytes32 poolId) external view returns (bytes memory encodedData) {
        Pool storage pool = pools[poolId];
        encodedData = abi.encodePacked(
            pool.token, pool.totalStaked, pool.rewardRate, pool.lastUpdateTime, pool.rewardPerTokenStored, pool.isActive
        );
    }

    /// @notice Returns a unique hash identifying a user's position in a pool.
    /// @param poolId Pool identifier.
    /// @param user User address.
    /// @return userHash keccak256 hash of poolId, user, and a domain separator.
    function getUserHash(bytes32 poolId, address user) external pure returns (bytes32 userHash) {
        userHash = keccak256(abi.encodePacked(poolId, user, "YIELD_FARMING_USER"));
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev Settles all rewards generated by the pool since the last update.
    ///      Must be called before any operation that reads or writes user balances.
    /// @param poolId Identifier of the pool to settle.
    function _updatePool(bytes32 poolId) internal {
        Pool storage pool = pools[poolId];

        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            pool.rewardPerTokenStored += timeElapsed * pool.rewardRate * 1e18 / pool.totalStaked;
        }

        pool.lastUpdateTime = block.timestamp;
    }

    /// @dev Rewards a user has earned but not yet received, including previously unpaid rewards.
    ///      Reads the already-settled rewardPerTokenStored, so call _updatePool first.
    /// @param poolId Identifier of the pool.
    /// @param user Address of the user.
    /// @return Pending reward token amount.
    function _calculatePendingRewards(bytes32 poolId, address user) internal view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserInfo storage userInfoData = userInfo[poolId][user];
        return
            userInfoData.amount * pool.rewardPerTokenStored / 1e18 - userInfoData.rewardDebt
                + userInfoData.unpaidRewards;
    }

    /// @dev Decides how much of `pending` can be paid now and records the rest as unpaid.
    ///      Must run before `stakedByToken` changes in the same call, so the principal being staked or
    ///      withdrawn is never counted as available reward balance. Only updates storage; the caller
    ///      performs the transfer afterwards.
    /// @param user Storage pointer to the user position.
    /// @param pending Total amount owed to the user.
    /// @return paid Amount that can be transferred now.
    function _settlePayout(UserInfo storage user, uint256 pending) internal returns (uint256 paid) {
        uint256 available = rewardToken.balanceOf(address(this)) - stakedByToken[address(rewardToken)];
        paid = pending > available ? available : pending;
        user.unpaidRewards = pending - paid;
    }
}
