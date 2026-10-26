# tokenized-equities

Reference contracts for putting an equity on-chain in three different ways. **Educational code, not audited.**

| Contract | Asset | Collateral | Backing |
|---|---|---|---|
| `BackedEquityToken` | off-chain equity | shares held at a brokerage | direct, 1:1 (+ 200% reserve check on mint) |
| `SyntheticEquityToken` | off-chain equity | native currency, on-chain | synthetic, price-feed driven |
| `NativeTokenBridge` | wrapped native token | the locked token itself | direct, lock-and-mint across chains |

## How each one works

### BackedEquityToken
- The owner mints. Before minting, an off-chain job reports the brokerage portfolio value; the mint only goes through if `value >= 200% x (supply + pending + new tokens) x price`.
- Anyone redeems. Tokens are burned up-front, an off-chain job sells the shares, buys the redemption coin and delivers it to the contract, then the holder calls `withdraw()`.
- A failed or errored redemption re-mints the burned tokens. Payouts are capped at the amount quoted at request time.
- Each request settles exactly once; unknown or repeated callbacks revert.
- Optional proof of reserve: `setReserveFeed(feed)` adds an independent attestation. When set, a mint also needs the attested reserves to cover 200% of the new supply, both when requested and when settled. A stale or broken feed rejects the mint (it never leaves a request stuck) and does not affect redemptions.

### SyntheticEquityToken
- Deposit native currency, mint against it, keep the health factor at or above 1 (200% collateral).
- `redeemAndBurn` returns collateral of equal USD value.
- `liquidate` lets anyone repay an unhealthy position and take its collateral plus 10%.

### NativeTokenBridge
- Home chain: tokens are locked / released. Other chains: tokens are minted / burned.
- Each bridge only accepts messages from the remote bridge address the owner registered for that chain.
- Fees are paid in native currency; any excess is refunded.

## Layout

```
src/                 contracts
src/bridge/          wrapped token, bridged token, bridge
src/libraries/       price-feed reader (staleness, positivity, 18-decimal normalisation)
functions/sources/   off-chain jobs (portfolio value, redemption settlement)
functions/           local simulator and secrets upload
script/              deploy scripts
test/                Foundry unit tests and mocks
test/invariant/      stateful fuzzing of the backed token (ledger, pending mints, cover, payout caps)
```

## Setup

Requirements: Foundry, Node 18+.

```
npm install
forge install foundry-rs/forge-std
forge build
forge test
```

Copy `.env.example` to `.env` and fill it in. Brokerage credentials are uploaded as encrypted DON-hosted
secrets with `npm run upload-secrets`; they are never stored on-chain.

Simulate the off-chain jobs before deploying:

```
npm run simulate:mint
npm run simulate:redeem -- <tokensWad> <quotedPayout> <coinDecimals> <destination>
```

## Things to settle before real use

- **Brokerage adapter.** `functions/sources/*.js` use a generic REST layout (`/v2/account`, `/v2/orders`, ...). Map them to your provider and set `EQUITY_SYMBOL` / `COIN_SYMBOL`.
- **Execution limits.** A single off-chain request has a short time budget and a small HTTP-call budget. A full sell, buy and withdraw cycle with polling may not fit; plan to split it or settle off-chain and report the result.
- **Price-feed age.** Equity feeds only update while the market is open. `MAX_PRICE_AGE` is a deliberate per-deployment choice, not a default.
- **Trust.** The backed token trusts the brokerage and the off-chain job. The optional reserve feed narrows that, but only as far as the feed itself is trustworthy.
- **Missing pieces.** No fees, no allow-lists / KYC, no corporate-action handling (splits, dividends), no bad-debt handling in the synthetic token.

## License

MIT
