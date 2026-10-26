# Local test record: what was written / modified vs. what already existed

> Setup prerequisites (Deno, Foundry/PATH, `.env`) are documented separately in `SETUP.md`.

Scope: the session that ran the prompt "get it to a green build and test run without changing
the intended behaviour". This doc marks, file by file and line by line, every change made to the
repository during that session, and separates it from code that already existed before the
session started.

---

## 1. Repository files modified during the session

Only one tracked file was modified. Nothing else in the repository was edited, added or deleted.

### 1.1 `functions/simulate.js` (modified)

- **Lines added:** 14-19 (6 lines: 2 comment + 4 code)
- **Lines removed:** none
- **Lines pre-existing and unchanged:** 1-13, 20-41 (everything else, byte-identical)
- **Reason:** before the session, running `node functions/simulate.js mint` with any of the
  `BROKER_*` env vars unset failed inside the toolkit with the cryptic message
  `secrets param not a string map`, because `undefined` values were passed in the `secrets`
  map. The session added an up-front validation that names the missing vars. The happy path
  (all env vars set) is byte-for-byte the same call into the toolkit as before.

**Before the session (entire file, 34 lines):**

```js
// Run an off-chain job locally before deploying it.
//   node functions/simulate.js mint
//   node functions/simulate.js redeem <tokensWad> <quotedPayout> <coinDecimals> <destination>
require("dotenv").config()
const fs = require("fs")
const path = require("path")
const { simulateScript, decodeResult, ReturnType } = require("@chainlink/functions-toolkit")

async function main() {
  const [mode, ...args] = process.argv.slice(2)
  const file = { mint: "portfolioBalance.js", redeem: "sellEquityAndSendCoin.js" }[mode]
  if (!file) throw Error("first argument must be 'mint' or 'redeem'")

  const result = await simulateScript({
    source: fs.readFileSync(path.join(__dirname, "sources", file)).toString(),
    args: mode === "redeem" ? args : [],
    secrets: {
      brokerBaseUrl: process.env.BROKER_BASE_URL,
      brokerKey: process.env.BROKER_KEY,
      brokerSecret: process.env.BROKER_SECRET,
    },
    maxExecutionTimeMs: 10000,
    numAllowedQueries: 5,
  })

  console.log(result.capturedTerminalOutput)
  if (result.errorString) return console.error("error:", result.errorString)
  console.log("uint256 result:", decodeResult(result.responseBytesHexstring, ReturnType.uint256).toString())
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
```

**After the session (entire file, 41 lines; the only delta is the marked block):**

```js
// Run an off-chain job locally before deploying it.
//   node functions/simulate.js mint
//   node functions/simulate.js redeem <tokensWad> <quotedPayout> <coinDecimals> <destination>
require("dotenv").config()
const fs = require("fs")
const path = require("path")
const { simulateScript, decodeResult, ReturnType } = require("@chainlink/functions-toolkit")

async function main() {
  const [mode, ...args] = process.argv.slice(2)
  const file = { mint: "portfolioBalance.js", redeem: "sellEquityAndSendCoin.js" }[mode]
  if (!file) throw Error("first argument must be 'mint' or 'redeem'")

  // <<< BEGIN ADDED IN SESSION (lines 14-19)
  // The toolkit rejects a secrets map whose values are not strings; missing env vars would
  // otherwise surface as the cryptic "secrets param not a string map".
  const missing = ["BROKER_BASE_URL", "BROKER_KEY", "BROKER_SECRET"].filter(
    (key) => !process.env[key]
  )
  if (missing.length) throw Error(`missing env var(s): ${missing.join(", ")} (see .env.example)`)
  // <<< END ADDED IN SESSION

  const result = await simulateScript({
    source: fs.readFileSync(path.join(__dirname, "sources", file)).toString(),
    args: mode === "redeem" ? args : [],
    secrets: {
      brokerBaseUrl: process.env.BROKER_BASE_URL,
      brokerKey: process.env.BROKER_KEY,
      brokerSecret: process.env.BROKER_SECRET,
    },
    maxExecutionTimeMs: 10000,
    numAllowedQueries: 5,
  })

  console.log(result.capturedTerminalOutput)
  if (result.errorString) return console.error("error:", result.errorString)
  console.log("uint256 result:", decodeResult(result.responseBytesHexstring, ReturnType.uint256).toString())
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
```

**Unified diff (old → new):**

```diff
--- a/functions/simulate.js
+++ b/functions/simulate.js
@@ -9,6 +9,12 @@ async function main() {
   const [mode, ...args] = process.argv.slice(2)
   const file = { mint: "portfolioBalance.js", redeem: "sellEquityAndSendCoin.js" }[mode]
   if (!file) throw Error("first argument must be 'mint' or 'redeem'")
+
+  // The toolkit rejects a secrets map whose values are not strings; missing env vars would
+  // otherwise surface as the cryptic "secrets param not a string map".
+  const missing = ["BROKER_BASE_URL", "BROKER_KEY", "BROKER_SECRET"].filter(
+    (key) => !process.env[key]
+  )
+  if (missing.length) throw Error(`missing env var(s): ${missing.join(", ")} (see .env.example)`)
 
   const result = await simulateScript({
     source: fs.readFileSync(path.join(__dirname, "sources", file)).toString(),
```

---

## 2. Repository files NOT modified (pre-existing, verified only)

These existed before the session and were read, compiled and tested, but never edited. Any
build/test result reported in the session applies to them as-is.

| Path | Role | Touched? |
|---|---|---|
| `src/BackedEquityToken.sol` | brokerage-backed token (Chainlink Functions) | no |
| `src/SyntheticEquityToken.sol` | native-collateral synthetic with liquidation | no |
| `src/bridge/NativeTokenBridge.sol` | CCIP lock-and-mint bridge | no |
| `src/bridge/WrappedNative.sol` | home-chain wrapped native | no |
| `src/bridge/BridgedWrappedNative.sol` | remote-chain bridged token | no |
| `src/interfaces/IBridgeableToken.sol` | bridge token interface | no |
| `src/libraries/PriceFeedLib.sol` | price-feed reader (staleness / decimals) | no |
| `test/BackedEquityToken.t.sol` | 22 unit tests | no |
| `test/SyntheticEquityToken.t.sol` | 7 unit tests | no |
| `test/NativeTokenBridge.t.sol` | 9 unit tests | no |
| `test/invariant/BackedEquityToken.invariant.t.sol` | 4 invariants + handler | no |
| `test/mocks/Mocks.sol` | price feed, coin, Functions router, CCIP router mocks | no |
| `script/DeployBackedEquity.s.sol` | deploy script | no |
| `script/DeploySyntheticEquity.s.sol` | deploy script | no |
| `script/DeployBridge.s.sol` | deploy script | no |
| `functions/sources/portfolioBalance.js` | mint off-chain job | no |
| `functions/sources/sellEquityAndSendCoin.js` | redeem off-chain job | no |
| `functions/uploadSecrets.js` | DON secrets upload | no |
| `foundry.toml`, `package.json`, `README.md`, `.env.example`, `.gitignore`, `.gitmodules` | config / docs | no |
| `lib/forge-std` (v1.17.0 submodule) | test framework | no (pin already present before session) |

Review conclusion recorded in the session: no confirmed logic bug was found in any `src/`
contract, therefore no Solidity line was changed and no test was weakened or deleted.

---

## 3. Files written OUTSIDE the repository (temporary harness, not part of the project)

Written during the session into
`C:\Users\mrsur\AppData\Local\Temp\opencode\` to exercise the off-chain jobs against a
mocked HTTP layer (the official simulator additionally requires Deno, which is not installed
on this machine). These are new files, not modifications of anything:

| File | What it is |
|---|---|
| `mock-broker.js` | new — tiny HTTP server implementing the generic brokerage layout (`/v2/account`, `/v2/orders`, `/v2/orders/:id` GET/DELETE, `/v2/wallets/transfers`) used only for local testing |
| `run-sim.js` | new — loads `functions/sources/*.js` and injects the same sandbox globals the toolkit provides (`Functions.makeHttpRequest` with the toolkit's response shape, `secrets`, `args`, `encodeUint256`) |

Neither file is imported by, or required for, anything in the repository.

---

## 4. Verification state after the (single) modification

- `forge build` → Compiler run successful (unchanged by the edit; no Solidity was touched).
- `forge test` → 39 passed / 0 failed (22 backed + 7 synthetic + 9 bridge + 4 invariants).
- `forge test --match-path "test/invariant/*" -vv` → 4/4 invariants pass (128 runs, 8192 calls, 0 reverts).
- `node functions/simulate.js mint` without env vars → now fails with
  `missing env var(s): BROKER_BASE_URL, BROKER_KEY, BROKER_SECRET (see .env.example)`;
  with env vars set it proceeds and surfaces the toolkit's own Deno requirement.
- Jobs exercised via the temp harness: mint returned `1234567890000000000000000` for
  `portfolio_value "1234567.89"`; redeem returned `125000000` (payout below quote) and
  `50000000` (capped at quote), matching the contract's quote-cap semantics.
