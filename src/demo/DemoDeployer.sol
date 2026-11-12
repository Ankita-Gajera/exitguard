// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { MockUSD } from "./MockUSD.sol";
import { DemoVault } from "./DemoVault.sol";
import { DemoVaultV2 } from "./DemoVaultV2.sol";

/// @title Sets the whole demo stage in one transaction.
/// @notice Deploys test dollars, a timelock, an upgradeable vault owned by that timelock and the "bad" V2 code,
///         then deposits 1,000 test dollars each for `you` and for `bob`, a depositor without ExitGuard.
///         Testnet only.
contract DemoDeployer {
    uint256 public constant DEPOSIT = 1_000e18;

    MockUSD public immutable usd;
    TimelockController public immutable timelock;
    DemoVault public immutable vault;
    DemoVaultV2 public immutable vaultV2;

    address public immutable you;
    address public immutable bob;

    event DemoDeployed(address usd, address timelock, address vault, address vaultV2, address you, address bob);

    /// @param timelockDelay_ Seconds between queueing a call in the timelock and executing it.
    /// @param you_ The protected depositor. Also the only proposer and executor of the timelock, so the demo's
    ///        "protocol admin" and the depositor can be played from one wallet.
    /// @param bob_ The unprotected depositor.
    constructor(uint256 timelockDelay_, address you_, address bob_) {
        address[] memory operators = new address[](1);
        operators[0] = you_;

        usd = new MockUSD();
        timelock = new TimelockController(timelockDelay_, operators, operators, address(0));
        vault = DemoVault(
            address(
                new ERC1967Proxy(
                    address(new DemoVault()),
                    abi.encodeCall(DemoVault.initialize, (IERC20(address(usd)), address(timelock)))
                )
            )
        );
        vaultV2 = new DemoVaultV2();

        you = you_;
        bob = bob_;

        usd.mint(address(this), 2 * DEPOSIT);
        usd.approve(address(vault), 2 * DEPOSIT);
        vault.deposit(DEPOSIT, you_);
        vault.deposit(DEPOSIT, bob_);

        emit DemoDeployed(address(usd), address(timelock), address(vault), address(vaultV2), you_, bob_);
    }
}
