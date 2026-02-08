// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";
import {YesToken} from "../src/YesToken.sol";

/* ─── helper: minimal ERC-20 ─────────────────────────────────────── */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/* ═══════════════════════════════════════════════════════════════════ *
 *  Test suite: YesToken position accounting                          *
 * ═══════════════════════════════════════════════════════════════════ */
contract YesTokenTest is Test {
    MockERC20 token;
    StubAnchorOracle oracle;
    PredictionMarket market;
    RiskController controller;
    BinaryPMAMM amm;
    YesToken yesToken;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        token = new MockERC20();
        oracle = new StubAnchorOracle();
        controller = new RiskController();
        market = new PredictionMarket(block.timestamp + 24 hours, address(0));

        amm = new BinaryPMAMM(
            address(token),
            address(market),
            address(oracle),
            address(controller),
            0.50e18,
            5000
        );
        yesToken = amm.yesToken();

        // Fund Alice and Bob
        token.mint(alice, 100_000e18);
        token.mint(bob, 100_000e18);
        vm.prank(alice);
        token.approve(address(amm), type(uint256).max);
        vm.prank(bob);
        token.approve(address(amm), type(uint256).max);

        // Seed AMM with collateral for payouts
        token.mint(address(amm), 10_000e18);

        // Aligned anchor
        oracle.setAnchorPrice(0.50e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 1 – sellYes reverts when caller has no position          *
     * ────────────────────────────────────────────────────────────── */
    function test_sellYes_reverts_without_position() public {
        // Bob has never bought — has zero YES tokens
        assertEq(yesToken.balanceOf(bob), 0);

        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientBalance
        amm.sellYes(1e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 2 – sellYes reverts when selling more than position      *
     * ────────────────────────────────────────────────────────────── */
    function test_sellYes_reverts_over_position() public {
        // Alice buys 10 collateral → gets some YES tokens
        vm.prank(alice);
        amm.buyYes(10e18);

        uint256 aliceYes = yesToken.balanceOf(alice);
        assertGt(aliceYes, 0, "alice should have YES tokens");

        // Try to sell more than she has
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance
        amm.sellYes(aliceYes + 1);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 3 – buyYes mints correct YES token amount                *
     * ────────────────────────────────────────────────────────────── */
    function test_buyYes_mints_position_tokens() public {
        uint256 beforeBal = yesToken.balanceOf(alice);
        assertEq(beforeBal, 0);

        vm.prank(alice);
        amm.buyYes(10e18);

        uint256 afterBal = yesToken.balanceOf(alice);
        assertGt(afterBal, 0, "should have received YES tokens");
        // afterBal should be collateralIn minus fee
        // Fee is ~97 bps in this config → afterFee ≈ 9.903e18
        assertLt(afterBal, 10e18, "should be less than collateralIn (fee deducted)");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 4 – sellYes burns tokens and returns collateral          *
     * ────────────────────────────────────────────────────────────── */
    function test_sellYes_burns_tokens_and_pays() public {
        // Alice buys
        vm.prank(alice);
        amm.buyYes(10e18);

        uint256 yesBal = yesToken.balanceOf(alice);
        uint256 collBefore = token.balanceOf(alice);

        // Alice sells her full position
        vm.prank(alice);
        amm.sellYes(yesBal);

        // YES tokens should be zero
        assertEq(yesToken.balanceOf(alice), 0, "YES tokens should be burned");
        // Should have received collateral back (minus sell fee)
        assertGt(token.balanceOf(alice), collBefore, "should receive collateral");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 5 – attacker cannot drain without position               *
     * ────────────────────────────────────────────────────────────── */
    function test_drain_attack_blocked() public {
        // Alice buys to create some collateral balance
        vm.prank(alice);
        amm.buyYes(50e18);

        uint256 ammCollateral = token.balanceOf(address(amm));
        assertGt(ammCollateral, 0, "AMM should hold collateral");

        // Bob (attacker) tries to drain without buying first
        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientBalance — no YES tokens
        amm.sellYes(50e18);

        // AMM collateral unchanged
        assertEq(
            token.balanceOf(address(amm)),
            ammCollateral,
            "AMM collateral should be unchanged after failed attack"
        );
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 6 – only AMM can mint/burn YES tokens                    *
     * ────────────────────────────────────────────────────────────── */
    function test_only_amm_can_mint_burn() public {
        vm.prank(alice);
        vm.expectRevert(YesToken.OnlyAMM.selector);
        yesToken.mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(YesToken.OnlyAMM.selector);
        yesToken.burn(alice, 1e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 7 – fees are tracked and collateralBalance stays in sync *
     * ────────────────────────────────────────────────────────────── */
    function test_fee_accounting_accurate() public {
        uint256 tradeSize = 10e18;

        // Before trade
        assertEq(amm.accumulatedFees(), 0);
        assertEq(amm.collateralBalance(), 0);

        // Buy
        vm.prank(alice);
        amm.buyYes(tradeSize);

        uint256 fees = amm.accumulatedFees();
        uint256 colBal = amm.collateralBalance();

        // fees + collateralBalance should equal the trade size exactly
        // (all of collateralIn is accounted for)
        assertGt(fees, 0, "fees should be non-zero");
        assertEq(
            fees + colBal,
            tradeSize,
            "fees + collateralBalance must equal collateralIn"
        );

        // The actual token balance of the AMM should include the seed + trade
        uint256 actualBal = token.balanceOf(address(amm));
        assertEq(
            actualBal,
            10_000e18 + tradeSize, // seed + incoming trade
            "token balance = seed + collateralIn"
        );
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 8 – fee recipient can withdraw accumulated fees          *
     * ────────────────────────────────────────────────────────────── */
    function test_withdraw_fees() public {
        // Alice buys → generates fees
        vm.prank(alice);
        amm.buyYes(10e18);

        uint256 fees = amm.accumulatedFees();
        assertGt(fees, 0);

        // Fee recipient is the deployer (this test contract)
        address recipient = amm.feeRecipient();
        uint256 recipientBefore = token.balanceOf(recipient);

        amm.withdrawFees();

        assertEq(amm.accumulatedFees(), 0, "fees should be zero after withdrawal");
        assertEq(
            token.balanceOf(recipient),
            recipientBefore + fees,
            "recipient should receive fees"
        );
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 9 – non-recipient cannot withdraw fees                   *
     * ────────────────────────────────────────────────────────────── */
    function test_only_fee_recipient_can_withdraw() public {
        vm.prank(alice);
        amm.buyYes(10e18);

        vm.prank(bob);
        vm.expectRevert(BinaryPMAMM.OnlyFeeRecipient.selector);
        amm.withdrawFees();
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 10 – withdraw reverts when no fees accumulated           *
     * ────────────────────────────────────────────────────────────── */
    function test_withdraw_reverts_when_no_fees() public {
        vm.expectRevert(BinaryPMAMM.NoFeesToWithdraw.selector);
        amm.withdrawFees();
    }
}
