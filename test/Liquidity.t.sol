// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";
import {LPToken} from "../src/LPToken.sol";

/* ─── helper: minimal ERC-20 ─────────────────────────────────────── */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/* ═══════════════════════════════════════════════════════════════════ *
 *  Test suite: LP deposit / withdraw                                 *
 * ═══════════════════════════════════════════════════════════════════ */
contract LiquidityTest is Test {
    MockERC20 token;
    StubAnchorOracle oracle;
    PredictionMarket market;
    RiskController controller;
    BinaryPMAMM amm;
    LPToken lpToken;

    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address trader = makeAddr("trader");

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
        lpToken = amm.lpToken();

        // Fund LPs and trader
        token.mint(lp1, 100_000e18);
        token.mint(lp2, 100_000e18);
        token.mint(trader, 100_000e18);

        vm.prank(lp1);
        token.approve(address(amm), type(uint256).max);
        vm.prank(lp2);
        token.approve(address(amm), type(uint256).max);
        vm.prank(trader);
        token.approve(address(amm), type(uint256).max);

        oracle.setAnchorPrice(0.50e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 1 – first deposit mints 1:1 LP shares                   *
     * ────────────────────────────────────────────────────────────── */
    function test_first_deposit_mints_1to1() public {
        vm.prank(lp1);
        amm.deposit(1_000e18);

        assertEq(lpToken.balanceOf(lp1), 1_000e18, "first depositor gets 1:1 shares");
        assertEq(amm.lpTotalDeposits(), 1_000e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 2 – second deposit mints proportional shares             *
     * ────────────────────────────────────────────────────────────── */
    function test_second_deposit_proportional() public {
        vm.prank(lp1);
        amm.deposit(1_000e18);

        vm.prank(lp2);
        amm.deposit(500e18);

        // lp2 deposits 50% of existing pool → gets 50% of existing shares
        assertEq(lpToken.balanceOf(lp2), 500e18);
        assertEq(amm.lpTotalDeposits(), 1_500e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 3 – full withdrawal returns exact deposit                *
     * ────────────────────────────────────────────────────────────── */
    function test_full_withdrawal() public {
        vm.prank(lp1);
        amm.deposit(1_000e18);

        uint256 balBefore = token.balanceOf(lp1);
        uint256 shares = lpToken.balanceOf(lp1);

        vm.prank(lp1);
        amm.withdraw(shares);

        assertEq(lpToken.balanceOf(lp1), 0, "LP shares burned");
        assertEq(token.balanceOf(lp1), balBefore + 1_000e18, "got deposit back");
        assertEq(amm.lpTotalDeposits(), 0);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 4 – partial withdrawal returns proportional amount       *
     * ────────────────────────────────────────────────────────────── */
    function test_partial_withdrawal() public {
        vm.prank(lp1);
        amm.deposit(1_000e18);

        uint256 halfShares = lpToken.balanceOf(lp1) / 2;
        uint256 balBefore = token.balanceOf(lp1);

        vm.prank(lp1);
        amm.withdraw(halfShares);

        assertEq(token.balanceOf(lp1), balBefore + 500e18, "got half back");
        assertEq(amm.lpTotalDeposits(), 500e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 5 – LP deposit lowers R_liq (reduces risk)               *
     * ────────────────────────────────────────────────────────────── */
    function test_lp_deposit_lowers_risk() public {
        // R with no LP liquidity
        uint256 rBefore = controller.riskScore(
            0.50e18,
            0.50e18,
            24 hours,
            amm.totalPool() // 0
        );

        // Deposit 1000 (hits L_TARGET exactly → R_liq = 0)
        vm.prank(lp1);
        amm.deposit(1_000e18);

        uint256 rAfter = controller.riskScore(
            0.50e18,
            0.50e18,
            24 hours,
            amm.totalPool() // 1000e18
        );

        assertLt(rAfter, rBefore, "LP deposit should reduce risk");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 6 – withdraw reverts without LP shares                   *
     * ────────────────────────────────────────────────────────────── */
    function test_withdraw_reverts_without_shares() public {
        vm.prank(lp1);
        amm.deposit(1_000e18);

        vm.prank(lp2); // lp2 has no shares
        vm.expectRevert(); // ERC20InsufficientBalance
        amm.withdraw(1e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 7 – zero deposit reverts                                 *
     * ────────────────────────────────────────────────────────────── */
    function test_zero_deposit_reverts() public {
        vm.prank(lp1);
        vm.expectRevert(BinaryPMAMM.ZeroAmount.selector);
        amm.deposit(0);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 8 – zero withdraw reverts                                *
     * ────────────────────────────────────────────────────────────── */
    function test_zero_withdraw_reverts() public {
        vm.prank(lp1);
        vm.expectRevert(BinaryPMAMM.ZeroAmount.selector);
        amm.withdraw(0);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 9 – only AMM can mint/burn LP tokens                     *
     * ────────────────────────────────────────────────────────────── */
    function test_only_amm_can_mint_burn_lp() public {
        vm.prank(lp1);
        vm.expectRevert(LPToken.OnlyAMM.selector);
        lpToken.mint(lp1, 1e18);

        vm.prank(lp1);
        vm.expectRevert(LPToken.OnlyAMM.selector);
        lpToken.burn(lp1, 1e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 10 – LP + trading round-trip: LP can still exit          *
     * ────────────────────────────────────────────────────────────── */
    function test_lp_can_exit_after_trades() public {
        // LP deposits
        vm.prank(lp1);
        amm.deposit(1_000e18);

        // Trader buys and sells
        vm.prank(trader);
        amm.buyYes(50e18);

        uint256 traderYes = amm.yesToken().balanceOf(trader);
        vm.prank(trader);
        amm.sellYes(traderYes);

        // LP withdraws full position
        uint256 shares = lpToken.balanceOf(lp1);
        uint256 balBefore = token.balanceOf(lp1);

        vm.prank(lp1);
        amm.withdraw(shares);

        // LP got their deposit back
        assertGt(token.balanceOf(lp1), balBefore, "LP should receive collateral");
        assertEq(lpToken.balanceOf(lp1), 0, "LP shares burned");
    }
}
