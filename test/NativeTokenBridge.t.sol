// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { NativeTokenBridge } from "../src/bridge/NativeTokenBridge.sol";
import { WrappedNative } from "../src/bridge/WrappedNative.sol";
import { BridgedWrappedNative } from "../src/bridge/BridgedWrappedNative.sol";
import { MockCcipRouter } from "./mocks/Mocks.sol";
import { Client } from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

contract NativeTokenBridgeTest is Test {
    uint64 constant HOME = 1;
    uint64 constant REMOTE = 2;

    MockCcipRouter router;
    WrappedNative wrapped;
    NativeTokenBridge homeBridge;
    NativeTokenBridge remoteBridge;
    BridgedWrappedNative bridged;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        router = new MockCcipRouter();
        wrapped = new WrappedNative();
        homeBridge = new NativeTokenBridge(address(router), address(wrapped), HOME, HOME);
        remoteBridge = new NativeTokenBridge(address(router), address(0), HOME, REMOTE);
        bridged = BridgedWrappedNative(remoteBridge.getToken());

        homeBridge.setRemoteBridge(REMOTE, address(remoteBridge));
        remoteBridge.setRemoteBridge(HOME, address(homeBridge));

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _sendHomeToRemote(uint256 amount) internal {
        vm.startPrank(alice);
        wrapped.deposit{ value: amount }();
        wrapped.approve(address(homeBridge), amount);
        homeBridge.bridgeTokens{ value: router.FEE() }(REMOTE, bob, amount);
        vm.stopPrank();
        router.deliver(address(remoteBridge), HOME, address(homeBridge), router.lastData());
    }

    function test_homeToRemoteLocksAndMints() public {
        _sendHomeToRemote(1 ether);
        assertEq(wrapped.balanceOf(address(homeBridge)), 1 ether);
        assertEq(wrapped.balanceOf(alice), 0);
        assertEq(bridged.balanceOf(bob), 1 ether);
    }

    function test_remoteToHomeBurnsAndUnlocks() public {
        _sendHomeToRemote(1 ether);

        uint256 fee = router.FEE(); // hoisted: an inline call would consume vm.prank
        vm.prank(bob);
        remoteBridge.bridgeTokens{ value: fee }(HOME, alice, 1 ether);
        assertEq(bridged.balanceOf(bob), 0);
        assertEq(bridged.totalSupply(), 0);

        router.deliver(address(homeBridge), REMOTE, address(remoteBridge), router.lastData());
        assertEq(wrapped.balanceOf(alice), 1 ether);
        assertEq(wrapped.balanceOf(address(homeBridge)), 0);
    }

    function test_excessFeeIsRefunded() public {
        vm.startPrank(alice);
        wrapped.deposit{ value: 1 ether }();
        wrapped.approve(address(homeBridge), 1 ether);
        uint256 before = alice.balance;
        homeBridge.bridgeTokens{ value: 1 ether }(REMOTE, bob, 1 ether);
        vm.stopPrank();
        assertEq(before - alice.balance, router.FEE());
    }

    function test_notEnoughFeeReverts() public {
        vm.startPrank(alice);
        wrapped.deposit{ value: 1 ether }();
        wrapped.approve(address(homeBridge), 1 ether);
        vm.expectRevert();
        homeBridge.bridgeTokens{ value: 1 wei }(REMOTE, bob, 1 ether);
        vm.stopPrank();
    }

    function test_unregisteredDestinationReverts() public {
        uint256 fee = router.FEE(); // hoisted: an inline call would consume vm.expectRevert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NativeTokenBridge.NativeTokenBridge__UnsupportedChain.selector, 99));
        homeBridge.bridgeTokens{ value: fee }(99, bob, 1 ether);
    }

    function test_messageFromUnknownSenderReverts() public {
        address attacker = makeAddr("attacker");
        bytes memory data = abi.encode(attacker, uint256(1 ether));
        vm.expectRevert(
            abi.encodeWithSelector(NativeTokenBridge.NativeTokenBridge__UnauthorizedSource.selector, REMOTE, attacker)
        );
        router.deliver(address(homeBridge), REMOTE, attacker, data);
    }

    function test_onlyRouterCanDeliver() public {
        vm.expectRevert();
        remoteBridge.ccipReceive(
            // empty message; the router check must reject before anything else runs
            _emptyMessage()
        );
    }

    function _emptyMessage() internal pure returns (Client.Any2EVMMessage memory m) { }

    function test_onlyBridgeCanMint() public {
        vm.expectRevert(BridgedWrappedNative.BridgedWrappedNative__NotBridge.selector);
        bridged.bridgeMint(alice, 1);
    }

    function test_wrappedNativeRoundTrip() public {
        vm.startPrank(alice);
        wrapped.deposit{ value: 1 ether }();
        wrapped.withdraw(1 ether);
        vm.stopPrank();
        assertEq(alice.balance, 10 ether);
    }
}

