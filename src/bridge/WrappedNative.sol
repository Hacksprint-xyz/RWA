// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 1:1 ERC-20 wrapper around the chain's native currency. Lives on the bridge's "home" chain.
contract WrappedNative is ERC20 {
    error WrappedNative__TransferFailed();

    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor() ERC20("Wrapped Native", "WNATIVE") { }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert WrappedNative__TransferFailed();
        emit Withdrawal(msg.sender, amount);
    }
}
