// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Test dollars for the ExitGuard demo.
/// @notice Anyone can mint. Testnet only; this token has no value.
contract MockUSD is ERC20 {
    /// @notice Largest amount one call may mint.
    uint256 public constant MAX_MINT = 1_000_000e18;

    error MintTooLarge();

    constructor() ERC20("Mock USD", "mUSD") { }

    /// @notice Mints test dollars to `to_`.
    function mint(address to_, uint256 amount_) external {
        if (amount_ > MAX_MINT) {
            revert MintTooLarge();
        }

        _mint(to_, amount_);
    }
}
