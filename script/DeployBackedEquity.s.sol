// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Script } from "forge-std/Script.sol";
import { BackedEquityToken } from "../src/BackedEquityToken.sol";

/// forge script script/DeployBackedEquity.s.sol --rpc-url $RPC_URL --broadcast
contract DeployBackedEquity is Script {
    function run() external returns (BackedEquityToken token) {
        BackedEquityToken.Config memory cfg = BackedEquityToken.Config({
            subscriptionId: uint64(vm.envUint("FUNCTIONS_SUBSCRIPTION_ID")),
            functionsRouter: vm.envAddress("FUNCTIONS_ROUTER"),
            donId: vm.envBytes32("DON_ID"),
            equityFeed: vm.envAddress("EQUITY_FEED"),
            redemptionCoinFeed: vm.envAddress("COIN_FEED"),
            redemptionCoin: vm.envAddress("REDEMPTION_COIN"),
            secretVersion: uint64(vm.envUint("SECRETS_VERSION")),
            secretSlot: uint8(vm.envUint("SECRETS_SLOT")),
            maxPriceAge: vm.envUint("MAX_PRICE_AGE")
        });

        string memory mintSource = vm.readFile("functions/sources/portfolioBalance.js");
        string memory redeemSource = vm.readFile("functions/sources/sellEquityAndSendCoin.js");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        token = new BackedEquityToken("Backed Equity", "bEQ", cfg, mintSource, redeemSource);
        vm.stopBroadcast();
    }
}
