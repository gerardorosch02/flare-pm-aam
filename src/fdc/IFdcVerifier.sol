// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFdcVerifier – interface for FDC attestation verification.
/// @notice In production, this would verify a Flare Data Connector Merkle proof.
///         For MVP, a mock verifier is used that checks a pre-set attestation hash.
interface IFdcVerifier {
    /// @notice Verify an attestation payload.
    /// @param attestation Raw attestation bytes (format is verifier-specific).
    /// @return ok        True if the attestation is valid.
    /// @return outcome   The attested market outcome (true = YES, false = NO).
    /// @return timestamp The timestamp the attestation refers to.
    function verify(
        bytes calldata attestation
    ) external view returns (bool ok, bool outcome, uint64 timestamp);
}
