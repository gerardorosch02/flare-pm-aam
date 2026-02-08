// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFtsoV2 – Minimal Flare FTSOv2 interface used by this project.
/// @dev   Matches the subset of FtsoV2Interface / TestFtsoV2Interface we need.
///        Full reference: https://dev.flare.network/ftso/solidity-reference/FtsoV2Interface
interface IFtsoV2 {
    /// @notice Returns the value of a feed in wei (18 decimal places) and the
    ///         timestamp of the last update.
    /// @param _feedId  The 21-byte feed identifier
    ///                 (e.g. 0x014554482f55534400000000000000000000000000 for ETH/USD).
    /// @return _value     Price scaled to 1e18.
    /// @return _timestamp UNIX timestamp of the last update.
    function getFeedByIdInWei(
        bytes21 _feedId
    ) external payable returns (uint256 _value, uint64 _timestamp);
}
