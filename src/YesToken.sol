// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title YesToken – ERC-20 position token for YES outcome shares.
/// @notice Only the BinaryPMAMM (set at construction) can mint and burn.
///         Sellers do NOT need to approve the AMM — the AMM burns directly.
contract YesToken is ERC20 {
    /* ─── immutables ─────────────────────────────────────────────── */
    address public immutable amm;

    /* ─── errors ─────────────────────────────────────────────────── */
    error OnlyAMM();

    /* ─── modifier ───────────────────────────────────────────────── */
    modifier onlyAMM() {
        if (msg.sender != amm) revert OnlyAMM();
        _;
    }

    /* ─── constructor ────────────────────────────────────────────── */
    constructor(address _amm) ERC20("PM-AMM YES Share", "pmYES") {
        amm = _amm;
    }

    /* ─── restricted mint / burn ─────────────────────────────────── */

    /// @notice Mint YES tokens to `to`. Only callable by the AMM.
    function mint(address to, uint256 amount) external onlyAMM {
        _mint(to, amount);
    }

    /// @notice Burn YES tokens from `from`. Only callable by the AMM.
    ///         Reverts with ERC20InsufficientBalance if `from` doesn't hold enough.
    function burn(address from, uint256 amount) external onlyAMM {
        _burn(from, amount);
    }
}
