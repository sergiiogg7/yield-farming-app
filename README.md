# Yield Farming Pool

![CI](https://github.com/sergiiogg7/yield-farming-app/actions/workflows/test.yml/badge.svg)
![Solidity 0.8.24](https://img.shields.io/badge/Solidity-0.8.24-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

Multi-pool yield farming protocol with a per-token accumulator reward model. Stake ERC20 tokens to earn rewards distributed continuously across all stakers, with each pool identified by a unique `keccak256` hash.

---

## Example Flow

1. Owner deploys the contract with a `rewardToken` address.
2. Owner creates a pool for a given ERC20 token and reward rate.
3. Owner funds the contract with `rewardToken`.
4. User approves and calls `stake(poolId, amount)`.
5. Rewards accrue per second, proportional to the user's share of `totalStaked`.
6. User calls `claimRewards(poolId)` to receive the pending rewards.
7. User calls `withdraw(poolId, amount)` to receive the staked tokens plus pending rewards.

---

## Key Features

| Feature | Detail |
|---|---|
| Multi-pool support | Each pool identified by `keccak256(token, rewardRate, timestamp, chainId)` |
| Per-token accumulator | `rewardPerTokenStored` tracks global rewards; `rewardDebt` isolates each user's share |
| Rewards on re-stake | Pending rewards are paid out before the position is updated |
| Underfunding safe | Rewards the contract cannot pay yet are kept as `unpaidRewards` and paid after a top-up. Withdrawals never get blocked |
| Principal protection | Staked tokens are tracked per token (`stakedByToken`); neither reward payouts nor `emergencyWithdraw` can use them, even when a pool stakes the reward token itself |
| Rate bounds | Reward rate is capped at `MAX_REWARD_RATE` to rule out accumulator overflow |

---

## Contract Reference

| Function | Access | Description |
|---|---|---|
| `createPool(token, rewardRate)` | owner | Creates a pool and returns its id |
| `updatePoolRewardRate(poolId, newRate)` | owner | Settles the pool and changes its rate (0 stops emission) |
| `pause()` / `unpause()` | owner | Halts staking and claims. Withdrawals stay available |
| `emergencyWithdraw(token, amount)` | owner | Recovers tokens that are not staked principal |
| `stake(poolId, amount)` | public | Stakes tokens, paying pending rewards |
| `withdraw(poolId, amount)` | public | Withdraws tokens plus pending rewards. Works while paused |
| `claimRewards(poolId)` | public | Claims pending rewards |
| `pendingRewards(poolId, user)` | view | Rewards earned and not yet received |

Custom errors: `InvalidRewardToken`, `InvalidTokenAddress`, `RewardRateMustBePositive`, `RewardRateTooHigh`, `PoolAlreadyExists`, `PoolNotActive`, `AmountMustBePositive`, `InsufficientStakedAmount`, `NoRewardsToClaim`, `RewardBalanceDepleted`, `AmountExceedsWithdrawable`.

---

## Security

| Measure | Location |
|---|---|
| Reentrancy guard on `stake`, `withdraw`, `claimRewards` and `emergencyWithdraw` | `nonReentrant` |
| State updated before every external transfer | `stake`, `withdraw`, `claimRewards` |
| Two-step ownership transfer | `Ownable2Step` |
| Pausable staking and claims, withdrawals never blocked | `Pausable` |
| Staked principal can never be recovered or paid out as rewards | `stakedByToken`, `_settlePayout`, `emergencyWithdraw` |
| Unpayable rewards kept as `unpaidRewards` instead of lost | `_settlePayout` |
| Reward rate bounded | `MAX_REWARD_RATE` |
| Custom errors only, full NatSpec | `YieldFarmingPool.sol` |
| Slither in CI | `slither.config.json` |

See [SECURITY.md](SECURITY.md) for assumptions and known limits.

---

## Testing

Unit, fuzz and handler-based invariant suites with mock tokens and a reentrant staking token. Invariants cover staked accounting, principal coverage and accumulator monotonicity, including a pool that stakes the reward token.

```bash
forge test                                           # all tests
forge coverage --no-match-coverage "script|test"      # coverage of src/
forge snapshot --check                               # gas regression check
```

CI runs `forge fmt --check`, `forge build --sizes`, `forge test` (profile `ci`, higher fuzz runs), a 95% line-coverage gate on `src/`, `forge snapshot --check` and Slither.

---

## Tech Stack

- **Solidity** `0.8.24`
- **Foundry**
- **OpenZeppelin Contracts** v5.7.0 (`SafeERC20`, `ReentrancyGuard`, `Ownable2Step`, `Pausable`)
- **forge-std** v1.16.2

---

## Project Structure

```
src/
  YieldFarmingPool.sol
script/
  Deploy.s.sol
test/
  YieldFarmingPool.t.sol          # unit
  YieldFarmingPoolFuzz.t.sol      # fuzz
  YieldFarmingPoolInvariant.t.sol # invariants with handler
  utils/FarmBase.sol              # shared setup
  mocks/MockToken.sol
.github/workflows/test.yml
```

---

## Getting Started

```bash
git clone --recurse-submodules https://github.com/sergiiogg7/yield-farming-app.git
cd yield-farming-app
forge build
forge test
```

Deploy (see `.env.example`):

```bash
cp .env.example .env   # fill in values
source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

## License

MIT
