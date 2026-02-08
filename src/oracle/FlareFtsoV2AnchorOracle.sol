// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAnchorOracle} from "../OracleAdapter.sol";
import {IFtsoV2} from "../flare/IFtsoV2.sol";

/// @title FlareFtsoV2AnchorOracle – production-grade IAnchorOracle backed by
///        Flare's FTSOv2 with staleness and zero-value validation.
///
/// @notice Reads a single FTSOv2 price feed and exposes it through the
///         project's `IAnchorOracle` interface.
///
///         `getFeedByIdInWei` returns the value already scaled to 18 decimals
///         (WAD), so no additional conversion is needed.
///
/// @dev    Reverts if:
///         - The FTSOv2 call itself fails.
///         - The returned value is zero (invalid / uninitialised feed).
///         - The returned timestamp is older than `MAX_STALENESS`.
contract FlareFtsoV2AnchorOracle is IAnchorOracle {
    /* ─── errors ─────────────────────────────────────────────────── */
    error FtsoCallFailed();
    error FtsoValueZero();
    error FtsoStalePrice(uint64 feedTimestamp, uint256 currentTimestamp);

    /* ─── immutables ─────────────────────────────────────────────── */

    /// @notice The FTSOv2 contract to read from.
    IFtsoV2 public immutable ftsoV2;

    /// @notice 21-byte Flare feed identifier (e.g. ETH/USD, BTC/USD).
    bytes21 public immutable feedId;

    /// @notice Maximum age (in seconds) before a feed value is considered stale.
    uint256 public immutable maxStaleness;

    /* ─── constants ──────────────────────────────────────────────── */

    /// @dev Default staleness window: 5 minutes.
    uint256 internal constant DEFAULT_MAX_STALENESS = 5 minutes;

    /* ─── constructor ────────────────────────────────────────────── */

    /// @param _ftsoV2        Address of the FTSOv2 contract.
    /// @param _feedId        21-byte feed identifier.
    /// @param _maxStaleness  Maximum acceptable age of the feed (seconds).
    ///                       Pass 0 to use the default (5 minutes).
    constructor(address _ftsoV2, bytes21 _feedId, uint256 _maxStaleness) {
        ftsoV2 = IFtsoV2(_ftsoV2);
        feedId = _feedId;
        maxStaleness = _maxStaleness == 0 ? DEFAULT_MAX_STALENESS : _maxStaleness;
    }

    /* ─── IAnchorOracle ──────────────────────────────────────────── */

    /// @inheritdoc IAnchorOracle
    /// @notice Returns the latest price from FTSOv2 in WAD (1e18), reverting
    ///         if the data is invalid or stale.
    function anchorPrice() external view override returns (uint256) {
        // Static call works for both Coston2 (view) and mainnet (payable in
        // its own context) when invoked from a view function.
        (bool ok, bytes memory ret) = address(ftsoV2).staticcall(
            abi.encodeWithSelector(IFtsoV2.getFeedByIdInWei.selector, feedId)
        );
        if (!ok) revert FtsoCallFailed();

        (uint256 value, uint64 timestamp) = abi.decode(ret, (uint256, uint64));

        // Validate: non-zero value
        if (value == 0) revert FtsoValueZero();

        // Validate: freshness
        if (block.timestamp > timestamp + maxStaleness) {
            revert FtsoStalePrice(timestamp, block.timestamp);
        }

        return value; // already 1e18-scaled by getFeedByIdInWei
    }
}
