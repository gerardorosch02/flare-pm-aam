// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";

/* ─── helper: minimal ERC-20 ─────────────────────────────────────── */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/* ═══════════════════════════════════════════════════════════════════ *
 *  Attack simulation – prove the AMM defends itself under            *
 *  manipulation scenarios.                                           *
 * ═══════════════════════════════════════════════════════════════════ */
contract AttackSimulationTest is Test {
    MockERC20 token;
    StubAnchorOracle oracle;
    PredictionMarket market;
    RiskController controller;
    BinaryPMAMM amm;

    address attacker = makeAddr("attacker");

    function setUp() public {
        token = new MockERC20();
        oracle = new StubAnchorOracle();
        controller = new RiskController();

        // Market expires in 24 hours
        market = new PredictionMarket(block.timestamp + 24 hours, address(0));

        amm = new BinaryPMAMM(
            address(token),
            address(market),
            address(oracle),
            address(controller),
            0.50e18,
            5000
        );

        // Fund attacker
        token.mint(attacker, 100_000e18);
        vm.prank(attacker);
        token.approve(address(amm), type(uint256).max);

        // Seed AMM with collateral
        token.mint(address(amm), 10_000e18);

        // Default anchor aligned with starting price
        oracle.setAnchorPrice(0.50e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 1 – pushing p away from anchor increases fee             *
     * ────────────────────────────────────────────────────────────── */
    function test_attack_increases_fee() public {
        // Baseline: compute fee at the initial state (p = anchor = 0.50)
        uint256 rBefore = controller.riskScore(
            amm.price(),
            oracle.anchorPrice(),
            market.timeToExpiry(),
            amm.collateralBalance()
        );
        (uint256 feeBefore, ) = controller.params(rBefore);

        // Attacker pumps price upward with repeated buys
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(attacker);
            amm.buyYes(10e18);
        }

        // p has drifted away from anchor → divergence increased
        uint256 rAfter = controller.riskScore(
            amm.price(),
            oracle.anchorPrice(),
            market.timeToExpiry(),
            amm.collateralBalance()
        );
        (uint256 feeAfter, ) = controller.params(rAfter);

        assertGt(amm.price(), 0.50e18, "price should have moved up");
        assertGt(feeAfter, feeBefore, "fee should increase as p diverges from anchor");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 2 – oracle divergence reduces max trade size             *
     * ────────────────────────────────────────────────────────────── */
    function test_attack_reduces_max_trade() public {
        // Baseline maxTrade with aligned anchor
        uint256 rAligned = controller.riskScore(
            0.50e18,
            0.50e18,
            market.timeToExpiry(),
            amm.collateralBalance()
        );
        (, uint256 maxAligned) = controller.params(rAligned);

        // Simulate oracle manipulation / divergence: anchor drops to 0.20
        oracle.setAnchorPrice(0.20e18);

        uint256 rDiverged = controller.riskScore(
            0.50e18,
            oracle.anchorPrice(),
            market.timeToExpiry(),
            amm.collateralBalance()
        );
        (, uint256 maxDiverged) = controller.params(rDiverged);

        // maxTrade should have decreased materially (at least 20% smaller)
        assertLt(maxDiverged, maxAligned, "maxTrade should decrease with divergence");
        assertLt(
            maxDiverged * 100 / maxAligned,
            80,
            "maxTrade should drop by more than 20%"
        );
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 3 – near expiry the AMM defends more aggressively       *
     * ────────────────────────────────────────────────────────────── */
    function test_near_expiry_defends_more() public {
        // Set the same divergence for both scenarios
        oracle.setAnchorPrice(0.35e18);

        // ── Scenario A: 2 hours to expiry (low time risk) ──
        vm.warp(market.expiry() - 2 hours);

        uint256 rFar = controller.riskScore(
            0.50e18,
            oracle.anchorPrice(),
            market.timeToExpiry(),
            amm.collateralBalance()
        );
        (uint256 feeFar, ) = controller.params(rFar);

        // ── Scenario B: 5 minutes to expiry (high time risk) ──
        vm.warp(market.expiry() - 5 minutes);

        uint256 rNear = controller.riskScore(
            0.50e18,
            oracle.anchorPrice(),
            market.timeToExpiry(),
            amm.collateralBalance()
        );
        (uint256 feeNear, ) = controller.params(rNear);

        // Near expiry should have higher risk and higher fee
        assertGt(rNear, rFar, "R should be higher near expiry");
        assertGt(feeNear, feeFar, "fee should be higher near expiry");
    }
}
