// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IAnchorOracle, StubAnchorOracle} from "../src/OracleAdapter.sol";
import {FlareFtsoV2AnchorOracle} from "../src/oracle/FlareFtsoV2AnchorOracle.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";

/* ─── mock ERC-20 (self-contained) ───────────────────────────────── */
contract DemoToken is ERC20 {
    constructor() ERC20("DemoUSD", "DUSD") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/* ═══════════════════════════════════════════════════════════════════ *
 *  Demo script                                                       *
 *                                                                    *
 *  Two modes:                                                        *
 *    USE_REAL_FTSO = false  → local / Anvil with StubAnchorOracle    *
 *    USE_REAL_FTSO = true   → Coston2 testnet with FTSOv2 oracle     *
 *                                                                    *
 *  Run (local):                                                      *
 *    forge script script/Demo.s.sol --tc Demo -vvvv                  *
 *                                                                    *
 *  Run (Coston2):                                                    *
 *    Set USE_REAL_FTSO = true, then:                                 *
 *    forge script script/Demo.s.sol --tc Demo -vvvv \                *
 *      --fork-url https://coston2-api.flare.network/ext/C/rpc       *
 * ═══════════════════════════════════════════════════════════════════ */
contract Demo is Script {
    /* ─── mode toggle ────────────────────────────────────────────── */
    bool constant USE_REAL_FTSO = false;

    /* ─── Coston2 constants ──────────────────────────────────────── */
    address constant COSTON2_FTSO_V2 = 0x3d893C53D9e8056135C26C8c638B76C8b60Df726;
    // ETH/USD feed ID  (see https://dev.flare.network/ftso/feeds)
    bytes21 constant ETH_USD_FEED = bytes21(0x014554482f55534400000000000000000000000000);
    uint256 constant MAX_STALENESS = 10 minutes;

    /* ─── shared state ───────────────────────────────────────────── */
    uint256 constant WAD = 1e18;
    uint256 constant TRADE_SIZE = 10e18;
    uint256 constant INITIAL_PRICE = 2500e18; // ETH/USD ~$2500
    uint256 constant BAND_BPS = 5000;          // ±50%

    DemoToken token;
    IAnchorOracle oracle;
    StubAnchorOracle stubOracle;
    PredictionMarket market;
    RiskController controller;
    BinaryPMAMM amm;

    function run() external {
        vm.startBroadcast();

        token = new DemoToken();
        controller = new RiskController();
        market = new PredictionMarket(block.timestamp + 2 hours, address(0));

        if (USE_REAL_FTSO) {
            FlareFtsoV2AnchorOracle ftso = new FlareFtsoV2AnchorOracle(
                COSTON2_FTSO_V2, ETH_USD_FEED, MAX_STALENESS
            );
            oracle = IAnchorOracle(address(ftso));
            console2.log("Mode           : TESTNET (Coston2 FTSOv2)");
            console2.log("FTSO feed      : ETH/USD");
        } else {
            stubOracle = new StubAnchorOracle();
            oracle = IAnchorOracle(address(stubOracle));
            console2.log("Mode           : LOCAL (StubAnchorOracle)");
        }

        amm = new BinaryPMAMM(
            address(token),
            address(market),
            address(oracle),
            address(controller),
            INITIAL_PRICE,
            BAND_BPS
        );

        _printBanner();

        token.mint(msg.sender, 100_000e18);
        token.approve(address(amm), type(uint256).max);

        // LP deposit to seed liquidity (from deployer)
        amm.deposit(10_000e18);

        vm.stopBroadcast();

        uint256 p1; uint256 p2; uint256 p3; uint256 p4;

        if (USE_REAL_FTSO) {
            _header("SCENARIO 1: first buy (live FTSO anchor)");
            _logPreTrade();
            vm.startBroadcast();
            p1 = amm.buyYes(TRADE_SIZE);
            vm.stopBroadcast();
            _logPostTrade(p1);

            _header("SCENARIO 2: second buy (price now diverges from anchor)");
            _logPreTrade();
            vm.startBroadcast();
            p2 = amm.buyYes(TRADE_SIZE);
            vm.stopBroadcast();
            _logPostTrade(p2);

            _header("SCENARIO 3: third buy (further divergence)");
            _logPreTrade();
            vm.startBroadcast();
            p3 = amm.buyYes(TRADE_SIZE);
            vm.stopBroadcast();
            _logPostTrade(p3);
        } else {
            _header("SCENARIO 1: anchor = $2500 (aligned with price)");
            vm.startBroadcast();
            stubOracle.setAnchorPrice(2500e18);
            vm.stopBroadcast();
            _logPreTrade();
            vm.startBroadcast();
            p1 = amm.buyYes(TRADE_SIZE);
            vm.stopBroadcast();
            _logPostTrade(p1);

            _header("SCENARIO 2: anchor = $1000 (high relative divergence)");
            vm.startBroadcast();
            stubOracle.setAnchorPrice(1000e18);
            vm.stopBroadcast();
            _logPreTrade();
            vm.startBroadcast();
            p2 = amm.buyYes(TRADE_SIZE);
            vm.stopBroadcast();
            _logPostTrade(p2);

            _header("SCENARIO 3: buyNo (NO side, pushes price DOWN)");
            vm.startBroadcast();
            stubOracle.setAnchorPrice(2500e18); // re-align anchor
            vm.stopBroadcast();
            _logPreTrade();
            vm.startBroadcast();
            p3 = amm.buyNo(TRADE_SIZE);
            vm.stopBroadcast();
            _logPostTrade(p3);
            console2.log("  YES supply    : %s", _fmtWad(amm.yesToken().totalSupply()));
            console2.log("  NO  supply    : %s", _fmtWad(amm.noToken().totalSupply()));

            _header("SCENARIO 4: warp to expiry - 5 min (time risk high)");
            vm.warp(market.expiry() - 5 minutes);
            console2.log("  block.timestamp warped to expiry - 5 min");
            _logPreTrade();
            vm.startBroadcast();
            p4 = amm.buyYes(TRADE_SIZE);
            vm.stopBroadcast();
            _logPostTrade(p4);
        }

        _printSummary(p1, p2, p3, p4);
    }

    /* ═══════════════════════════════════════════════════════════════ */

    function _printBanner() internal view {
        console2.log("========================================");
        console2.log("  Flare PM-AMM Demo (Price Mode)");
        console2.log("========================================");
        console2.log("Token      :", address(token));
        console2.log("Oracle     :", address(oracle));
        console2.log("Market     :", address(market));
        console2.log("Controller :", address(controller));
        console2.log("AMM        :", address(amm));
        console2.log("Band       : +/-%s bps", BAND_BPS);
        console2.log("");
    }

    function _header(string memory title) internal pure {
        console2.log("");
        console2.log("----------------------------------------");
        console2.log(title);
        console2.log("----------------------------------------");
    }

    function _logPreTrade() internal view {
        uint256 pr = amm.price();
        uint256 anchor = oracle.anchorPrice();
        uint256 tte = market.timeToExpiry();

        uint256 divergence = pr > anchor ? pr - anchor : anchor - pr;
        uint256 relDiv = anchor > 0 ? divergence * WAD / anchor : 0;

        uint256 R = controller.riskScore(pr, anchor, tte, amm.totalPool());
        (uint256 feeBps, uint256 maxTrade) = controller.params(R);

        console2.log("  price (pre)      : %s", _fmtWad(pr));
        console2.log("  anchor price     : %s", _fmtWad(anchor));
        console2.log("  rel divergence   : %s", _fmtWad(relDiv));
        console2.log("  timeToExpiry     : %s s", tte);
        console2.log("  totalPool        : %s", _fmtWad(amm.totalPool()));
        console2.log("  R (risk score)   : %s", _fmtWad(R));
        console2.log("  feeBps           : %s", feeBps);
        console2.log("  maxTrade         : %s", _fmtWad(maxTrade));
        console2.log("  trade size       : %s", _fmtWad(TRADE_SIZE));
    }

    function _logPostTrade(uint256 newPrice) internal pure {
        console2.log("  price (post)     : %s", _fmtWad(newPrice));
    }

    function _printSummary(uint256 p1, uint256 p2, uint256 p3, uint256 p4) internal pure {
        console2.log("");
        console2.log("========================================");
        console2.log("  SUMMARY");
        console2.log("========================================");
        console2.log("Scenario 1  price -> %s", _fmtWad(p1));
        console2.log("Scenario 2  price -> %s", _fmtWad(p2));
        if (USE_REAL_FTSO) {
            console2.log("Scenario 3  price -> %s", _fmtWad(p3));
        } else {
            console2.log("Scenario 3  price -> %s (after buyNo)", _fmtWad(p3));
            console2.log("Scenario 4  price -> %s", _fmtWad(p4));
        }

        if (USE_REAL_FTSO) {
            console2.log("");
            console2.log("  - Anchor is live from Flare FTSOv2");
            console2.log("  - As price drifts from anchor, R increases");
        } else {
            console2.log("");
            console2.log("  - Scenario 2 charged higher fee (relative divergence)");
            console2.log("  - Scenario 2 had lower maxTrade (divergence risk)");
            console2.log("  - Scenario 3 moved price less (deeper depth from time risk)");
        }
    }

    function _fmtWad(uint256 w) internal pure returns (string memory) {
        uint256 integer = w / WAD;
        uint256 frac = (w % WAD) / 1e12;
        bytes memory fracStr = new bytes(6);
        uint256 tmp = frac;
        for (uint256 i = 6; i > 0; i--) {
            fracStr[i - 1] = bytes1(uint8(48 + tmp % 10));
            tmp /= 10;
        }
        return string(abi.encodePacked(_uint2str(integer), ".", fracStr));
    }

    function _uint2str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits; uint256 tmp = v;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits -= 1; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }
}
