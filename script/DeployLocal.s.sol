// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";

contract DemoToken is ERC20 {
    constructor() ERC20("DemoUSD", "DUSD") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Deploy full stack to Anvil for frontend demo.
///         Run: anvil &
///         forge script script/DeployLocal.s.sol --tc DeployLocal --broadcast --rpc-url http://127.0.0.1:8545
contract DeployLocal is Script {
    function run() external {
        vm.startBroadcast();

        DemoToken token = new DemoToken();
        StubAnchorOracle oracle = new StubAnchorOracle();
        RiskController controller = new RiskController();
        PredictionMarket market = new PredictionMarket(block.timestamp + 24 hours, address(0));

        BinaryPMAMM amm = new BinaryPMAMM(
            address(token),
            address(market),
            address(oracle),
            address(controller),
            2500e18,  // initial price (ETH/USD)
            5000      // bandBps ±50%
        );

        // Set oracle to aligned anchor
        oracle.setAnchorPrice(2500e18);

        // Raise lTarget so the LP slider (100 – 100k) visibly affects risk score.
        // Default lTarget is 1000e18; anything above that produces R_liq = 0.
        // Setting lTarget = 100_000e18 means the full slider range is sensitive.
        controller.setRiskParams(
            0.10e18,      // dMax  (unchanged)
            24 hours,     // tMax  (unchanged)
            100_000e18,   // lTarget ← raised from 1000e18
            0.50e18,      // w1 (unchanged)
            0.30e18,      // w2 (unchanged)
            0.20e18       // w3 (unchanged)
        );

        // Mint tokens to deployer, approve AMM
        token.mint(msg.sender, 1_000_000e18);
        token.approve(address(amm), type(uint256).max);

        // LP deposit to seed liquidity
        amm.deposit(100_000e18);

        vm.stopBroadcast();

        // Log addresses for frontend config
        console2.log("===== FRONTEND CONFIG =====");
        console2.log("TOKEN=%s", address(token));
        console2.log("ORACLE=%s", address(oracle));
        console2.log("CONTROLLER=%s", address(controller));
        console2.log("MARKET=%s", address(market));
        console2.log("AMM=%s", address(amm));
        console2.log("YES_TOKEN=%s", address(amm.yesToken()));
        console2.log("NO_TOKEN=%s", address(amm.noToken()));
        console2.log("LP_TOKEN=%s", address(amm.lpToken()));
        console2.log("===========================");
    }
}
