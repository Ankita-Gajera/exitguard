// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

import { IExitGuard } from "./interfaces/IExitGuard.sol";

/// @title ExitGuardReactive: the tripwires behind an ExitGuard.
/// @notice Lives on Reactive Network. The owner lays tripwires across governance events on any supported chain:
///         a timelock queueing a call against a vault, a proxy pointing at new code, an owner changing, a pause.
///         When a matching event is emitted, this contract asks the owner's ExitGuard on the destination chain to
///         pull the owner's position out of the vault that tripwire protects.
/// @dev A tripwire is a subscription plus two optional filters that subscriptions cannot express on their own:
///      exact values for indexed topics, and an exact value for one 32-byte word of the event's data (which is
///      where a timelock puts the target of a queued call).
contract ExitGuardReactive is AbstractReactive {
    // ------------------------------------------------------------------------------------------------------------
    // Reason labels passed to the guard, so the exit records why it happened
    // ------------------------------------------------------------------------------------------------------------

    uint8 public constant REASON_UPGRADE_SCHEDULED = 1;
    uint8 public constant REASON_UPGRADED = 2;
    uint8 public constant REASON_ADMIN_CHANGED = 3;
    uint8 public constant REASON_OWNERSHIP_TRANSFER_STARTED = 4;
    uint8 public constant REASON_OWNERSHIP_TRANSFERRED = 5;
    uint8 public constant REASON_PAUSED = 6;

    // ------------------------------------------------------------------------------------------------------------
    // Topics of the governance events this contract knows how to watch out of the box
    // ------------------------------------------------------------------------------------------------------------

    /// @notice OpenZeppelin `TimelockController.CallScheduled`.
    uint256 public constant TOPIC_CALL_SCHEDULED =
        uint256(keccak256("CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)"));

    /// @notice ERC-1967 `Upgraded`.
    uint256 public constant TOPIC_UPGRADED = uint256(keccak256("Upgraded(address)"));

    /// @notice ERC-1967 `AdminChanged`.
    uint256 public constant TOPIC_ADMIN_CHANGED = uint256(keccak256("AdminChanged(address,address)"));

    /// @notice `Ownable2Step.OwnershipTransferStarted`.
    uint256 public constant TOPIC_OWNERSHIP_TRANSFER_STARTED =
        uint256(keccak256("OwnershipTransferStarted(address,address)"));

    /// @notice `Ownable.OwnershipTransferred`.
    uint256 public constant TOPIC_OWNERSHIP_TRANSFERRED = uint256(keccak256("OwnershipTransferred(address,address)"));

    /// @notice `Pausable.Paused`.
    uint256 public constant TOPIC_PAUSED = uint256(keccak256("Paused(address)"));

    // ------------------------------------------------------------------------------------------------------------
    // Limits and sentinels
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Topic filter value meaning "any value".
    uint256 public constant ANY_TOPIC = REACTIVE_IGNORE;

    /// @notice `dataWord` value meaning "do not look at the event data".
    uint8 public constant NO_DATA_MATCH = type(uint8).max;

    /// @notice Most tripwires that may share one (chain, contract, event) triple. Keeps `react` cheap.
    uint256 public constant MAX_TRIPWIRES_PER_EVENT = 8;

    /// @notice Reactive Network ignores callbacks requested with less gas than this.
    uint64 public constant MIN_CALLBACK_GAS = 100_000;

    error NotOwner();
    error ZeroAddress();
    error ZeroChainId();
    error GuardAlreadySet();
    error GuardNotSet();
    error InvalidTripwire();
    error TooManyTripwires();
    error UnknownTripwire(uint256 id);
    error GasLimitTooLow();
    error WithdrawFailed();

    /// @notice One tripwire: which event to watch, how to recognise it, and which vault to leave when it fires.
    struct Tripwire {
        uint64 chainId; // chain where the event is emitted
        address source; // contract that emits it
        uint256 topic0; // event signature
        uint256 topic1; // exact value, or ANY_TOPIC
        uint256 topic2; // exact value, or ANY_TOPIC
        uint256 topic3; // exact value, or ANY_TOPIC
        bytes32 dataValue; // value the chosen data word must equal
        address vault; // position to exit on the destination chain
        uint8 dataWord; // index of the 32-byte data word to compare, or NO_DATA_MATCH
        uint8 reason; // label handed to the guard
        bool active;
    }

    event GuardSet(address indexed guard);
    event TripwireAdded(
        uint256 indexed id, uint256 indexed chainId, address indexed source, uint256 topic0, address vault, uint8 reason
    );
    event TripwireRemoved(uint256 indexed id);
    event Tripped(
        uint256 indexed id, address indexed vault, uint8 indexed reason, uint256 originChainId, uint256 originTxHash
    );
    event Suppressed(uint256 indexed id, address indexed vault);
    event DrillAnswered(uint256 indexed nonce, address indexed vault, uint256 tripwires);
    event CallbackGasLimitSet(uint64 gasLimit);
    event CooldownSet(uint64 cooldown);

    /// @notice The person whose positions are protected.
    address public immutable owner;

    /// @notice Chain where the owner's ExitGuard lives.
    uint256 public immutable destinationChainId;

    /// @notice The owner's ExitGuard on the destination chain. Set once, after the guard is deployed.
    address public guard;

    /// @notice Gas limit requested for callbacks to the guard.
    /// @dev The callback proxy keeps part of this for its own accounting, and the guard keeps a reserve to record
    ///      a failed exit, so the vault sees a good deal less. The first live run on Sepolia, where creating a
    ///      storage slot costs about five times what it does on mainnet, ran out of gas inside the vault with a
    ///      limit of 500,000.
    uint64 public callbackGasLimit = 1_000_000;

    /// @notice Minimum number of seconds between two exit requests for the same vault.
    /// @dev One governance action often emits several watched events (a batch of queued calls, an upgrade followed
    ///      by an ownership change). Without a cooldown each of them would pay for a callback.
    uint64 public cooldown = 5 minutes;

    /// @notice Number of active tripwires protecting each vault.
    mapping(address vault => uint256 count) public tripwiresOf;

    /// @notice When an exit was last requested for each vault (Reactive Network time).
    mapping(address vault => uint256 timestamp) public lastFiredAt;

    Tripwire[] internal _tripwires;
    mapping(bytes32 eventKey => uint256[] ids) internal _byEvent;
    mapping(bytes32 subscriptionKey => uint256 references) internal _subscriptionRefs;

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    /// @param owner_ The person whose positions are protected.
    /// @param destinationChainId_ Chain where the owner's ExitGuard will live.
    /// @dev `payable` so the contract can be funded for reactive transactions at deployment.
    constructor(address owner_, uint256 destinationChainId_) payable {
        if (owner_ == address(0)) {
            revert ZeroAddress();
        }

        if (destinationChainId_ == 0) {
            revert ZeroChainId();
        }

        owner = owner_;
        destinationChainId = destinationChainId_;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Links this contract to the owner's ExitGuard. Can only be done once.
    /// @dev The guard needs this contract's address in its constructor, so it is always deployed second.
    function setGuard(address guard_) external onlyOwner {
        if (guard_ == address(0)) {
            revert ZeroAddress();
        }

        if (guard != address(0)) {
            revert GuardAlreadySet();
        }

        guard = guard_;

        // Health checks: the guard emits `DrillRequested`, this contract answers with a callback.
        SYSTEM.subscribe(
            destinationChainId, guard_, uint256(IExitGuard.DrillRequested.selector), ANY_TOPIC, ANY_TOPIC, ANY_TOPIC
        );

        emit GuardSet(guard_);
    }

    /// @notice Sets the gas limit requested for callbacks to the guard.
    function setCallbackGasLimit(uint64 gasLimit_) external onlyOwner {
        if (gasLimit_ < MIN_CALLBACK_GAS) {
            revert GasLimitTooLow();
        }

        callbackGasLimit = gasLimit_;

        emit CallbackGasLimitSet(gasLimit_);
    }

    /// @notice Sets the minimum spacing between two exit requests for the same vault.
    function setCooldown(uint64 cooldown_) external onlyOwner {
        cooldown = cooldown_;

        emit CooldownSet(cooldown_);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Laying tripwires
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Exit `vault_` when `timelock_` queues any call against `target_`.
    /// @dev Works with OpenZeppelin's `TimelockController`. For a UUPS vault the target is the vault itself; for
    ///      a transparent proxy it is the vault's `ProxyAdmin`. This is the earliest warning there is: the exit
    ///      runs while the old code is still in place.
    function watchTimelock(uint64 chainId_, address timelock_, address target_, address vault_)
        external
        onlyOwner
        returns (uint256 id_)
    {
        id_ = _add(
            Tripwire({
                chainId: chainId_,
                source: timelock_,
                topic0: TOPIC_CALL_SCHEDULED,
                topic1: ANY_TOPIC,
                topic2: ANY_TOPIC,
                topic3: ANY_TOPIC,
                dataValue: bytes32(uint256(uint160(target_))), // `target` is the first word of the event data
                vault: vault_,
                dataWord: 0,
                reason: REASON_UPGRADE_SCHEDULED,
                active: true
            })
        );
    }

    /// @notice Exit `vault_` when the ERC-1967 proxy `proxy_` changes its implementation or its admin.
    function watchProxy(uint64 chainId_, address proxy_, address vault_)
        external
        onlyOwner
        returns (uint256 upgradedId_, uint256 adminChangedId_)
    {
        upgradedId_ = _add(_plain(chainId_, proxy_, TOPIC_UPGRADED, vault_, REASON_UPGRADED));
        adminChangedId_ = _add(_plain(chainId_, proxy_, TOPIC_ADMIN_CHANGED, vault_, REASON_ADMIN_CHANGED));
    }

    /// @notice Exit `vault_` when ownership of `ownable_` starts to move, or moves.
    function watchOwnership(uint64 chainId_, address ownable_, address vault_)
        external
        onlyOwner
        returns (uint256 startedId_, uint256 transferredId_)
    {
        startedId_ = _add(
            _plain(chainId_, ownable_, TOPIC_OWNERSHIP_TRANSFER_STARTED, vault_, REASON_OWNERSHIP_TRANSFER_STARTED)
        );
        transferredId_ =
            _add(_plain(chainId_, ownable_, TOPIC_OWNERSHIP_TRANSFERRED, vault_, REASON_OWNERSHIP_TRANSFERRED));
    }

    /// @notice Exit `vault_` when `pausable_` is paused.
    /// @dev Most useful across contracts or chains: a sister deployment being paused is an early sign of trouble.
    function watchPause(uint64 chainId_, address pausable_, address vault_) external onlyOwner returns (uint256 id_) {
        id_ = _add(_plain(chainId_, pausable_, TOPIC_PAUSED, vault_, REASON_PAUSED));
    }

    /// @notice Lays a fully custom tripwire.
    function addTripwire(Tripwire calldata tripwire_) external onlyOwner returns (uint256 id_) {
        id_ = _add(tripwire_);
    }

    /// @notice Removes a tripwire and, if nothing else needs it, its subscription.
    function removeTripwire(uint256 id_) external onlyOwner {
        if (id_ >= _tripwires.length || !_tripwires[id_].active) {
            revert UnknownTripwire(id_);
        }

        Tripwire storage wire = _tripwires[id_];
        wire.active = false;

        uint256[] storage ids = _byEvent[_eventKey(wire.chainId, wire.source, wire.topic0)];
        uint256 count = ids.length;

        for (uint256 i = 0; i < count; ++i) {
            if (ids[i] == id_) {
                ids[i] = ids[count - 1];
                ids.pop();
                break;
            }
        }

        --tripwiresOf[wire.vault];

        bytes32 key = _subscriptionKey(wire);

        if (--_subscriptionRefs[key] == 0) {
            SYSTEM.unsubscribe(wire.chainId, wire.source, wire.topic0, wire.topic1, wire.topic2, wire.topic3);
        }

        emit TripwireRemoved(id_);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Funds
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Settles this contract's outstanding debt to the system contract from its own balance.
    /// @dev Open to anyone on purpose: a contract in debt receives no events, so paying can only help the owner.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Takes back REACT that was deposited to pay for reactive transactions.
    function withdraw(uint256 amount_) external onlyOwner {
        (bool success,) = payable(owner).call{ value: amount_ }("");

        if (!success) {
            revert WithdrawFailed();
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reacting
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IReactive
    /// @dev Never reverts on a log it does not care about: a reverting reactive transaction is still billed.
    function react(LogRecord calldata log_) external onlySystem {
        address guard_ = guard;

        if (guard_ == address(0)) {
            return;
        }

        if (log_.chainId == destinationChainId && log_.contractAddress == guard_) {
            // `DrillRequested(uint256 indexed nonce, address indexed vault)` carries three topics.
            if (log_.topic0 == uint256(IExitGuard.DrillRequested.selector) && log_.opCode == 3) {
                _answerDrill(guard_, log_);
            }

            return;
        }

        uint256[] storage ids = _byEvent[_eventKey(log_.chainId, log_.contractAddress, log_.topic0)];
        uint256 count = ids.length;

        for (uint256 i = 0; i < count; ++i) {
            uint256 id = ids[i];
            Tripwire storage wire = _tripwires[id];

            if (_matches(wire, log_)) {
                _fire(guard_, id, wire, log_);
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Number of tripwires ever laid (including removed ones). Valid ids are `0 .. tripwireCount() - 1`.
    function tripwireCount() external view returns (uint256) {
        return _tripwires.length;
    }

    /// @notice Details of one tripwire.
    function tripwire(uint256 id_) external view returns (Tripwire memory) {
        if (id_ >= _tripwires.length) {
            revert UnknownTripwire(id_);
        }

        return _tripwires[id_];
    }

    /// @notice Ids of the active tripwires listening to one event of one contract.
    function tripwiresFor(uint256 chainId_, address source_, uint256 topic0_) external view returns (uint256[] memory) {
        return _byEvent[_eventKey(chainId_, source_, topic0_)];
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    function _plain(uint64 chainId_, address source_, uint256 topic0_, address vault_, uint8 reason_)
        internal
        pure
        returns (Tripwire memory)
    {
        return Tripwire({
            chainId: chainId_,
            source: source_,
            topic0: topic0_,
            topic1: ANY_TOPIC,
            topic2: ANY_TOPIC,
            topic3: ANY_TOPIC,
            dataValue: bytes32(0),
            vault: vault_,
            dataWord: NO_DATA_MATCH,
            reason: reason_,
            active: true
        });
    }

    function _add(Tripwire memory tripwire_) internal returns (uint256 id_) {
        address guard_ = guard;

        if (guard_ == address(0)) {
            revert GuardNotSet();
        }

        // A tripwire must name one event of one contract on one chain, and one vault to leave. The guard's own
        // events are reserved for health checks.
        if (
            tripwire_.chainId == 0 || tripwire_.source == address(0) || tripwire_.topic0 == ANY_TOPIC
                || tripwire_.vault == address(0)
                || (tripwire_.chainId == destinationChainId && tripwire_.source == guard_)
        ) {
            revert InvalidTripwire();
        }

        uint256[] storage ids = _byEvent[_eventKey(tripwire_.chainId, tripwire_.source, tripwire_.topic0)];

        if (ids.length >= MAX_TRIPWIRES_PER_EVENT) {
            revert TooManyTripwires();
        }

        tripwire_.active = true;

        id_ = _tripwires.length;
        _tripwires.push(tripwire_);
        ids.push(id_);
        ++tripwiresOf[tripwire_.vault];

        if (_subscriptionRefs[_subscriptionKey(tripwire_)]++ == 0) {
            SYSTEM.subscribe(
                tripwire_.chainId,
                tripwire_.source,
                tripwire_.topic0,
                tripwire_.topic1,
                tripwire_.topic2,
                tripwire_.topic3
            );
        }

        emit TripwireAdded(
            id_, tripwire_.chainId, tripwire_.source, tripwire_.topic0, tripwire_.vault, tripwire_.reason
        );
    }

    /// @dev `opCode` is the number of topics in the log. A filter on a topic the log does not have never matches,
    ///      even when the filter value is zero.
    function _matches(Tripwire storage tripwire_, LogRecord calldata log_) internal view returns (bool) {
        uint256 topic = tripwire_.topic1;

        if (topic != ANY_TOPIC && (log_.opCode < 2 || topic != log_.topic1)) {
            return false;
        }

        topic = tripwire_.topic2;

        if (topic != ANY_TOPIC && (log_.opCode < 3 || topic != log_.topic2)) {
            return false;
        }

        topic = tripwire_.topic3;

        if (topic != ANY_TOPIC && (log_.opCode < 4 || topic != log_.topic3)) {
            return false;
        }

        uint256 word = tripwire_.dataWord;

        if (word != NO_DATA_MATCH) {
            uint256 start = word * 32;

            if (log_.data.length < start + 32 || bytes32(log_.data[start:start + 32]) != tripwire_.dataValue) {
                return false;
            }
        }

        return true;
    }

    function _fire(address guard_, uint256 id_, Tripwire storage tripwire_, LogRecord calldata log_) internal {
        address vault = tripwire_.vault;
        uint256 last = lastFiredAt[vault];

        if (last != 0 && block.timestamp - last < cooldown) {
            emit Suppressed(id_, vault);
            return;
        }

        lastFiredAt[vault] = block.timestamp;

        uint8 reason = tripwire_.reason;

        _requestCallback(
            guard_, abi.encodeCall(IExitGuard.exit, (address(0), vault, reason, log_.chainId, log_.txHash))
        );

        emit Tripped(id_, vault, reason, log_.chainId, log_.txHash);
    }

    function _answerDrill(address guard_, LogRecord calldata log_) internal {
        uint256 nonce = log_.topic1;
        address vault = address(uint160(log_.topic2));
        uint256 count = tripwiresOf[vault];

        _requestCallback(guard_, abi.encodeCall(IExitGuard.drill, (address(0), nonce, vault, count)));

        emit DrillAnswered(nonce, vault, count);
    }

    /// @dev The first argument of every callback is a placeholder: the callback proxy overwrites it with this
    ///      contract's address so the guard can authenticate the sender.
    function _requestCallback(address guard_, bytes memory payload_) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId, recipient: guard_, gasLimit: callbackGasLimit, payload: payload_
            })
        );
    }

    function _eventKey(uint256 chainId_, address source_, uint256 topic0_) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId_, source_, topic0_));
    }

    function _subscriptionKey(Tripwire memory tripwire_) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                tripwire_.chainId,
                tripwire_.source,
                tripwire_.topic0,
                tripwire_.topic1,
                tripwire_.topic2,
                tripwire_.topic3
            )
        );
    }
}
