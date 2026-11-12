// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Stand-in for an OP Stack `L1StandardBridge` in the console's browser test: takes the ETH and says so.
contract BridgeLike {
    event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);

    function bridgeETH(uint32, bytes calldata extraData_) external payable {
        emit ETHBridgeInitiated(msg.sender, msg.sender, msg.value, extraData_);
    }
}
