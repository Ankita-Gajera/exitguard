// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IExitGuard } from "./interfaces/IExitGuard.sol";
import { BoundedCall } from "./libraries/BoundedCall.sol";

/// @title ExitGuard: a personal emergency exit for ERC-4626 vault positions.
/// @notice Lives on the chain where the vault is. The owner keeps their vault shares in their own wallet and
///         gives this contract an allowance on them. When the owner's reactive contract on Reactive Network sees
///         a governance event it was told to watch (an upgrade being queued, an owner changing, a proxy pointing
///         at new code), it calls `exit` through the callback proxy and the shares are redeemed straight to the
///         receiver the owner chose.
/// @dev Trust model:
///      - Only the callback proxy can call the callback methods, and only on behalf of the one reactive contract
///        fixed at deployment.
///      - A callback can only ever redeem the owner's shares to the receiver the owner configured. A forged or
///        mistaken trigger costs the owner yield and gas, never principal.
///      - The vault is treated as untrusted: it may be mid-upgrade when `exit` runs. See `BoundedCall`.
contract ExitGuard is AbstractCallback, IExitGuard {
    /// @notice Reason code used for exits started by the owner with `exitNow`.
    uint8 public constant REASON_MANUAL = 0;

    /// @dev Gas kept back from the vault call so a failed exit can still be recorded.
    uint256 internal constant EXIT_GAS_RESERVE = 60_000;

    /// @dev Maximum number of revert bytes kept from a failed redemption.
    uint256 internal constant MAX_REVERT_BYTES = 256;

    error NotOwner();
    error ZeroAddress();
    error InvalidReceiver();
    error NotArmed(address vault);
    error WithdrawFailed();

    struct Position {
        bool armed;
        address receiver;
    }

    struct Drill {
        uint64 requestedAt;
        uint64 requestedBlock;
        uint64 secondsElapsed;
        uint64 blocksElapsed;
        address vault;
        uint64 tripwires;
        bool passed;
    }

    /// @notice The person whose positions this guard protects.
    address public immutable owner;

    /// @notice Protection settings per vault.
    mapping(address vault => Position) public positions;

    /// @notice Health checks requested so far, by nonce (starting at 1).
    mapping(uint256 nonce => Drill) public drills;

    /// @notice Number of health checks requested so far.
    uint256 public drillCount;

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    /// @param callbackProxy_ Reactive Network callback proxy on this chain.
    /// @param reactive_ The owner's ExitGuardReactive contract on Reactive Network.
    /// @param owner_ The person whose positions this guard protects.
    /// @dev `payable` so the contract can be given gas money for callbacks at deployment.
    constructor(IPayable callbackProxy_, address reactive_, address owner_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        if (address(callbackProxy_) == address(0) || reactive_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }

        owner = owner_;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Owner controls
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Starts protecting the owner's position in `vault_`.
    /// @dev The owner must separately approve this contract on the vault's share token, e.g.
    ///      `vault.approve(guard, type(uint256).max)`.
    /// @param vault_ ERC-4626 vault holding the position.
    /// @param receiver_ Where redeemed assets go. `address(0)` means the owner.
    function arm(address vault_, address receiver_) external onlyOwner {
        if (vault_ == address(0)) {
            revert ZeroAddress();
        }

        address receiver = receiver_ == address(0) ? owner : receiver_;

        // Assets must leave straight to a wallet the owner controls; the guard never holds them.
        if (receiver == address(this) || receiver == vault_) {
            revert InvalidReceiver();
        }

        positions[vault_] = Position({ armed: true, receiver: receiver });

        emit Armed(vault_, receiver);
    }

    /// @notice Stops protecting the owner's position in `vault_`.
    function disarm(address vault_) external onlyOwner {
        if (!positions[vault_].armed) {
            revert NotArmed(vault_);
        }

        positions[vault_].armed = false;

        emit Disarmed(vault_);
    }

    /// @notice Runs the same exit a tripwire would, on the owner's command.
    function exitNow(address vault_) external onlyOwner {
        if (!positions[vault_].armed) {
            revert NotArmed(vault_);
        }

        _exit(vault_, REASON_MANUAL, block.chainid, 0);
    }

    /// @notice Asks the reactive contract to prove the whole pipeline still works.
    /// @dev Emits `DrillRequested`; the reactive contract answers with a `drill` callback, which emits
    ///      `DrillPassed` with the round-trip time and the number of tripwires guarding `vault_`.
    /// @param vault_ Vault whose tripwire count should be reported (may be `address(0)`).
    /// @return nonce_ Identifier of this drill.
    function requestDrill(address vault_) external onlyOwner returns (uint256 nonce_) {
        nonce_ = ++drillCount;

        Drill storage record = drills[nonce_];
        record.requestedAt = uint64(block.timestamp);
        record.requestedBlock = uint64(block.number);
        record.vault = vault_;

        emit DrillRequested(nonce_, vault_);
    }

    /// @notice Takes back native tokens that were deposited to pay for callbacks.
    function withdrawGasFunds(uint256 amount_) external onlyOwner {
        (bool success,) = payable(owner).call{ value: amount_ }("");

        if (!success) {
            revert WithdrawFailed();
        }
    }

    /// @notice Settles this contract's outstanding debt to the callback proxy from its own balance.
    /// @dev Open to anyone on purpose: paying the guard's bills can only help the owner.
    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Callbacks from Reactive Network
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IExitGuard
    function exit(address reactive_, address vault_, uint8 reason_, uint256 originChainId_, uint256 originTxHash_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        _exit(vault_, reason_, originChainId_, originTxHash_);
    }

    /// @inheritdoc IExitGuard
    function drill(address reactive_, uint256 nonce_, address vault_, uint256 tripwires_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Drill storage record = drills[nonce_];

        // Unknown or repeated answers are ignored rather than reverted: a reverting callback is still billed.
        if (record.requestedAt == 0 || record.passed) {
            return;
        }

        record.passed = true;
        record.secondsElapsed = uint64(block.timestamp - record.requestedAt);
        record.blocksElapsed = uint64(block.number - record.requestedBlock);
        // The count comes from the owner's own reactive contract and is bounded by its storage; it fits in 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        record.tripwires = uint64(tripwires_);

        emit DrillPassed(nonce_, vault_, tripwires_, record.secondsElapsed, record.blocksElapsed);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Answers "if a tripwire fired right now, what would happen?".
    /// @return armed_ Whether the position is armed.
    /// @return receiver_ Where the assets would go.
    /// @return shares_ Shares the guard could redeem right now.
    /// @return expectedAssets_ What the vault says those shares are worth (0 if it does not answer).
    /// @return blocker_ If `shares_` is zero, the reason why.
    function readiness(address vault_)
        external
        view
        returns (bool armed_, address receiver_, uint256 shares_, uint256 expectedAssets_, SkipCause blocker_)
    {
        Position memory position = positions[vault_];
        armed_ = position.armed;
        receiver_ = position.receiver;

        (shares_, blocker_) = _redeemable(vault_);

        if (!armed_) {
            blocker_ = SkipCause.NotArmed;
        }

        if (shares_ > 0) {
            (, expectedAssets_) = BoundedCall.staticUint(vault_, abi.encodeCall(IERC4626.previewRedeem, (shares_)));
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Redeems as many of the owner's shares as possible. Never reverts because of the vault.
    function _exit(address vault_, uint8 reason_, uint256 originChainId_, uint256 originTxHash_) internal {
        Position memory position = positions[vault_];

        if (!position.armed) {
            emit ExitSkipped(vault_, reason_, SkipCause.NotArmed);
            return;
        }

        (uint256 shares, SkipCause cause) = _redeemable(vault_);

        if (shares == 0) {
            emit ExitSkipped(vault_, reason_, cause);
            return;
        }

        // Effects before the interaction: the vault may be hostile by the time this runs.
        positions[vault_].armed = false;

        uint256 gasLeft = gasleft();
        uint256 gasForVault = gasLeft > EXIT_GAS_RESERVE ? gasLeft - EXIT_GAS_RESERVE : 0;

        (bool success, uint256 assets, bytes memory revertData) = BoundedCall.callUint(
            vault_, abi.encodeCall(IERC4626.redeem, (shares, position.receiver, owner)), gasForVault, MAX_REVERT_BYTES
        );

        if (success) {
            emit Disarmed(vault_);
            emit Exited(vault_, reason_, shares, assets, originChainId_, originTxHash_);
        } else {
            // Stay armed so the next tripwire, or the owner with `exitNow`, can try again.
            positions[vault_].armed = true;

            emit ExitFailed(vault_, reason_, originChainId_, originTxHash_, revertData);
        }
    }

    /// @dev Shares the guard can redeem right now: the smallest of the owner's balance, the allowance given to
    ///      the guard, and the vault's own redemption limit.
    function _redeemable(address vault_) internal view returns (uint256 shares_, SkipCause cause_) {
        (bool hasBalance, uint256 balance) = BoundedCall.staticUint(vault_, abi.encodeCall(IERC20.balanceOf, (owner)));

        if (!hasBalance || balance == 0) {
            return (0, SkipCause.NoShares);
        }

        (bool hasAllowance, uint256 allowance) =
            BoundedCall.staticUint(vault_, abi.encodeCall(IERC20.allowance, (owner, address(this))));

        if (!hasAllowance || allowance == 0) {
            return (0, SkipCause.NoAllowance);
        }

        shares_ = balance < allowance ? balance : allowance;

        // A vault that does not answer `maxRedeem` is treated as having no limit.
        (bool hasLimit, uint256 limit) = BoundedCall.staticUint(vault_, abi.encodeCall(IERC4626.maxRedeem, (owner)));

        if (hasLimit && limit < shares_) {
            shares_ = limit;
        }

        if (shares_ == 0) {
            cause_ = SkipCause.VaultLimit;
        }
    }
}
