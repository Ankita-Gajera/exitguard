// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";

/// @notice Test double for Reactive Network's system contract.
/// @dev Stricter than the real one on purpose: subscribing twice to the same criteria, or unsubscribing from
///      criteria that were never subscribed, reverts. That makes the reference counting in ExitGuardReactive
///      observable in tests.
contract MockSystemContract {
    struct CallbackRequest {
        address sender;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    error AlreadySubscribed();
    error NotSubscribed();

    mapping(bytes32 key => bool active) public subscribed;
    mapping(address subscriber => uint256 count) public subscriptionsOf;
    mapping(address account => uint256 amount) public debt;

    uint256 public subscribeCalls;
    uint256 public unsubscribeCalls;

    CallbackRequest[] internal _callbacks;

    receive() external payable { }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        bytes32 key = _key(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_);

        if (subscribed[key]) {
            revert AlreadySubscribed();
        }

        subscribed[key] = true;
        ++subscriptionsOf[msg.sender];
        ++subscribeCalls;
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        bytes32 key = _key(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_);

        if (!subscribed[key]) {
            revert NotSubscribed();
        }

        subscribed[key] = false;
        --subscriptionsOf[msg.sender];
        ++unsubscribeCalls;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        _callbacks.push(
            CallbackRequest({
                sender: msg.sender,
                chainId: config_.chainId,
                recipient: config_.recipient,
                gasLimit: config_.gasLimit,
                payload: config_.payload
            })
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // Test helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Delivers a log to a reactive contract the way the network does: as a call from this address.
    function deliver(IReactive reactive_, IReactive.LogRecord calldata log_) external {
        reactive_.react(log_);
    }

    function isSubscribed(
        address subscriber_,
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external view returns (bool) {
        return subscribed[_key(subscriber_, chainId_, contract_, topic0_, topic1_, topic2_, topic3_)];
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 index_) external view returns (CallbackRequest memory) {
        return _callbacks[index_];
    }

    function setDebt(address account_, uint256 amount_) external {
        debt[account_] = amount_;
    }

    function _key(
        address subscriber_,
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(subscriber_, chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
    }
}
