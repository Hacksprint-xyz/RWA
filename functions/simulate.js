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

  // The toolkit rejects a secrets map whose values are not strings; missing env vars would
  // otherwise surface as the cryptic "secrets param not a string map".
  const missing = ["BROKER_BASE_URL", "BROKER_KEY", "BROKER_SECRET"].filter(
    (key) => !process.env[key]
  )
  if (missing.length) throw Error(`missing env var(s): ${missing.join(", ")} (see .env.example)`)

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
