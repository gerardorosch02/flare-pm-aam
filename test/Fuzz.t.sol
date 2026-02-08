// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";

/* ─── helper ─────────────────────────────────────────────────────── */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/* ═══════════════════════════════════════════════════════════════════ *
 *  Fuzz tests for RiskController math and BinaryPMAMM price model    *
 * ═══════════════════════════════════════════════════════════════════ */
contract FuzzTest is Test {
    RiskController controller;

    function setUp() public {
        controller = new RiskController();
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 1 – riskScore always returns R ∈ [0, 1e18]              *
     *           (anchor must be > 0 for relative divergence)         *
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_riskScore_bounded(
        uint256 p,
        uint256 a,
        uint256 tte,
        uint256 col
    ) public view {
        // Price-space ranges; anchor must be > 0
        p   = bound(p,   0.001e18, 100e18);
        a   = bound(a,   0.001e18, 100e18);
        tte = bound(tte, 0, 7 days);
        col = bound(col, 0, 10_000e18);

        uint256 R = controller.riskScore(p, a, tte, col);

        assertLe(R, 1e18, "R must be <= 1e18");
        assertGe(R, 0, "R must be >= 0");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 2 – feeBps stays in [feeMin, feeMax]                    *
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_feeBps_bounded(uint256 R) public view {
        R = bound(R, 0, 1e18);

        (uint256 feeBps, ) = controller.params(R);

        assertGe(feeBps, controller.feeMin(), "fee >= feeMin");
        assertLe(feeBps, controller.feeMax(), "fee <= feeMax");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 3 – maxTrade stays in [baseMax*(1-beta), baseMax]        *
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_maxTrade_bounded(uint256 R) public view {
        R = bound(R, 0, 1e18);

        (, uint256 maxTrade) = controller.params(R);

        uint256 floor = controller.baseMax() * (1e18 - controller.beta()) / 1e18;
        assertGe(maxTrade, floor, "maxTrade >= floor");
        assertLe(maxTrade, controller.baseMax(), "maxTrade <= baseMax");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 4 – higher relative divergence → higher R (monotonicity) *
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_divergence_monotonic(uint256 a1, uint256 a2) public view {
        uint256 p = 0.50e18;
        a1 = bound(a1, 0.001e18, 100e18);
        a2 = bound(a2, 0.001e18, 100e18);

        // Relative divergence from p to each anchor
        uint256 d1abs = p > a1 ? p - a1 : a1 - p;
        uint256 d2abs = p > a2 ? p - a2 : a2 - p;
        uint256 relDiv1 = d1abs * 1e18 / a1;
        uint256 relDiv2 = d2abs * 1e18 / a2;

        uint256 R1 = controller.riskScore(p, a1, 24 hours, 1_000e18);
        uint256 R2 = controller.riskScore(p, a2, 24 hours, 1_000e18);

        if (relDiv1 <= relDiv2) {
            assertLe(R1, R2, "more relative divergence -> higher or equal R");
        } else {
            assertGe(R1, R2, "less relative divergence -> lower or equal R");
        }
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 5 – higher R → higher fee (monotonicity)                 *
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_fee_monotonic(uint256 R1, uint256 R2) public view {
        R1 = bound(R1, 0, 1e18);
        R2 = bound(R2, 0, 1e18);

        (uint256 fee1, ) = controller.params(R1);
        (uint256 fee2, ) = controller.params(R2);

        if (R1 <= R2) {
            assertLe(fee1, fee2, "higher R -> higher or equal fee");
        } else {
            assertGe(fee1, fee2, "lower R -> lower or equal fee");
        }
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 6 – higher R → lower maxTrade (anti-monotonic)           *
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_maxTrade_antiMonotonic(uint256 R1, uint256 R2) public view {
        R1 = bound(R1, 0, 1e18);
        R2 = bound(R2, 0, 1e18);

        (, uint256 max1) = controller.params(R1);
        (, uint256 max2) = controller.params(R2);

        if (R1 <= R2) {
            assertGe(max1, max2, "higher R -> lower or equal maxTrade");
        } else {
            assertLe(max1, max2, "lower R -> higher or equal maxTrade");
        }
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 7 – buyYes always leaves price within anchor-derived band*
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_buyYes_price_bounded(uint256 tradeSize) public {
        MockERC20 token = new MockERC20();
        StubAnchorOracle oracle = new StubAnchorOracle();
        PredictionMarket market = new PredictionMarket(block.timestamp + 24 hours, address(0));

        uint256 anchorVal = 0.50e18;
        uint256 band = 5000; // ±50%

        BinaryPMAMM amm = new BinaryPMAMM(
            address(token),
            address(market),
            address(oracle),
            address(controller),
            anchorVal,
            band
        );

        oracle.setAnchorPrice(anchorVal);

        token.mint(address(this), 100_000e18);
        token.approve(address(amm), type(uint256).max);
        amm.deposit(1_000e18);

        tradeSize = bound(tradeSize, 1, 20e18);

        address trader = makeAddr("fuzzTrader");
        token.mint(trader, tradeSize);
        vm.prank(trader);
        token.approve(address(amm), type(uint256).max);

        vm.prank(trader);
        uint256 newPrice = amm.buyYes(tradeSize);

        uint256 pMin = anchorVal * (10_000 - band) / 10_000;
        uint256 pMax = anchorVal * (10_000 + band) / 10_000;
        assertGe(newPrice, pMin, "price >= anchor-derived min");
        assertLe(newPrice, pMax, "price <= anchor-derived max");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 8 – governance: setRiskParams rejects bad weights        *
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_setRiskParams_rejects_bad_weights(
        uint256 _w1,
        uint256 _w2,
        uint256 _w3
    ) public {
        _w1 = bound(_w1, 0, 1e18);
        _w2 = bound(_w2, 0, 1e18);
        _w3 = bound(_w3, 0, 1e18);

        if (_w1 + _w2 + _w3 != 1e18) {
            vm.expectRevert(RiskController.WeightsMustSumToWAD.selector);
            controller.setRiskParams(0.10e18, 24 hours, 1_000e18, _w1, _w2, _w3);
        }
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Fuzz 9 – riskScore reverts when anchor == 0                   *
     * ────────────────────────────────────────────────────────────── */
    function testFuzz_riskScore_reverts_zero_anchor(uint256 p) public {
        p = bound(p, 0.001e18, 100e18);

        vm.expectRevert(RiskController.AnchorPriceZero.selector);
        controller.riskScore(p, 0, 24 hours, 1_000e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 10 – depth scales proportionally with anchor price       *
     * ────────────────────────────────────────────────────────────── */
    function test_depth_scales_with_anchor() public {
        // Verify the core property: baseDepth = anchor * DEPTH_MULTIPLIER
        // With DEPTH_MULTIPLIER = 200:
        //   anchor = 0.05  → baseDepth = 10
        //   anchor = 2000  → baseDepth = 400000
        // The ratio of depths should equal the ratio of anchors.

        MockERC20 tok = new MockERC20();
        StubAnchorOracle oracleLow = new StubAnchorOracle();
        StubAnchorOracle oracleHigh = new StubAnchorOracle();

        uint256 anchorLow = 0.05e18;
        uint256 anchorHigh = 2000e18;
        oracleLow.setAnchorPrice(anchorLow);
        oracleHigh.setAnchorPrice(anchorHigh);

        PredictionMarket mkt = new PredictionMarket(block.timestamp + 24 hours, address(0));

        BinaryPMAMM ammLow = new BinaryPMAMM(
            address(tok), address(mkt), address(oracleLow),
            address(controller), anchorLow, 5000
        );
        BinaryPMAMM ammHigh = new BinaryPMAMM(
            address(tok), address(mkt), address(oracleHigh),
            address(controller), anchorHigh, 5000
        );

        tok.mint(address(this), 500_000e18);
        tok.approve(address(ammLow), type(uint256).max);
        tok.approve(address(ammHigh), type(uint256).max);
        ammLow.deposit(10_000e18);
        ammHigh.deposit(10_000e18);

        address trader = makeAddr("depthTrader");
        tok.mint(trader, 20e18);
        vm.startPrank(trader);
        tok.approve(address(ammLow), type(uint256).max);
        tok.approve(address(ammHigh), type(uint256).max);

        // Trade SMALL amount so neither AMM hits the price-band clamp.
        // Low anchor depth = 0.05*200 = 10. Trade of 0.1 → impact ≈ 0.01 (20% of 0.05, within ±50% band).
        uint256 tradeAmt = 0.1e18;

        uint256 priceLowBefore = ammLow.price();
        ammLow.buyYes(tradeAmt);
        uint256 moveLow = ammLow.price() - priceLowBefore;

        uint256 priceHighBefore = ammHigh.price();
        ammHigh.buyYes(tradeAmt);
        uint256 moveHigh = ammHigh.price() - priceHighBefore;
        vm.stopPrank();

        // Low anchor has smaller depth → same trade creates LARGER absolute move
        assertGt(moveLow, moveHigh, "low anchor should have larger absolute impact");

        // The ratio of moves should be roughly inverse to the ratio of anchors:
        // moveLow / moveHigh ≈ anchorHigh / anchorLow = 40000
        // Allow 2x tolerance for fee/risk rounding
        uint256 moveRatio = moveLow * 1e18 / moveHigh;
        uint256 anchorRatio = anchorHigh * 1e18 / anchorLow;
        assertGt(moveRatio, anchorRatio / 2, "move ratio should track anchor ratio (lower bound)");
        assertLt(moveRatio, anchorRatio * 2, "move ratio should track anchor ratio (upper bound)");
    }
}
