# Setup & environment guide

Everything needed to install, configure and run this project on a fresh machine, written from
what this session actually observed and used. Companion to `changes.md` (which records the one
code change made during the session).

---

## 1. Things to install

| Tool | Needed for | Version used here | Installed? |
|---|---|---|---|
| Node.js | off-chain jobs, secrets upload, npm deps | v24.12.0 (Node 18+ required) | yes |
| Foundry (`forge`) | build, test, deploy scripts | forge 1.8.5 | yes, but **not on PATH** (see §2) |
| Deno | `npm run simulate:*` — the Functions toolkit sandbox runs source in Deno | any recent | **not installed** |
| git + submodule support | fetching `forge-std` | any recent | yes |

### 1.1 Foundry

Installed here under `%USERPROFILE%\.foundry\bin\` (`forge.exe`, `cast.exe`, `anvil.exe`,
`chisel.exe`). The installer normally offers to add it to PATH; on this machine it was not on
PATH, so every session command prefixed it (see §2).

Update/reinstall tool: `foundryup` (also lives in the same bin folder).

### 1.2 Deno

`@chainlink/functions-toolkit@0.2.8` spawns a Deno sandbox inside `simulateScript`. Without
Deno, `npm run simulate:mint` / `simulate:redeem` fail with:

```
Error: Deno must be installed and accessible via the PATH environment variable ...
```

Install options (any one), then confirm with `deno --version`:

```
winget install DenoLang.Deno        # Windows, winget
scoop install deno                  # Windows, scoop
choco install deno                  # Windows, chocolatey
```

This was left uninstalled during the session because adding system tools needs your approval;
the job logic was instead verified through a local mock harness (see `changes.md` §3).

### 1.3 npm dependencies

```
npm install
```

Brings in everything from `package.json`: `@chainlink/contracts@1.2.0`, `@chainlink/contracts-ccip`,
`@chainlink/functions-toolkit`, `@openzeppelin/contracts@5.0.2`, `dotenv`, `ethers`. No other
dependency may be added without asking.

Note: on Node 24 the toolkit's optional `ganache` dependency prints a harmless
`uws_win32_...node` fallback warning. Cosmetic only — simulation still works once Deno exists.

### 1.4 forge-std

```
forge install foundry-rs/forge-std
```

Already present as a git submodule at `lib/forge-std` (v1.17.0). On a fresh clone use:

```
git submodule update --init --recursive
```

---

## 2. PATH configuration

### 2.1 Foundry (required for all forge commands)

Temporary (current PowerShell session only — this is what the session used):

```powershell
$env:Path = "$env:USERPROFILE\.foundry\bin;$env:Path"
forge --version
```

Permanent (user-level, takes effect in new terminals):

```powershell
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:USERPROFILE\.foundry\bin",
  "User"
)
```

### 2.2 Deno (required only for `npm run simulate:*`)

If installed via winget/scoop/choco it normally lands on PATH automatically. Verify in a
**new** terminal:

```
deno --version
```

If not found, add the install folder (commonly `%LOCALAPPDATA%\Deno`) to the user PATH the
same way as above.

### 2.3 Sanity checklist

```
node --version     -> v18 or newer
npm --version      -> any recent
forge --version    -> any recent (1.8.5 here)
deno --version     -> any recent (needed only for simulate)
```

---

## 3. `.env` configuration

Copy the template and fill it in — never commit the real file:

```
copy .env.example .env
```

### 3.1 Variable reference

| Variable | Meaning | Format / notes | Needed by |
|---|---|---|---|
| `PRIVATE_KEY` | deployer / signer key | hex, no `0x` prefix issues either way — used via `vm.envUint` | upload-secrets, all deploy scripts |
| `RPC_URL` | chain RPC endpoint | https URL | upload-secrets |
| `FUNCTIONS_ROUTER` | Chainlink Functions router address | 0x… | upload-secrets, DeployBackedEquity |
| `DON_ID` | DON identifier | bytes32 hex | upload-secrets, DeployBackedEquity |
| `FUNCTIONS_SUBSCRIPTION_ID` | Functions subscription id | decimal integer | DeployBackedEquity |
| `GATEWAY_URLS` | DON gateway URLs | comma-separated list | upload-secrets |
| `SECRETS_SLOT` | DON-hosted secrets slot | integer, default `0` | DeployBackedEquity (`setSecrets` initial) |
| `SECRETS_VERSION` | secrets version returned by the upload | decimal integer | DeployBackedEquity |
| `EQUITY_FEED` | equity/USD price feed address | 0x… | DeployBackedEquity, DeploySyntheticEquity |
| `COIN_FEED` | redemption-coin/USD price feed address | 0x… | DeployBackedEquity |
| `NATIVE_FEED` | native-asset/USD price feed address | 0x… | DeploySyntheticEquity |
| `REDEMPTION_COIN` | ERC-20 used for redemptions | 0x…, must implement `decimals()` | DeployBackedEquity |
| `MAX_PRICE_AGE` | max feed answer age, seconds | e.g. `86400` — deliberate per-deployment choice (equity feeds idle when markets close) | DeployBackedEquity, DeploySyntheticEquity |
| `BROKER_BASE_URL` | brokerage REST base URL | https URL, no trailing path | simulate, upload-secrets |
| `BROKER_KEY` | brokerage API key id | string | simulate, upload-secrets |
| `BROKER_SECRET` | brokerage API secret | string | simulate, upload-secrets |
| `CCIP_ROUTER` | CCIP router address on the target chain | 0x… | DeployBridge |
| `HOME_CHAIN_SELECTOR` | CCIP chain selector of the home chain | uint64 decimal | DeployBridge |
| `THIS_CHAIN_SELECTOR` | CCIP chain selector of the chain being deployed to | uint64 decimal | DeployBridge |
| `WRAPPED_NATIVE` | existing wrapped-native token on the home chain (optional) | 0x… or leave empty — DeployBridge deploys a fresh one when empty | DeployBridge |

`SECRETS_MINUTES` (optional, used by `functions/uploadSecrets.js`, default 1440) controls how
long uploaded secrets live on the DON.

### 3.2 Per-command minimum env

- `npm run simulate:mint` / `simulate:redeem`: `BROKER_BASE_URL`, `BROKER_KEY`, `BROKER_SECRET`
  (+ Deno on PATH). Missing vars now fail fast with
  `missing env var(s): ... (see .env.example)` — this validation is the session's only code
  change (`functions/simulate.js`, see `changes.md` §1).
- `npm run upload-secrets`: everything in §3.1 marked for upload-secrets, i.e. signer, RPC,
  Functions router, DON id, gateways and the three broker vars.
- `forge script script/DeployBackedEquity.s.sol`: all `DeployBackedEquity` vars above plus
  `PRIVATE_KEY`; run the script from the repo root so `vm.readFile("functions/sources/...")`
  resolves.
- `forge script script/DeploySyntheticEquity.s.sol`: `PRIVATE_KEY`, `EQUITY_FEED`,
  `NATIVE_FEED`, `MAX_PRICE_AGE`.
- `forge script script/DeployBridge.s.sol`: `PRIVATE_KEY`, `CCIP_ROUTER`,
  `HOME_CHAIN_SELECTOR`, `THIS_CHAIN_SELECTOR`, optional `WRAPPED_NATIVE`. Run once per
  chain, then call `setRemoteBridge` on every bridge with the others' addresses.

---

## 4. Build, test, run — verification order

```powershell
# 0. PATH (new terminal, or per-session prefix)
$env:Path = "$env:USERPROFILE\.foundry\bin;$env:Path"

# 1. deps
npm install
git submodule update --init --recursive   # or: forge install foundry-rs/forge-std

# 2. build
forge build                                # expect: Compiler run successful

# 3. unit + invariant tests
forge test                                 # expect: 39 passed, 0 failed
forge test --match-path "test/invariant/*" -vv   # expect: 4/4 invariants, 0 reverts

# 4. off-chain jobs (needs Deno + filled .env)
copy .env.example .env                     # then fill BROKER_* at minimum
npm run simulate:mint
npm run simulate:redeem -- <tokensWad> <quotedPayout> <coinDecimals> <destination>

# 5. secrets + deploy (needs real network values)
npm run upload-secrets
forge script script/DeployBackedEquity.s.sol --rpc-url $env:RPC_URL --broadcast
forge script script/DeploySyntheticEquity.s.sol --rpc-url $env:RPC_URL --broadcast
forge script script/DeployBridge.s.sol --rpc-url $env:RPC_URL --broadcast
```

---

## 5. Environment quirks observed on this machine (session log)

1. `forge` not on PATH — every command used the `$env:USERPROFILE\.foundry\bin` prefix
   (§2.1). Remember this in any new terminal.
2. Deno missing — official simulate entrypoint cannot run; job logic was validated against a
   temporary local mock HTTP layer instead (`changes.md` §3). Install Deno (§1.2) to use the
   official path.
3. `ganache`/µWS warning under Node 24 — harmless fallback message from the toolkit's
   optional local-testnet dependency; ignore it.
4. `.env` not present in the repo (only `.env.example`) — as intended; copy and fill locally.
5. No `.env` secrets were committed or written during the session.
