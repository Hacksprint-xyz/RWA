// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IRouterClient } from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import { CCIPReceiver } from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import { ConfirmedOwner } from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { BridgedWrappedNative } from "./BridgedWrappedNative.sol";
import { IBridgeableToken } from "../interfaces/IBridgeableToken.sol";

/**
 * @title NativeTokenBridge
 * @notice Lock-and-mint bridge for a wrapped-native token using plain cross-chain messages (no token pools).
 *
 *  - Home chain:   tokens are locked in this contract and released when a message comes back.
 *  - Other chains: tokens are minted on receipt and burned when sent back.
 *
 * Each bridge only accepts messages from the remote bridge address the owner registered for that chain.
 *
 * @dev Educational code. Not audited.
 */
contract NativeTokenBridge is ConfirmedOwner, CCIPReceiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NativeTokenBridge__UnsupportedChain(uint64 chainSelector);
    error NativeTokenBridge__InvalidReceiver();
    error NativeTokenBridge__ZeroAmount();
    error NativeTokenBridge__NotEnoughValueSent(uint256 sent, uint256 required);
    error NativeTokenBridge__UnauthorizedSource(uint64 chainSelector, address sender);
    error NativeTokenBridge__TransferFailed();

    uint256 private constant DESTINATION_GAS_LIMIT = 200_000;

    address private immutable i_token; // WrappedNative on the home chain, BridgedWrappedNative elsewhere
    uint64 private immutable i_homeChainSelector;
    uint64 private immutable i_thisChainSelector;

    mapping(uint64 chainSelector => address remoteBridge) private s_remoteBridge;

    event RemoteBridgeSet(uint64 indexed chainSelector, address indexed bridge);
    event TokensSent(
        bytes32 indexed messageId, uint64 indexed destinationChainSelector, address indexed receiver, uint256 amount
    );
    event TokensReceived(uint64 indexed sourceChainSelector, address indexed receiver, uint256 amount);

    /// @param token pass address(0) on a non-home chain to deploy the bridged token alongside the bridge
    constructor(
        address router,
        address token,
        uint64 homeChainSelector,
        uint64 thisChainSelector
    )
        CCIPReceiver(router)
        ConfirmedOwner(msg.sender)
    {
        i_homeChainSelector = homeChainSelector;
        i_thisChainSelector = thisChainSelector;
        if (token == address(0)) {
            if (homeChainSelector == thisChainSelector) revert NativeTokenBridge__InvalidReceiver();
            i_token = address(new BridgedWrappedNative(address(this)));
        } else {
            i_token = token;
        }
    }

    function setRemoteBridge(uint64 chainSelector, address bridge) external onlyOwner {
        s_remoteBridge[chainSelector] = bridge;
        emit RemoteBridgeSet(chainSelector, bridge);
    }

    /**
     * @notice Send `amount` tokens to `receiver` on `destinationChainSelector`, paying the fee in native
     *         currency. Any excess `msg.value` is refunded.
     */
    function bridgeTokens(
        uint64 destinationChainSelector,
        address receiver,
        uint256 amount
    )
        external
        payable
        nonReentrant
        returns (bytes32 messageId)
    {
        address remote = s_remoteBridge[destinationChainSelector];
        if (remote == address(0)) revert NativeTokenBridge__UnsupportedChain(destinationChainSelector);
        if (receiver == address(0)) revert NativeTokenBridge__InvalidReceiver();
        if (amount == 0) revert NativeTokenBridge__ZeroAmount();

        // Take the tokens first, then message: if the message fails the whole call reverts.
        if (_isHome()) {
            IERC20(i_token).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            IBridgeableToken(i_token).bridgeBurn(msg.sender, amount);
        }

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(remote),
            data: abi.encode(receiver, amount),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: DESTINATION_GAS_LIMIT })),
            feeToken: address(0)
        });

        uint256 fee = IRouterClient(i_router).getFee(destinationChainSelector, message);
        if (fee > msg.value) revert NativeTokenBridge__NotEnoughValueSent(msg.value, fee);

        messageId = IRouterClient(i_router).ccipSend{ value: fee }(destinationChainSelector, message);
        emit TokensSent(messageId, destinationChainSelector, receiver, amount);

        uint256 excess = msg.value - fee;
        if (excess != 0) {
            (bool ok,) = msg.sender.call{ value: excess }("");
            if (!ok) revert NativeTokenBridge__TransferFailed();
        }
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        address expected = s_remoteBridge[message.sourceChainSelector];
        if (expected == address(0) || sender != expected) {
            revert NativeTokenBridge__UnauthorizedSource(message.sourceChainSelector, sender);
        }

        (address receiver, uint256 amount) = abi.decode(message.data, (address, uint256));
        if (_isHome()) {
            IERC20(i_token).safeTransfer(receiver, amount);
        } else {
            IBridgeableToken(i_token).bridgeMint(receiver, amount);
        }
        emit TokensReceived(message.sourceChainSelector, receiver, amount);
    }

    /// @notice Recover native currency left over from fee payments.
    function withdrawNative() external onlyOwner {
        (bool ok,) = owner().call{ value: address(this).balance }("");
        if (!ok) revert NativeTokenBridge__TransferFailed();
    }

    receive() external payable { }

    function _isHome() private view returns (bool) {
        return i_homeChainSelector == i_thisChainSelector;
    }

    function getToken() external view returns (address) {
        return i_token;
    }

    function getRemoteBridge(uint64 chainSelector) external view returns (address) {
        return s_remoteBridge[chainSelector];
    }

    function getHomeChainSelector() external view returns (uint64) {
        return i_homeChainSelector;
    }

    function getThisChainSelector() external view returns (uint64) {
        return i_thisChainSelector;
    }
}
