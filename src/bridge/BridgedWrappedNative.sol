// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IBridgeableToken } from "../interfaces/IBridgeableToken.sol";

/// @notice Representation of `WrappedNative` on non-home chains. Only the bridge can mint or burn.
contract BridgedWrappedNative is ERC20, IBridgeableToken {
    error BridgedWrappedNative__NotBridge();

    address private immutable i_bridge;

    event BridgeMint(address indexed to, uint256 amount);
    event BridgeBurn(address indexed from, uint256 amount);

    modifier onlyBridge() {
        if (msg.sender != i_bridge) revert BridgedWrappedNative__NotBridge();
        _;
    }

    constructor(address bridge) ERC20("Bridged Wrapped Native", "bWNATIVE") {
        i_bridge = bridge;
    }

    function bridgeMint(address to, uint256 amount) external onlyBridge {
        _mint(to, amount);
        emit BridgeMint(to, amount);
    }

    function bridgeBurn(address from, uint256 amount) external onlyBridge {
        _burn(from, amount);
        emit BridgeBurn(from, amount);
    }

    function getBridge() external view returns (address) {
        return i_bridge;
    }
}
