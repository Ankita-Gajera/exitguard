// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// Compiled so the console's browser test can put a vault behind a transparent proxy.
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Just enough of a Safe: who signs, how many must, and the events it emits when either changes.
contract SafeLike {
    event AddedOwner(address indexed owner);
    event RemovedOwner(address indexed owner);
    event ChangedThreshold(uint256 threshold);

    address[] internal _owners;
    uint256 internal _threshold;

    constructor(address[] memory owners_, uint256 threshold_) {
        _owners = owners_;
        _threshold = threshold_;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function addOwnerWithThreshold(address owner_, uint256 threshold_) external {
        _owners.push(owner_);
        emit AddedOwner(owner_);

        if (threshold_ != _threshold) {
            changeThreshold(threshold_);
        }
    }

    function removeLastOwner() external {
        address removed = _owners[_owners.length - 1];
        _owners.pop();
        emit RemovedOwner(removed);
    }

    function changeThreshold(uint256 threshold_) public {
        _threshold = threshold_;
        emit ChangedThreshold(threshold_);
    }
}

/// @notice Just enough of Compound's `Timelock`: its delay, its grace period, and the event it emits on queueing.
contract CompoundTimelockLike {
    event QueueTransaction(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    uint256 public constant GRACE_PERIOD = 14 days;

    address public admin;
    uint256 public delay;

    constructor(address admin_, uint256 delay_) {
        admin = admin_;
        delay = delay_;
    }

    function queueTransaction(address target_, uint256 value_, string memory signature_, bytes memory data_)
        external
        returns (bytes32 txHash_)
    {
        uint256 eta = block.timestamp + delay;
        txHash_ = keccak256(abi.encode(target_, value_, signature_, data_, eta));

        emit QueueTransaction(txHash_, target_, value_, signature_, data_, eta);
    }
}

/// @notice An ERC-4626 vault that announces changes to its risk rules the way a MetaMorpho vault does.
contract MetaMorphoLike is ERC4626, Ownable {
    event SubmitTimelock(uint256 newTimelock);
    event SubmitGuardian(address indexed newGuardian);
    event SubmitMarketRemoval(address indexed caller, bytes32 indexed id);
    event SubmitCap(address indexed caller, bytes32 indexed id, uint256 cap);
    event SetCurator(address indexed newCurator);

    address public immutable MORPHO;

    address public curator;
    uint256 public timelock;

    constructor(IERC20 asset_, address owner_, address morpho_, uint256 timelock_)
        ERC20("MetaMorpho-like Vault", "mmUSD")
        ERC4626(asset_)
        Ownable(owner_)
    {
        MORPHO = morpho_;
        curator = owner_;
        timelock = timelock_;
    }

    function setCurator(address curator_) external onlyOwner {
        curator = curator_;
        emit SetCurator(curator_);
    }

    function submitTimelock(uint256 timelock_) external onlyOwner {
        emit SubmitTimelock(timelock_);
    }

    function submitGuardian(address guardian_) external onlyOwner {
        emit SubmitGuardian(guardian_);
    }

    function submitMarketRemoval(bytes32 id_) external {
        emit SubmitMarketRemoval(msg.sender, id_);
    }

    function submitCap(bytes32 id_, uint256 cap_) external {
        emit SubmitCap(msg.sender, id_, cap_);
    }
}
