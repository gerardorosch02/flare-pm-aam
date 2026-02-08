// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IAnchorOracle} from "../src/OracleAdapter.sol";
import {FlareFtsoV2AnchorOracle} from "../src/oracle/FlareFtsoV2AnchorOracle.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";

/* ─── Mock FTSOv2 ────────────────────────────────────────────────── *
 *  Simulates Flare's TestFtsoV2Interface.getFeedByIdInWei()          *
 *  so we can test the adapter without a live Coston2 fork.           *
 * ────────────────────────────────────────────────────────────────── */
contract MockFtsoV2 {
    mapping(bytes21 => uint256) public prices;

    function setPrice(bytes21 feedId, uint256 priceWei) external {
        prices[feedId] = priceWei;
    }

    /// @dev Matches FtsoV2Interface.getFeedByIdInWei signature.
    function getFeedByIdInWei(
        bytes21 _feedId
    ) external view returns (uint256 _value, uint64 _timestamp) {
        _value = prices[_feedId];
        _timestamp = uint64(block.timestamp);
    }
}

/* ─── helper: minimal ERC-20 ─────────────────────────────────────── */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/* ═══════════════════════════════════════════════════════════════════ *
 *  Test suite: FlareFtsoV2AnchorOracle adapter                       *
 * ═══════════════════════════════════════════════════════════════════ */
contract FtsoAnchorOracleTest is Test {
    MockFtsoV2 mockFtso;
    FlareFtsoV2AnchorOracle ftsoOracle;

    // ETH/USD feed ID (from Flare docs)
    bytes21 constant ETH_USD = bytes21(0x014554482f55534400000000000000000000000000);

    function setUp() public {
        mockFtso = new MockFtsoV2();
        ftsoOracle = new FlareFtsoV2AnchorOracle(address(mockFtso), ETH_USD, 5 minutes);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 1 – anchorPrice() returns the FTSOv2 value in WAD       *
     * ────────────────────────────────────────────────────────────── */
    function test_anchorPriceReturnsFtsoValue() public {
        uint256 expected = 0.50e18; // $0.50 in WAD
        mockFtso.setPrice(ETH_USD, expected);
        assertEq(ftsoOracle.anchorPrice(), expected, "should relay FTSO price");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 2 – anchorPrice() tracks price changes                  *
     * ────────────────────────────────────────────────────────────── */
    function test_anchorPriceUpdatesWithFtso() public {
        mockFtso.setPrice(ETH_USD, 0.50e18);
        assertEq(ftsoOracle.anchorPrice(), 0.50e18);

        // Simulate oracle price moving up
        mockFtso.setPrice(ETH_USD, 0.75e18);
        assertEq(ftsoOracle.anchorPrice(), 0.75e18, "should reflect updated FTSO price");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 3 – FlareFtsoV2AnchorOracle implements IAnchorOracle     *
     * ────────────────────────────────────────────────────────────── */
    function test_implementsIAnchorOracle() public {
        // The adapter should be usable anywhere IAnchorOracle is expected.
        IAnchorOracle oracleInterface = IAnchorOracle(address(ftsoOracle));
        mockFtso.setPrice(ETH_USD, 0.42e18);
        assertEq(oracleInterface.anchorPrice(), 0.42e18);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 4 – Full AMM integration with FTSO-backed oracle        *
     * ────────────────────────────────────────────────────────────── */
    function test_ammWorksWithFtsoOracle() public {
        // Wire up the full stack using the FTSO adapter instead of StubAnchorOracle
        MockERC20 token = new MockERC20();
        RiskController ctrl = new RiskController();
        PredictionMarket mkt = new PredictionMarket(block.timestamp + 24 hours, address(0));

        BinaryPMAMM amm = new BinaryPMAMM(
            address(token),
            address(mkt),
            address(ftsoOracle), // ← FTSO-backed oracle
            address(ctrl),
            0.50e18,  // initial price matching oracle
            5000      // bandBps = ±50%
        );

        // Set FTSO price to 0.50e18 (matches AMM starting price)
        mockFtso.setPrice(ETH_USD, 0.50e18);

        // Fund and approve
        address alice = makeAddr("alice");
        token.mint(alice, 100_000e18);
        token.mint(address(amm), 10_000e18);
        vm.prank(alice);
        token.approve(address(amm), type(uint256).max);

        // Execute a buy
        vm.prank(alice);
        uint256 newP = amm.buyYes(5e18);

        // Price should have moved up from 0.50e18
        assertGt(newP, 0.50e18, "buy should push price up");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 5 – FTSO divergence drives higher fees in full AMM      *
     * ────────────────────────────────────────────────────────────── */
    function test_ftsoDivergenceDrivesHigherFee() public {
        RiskController ctrl = new RiskController();

        // Scenario A: FTSO close to AMM price
        mockFtso.setPrice(ETH_USD, 0.50e18);
        uint256 rClose = ctrl.riskScore(
            0.50e18,
            ftsoOracle.anchorPrice(),
            24 hours,
            1_000e18
        );
        (uint256 feeLow, ) = ctrl.params(rClose);

        // Scenario B: FTSO far from AMM price
        mockFtso.setPrice(ETH_USD, 0.80e18);
        uint256 rFar = ctrl.riskScore(
            0.50e18,
            ftsoOracle.anchorPrice(),
            24 hours,
            1_000e18
        );
        (uint256 feeHigh, ) = ctrl.params(rFar);

        assertGt(feeHigh, feeLow, "FTSO divergence should raise fees");
    }
}
