// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Callback surface and events of an ExitGuard.
/// @notice Shared between the guard (destination chain) and its reactive contract (Reactive Network), so the
///         reactive side encodes callbacks with `abi.encodeCall` and subscribes by event selector.
interface IExitGuard {
    /// @notice Why an exit callback did nothing.
    enum SkipCause {
        NotArmed, // the owner has not armed this vault, or it has already exited
        NoShares, // the owner holds no shares in the vault
        NoAllowance, // the owner has not approved the guard to move their shares
        VaultLimit // the vault itself reports that nothing can be redeemed right now
    }

    /// @notice The owner asked the guard to protect their position in `vault`.
    event Armed(address indexed vault, address indexed receiver);

    /// @notice The position in `vault` is no longer protected (manual disarm, or a completed exit).
    event Disarmed(address indexed vault);

    /// @notice Shares were redeemed and the assets sent to the receiver.
    /// @param reason Label of the tripwire that fired (0 = manual exit by the owner).
    /// @param originChainId Chain of the event that tripped the wire.
    /// @param originTxHash Transaction that emitted the event that tripped the wire.
    event Exited(
        address indexed vault,
        uint8 indexed reason,
        uint256 shares,
        uint256 assets,
        uint256 originChainId,
        uint256 originTxHash
    );

    /// @notice The vault refused the redemption. The position stays armed so a later tripwire can retry.
    event ExitFailed(
        address indexed vault, uint8 indexed reason, uint256 originChainId, uint256 originTxHash, bytes revertData
    );

    /// @notice An exit was requested but there was nothing to do.
    event ExitSkipped(address indexed vault, uint8 indexed reason, SkipCause cause);

    /// @notice The owner asked for an end-to-end health check of the pipeline.
    event DrillRequested(uint256 indexed nonce, address indexed vault);

    /// @notice The reactive contract answered a drill.
    /// @param tripwires Number of active tripwires the reactive contract holds for `vault`.
    /// @param secondsElapsed Destination-chain seconds between the request and the answer.
    /// @param blocksElapsed Destination-chain blocks between the request and the answer.
    event DrillPassed(
        uint256 indexed nonce, address indexed vault, uint256 tripwires, uint256 secondsElapsed, uint256 blocksElapsed
    );

    /// @notice Callback: redeem the owner's shares in `vault` to the configured receiver.
    /// @param reactive Filled in by the callback proxy with the reactive contract that requested the callback.
    function exit(address reactive, address vault, uint8 reason, uint256 originChainId, uint256 originTxHash) external;

    /// @notice Callback: answer to `DrillRequested`.
    /// @param reactive Filled in by the callback proxy with the reactive contract that requested the callback.
    function drill(address reactive, uint256 nonce, address vault, uint256 tripwires) external;
}
