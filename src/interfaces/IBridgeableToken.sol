// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IBridgeableToken {
    function bridgeMint(address to, uint256 amount) external;
    function bridgeBurn(address from, uint256 amount) external;
}
