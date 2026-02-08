// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IFdcVerifier} from "./IFdcVerifier.sol";

/// @title MockFdcVerifier – test/demo FDC attestation verifier.
///
/// @notice The owner pre-sets the expected attestation hash, outcome, and
///         timestamp.  `verify()` returns `ok = true` only if
///         `keccak256(attestation) == expectedHash`.
///
/// @dev    Attestation format (for tests / demo):
///         `abi.encode(marketAddress, outcome, timestamp, nonce)`
///         where `nonce` is an arbitrary salt. The hash of this payload must
///         match `expectedHash` set by the owner.
///
///         In production, replace this contract with one that calls
///         `FtsoV2Interface.verifyFeedData(FeedDataWithProof)` and extracts
///         the price + timestamp from the proven feed data.
contract MockFdcVerifier is IFdcVerifier, Ownable {
    bytes32 public expectedHash;
    bool    public expectedOutcome;
    uint64  public expectedTimestamp;

    event ExpectedSet(bytes32 hash, bool outcome, uint64 timestamp);

    constructor() Ownable(msg.sender) {}

    /// @notice Owner sets the expected attestation parameters.
    function setExpected(
        bytes32 _hash,
        bool _outcome,
        uint64 _timestamp
    ) external onlyOwner {
        expectedHash = _hash;
        expectedOutcome = _outcome;
        expectedTimestamp = _timestamp;
        emit ExpectedSet(_hash, _outcome, _timestamp);
    }

    /// @inheritdoc IFdcVerifier
    function verify(
        bytes calldata attestation
    ) external view override returns (bool ok, bool outcome, uint64 timestamp) {
        ok = keccak256(attestation) == expectedHash;
        outcome = expectedOutcome;
        timestamp = expectedTimestamp;
    }
}
