// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAnchorOracle} from "./OracleAdapter.sol";
import {PredictionMarket} from "./PredictionMarket.sol";
import {RiskController} from "./RiskController.sol";
import {YesToken} from "./YesToken.sol";
import {NoToken} from "./NoToken.sol";
import {LPToken} from "./LPToken.sol";

/// @title BinaryPMAMM – risk-aware binary-outcome AMM.
/// @notice The AMM maintains an internal market price `price` (WAD) anchored
///         against the oracle price `a`.  Price bounds are derived dynamically
///         from the anchor: [a*(1-bandBps/10000), a*(1+bandBps/10000)].
contract BinaryPMAMM is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ─── immutables ─────────────────────────────────────────────── */
    IERC20 public immutable collateral;
    PredictionMarket public immutable market;
    IAnchorOracle public immutable oracle;
    RiskController public immutable controller;
    YesToken public immutable yesToken;
    NoToken public immutable noToken;
    LPToken public immutable lpToken;
    address public immutable feeRecipient;
    uint256 public immutable bandBps; // price band around anchor (e.g. 5000 = ±50%)

    /* ─── state ──────────────────────────────────────────────────── */
    uint256 public price;                // internal market price in WAD
    uint256 public collateralBalance;    // collateral backing outstanding positions
    uint256 public accumulatedFees;      // fee revenue (withdrawable)
    uint256 public lpTotalDeposits;      // total LP collateral in pool

    /* ─── constants ──────────────────────────────────────────────── */
    uint256 internal constant WAD = 1e18;
    uint256 public constant DEPTH_MULTIPLIER = 200;
    uint256 public constant MIN_BASE_DEPTH = 1e18;
    uint256 internal constant ALPHA = 1e18;
    uint256 internal constant BPS_BASE = 10_000;

    /* ─── errors ─────────────────────────────────────────────────── */
    error ExceedsMaxTrade();
    error InsufficientCollateral();
    error OnlyFeeRecipient();
    error NoFeesToWithdraw();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error NothingToClaim();
    error ZeroAmount();
    error InsufficientLPLiquidity();

    /* ─── events ─────────────────────────────────────────────────── */
    event FeesWithdrawn(address indexed to, uint256 amount);
    event WinningsClaimed(address indexed claimant, uint256 amount, bool won);
    event LiquidityDeposited(address indexed provider, uint256 amount, uint256 lpShares);
    event LiquidityWithdrawn(address indexed provider, uint256 amount, uint256 lpShares);
    event BuyYesExecuted(address indexed trader, uint256 collateralIn, uint256 fee, uint256 sharesMinted, uint256 newPrice);
    event SellYesExecuted(address indexed trader, uint256 sharesBurned, uint256 fee, uint256 collateralOut, uint256 newPrice);
    event BuyNoExecuted(address indexed trader, uint256 collateralIn, uint256 fee, uint256 sharesMinted, uint256 newPrice);
    event SellNoExecuted(address indexed trader, uint256 sharesBurned, uint256 fee, uint256 collateralOut, uint256 newPrice);

    /* ─── constructor ────────────────────────────────────────────── */
    /// @param _collateral  ERC-20 collateral token.
    /// @param _market      PredictionMarket instance.
    /// @param _oracle      IAnchorOracle implementation (stub or FTSO).
    /// @param _controller  RiskController instance.
    /// @param _initialPrice Starting internal market price in WAD.
    /// @param _bandBps     Price band in basis points (e.g. 5000 = ±50%).
    constructor(
        address _collateral,
        address _market,
        address _oracle,
        address _controller,
        uint256 _initialPrice,
        uint256 _bandBps
    ) {
        collateral = IERC20(_collateral);
        market = PredictionMarket(_market);
        oracle = IAnchorOracle(_oracle);
        controller = RiskController(_controller);
        yesToken = new YesToken(address(this));
        noToken = new NoToken(address(this));
        lpToken = new LPToken(address(this));
        feeRecipient = msg.sender;
        price = _initialPrice;
        bandBps = _bandBps;
    }

    /* ─── helpers ────────────────────────────────────────────────── */

    /// @notice Total pool seen by the risk engine (positions + fees + LP).
    function totalPool() public view returns (uint256) {
        return collateralBalance + accumulatedFees + lpTotalDeposits;
    }

    /// @dev Clamp `price` to [anchor*(1-bandBps/10000), anchor*(1+bandBps/10000)].
    function _clampPrice(uint256 anchor) internal {
        uint256 pMin = anchor * (BPS_BASE - bandBps) / BPS_BASE;
        uint256 pMax = anchor * (BPS_BASE + bandBps) / BPS_BASE;
        if (price > pMax) price = pMax;
        if (price < pMin) price = pMin;
    }

    /* ─── LP deposit / withdraw ──────────────────────────────────── */

    /// @notice Deposit collateral as liquidity. Mints LP shares proportionally.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        collateral.safeTransferFrom(msg.sender, address(this), amount);

        uint256 supply = lpToken.totalSupply();
        uint256 sharesToMint;
        if (supply == 0) {
            sharesToMint = amount; // first depositor: 1:1
        } else {
            sharesToMint = amount * supply / lpTotalDeposits;
        }

        lpTotalDeposits += amount;
        lpToken.mint(msg.sender, sharesToMint);

        emit LiquidityDeposited(msg.sender, amount, sharesToMint);
    }

    /// @notice Withdraw liquidity by burning LP shares.
    ///         Cannot withdraw collateral that is backing outstanding positions.
    function withdraw(uint256 lpShares) external nonReentrant {
        if (lpShares == 0) revert ZeroAmount();

        uint256 supply = lpToken.totalSupply();
        uint256 amount = lpShares * lpTotalDeposits / supply;

        if (amount > lpTotalDeposits) revert InsufficientLPLiquidity();

        lpToken.burn(msg.sender, lpShares);
        lpTotalDeposits -= amount;

        collateral.safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(msg.sender, amount, lpShares);
    }

    /* ─── buy YES ────────────────────────────────────────────────── */

    /// @notice Buy YES shares with `collateralIn` tokens.
    ///         Mints `afterFee` YES position tokens to the caller.
    /// @return newPrice The updated internal market price after the trade.
    function buyYes(uint256 collateralIn) external nonReentrant returns (uint256 newPrice) {
        if (market.resolved()) revert MarketAlreadyResolved();

        // 1. Read anchor once for risk score + clamping
        uint256 anchor = oracle.anchorPrice();

        // 2. Risk score & trade constraints
        uint256 R = controller.riskScore(
            price,
            anchor,
            market.timeToExpiry(),
            totalPool()
        );
        (uint256 feeBps, uint256 maxTrade) = controller.params(R);
        if (collateralIn > maxTrade) revert ExceedsMaxTrade();

        // 3. Pull collateral
        collateral.safeTransferFrom(msg.sender, address(this), collateralIn);

        // 4. Apply fee
        uint256 fee = collateralIn * feeBps / BPS_BASE;
        uint256 afterFee = collateralIn - fee;

        // 5. Update balances
        collateralBalance += afterFee;
        accumulatedFees += fee;

        // 6. Mint YES position tokens to buyer
        yesToken.mint(msg.sender, afterFee);

        // 7. Price impact: Δprice = afterFee / depth (depth scales with anchor)
        uint256 baseDepth = anchor * DEPTH_MULTIPLIER;
        if (baseDepth < MIN_BASE_DEPTH) baseDepth = MIN_BASE_DEPTH;
        uint256 depth = baseDepth * (WAD + ALPHA * R / WAD) / WAD;
        uint256 impact = afterFee * WAD / depth;

        // 8. Update price (buy ⇒ price up), clamp to anchor-derived band
        price = price + impact;
        _clampPrice(anchor);

        emit BuyYesExecuted(msg.sender, collateralIn, fee, afterFee, price);
        return price;
    }

    /* ─── sell YES ───────────────────────────────────────────────── */

    /// @notice Sell YES shares; burns position tokens and returns collateral.
    ///         Reverts if the caller does not hold `sharesIn` YES tokens.
    /// @return newPrice The updated internal market price after the trade.
    function sellYes(uint256 sharesIn) external nonReentrant returns (uint256 newPrice) {
        if (market.resolved()) revert MarketAlreadyResolved();

        // 1. Burn YES tokens from seller (reverts if insufficient balance)
        yesToken.burn(msg.sender, sharesIn);

        // 2. Read anchor once
        uint256 anchor = oracle.anchorPrice();

        // 3. Risk score & trade constraints
        uint256 R = controller.riskScore(
            price,
            anchor,
            market.timeToExpiry(),
            totalPool()
        );
        (uint256 feeBps, uint256 maxTrade) = controller.params(R);
        if (sharesIn > maxTrade) revert ExceedsMaxTrade();

        // 4. Apply fee
        uint256 fee = sharesIn * feeBps / BPS_BASE;
        uint256 afterFee = sharesIn - fee;

        // 5. Update balances
        if (afterFee > collateralBalance) revert InsufficientCollateral();
        collateralBalance -= afterFee;
        accumulatedFees += fee;

        // 6. Price impact: Δprice = afterFee / depth (depth scales with anchor)
        uint256 baseDepth = anchor * DEPTH_MULTIPLIER;
        if (baseDepth < MIN_BASE_DEPTH) baseDepth = MIN_BASE_DEPTH;
        uint256 depth = baseDepth * (WAD + ALPHA * R / WAD) / WAD;
        uint256 impact = afterFee * WAD / depth;

        // 7. Update price (sell ⇒ price down), clamp to anchor-derived band
        if (impact >= price) {
            price = anchor * (BPS_BASE - bandBps) / BPS_BASE; // floor
        } else {
            price = price - impact;
        }
        _clampPrice(anchor);

        // 8. Transfer collateral out
        collateral.safeTransfer(msg.sender, afterFee);

        emit SellYesExecuted(msg.sender, sharesIn, fee, afterFee, price);
        return price;
    }

    /* ─── buy NO ─────────────────────────────────────────────────── */

    /// @notice Buy NO shares with `collateralIn` tokens.
    ///         Mints `afterFee` NO position tokens to the caller.
    ///         Buying NO pushes the YES price DOWN (symmetric to buyYes).
    /// @return newPrice The updated internal market price after the trade.
    function buyNo(uint256 collateralIn) external nonReentrant returns (uint256 newPrice) {
        if (market.resolved()) revert MarketAlreadyResolved();

        uint256 anchor = oracle.anchorPrice();

        uint256 R = controller.riskScore(
            price,
            anchor,
            market.timeToExpiry(),
            totalPool()
        );
        (uint256 feeBps, uint256 maxTrade) = controller.params(R);
        if (collateralIn > maxTrade) revert ExceedsMaxTrade();

        collateral.safeTransferFrom(msg.sender, address(this), collateralIn);

        uint256 fee = collateralIn * feeBps / BPS_BASE;
        uint256 afterFee = collateralIn - fee;

        collateralBalance += afterFee;
        accumulatedFees += fee;

        noToken.mint(msg.sender, afterFee);

        // Price impact: buying NO pushes YES price DOWN (depth scales with anchor)
        uint256 baseDepth = anchor * DEPTH_MULTIPLIER;
        if (baseDepth < MIN_BASE_DEPTH) baseDepth = MIN_BASE_DEPTH;
        uint256 depth = baseDepth * (WAD + ALPHA * R / WAD) / WAD;
        uint256 impact = afterFee * WAD / depth;

        if (impact >= price) {
            price = anchor * (BPS_BASE - bandBps) / BPS_BASE;
        } else {
            price = price - impact;
        }
        _clampPrice(anchor);

        emit BuyNoExecuted(msg.sender, collateralIn, fee, afterFee, price);
        return price;
    }

    /* ─── sell NO ────────────────────────────────────────────────── */

    /// @notice Sell NO shares; burns position tokens and returns collateral.
    ///         Selling NO pushes the YES price UP (symmetric to sellYes).
    /// @return newPrice The updated internal market price after the trade.
    function sellNo(uint256 sharesIn) external nonReentrant returns (uint256 newPrice) {
        if (market.resolved()) revert MarketAlreadyResolved();

        noToken.burn(msg.sender, sharesIn);

        uint256 anchor = oracle.anchorPrice();

        uint256 R = controller.riskScore(
            price,
            anchor,
            market.timeToExpiry(),
            totalPool()
        );
        (uint256 feeBps, uint256 maxTrade) = controller.params(R);
        if (sharesIn > maxTrade) revert ExceedsMaxTrade();

        uint256 fee = sharesIn * feeBps / BPS_BASE;
        uint256 afterFee = sharesIn - fee;

        if (afterFee > collateralBalance) revert InsufficientCollateral();
        collateralBalance -= afterFee;
        accumulatedFees += fee;

        // Price impact: selling NO pushes YES price UP (depth scales with anchor)
        uint256 baseDepth = anchor * DEPTH_MULTIPLIER;
        if (baseDepth < MIN_BASE_DEPTH) baseDepth = MIN_BASE_DEPTH;
        uint256 depth = baseDepth * (WAD + ALPHA * R / WAD) / WAD;
        uint256 impact = afterFee * WAD / depth;

        price = price + impact;
        _clampPrice(anchor);

        collateral.safeTransfer(msg.sender, afterFee);

        emit SellNoExecuted(msg.sender, sharesIn, fee, afterFee, price);
        return price;
    }

    /* ─── claim winnings after resolution ────────────────────────── */

    /// @notice After market resolution, token holders claim winnings.
    ///         If outcome == true:  YES shares redeem 1:1, NO shares redeem 0.
    ///         If outcome == false: NO shares redeem 1:1, YES shares redeem 0.
    ///         Burns all of the caller's YES and NO tokens.
    function claimWinnings() external nonReentrant {
        if (!market.resolved()) revert MarketNotResolved();

        uint256 yesShares = yesToken.balanceOf(msg.sender);
        uint256 noShares = noToken.balanceOf(msg.sender);
        if (yesShares == 0 && noShares == 0) revert NothingToClaim();

        // Burn all position tokens
        if (yesShares > 0) yesToken.burn(msg.sender, yesShares);
        if (noShares > 0) noToken.burn(msg.sender, noShares);

        uint256 payout;
        if (market.outcome()) {
            // YES won
            payout = yesShares;
        } else {
            // NO won
            payout = noShares;
        }

        if (payout > 0) {
            collateralBalance -= payout;
            collateral.safeTransfer(msg.sender, payout);
        }

        emit WinningsClaimed(msg.sender, payout, market.outcome());
    }

    /* ─── fee withdrawal ─────────────────────────────────────────── */

    /// @notice Withdraw accumulated fees to the fee recipient.
    function withdrawFees() external nonReentrant {
        if (msg.sender != feeRecipient) revert OnlyFeeRecipient();
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToWithdraw();

        accumulatedFees = 0;
        collateral.safeTransfer(feeRecipient, amount);

        emit FeesWithdrawn(feeRecipient, amount);
    }
}
