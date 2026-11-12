// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title The demo protocol's deployment on another chain.
/// @notice Reduced to the one thing that matters for the demo: its guardian can pause it. When a protocol pauses
///         one deployment, that is often the first public sign of trouble that concerns all of them. Testnet only.
contract DemoSister is Ownable, Pausable {
    /// @param guardian_ The account allowed to pause and unpause.
    constructor(address guardian_) Ownable(guardian_) { }

    /// @notice Incident response: stop everything here.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice All clear.
    function unpause() external onlyOwner {
        _unpause();
    }
}
