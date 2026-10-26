// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Client } from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import { CCIPReceiver } from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";

contract MockPriceFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public round;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        update(answer_);
    }

    function update(int256 answer_) public {
        answer = answer_;
        updatedAt = block.timestamp;
        round++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, round);
    }
}

contract MockCoin is ERC20 {
    uint8 private immutable i_decimals;

    constructor(uint8 decimals_) ERC20("Mock Coin", "MCK") {
        i_decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IOracleClient {
    function handleOracleFulfillment(bytes32 requestId, bytes memory response, bytes memory err) external;
}

/// @dev Stands in for the Functions router: hands out request ids and lets tests deliver responses.
contract MockFunctionsRouter {
    uint256 public nonce;
    bytes32 public lastRequestId;

    function sendRequest(uint64, bytes calldata, uint16, uint32, bytes32) external returns (bytes32 id) {
        id = keccak256(abi.encode(++nonce));
        lastRequestId = id;
    }

    function fulfill(address client, bytes32 id, bytes memory response, bytes memory err) external {
        IOracleClient(client).handleOracleFulfillment(id, response, err);
    }
}

/// @dev Stands in for the cross-chain router: fixed fee, records the last message, lets tests deliver one.
contract MockCcipRouter {
    uint256 public constant FEE = 0.01 ether;
    uint256 public nonce;

    uint64 public lastDestination;
    bytes public lastReceiver;
    bytes public lastData;
    address public lastSender;

    function getFee(uint64, Client.EVM2AnyMessage calldata) external pure returns (uint256) {
        return FEE;
    }

    function ccipSend(uint64 destination, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        require(msg.value >= FEE, "fee");
        lastDestination = destination;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastSender = msg.sender;
        return keccak256(abi.encode(++nonce));
    }

    function deliver(address target, uint64 sourceSelector, address remoteSender, bytes memory data) external {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256(abi.encode(++nonce)),
            sourceChainSelector: sourceSelector,
            sender: abi.encode(remoteSender),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        CCIPReceiver(target).ccipReceive(message);
    }
}
