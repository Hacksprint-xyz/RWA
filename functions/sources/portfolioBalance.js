// Off-chain job: report the brokerage portfolio value for BackedEquityToken.sendMintRequest.
//
// Runs inside the Chainlink Functions sandbox (globals: Functions, secrets, args).
// Secrets expected: brokerBaseUrl, brokerKey, brokerSecret
// Returns: portfolio value in USD scaled to 18 decimals, ABI-encoded as uint256.
//
// The endpoint and field names below follow a common REST brokerage layout; adapt them to your provider.

const toWad = (decimalString) => {
  const [whole, frac = ""] = String(decimalString).split(".")
  const fracWad = (frac + "0".repeat(18)).slice(0, 18)
  return BigInt(whole) * 10n ** 18n + BigInt(fracWad)
}

const response = await Functions.makeHttpRequest({
  method: "GET",
  url: `${secrets.brokerBaseUrl}/v2/account`,
  headers: {
    accept: "application/json",
    "X-API-KEY-ID": secrets.brokerKey,
    "X-API-SECRET-KEY": secrets.brokerSecret,
  },
})

if (response.error || response.status !== 200 || !response.data) {
  throw Error(`balance request failed (status ${response.status})`)
}

return Functions.encodeUint256(toWad(response.data.portfolio_value))
