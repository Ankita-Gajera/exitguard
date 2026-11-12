// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ExitGuard } from "../../src/ExitGuard.sol";
import { ExitGuardReactive } from "../../src/ExitGuardReactive.sol";
import { MockUSD } from "../../src/demo/MockUSD.sol";
import { MockSystemContract } from "../mocks/MockSystemContract.sol";
import { MockCallbackProxy } from "../mocks/MockCallbackProxy.sol";

/// @notice Plain, well-behaved ERC-4626 vault.
contract SimpleVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Simple Vault", "svUSD") ERC4626(asset_) { }
}

/// @notice Deploys ExitGuard against test doubles of Reactive Network and offers helpers to push an event
///         through the whole pipeline: origin log -> `react` -> callback request -> callback proxy -> guard.
abstract contract Fixture is Test {
    /// @dev Address of the real system contract; the reactive contract has it hard-coded.
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    uint64 internal constant ETHEREUM_SEPOLIA = 11155111;
    uint64 internal constant BASE_SEPOLIA = 84532;

    uint64 internal constant DEFAULT_CALLBACK_GAS = 1_000_000;

    MockSystemContract internal system;
    MockCallbackProxy internal proxy;
    ExitGuardReactive internal reactive;
    ExitGuard internal guard;
    MockUSD internal usd;

    address internal alice = makeAddr("alice"); // owner of the guard
    address internal bob = makeAddr("bob"); // another depositor, unprotected
    address internal stranger = makeAddr("stranger");
    address internal coldWallet = makeAddr("coldWallet");

    /// @dev Number of callback requests already handed to the guard.
    uint256 private _delivered;

    function _deployCore() internal {
        vm.etch(SYSTEM_ADDR, address(new MockSystemContract()).code);
        system = MockSystemContract(payable(SYSTEM_ADDR));
        proxy = new MockCallbackProxy();
        usd = new MockUSD();

        vm.deal(alice, 100 ether);

        vm.startPrank(alice);
        reactive = new ExitGuardReactive{ value: 1 ether }(alice, BASE_SEPOLIA);
        guard = new ExitGuard{ value: 0.1 ether }(IPayable(payable(address(proxy))), address(reactive), alice);
        reactive.setGuard(address(guard));
        vm.stopPrank();
    }

    /// @dev Gives `account_` test dollars, deposits them into `vault_`, and returns the shares received.
    function _deposit(address account_, IERC4626 vault_, uint256 assets_) internal returns (uint256 shares_) {
        usd.mint(account_, assets_);

        vm.startPrank(account_);
        usd.approve(address(vault_), assets_);
        shares_ = vault_.deposit(assets_, account_);
        vm.stopPrank();
    }

    /// @dev Builds the record Reactive Network would hand to `react` for a log with the given topics.
    function _record(uint256 chainId_, address emitter_, bytes32[] memory topics_, bytes memory data_)
        internal
        view
        returns (IReactive.LogRecord memory record_)
    {
        uint256 count = topics_.length;

        record_.chainId = chainId_;
        record_.contractAddress = emitter_;
        record_.opCode = count;
        record_.data = data_;
        record_.blockNumber = block.number;
        record_.txHash = uint256(keccak256(abi.encode(chainId_, emitter_, topics_, data_, block.number)));

        if (count > 0) record_.topic0 = uint256(topics_[0]);
        if (count > 1) record_.topic1 = uint256(topics_[1]);
        if (count > 2) record_.topic2 = uint256(topics_[2]);
        if (count > 3) record_.topic3 = uint256(topics_[3]);
    }

    function _record(uint256 chainId_, Vm.Log memory entry_) internal view returns (IReactive.LogRecord memory) {
        return _record(chainId_, entry_.emitter, entry_.topics, entry_.data);
    }

    function _topics(bytes32 topic0_) internal pure returns (bytes32[] memory topics_) {
        topics_ = new bytes32[](1);
        topics_[0] = topic0_;
    }

    function _topics(bytes32 topic0_, bytes32 topic1_) internal pure returns (bytes32[] memory topics_) {
        topics_ = new bytes32[](2);
        topics_[0] = topic0_;
        topics_[1] = topic1_;
    }

    function _topics(bytes32 topic0_, bytes32 topic1_, bytes32 topic2_)
        internal
        pure
        returns (bytes32[] memory topics_)
    {
        topics_ = new bytes32[](3);
        topics_[0] = topic0_;
        topics_[1] = topic1_;
        topics_[2] = topic2_;
    }

    /// @dev First recorded log emitted by `emitter_` with signature `topic0_`.
    function _find(Vm.Log[] memory logs_, address emitter_, bytes32 topic0_) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length > 0 && logs_[i].topics[0] == topic0_) {
                return logs_[i];
            }
        }

        revert("log not found");
    }

    /// @dev Reactive Network notices an event and calls `react`.
    function _react(IReactive.LogRecord memory record_) internal {
        system.deliver(reactive, record_);
    }

    /// @dev The callback proxy delivers every callback requested since the last call. Returns how many.
    function _deliverPending() internal returns (uint256 count_) {
        uint256 total = system.callbackCount();

        for (; _delivered < total; ++_delivered) {
            MockSystemContract.CallbackRequest memory request = system.callbackAt(_delivered);

            (bool success, bytes memory result) =
                proxy.deliver(request.sender, request.recipient, request.gasLimit, request.payload);

            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }

            ++count_;
        }
    }

    /// @dev The whole pipeline for one log. Returns how many callbacks reached the guard.
    function _pipe(IReactive.LogRecord memory record_) internal returns (uint256) {
        _react(record_);
        return _deliverPending();
    }
}
