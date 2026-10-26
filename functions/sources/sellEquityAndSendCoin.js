// Off-chain job: settle a BackedEquityToken redemption.
//
//   1. sell the equity at the brokerage
//   2. use the proceeds to buy the redemption coin
//   3. withdraw the coin to the token contract
//
// args[0] tokens burned (18 decimals, integer string)
// args[1] quoted payout in redemption-coin base units (integer string)
// args[2] redemption-coin decimals
// args[3] address of the token contract (withdrawal destination)
// secrets: brokerBaseUrl, brokerKey, brokerSecret
//
// Returns the amount of coin (base units) actually delivered, or 0 on any failure so the contract refunds
// the holder. The amount is capped at the quote, so slippage is borne by the holder, never by the reserve.
//
// Sandbox limits to keep in mind: roughly 10 s of run time and a handful of HTTP calls per request. This
// reference keeps polling short; production setups usually split the settlement across several calls or run
// it off-chain and use Functions only to report the result.

const EQUITY_SYMBOL = "EQUITY" // replace with the ticker you are tokenizing
const COIN_SYMBOL = "COINUSD" // replace with the brokerage's symbol for the redemption coin
const POLL_MS = 1000
const MAX_POLLS = 3

const tokensWad = BigInt(args[0])
const quotedPayout = BigInt(args[1])
const coinDecimals = Number(args[2])
const destination = args[3]

const FAIL = Functions.encodeUint256(0n)

const headers = {
  accept: "application/json",
  "content-type": "application/json",
  "X-API-KEY-ID": secrets.brokerKey,
  "X-API-SECRET-KEY": secrets.brokerSecret,
}
const api = (method, path, data) =>
  Functions.makeHttpRequest({ method, url: `${secrets.brokerBaseUrl}${path}`, headers, data })

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// "123456789000000000000" (18 decimals) -> "123.456789"
const fromUnits = (value, decimals) => {
  const s = value.toString().padStart(decimals + 1, "0")
  const whole = s.slice(0, s.length - decimals)
  const frac = s.slice(s.length - decimals).replace(/0+$/, "")
  return frac ? `${whole}.${frac}` : whole
}

const placeOrder = async (body) => {
  const res = await api("POST", "/v2/orders", { type: "market", time_in_force: "gtc", ...body })
  if (res.error || res.status !== 200 || !res.data) return null
  return res.data // { id, status, ... }
}

const waitForFill = async (orderId) => {
  for (let i = 0; i < MAX_POLLS; i++) {
    const res = await api("GET", `/v2/orders/${orderId}`)
    if (!res.error && res.status === 200 && res.data) {
      if (res.data.status === "filled") return res.data
      if (["canceled", "expired", "rejected"].includes(res.data.status)) return null
    }
    await sleep(POLL_MS)
  }
  await api("DELETE", `/v2/orders/${orderId}`) // best effort: do not leave an open order behind
  return null
}

// 1. sell
const sell = await placeOrder({ side: "sell", symbol: EQUITY_SYMBOL, qty: fromUnits(tokensWad, 18) })
if (!sell) return FAIL
const sold = await waitForFill(sell.id)
if (!sold) return FAIL
const proceedsUsd = Number(sold.filled_qty) * Number(sold.filled_avg_price)

// 2. buy the redemption coin with the proceeds
const buy = await placeOrder({ side: "buy", symbol: COIN_SYMBOL, notional: proceedsUsd.toFixed(2) })
if (!buy) return FAIL
const bought = await waitForFill(buy.id)
if (!bought) return FAIL

// 3. withdraw, capped at the quote
const boughtUnits = BigInt(Math.floor(Number(bought.filled_qty) * 10 ** coinDecimals))
const payout = boughtUnits < quotedPayout ? boughtUnits : quotedPayout
const transfer = await api("POST", "/v2/wallets/transfers", {
  amount: fromUnits(payout, coinDecimals),
  address: destination,
  asset: COIN_SYMBOL.replace("USD", ""),
})
if (transfer.error || transfer.status !== 200) return FAIL

return Functions.encodeUint256(payout)
