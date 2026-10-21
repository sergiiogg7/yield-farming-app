# Yield Farming Pool

Multi-pool yield farming protocol with a per-token accumulator reward model. Stake ERC20 tokens to earn rewards distributed continuously across all stakers, with each pool identified by a unique `keccak256` hash.

---

## Example Flow

1. Owner deploys the contract with a `rewardToken` address
2. Owner creates a pool for a given ERC20 token and reward rate
3. Owner funds the contract with `rewardToken` balance
4. User approves and calls `stake(poolId, amount)`
5. Rewards accumulate per second proportional to the user's share of `totalStaked`
6. User calls `claimRewards(poolId)` → receives pending rewards
7. User calls `withdraw(poolId, amount)` → receives staked tokens + pending rewards

---

## Key Features

| Feature | Detail |
|---|---|
| Multi-pool support | Each pool identified by `keccak256(token, rewardRate, timestamp, chainId)` |
| Per-token accumulator | `rewardPerTokenStored` tracks global rewards; `rewardDebt` isolates each user's share |
| Auto-liquidation on re-stake | Pending rewards paid out before updating user position |
| Safe reward transfers | Caps payout to available balance instead of reverting |
| Emergency withdrawal | Owner can recover any token from the contract |

---

## Security Measures

- CEI pattern on `withdraw` (state updated before token transfer)
- `ReentrancyGuard` on `stake`, `withdraw`, and `claimRewards`
- `SafeERC20` wrapping all ERC20 calls
- `Ownable` gates pool creation and reward rate updates
- `immutable` on `rewardToken`

---

## Testing — 14 Tests

| Suite | Type |
|---|---|
| `YieldFarmingPool.t.sol` | Unit (happy path, multi-user, multi-pool, reverts, edge cases) |

```bash
forge test
forge test -vvv
forge test --match-test testStakeAndRewards -vvv
```

---

## Gas Estimates

| Function | Gas |
|---|---|
| `createPool` | ~150,000 |
| `stake` | ~80,000 |
| `withdraw` | ~70,000 |
| `claimRewards` | ~60,000 |

---

## Tech Stack

- **Solidity** `^0.8.19`
- **Foundry**
- **OpenZeppelin Contracts** — `SafeERC20`, `ReentrancyGuard`, `Ownable`

---

## Project Structure

```
src/
  YieldFarmingPool.sol
  MockToken.sol
test/
  YieldFarmingPool.t.sol
.github/workflows/
  test.yml
```

---

## Getting Started

```bash
git clone https://github.com/sergiiogg7/yield-farming-app.git
cd yield-farming-app
forge build
forge test
```
