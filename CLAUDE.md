# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
forge build
forge test -vvv
forge test --match-test <name> -vvvv
forge coverage --no-match-coverage "script|test"   # coverage of src/ (CI gate: 95% lines)
forge snapshot --check                              # gas regression check
forge fmt --check                                   # CI enforces formatting
```

Dependencies (`forge-std`, `openzeppelin-contracts`) are git submodules in `lib/`; clone with `--recursive`.

## Architecture

One contract, `src/YieldFarmingPool.sol` (`ReentrancyGuard`, `Ownable2Step`, `Pausable`). Many pools, each identified by `keccak256(token, rewardRate, timestamp, chainId)`, all paying a single immutable `rewardToken`.

- Reward model: per-pool accumulator `rewardPerTokenStored` (scaled 1e18) and per-user `rewardDebt`. `_updatePool` must run before reading or changing balances.
- `stakedByToken[token]` tracks staked principal across pools. `_settlePayout` and `emergencyWithdraw` use it so principal is never paid out as rewards or recovered by the owner. `_settlePayout` must run before `stakedByToken` changes in the same call.
- Rewards that cannot be paid because the contract is underfunded are stored in `UserInfo.unpaidRewards` and paid later. `claimRewards` reverts with `RewardBalanceDepleted` when nothing can be paid.
- `withdraw` is never paused. `stake` and `claimRewards` are `whenNotPaused`.
- `MAX_REWARD_RATE` bounds the rate to avoid accumulator overflow.
- Custom errors are file-level declarations in `YieldFarmingPool.sol`.

## Tests

`test/utils/FarmBase.sol` holds the shared setup (three mock tokens, two pools, funded users). `YieldFarmingPool.t.sol` (unit, includes a reentrant staking token), `YieldFarmingPoolFuzz.t.sol` and `YieldFarmingPoolInvariant.t.sol` (handler over two pools, one of which stakes the reward token) extend or use it. `MockToken` lives in `test/mocks/`.

Tests are named `test_<function>_<scenario>_<result>` with `// Arrange`, `// Act`, `// Assert` blocks.

## CI

`.github/workflows/test.yml` runs `forge fmt --check`, `forge build --sizes`, `forge test` (profile `ci`), a 95% line-coverage gate on `src/`, `forge snapshot --check` and Slither. Update `.gas-snapshot` with `forge snapshot` after intentional gas changes.
