// Encrypt the brokerage credentials and upload them to the DON, then print the slot + version to give the
// token contract (`setSecrets`).
require("dotenv").config()
const { SecretsManager } = require("@chainlink/functions-toolkit")
const { ethers } = require("ethers")

async function main() {
  const required = [
    "PRIVATE_KEY", "RPC_URL", "FUNCTIONS_ROUTER", "DON_ID", "GATEWAY_URLS",
    "BROKER_BASE_URL", "BROKER_KEY", "BROKER_SECRET",
  ]
  for (const key of required) if (!process.env[key]) throw Error(`missing env var ${key}`)

  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL)
  const signer = new ethers.Wallet(process.env.PRIVATE_KEY, provider)

  const manager = new SecretsManager({
    signer,
    functionsRouterAddress: process.env.FUNCTIONS_ROUTER,
    donId: process.env.DON_ID,
  })
  await manager.initialize()

  const encrypted = await manager.encryptSecrets({
    brokerBaseUrl: process.env.BROKER_BASE_URL,
    brokerKey: process.env.BROKER_KEY,
    brokerSecret: process.env.BROKER_SECRET,
  })

  const slotId = Number(process.env.SECRETS_SLOT || 0)
  const upload = await manager.uploadEncryptedSecretsToDON({
    encryptedSecretsHexstring: encrypted.encryptedSecrets,
    gatewayUrls: process.env.GATEWAY_URLS.split(","),
    slotId,
    minutesUntilExpiration: Number(process.env.SECRETS_MINUTES || 1440),
  })
  if (!upload.success) throw Error("upload failed")
  console.log(`uploaded. slot=${slotId} version=${upload.version}`)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
