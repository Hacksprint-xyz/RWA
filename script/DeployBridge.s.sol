// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Script } from "forge-std/Script.sol";
import { NativeTokenBridge } from "../src/bridge/NativeTokenBridge.sol";
import { WrappedNative } from "../src/bridge/WrappedNative.sol";

/// Run once per chain. On the home chain a WrappedNative is deployed (unless WRAPPED_NATIVE is set);
/// on every other chain the bridge deploys its own BridgedWrappedNative. Afterwards, call `setRemoteBridge`
/// on every bridge with the addresses of the others.
contract DeployBridge is Script {
    function run() external returns (NativeTokenBridge bridge) {
        uint64 home = uint64(vm.envUint("HOME_CHAIN_SELECTOR"));
        uint64 here = uint64(vm.envUint("THIS_CHAIN_SELECTOR"));
        address token = vm.envOr("WRAPPED_NATIVE", address(0));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        if (home == here && token == address(0)) token = address(new WrappedNative());
        bridge = new NativeTokenBridge(vm.envAddress("CCIP_ROUTER"), token, home, here);
        vm.stopBroadcast();
    }
}
