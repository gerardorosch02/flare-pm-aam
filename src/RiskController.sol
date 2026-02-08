// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RiskController – configurable risk engine for BinaryPMAMM.
/// @notice All parameters are set in the constructor with sane defaults,
///         and can be updated by the owner via `setRiskParams` and `setFeeParams`.
///         Divergence is computed as a *relative* deviation of the internal
///         market price from the oracle anchor price.
contract RiskController is Ownable {
    /* ─── WAD constant ───────────────────────────────────────────── */
    uint256 internal constant WAD = 1e18;

    /* ─── risk parameters (mutable by owner) ─────────────────────── */
    uint256 public dMax;       // relative divergence ceiling (WAD, e.g. 0.10e18 = 10%)
    uint256 public tMax;       // time-risk ceiling  (seconds)
    uint256 public lTarget;    // liquidity target   (WAD-scaled tokens)
    uint256 public w1;         // divergence weight  (WAD)
    uint256 public w2;         // time weight        (WAD)
    uint256 public w3;         // liquidity weight   (WAD)

    /* ─── fee / trade parameters (mutable by owner) ──────────────── */
    uint256 public feeMin;     // bps
    uint256 public feeMax;     // bps
    uint256 public baseMax;    // max trade at R=0 (WAD-scaled tokens)
    uint256 public beta;       // trade-size sensitivity (WAD)

    /* ─── errors ─────────────────────────────────────────────────── */
    error WeightsMustSumToWAD();
    error FeeMinGtFeeMax();
    error ZeroValue();
    error AnchorPriceZero();

    /* ─── events ─────────────────────────────────────────────────── */
    event RiskParamsUpdated(uint256 dMax, uint256 tMax, uint256 lTarget, uint256 w1, uint256 w2, uint256 w3);
    event FeeParamsUpdated(uint256 feeMin, uint256 feeMax, uint256 baseMax, uint256 beta);

    /* ─── constructor (sane defaults) ────────────────────────────── */
    constructor() Ownable(msg.sender) {
        dMax     = 0.10e18;     // 10 % relative divergence saturates R_div
        tMax     = 24 hours;    // seconds
        lTarget  = 1000e18;
        w1       = 0.50e18;
        w2       = 0.30e18;
        w3       = 0.20e18;
        feeMin   = 5;           // bps
        feeMax   = 200;         // bps
        baseMax  = 100e18;
        beta     = 0.80e18;
    }

    /* ─── governance setters ─────────────────────────────────────── */

    /// @notice Update risk-score parameters.  Weights must sum to 1e18.
    function setRiskParams(
        uint256 _dMax,
        uint256 _tMax,
        uint256 _lTarget,
        uint256 _w1,
        uint256 _w2,
        uint256 _w3
    ) external onlyOwner {
        if (_dMax == 0 || _tMax == 0 || _lTarget == 0) revert ZeroValue();
        if (_w1 + _w2 + _w3 != WAD) revert WeightsMustSumToWAD();
        dMax    = _dMax;
        tMax    = _tMax;
        lTarget = _lTarget;
        w1      = _w1;
        w2      = _w2;
        w3      = _w3;
        emit RiskParamsUpdated(_dMax, _tMax, _lTarget, _w1, _w2, _w3);
    }

    /// @notice Update fee / trade-size curve parameters.
    function setFeeParams(
        uint256 _feeMin,
        uint256 _feeMax,
        uint256 _baseMax,
        uint256 _beta
    ) external onlyOwner {
        if (_feeMin > _feeMax) revert FeeMinGtFeeMax();
        if (_baseMax == 0) revert ZeroValue();
        feeMin  = _feeMin;
        feeMax  = _feeMax;
        baseMax = _baseMax;
        beta    = _beta;
        emit FeeParamsUpdated(_feeMin, _feeMax, _baseMax, _beta);
    }

    /* ─── risk score ─────────────────────────────────────────────── */

    /// @notice Computes composite risk score R ∈ [0, 1e18].
    /// @param price  Current internal market price (WAD).
    /// @param anchor Oracle anchor price (WAD). Must be > 0.
    /// @param _timeToExpiry Seconds until market expiry.
    /// @param collateralBalance Total collateral held by AMM (WAD-scaled).
    function riskScore(
        uint256 price,
        uint256 anchor,
        uint256 _timeToExpiry,
        uint256 collateralBalance
    ) external view returns (uint256) {
        // R_div = clamp(|price - anchor| / (anchor * dMax / WAD), 0, 1)
        //       = clamp(|price - anchor| * WAD / anchor * WAD / dMax, WAD)
        //       using relative divergence: relDiv = |price - anchor| * WAD / anchor
        if (anchor == 0) revert AnchorPriceZero();
        uint256 d = price > anchor ? price - anchor : anchor - price;
        uint256 relDiv = d * WAD / anchor;
        uint256 rDiv = _clamp(relDiv * WAD / dMax, WAD);

        // R_time = clamp((tMax - timeToExpiry) / tMax, 0, 1)
        uint256 rTime;
        if (_timeToExpiry >= tMax) {
            rTime = 0;
        } else {
            rTime = (tMax - _timeToExpiry) * WAD / tMax;
        }

        // R_liq = clamp((lTarget - collateralBalance) / lTarget, 0, 1)
        uint256 rLiq;
        if (collateralBalance >= lTarget) {
            rLiq = 0;
        } else {
            rLiq = (lTarget - collateralBalance) * WAD / lTarget;
        }

        // R = clamp(w1·R_div + w2·R_time + w3·R_liq, 0, 1)
        uint256 R = (w1 * rDiv + w2 * rTime + w3 * rLiq) / WAD;
        return _clamp(R, WAD);
    }

    /* ─── fee + trade-size params ────────────────────────────────── */

    /// @notice Maps risk score R → (feeBps, maxTrade).
    function params(uint256 R) external view returns (uint256 feeBps, uint256 maxTrade) {
        feeBps = feeMin + R * (feeMax - feeMin) / WAD;
        uint256 reduction = beta * R / WAD;
        maxTrade = baseMax * (WAD - reduction) / WAD;
    }

    /* ─── helpers ────────────────────────────────────────────────── */

    function _clamp(uint256 val, uint256 maxVal) internal pure returns (uint256) {
        return val > maxVal ? maxVal : val;
    }
}
