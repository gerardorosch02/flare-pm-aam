// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";
import {NoToken} from "../src/NoToken.sol";
import {YesToken} from "../src/YesToken.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract NoTokenTest is Test {
    MockERC20 token;
    StubAnchorOracle oracle;
    PredictionMarket market;
    RiskController controller;
    BinaryPMAMM amm;
    NoToken noToken;
    YesToken yesToken;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        token = new MockERC20();
        oracle = new StubAnchorOracle();
        controller = new RiskController();
        market = new PredictionMarket(block.timestamp + 24 hours, address(0));

        amm = new BinaryPMAMM(
            address(token), address(market), address(oracle),
            address(controller), 0.50e18, 5000
        );
        noToken = amm.noToken();
        yesToken = amm.yesToken();

        token.mint(alice, 100_000e18);
        token.mint(bob, 100_000e18);
        vm.prank(alice);
        token.approve(address(amm), type(uint256).max);
        vm.prank(bob);
        token.approve(address(amm), type(uint256).max);

        // LP seed
        token.mint(address(this), 10_000e18);
        token.approve(address(amm), type(uint256).max);
        amm.deposit(10_000e18);

        oracle.setAnchorPrice(0.50e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 1 – buyNo mints NO tokens and moves price downward      *
     * ────────────────────────────────────────────────────────────── */
    function test_buyNo_mints_and_moves_price_down() public {
        uint256 priceBefore = amm.price();

        vm.prank(alice);
        uint256 priceAfter = amm.buyNo(10e18);

        assertGt(noToken.balanceOf(alice), 0, "should receive NO tokens");
        assertLt(priceAfter, priceBefore, "buyNo should push price down");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 2 – sellNo burns NO tokens and moves price upward       *
     * ────────────────────────────────────────────────────────────── */
    function test_sellNo_burns_and_moves_price_up() public {
        vm.prank(alice);
        amm.buyNo(10e18);

        uint256 priceBefore = amm.price();
        uint256 noShares = noToken.balanceOf(alice);

        vm.prank(alice);
        uint256 priceAfter = amm.sellNo(noShares);

        assertEq(noToken.balanceOf(alice), 0, "NO tokens should be burned");
        assertGt(priceAfter, priceBefore, "sellNo should push price up");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 3 – cannot sellNo without NO balance                    *
     * ────────────────────────────────────────────────────────────── */
    function test_sellNo_reverts_without_position() public {
        assertEq(noToken.balanceOf(bob), 0);

        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientBalance
        amm.sellNo(1e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 4 – NO holders claim 1:1 when outcome is NO             *
     * ────────────────────────────────────────────────────────────── */
    function test_no_holders_claim_when_outcome_no() public {
        vm.prank(alice);
        amm.buyNo(10e18);

        uint256 noShares = noToken.balanceOf(alice);
        uint256 collBefore = token.balanceOf(alice);

        vm.warp(market.expiry() + 24 hours);
        market.resolve(false); // NO wins

        vm.prank(alice);
        amm.claimWinnings();

        assertEq(noToken.balanceOf(alice), 0, "NO tokens burned");
        assertEq(token.balanceOf(alice), collBefore + noShares, "should receive 1:1 collateral");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 5 – NO holders get 0 when outcome is YES                *
     * ────────────────────────────────────────────────────────────── */
    function test_no_holders_get_nothing_when_outcome_yes() public {
        vm.prank(alice);
        amm.buyNo(10e18);

        uint256 collBefore = token.balanceOf(alice);

        vm.warp(market.expiry() + 24 hours);
        market.resolve(true); // YES wins

        vm.prank(alice);
        amm.claimWinnings();

        assertEq(noToken.balanceOf(alice), 0, "NO tokens burned");
        assertEq(token.balanceOf(alice), collBefore, "should receive nothing");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 6 – buyNo/sellNo revert after resolution                *
     * ────────────────────────────────────────────────────────────── */
    function test_buyNo_sellNo_revert_after_resolution() public {
        vm.warp(market.expiry() + 24 hours);
        market.resolve(true);

        vm.prank(alice);
        vm.expectRevert(BinaryPMAMM.MarketAlreadyResolved.selector);
        amm.buyNo(10e18);

        vm.prank(alice);
        vm.expectRevert(BinaryPMAMM.MarketAlreadyResolved.selector);
        amm.sellNo(1e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 7 – mixed YES+NO holder claims correctly                *
     * ────────────────────────────────────────────────────────────── */
    function test_mixed_yes_no_holder_claims() public {
        // Alice buys both YES and NO
        vm.prank(alice);
        amm.buyYes(10e18);
        vm.prank(alice);
        amm.buyNo(10e18);

        uint256 yesShares = yesToken.balanceOf(alice);
        uint256 noShares = noToken.balanceOf(alice);
        uint256 collBefore = token.balanceOf(alice);

        vm.warp(market.expiry() + 24 hours);
        market.resolve(true); // YES wins

        vm.prank(alice);
        amm.claimWinnings();

        // YES shares pay out, NO shares burn worthless
        assertEq(yesToken.balanceOf(alice), 0, "YES tokens burned");
        assertEq(noToken.balanceOf(alice), 0, "NO tokens burned");
        assertEq(token.balanceOf(alice), collBefore + yesShares, "payout = YES shares only");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 8 – buyNo emits event                                   *
     * ────────────────────────────────────────────────────────────── */
    function test_buyNo_emits_event() public {
        vm.expectEmit(true, false, false, false);
        emit BinaryPMAMM.BuyNoExecuted(alice, 0, 0, 0, 0);

        vm.prank(alice);
        amm.buyNo(5e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 9 – sellNo emits event                                  *
     * ────────────────────────────────────────────────────────────── */
    function test_sellNo_emits_event() public {
        vm.prank(alice);
        amm.buyNo(5e18);

        uint256 shares = noToken.balanceOf(alice) / 2;

        vm.expectEmit(true, false, false, false);
        emit BinaryPMAMM.SellNoExecuted(alice, 0, 0, 0, 0);

        vm.prank(alice);
        amm.sellNo(shares);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 10 – only AMM can mint/burn NO tokens                   *
     * ────────────────────────────────────────────────────────────── */
    function test_only_amm_can_mint_burn_no() public {
        vm.prank(alice);
        vm.expectRevert(NoToken.OnlyAMM.selector);
        noToken.mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(NoToken.OnlyAMM.selector);
        noToken.burn(alice, 1e18);
    }
}
