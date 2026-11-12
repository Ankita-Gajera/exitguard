// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

/// @title An ordinary upgradeable yield vault, used to demonstrate ExitGuard.
/// @notice Stands in for the kind of vault people really deposit into: ERC-4626 shares behind a UUPS proxy whose
///         owner (in the demo, a timelock) can replace the code. Testnet only.
contract DemoVault is Initializable, ERC4626Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param asset_ Token the vault accepts.
    /// @param owner_ Account allowed to upgrade the vault.
    function initialize(IERC20 asset_, address owner_) external initializer {
        __ERC20_init("Demo Yield Vault", "dyvUSD");
        __ERC4626_init(asset_);
        __Ownable_init(owner_);
    }

    /// @notice Version of the code behind the proxy.
    function version() external pure virtual returns (string memory) {
        return "1";
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }
}
