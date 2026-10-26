// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Script } from "forge-std/Script.sol";
import { SyntheticEquityToken } from "../src/SyntheticEquityToken.sol";

contract DeploySyntheticEquity is Script {
    function run() external returns (SyntheticEquityToken token) {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        token = new SyntheticEquityToken(
            "Synthetic Equity",
            "sEQ",
            vm.envAddress("EQUITY_FEED"),
            vm.envAddress("NATIVE_FEED"),
            vm.envUint("MAX_PRICE_AGE")
        );
        vm.stopBroadcast();
    }
}
