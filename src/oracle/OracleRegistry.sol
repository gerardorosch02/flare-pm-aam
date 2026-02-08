// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAnchorOracle} from "../OracleAdapter.sol";

/// @title OracleRegistry – owner-switchable oracle proxy.
///
/// @notice Implements `IAnchorOracle` and delegates every `anchorPrice()` call
///         to whichever concrete oracle the owner has selected (e.g.
///         StubAnchorOracle for local dev, FlareFtsoV2AnchorOracle on testnet).
///
///         Pass this contract's address as the `_oracle` parameter when
///         constructing `BinaryPMAMM`.  The AMM already depends on the
///         `IAnchorOracle` interface, so no AMM code change is required.
contract OracleRegistry is IAnchorOracle, Ownable {
    /* ─── errors ─────────────────────────────────────────────────── */
    error OracleNotSet();

    /* ─── events ─────────────────────────────────────────────────── */
    event OracleUpdated(address indexed previousOracle, address indexed newOracle);

    /* ─── state ──────────────────────────────────────────────────── */

    /// @notice The currently active oracle implementation.
    IAnchorOracle public currentOracle;

    /* ─── constructor ────────────────────────────────────────────── */

    /// @param _initialOracle  The first oracle to activate (may be address(0)
    ///                        if you plan to call `setOracle` before the first
    ///                        trade).
    constructor(address _initialOracle) Ownable(msg.sender) {
        if (_initialOracle != address(0)) {
            currentOracle = IAnchorOracle(_initialOracle);
        }
    }

    /* ─── admin ──────────────────────────────────────────────────── */

    /// @notice Switch the active oracle.  Only callable by the owner.
    /// @param _newOracle  Address of a contract that implements IAnchorOracle.
    function setOracle(address _newOracle) external onlyOwner {
        address previous = address(currentOracle);
        currentOracle = IAnchorOracle(_newOracle);
        emit OracleUpdated(previous, _newOracle);
    }

    /* ─── IAnchorOracle ──────────────────────────────────────────── */

    /// @inheritdoc IAnchorOracle
    /// @notice Delegates to the currently active oracle implementation.
    function anchorPrice() external view override returns (uint256) {
        if (address(currentOracle) == address(0)) revert OracleNotSet();
        return currentOracle.anchorPrice();
    }
}
