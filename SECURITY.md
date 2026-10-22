# Security

## Status

This repository has not been externally audited. Do not use it with real funds without an independent review.

## Assumptions and known limits

- The owner is trusted to fund the contract with reward tokens and to choose reasonable reward rates. The owner cannot touch staked principal, but can recover the unspent balance of the reward token with `emergencyWithdraw`, including rewards that stakers have earned and not yet claimed.
- When the contract holds fewer reward tokens than users have earned, the shortfall is kept as `unpaidRewards` and paid after the owner tops up the balance. Withdrawals of principal are never blocked by an underfunded balance.
- Rewards emitted while a pool has no stakers are not distributed.
- Staking and reward tokens must be standard ERC-20 tokens. Fee-on-transfer, rebasing and callback (ERC-777 style) tokens are not supported: the accounting would not match the real balances.
- Pools are never deactivated. Setting a pool's reward rate to zero stops its emission.
- `createPool` derives the pool id from the token, rate, timestamp and chain id. Two pools with the same token and rate can exist if created at different times.
- `getActivePools` returns every pool and is unbounded.
- Integer division in the accumulator can leave a few wei of dust per interaction.

## Invariants

- A pool's `totalStaked` equals the sum of its user positions.
- `stakedByToken[token]` equals the sum of `totalStaked` of the pools that stake that token.
- The contract holds at least all staked principal for every token.
- `rewardPerTokenStored` never decreases.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository. Do not open a public issue.
