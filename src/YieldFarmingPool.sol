// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title YieldFarmingPool
 * @dev Yield Farming contract demonstrating the use of abi.encodePacked
 * to encode pool parameters and calculate unique identifiers
 */
contract YieldFarmingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Structure to store pool information
    struct Pool {
        address token;           // Pool token
        uint256 totalStaked;     // Total staked tokens
        uint256 rewardRate;      // Reward rate per second
        uint256 lastUpdateTime;  // Last time it was updated
        uint256 rewardPerTokenStored; // Accumulated reward per token
        bool isActive;           // Whether the pool is active
    }

    // Structure to store user information
    struct UserInfo {
        uint256 amount;          // Staked amount
        uint256 rewardDebt;      // Reward debt
        uint256 lastClaimTime;   // Last time rewards were claimed
    }

    // Reward token
    IERC20 public immutable rewardToken;
    
    // Mapping of pools by their unique identifier
    mapping(bytes32 => Pool) public pools;
    
    // Mapping of user information by pool and address
    mapping(bytes32 => mapping(address => UserInfo)) public userInfo;
    
    // List of all active pools
    bytes32[] public activePools;
    
    // Events
    event PoolCreated(bytes32 indexed poolId, address indexed token, uint256 rewardRate);
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount);
    event Withdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);
    event RewardClaimed(bytes32 indexed poolId, address indexed user, uint256 amount);
    event PoolUpdated(bytes32 indexed poolId, uint256 newRewardRate);

    /**
     * @dev Contract constructor
     * @param _rewardToken Address of the reward token
     */
    constructor(address _rewardToken) Ownable(msg.sender) {
        require(_rewardToken != address(0), "Invalid reward token");
        rewardToken = IERC20(_rewardToken);
    }

    /**
     * @dev Creates a new yield farming pool
     * @param token Address of the token to stake
     * @param rewardRate Reward rate per second
     * @return poolId Unique pool identifier
     */
    function createPool(address token, uint256 rewardRate) 
        external 
        onlyOwner 
        returns (bytes32 poolId) 
    {
        require(token != address(0), "Invalid token address");
        require(rewardRate > 0, "Reward rate must be positive");
        
        // USAGE OF ABI.ENCODEPACKED: Create a unique identifier for the pool
        // We combine the token address, reward rate, and timestamp
        // to create a unique hash that identifies the pool
        poolId = keccak256(
            abi.encodePacked(
                token,
                rewardRate,
                block.timestamp,
                block.chainid
            )
        );
        
        require(pools[poolId].token == address(0), "Pool already exists");
        
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

    /**
     * @dev Stake tokens in a specific pool
     * @param poolId Pool identifier
     * @param amount Amount of tokens to stake
     */
    function stake(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool is not active");
        require(amount > 0, "Amount must be positive");
        
        _updatePool(poolId);
        
        UserInfo storage user = userInfo[poolId][msg.sender];
        
        if (user.amount > 0) {
            uint256 pending = _calculatePendingRewards(poolId, msg.sender);
            if (pending > 0) {
                _safeRewardTransfer(msg.sender, pending);
                emit RewardClaimed(poolId, msg.sender, pending);
            }
        }
        
        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount);
        
        user.amount += amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;
        
        pool.totalStaked += amount;
        
        emit Staked(poolId, msg.sender, amount);
    }

    /**
     * @dev Withdraw staked tokens from a pool
     * @param poolId Pool identifier
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        UserInfo storage user = userInfo[poolId][msg.sender];
        
        require(user.amount >= amount, "Insufficient staked amount");
        
        _updatePool(poolId);
        
        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        if (pending > 0) {
            _safeRewardTransfer(msg.sender, pending);
            emit RewardClaimed(poolId, msg.sender, pending);
        }
        
        user.amount -= amount;
        user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;
        
        pool.totalStaked -= amount;
        
        IERC20(pool.token).safeTransfer(msg.sender, amount);
        
        emit Withdrawn(poolId, msg.sender, amount);
    }

    /**
     * @dev Claim pending rewards
     * @param poolId Pool identifier
     */
    function claimRewards(bytes32 poolId) external nonReentrant {
        _updatePool(poolId);
        
        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        require(pending > 0, "No rewards to claim");
        
        UserInfo storage user = userInfo[poolId][msg.sender];
        user.rewardDebt = user.amount * pools[poolId].rewardPerTokenStored / 1e18;
        user.lastClaimTime = block.timestamp;
        
        _safeRewardTransfer(msg.sender, pending);
        
        emit RewardClaimed(poolId, msg.sender, pending);
    }

    /**
     * @dev Update the reward rate of a pool
     * @param poolId Pool identifier
     * @param newRewardRate New reward rate
     */
    function updatePoolRewardRate(bytes32 poolId, uint256 newRewardRate) external onlyOwner {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool is not active");
        
        _updatePool(poolId);
        pool.rewardRate = newRewardRate;
        
        emit PoolUpdated(poolId, newRewardRate);
    }

    /**
     * @dev Calculate the pending rewards of a user
     * @param poolId Pool identifier
     * @param user User address
     * @return Amount of pending rewards
     */
    function pendingRewards(bytes32 poolId, address user) external view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserInfo storage userInfoData = userInfo[poolId][user];
        
        uint256 rewardPerTokenStored = pool.rewardPerTokenStored;
        
        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            uint256 rewards = timeElapsed * pool.rewardRate;
            rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
        }
        
        return userInfoData.amount * rewardPerTokenStored / 1e18 - userInfoData.rewardDebt;
    }

    /**
     * @dev Get encoded pool information for external use
     * @param poolId Pool identifier
     * @return encodedData Encoded pool data
     * 
     * DEMONSTRATION: This method shows how to use abi.encodePacked to
     * create compact data that can be used in other contracts
     */
    function getPoolEncodedData(bytes32 poolId) external view returns (bytes memory encodedData) {
        Pool storage pool = pools[poolId];
        
        // Encode the pool data in a compact format
        encodedData = abi.encodePacked(
            pool.token,
            pool.totalStaked,
            pool.rewardRate,
            pool.lastUpdateTime,
            pool.rewardPerTokenStored,
            pool.isActive
        );
    }

    /**
     * @dev Create a unique hash for a user in a specific pool
     * @param poolId Pool identifier
     * @param user User address
     * @return userHash Unique user hash
     * 
     * DEMONSTRATION: Use of abi.encodePacked to create unique identifiers
     * by combining multiple parameters
     */
    function getUserHash(bytes32 poolId, address user) external pure returns (bytes32 userHash) {
        userHash = keccak256(
            abi.encodePacked(
                poolId,
                user,
                "YIELD_FARMING_USER"
            )
        );
    }

    /**
     * @dev Update the pool state
     * @param poolId Pool identifier
     */
    function _updatePool(bytes32 poolId) internal {
        Pool storage pool = pools[poolId];
        
        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            uint256 rewards = timeElapsed * pool.rewardRate;
            pool.rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
        }
        
        pool.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Calculate the pending rewards of a user
     * @param poolId Pool identifier
     * @param user User address
     * @return Amount of pending rewards
     */
    function _calculatePendingRewards(bytes32 poolId, address user) internal view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserInfo storage userInfoData = userInfo[poolId][user];
        
        uint256 rewardPerTokenStored = pool.rewardPerTokenStored;
        
        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            uint256 rewards = timeElapsed * pool.rewardRate;
            rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
        }
        
        return userInfoData.amount * rewardPerTokenStored / 1e18 - userInfoData.rewardDebt;
    }

    /**
     * @dev Safely transfer rewards
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _safeRewardTransfer(address to, uint256 amount) internal {
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        if (amount > rewardBalance) {
            amount = rewardBalance;
        }
        if (amount > 0) {
            rewardToken.safeTransfer(to, amount);
        }
    }

    /**
     * @dev Get the total number of active pools
     * @return Number of active pools
     */
    function getActivePoolsCount() external view returns (uint256) {
        return activePools.length;
    }

    /**
     * @dev Get all active pools
     * @return Array with the identifiers of the active pools
     */
    function getActivePools() external view returns (bytes32[] memory) {
        return activePools;
    }

     
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}
