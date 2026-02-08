// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IFdcVerifier} from "./fdc/IFdcVerifier.sol";

/// @title PredictionMarket – binary market with FDC attestation-based resolution.
///
/// @notice Two resolution paths:
///   1. **Attestation (primary):** Anyone calls `resolveWithAttestation(bytes)`
///      after expiry. The attestation is verified by an `IFdcVerifier`.
///   2. **Emergency (fallback):** Owner calls `resolve(bool)` but only after
///      `expiry + EMERGENCY_DELAY` (24 hours). This is a safety valve in case
///      the FDC verifier is unavailable.
contract PredictionMarket is Ownable {
    /* ─── state (expiry) ──────────────────────────────────────────── */
    uint256 public expiry;

    /* ─── constants ──────────────────────────────────────────────── */
    uint256 public constant EMERGENCY_DELAY = 24 hours;

    /* ─── state ──────────────────────────────────────────────────── */
    IFdcVerifier public verifier;
    bool public resolved;
    bool public outcome;

    /* ─── errors ─────────────────────────────────────────────────── */
    error NotExpired();
    error AlreadyResolved();
    error EmergencyDelayNotMet();
    error AttestationInvalid();
    error VerifierNotSet();

    /* ─── events ─────────────────────────────────────────────────── */
    event MarketResolved(bool outcome, uint256 timestamp, string method);
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);

    /* ─── constructor ────────────────────────────────────────────── */
    /// @param _expiry    UNIX timestamp when the market expires.
    /// @param _verifier  Address of an IFdcVerifier (may be address(0) if
    ///                   only the emergency path will be used).
    constructor(uint256 _expiry, address _verifier) Ownable(msg.sender) {
        expiry = _expiry;
        if (_verifier != address(0)) {
            verifier = IFdcVerifier(_verifier);
        }
    }

    /* ─── admin ──────────────────────────────────────────────────── */

    /// @notice Owner can update the verifier (e.g., upgrade from mock to real FDC).
    function setVerifier(address _verifier) external onlyOwner {
        address old = address(verifier);
        verifier = IFdcVerifier(_verifier);
        emit VerifierUpdated(old, _verifier);
    }

    /* ─── queries ────────────────────────────────────────────────── */

    /// @notice Seconds until expiry; returns 0 if already past.
    function timeToExpiry() external view returns (uint256) {
        if (block.timestamp >= expiry) return 0;
        return expiry - block.timestamp;
    }

    /* ─── resolution: attestation (primary) ──────────────────────── */

    /// @notice Resolve the market using a verified FDC attestation.
    ///         Callable by anyone after expiry.
    /// @param attestation  Raw attestation bytes verified by the IFdcVerifier.
    function resolveWithAttestation(bytes calldata attestation) external {
        if (block.timestamp < expiry) revert NotExpired();
        if (resolved) revert AlreadyResolved();
        if (address(verifier) == address(0)) revert VerifierNotSet();

        (bool ok, bool attestedOutcome, ) = verifier.verify(attestation);
        if (!ok) revert AttestationInvalid();

        resolved = true;
        outcome = attestedOutcome;
        emit MarketResolved(attestedOutcome, block.timestamp, "FDC");
    }

    /* ─── resolution: emergency fallback ─────────────────────────── */

    /// @notice Emergency owner resolution. Only callable after
    ///         `expiry + EMERGENCY_DELAY` (24 hours after expiry).
    ///         Use only if the FDC attestation path is unavailable.
    function resolve(bool _outcome) external onlyOwner {
        if (block.timestamp < expiry + EMERGENCY_DELAY) revert EmergencyDelayNotMet();
        if (resolved) revert AlreadyResolved();
        resolved = true;
        outcome = _outcome;
        emit MarketResolved(_outcome, block.timestamp, "EMERGENCY_OWNER");
    }

    /* ─── demo / testing helper ────────────────────────────────── */

    /// @notice Reset market for demo purposes. Owner-only.
    ///         Sets a new expiry and clears resolution state.
    function resetForDemo(uint256 _newExpiry) external onlyOwner {
        expiry = _newExpiry;
        resolved = false;
        outcome = false;
    }
}
