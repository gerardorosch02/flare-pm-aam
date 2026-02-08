// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";

/* ─── helper: minimal ERC-20 for tests ──────────────────────────── */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/* ─── test suite ────────────────────────────────────────────────── */
contract BinaryPMAMMTest is Test {
    MockERC20 token;
    StubAnchorOracle oracle;
    PredictionMarket market;
    RiskController controller;
    BinaryPMAMM amm;

    address alice = makeAddr("alice");

    uint256 constant WAD = 1e18;

    /* ─── setUp: deploy full stack with 24-hour expiry ──────────── */
    function setUp() public {
        token = new MockERC20();
        oracle = new StubAnchorOracle();
        controller = new RiskController();

        // Market expires 24 h from now
        market = new PredictionMarket(block.timestamp + 24 hours, address(0));

        amm = new BinaryPMAMM(
            address(token),
            address(market),
            address(oracle),
            address(controller),
            0.50e18,  // initial price (WAD)
            5000      // bandBps = ±50%
        );

        // Give Alice plenty of tokens and approve AMM
        token.mint(alice, 100_000e18);
        vm.prank(alice);
        token.approve(address(amm), type(uint256).max);

        // Seed AMM with collateral so it can pay out sells
        token.mint(address(amm), 10_000e18);

        // Default oracle = 0.50e18 (matches starting price)
        oracle.setAnchorPrice(0.50e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 1 – fee increases when oracle diverges from price       *
     * ────────────────────────────────────────────────────────────── */
    function test_feeIncreasesWithOracleDivergence() public view {
        // Close anchor → low divergence
        uint256 R_close = controller.riskScore(
            0.50e18, // p
            0.50e18, // a  (same as p)
            24 hours, // full time left
            1_000e18  // at target collateral
        );
        (uint256 feeLow, ) = controller.params(R_close);

        // Far anchor → high divergence
        uint256 R_far = controller.riskScore(
            0.50e18,
            0.80e18, // a  30 pp away (>dMax=10 pp → R_div clamped to 1)
            24 hours,
            1_000e18
        );
        (uint256 feeHigh, ) = controller.params(R_far);

        assertGt(feeHigh, feeLow, "fee should increase with oracle divergence");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 2 – maxTrade decreases when oracle diverges             *
     * ────────────────────────────────────────────────────────────── */
    function test_maxTradeDecreasesWithOracleDivergence() public view {
        uint256 R_close = controller.riskScore(
            0.50e18,
            0.50e18,
            24 hours,
            1_000e18
        );
        (, uint256 maxClose) = controller.params(R_close);

        uint256 R_far = controller.riskScore(
            0.50e18,
            0.80e18,
            24 hours,
            1_000e18
        );
        (, uint256 maxFar) = controller.params(R_far);

        assertLt(maxFar, maxClose, "maxTrade should decrease with oracle divergence");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 3 – buy moves price less when near expiry (high R_time) *
     * ────────────────────────────────────────────────────────────── */
    function test_buyMovesLessNearExpiry() public {
        uint256 tradeSize = 5e18;

        // ── Scenario A: far from expiry (now), full 24 h left ──
        uint256 pBefore_A = amm.price();
        vm.prank(alice);
        amm.buyYes(tradeSize);
        uint256 pAfter_A = amm.price();
        uint256 move_A = pAfter_A - pBefore_A;

        // ── Reset AMM price to 0.50e18 for fair comparison ──
        // Re-deploy AMM
        amm = new BinaryPMAMM(
            address(token),
            address(market),
            address(oracle),
            address(controller),
            0.50e18,
            5000
        );
        token.mint(address(amm), 10_000e18);
        vm.prank(alice);
        token.approve(address(amm), type(uint256).max);

        // ── Scenario B: near expiry – warp to 1 minute before expiry ──
        vm.warp(market.expiry() - 1 minutes);

        uint256 pBefore_B = amm.price();
        vm.prank(alice);
        amm.buyYes(tradeSize);
        uint256 pAfter_B = amm.price();
        uint256 move_B = pAfter_B - pBefore_B;

        // Near expiry → higher R → larger depth → *smaller* price move
        assertLt(move_B, move_A, "buy should move price less when near expiry");
    }
}
