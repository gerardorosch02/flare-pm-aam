// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {RiskController} from "../src/RiskController.sol";
import {BinaryPMAMM} from "../src/BinaryPMAMM.sol";
import {MockFdcVerifier} from "../src/fdc/MockFdcVerifier.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Attestation format: abi.encode(marketAddress, outcome, timestamp, nonce)
contract FdcResolutionTest is Test {
    MockERC20 token;
    StubAnchorOracle oracle;
    RiskController controller;
    MockFdcVerifier verifier;
    PredictionMarket market;
    BinaryPMAMM amm;

    address alice = makeAddr("alice");

    uint256 constant EXPIRY_OFFSET = 2 hours;

    function setUp() public {
        token = new MockERC20();
        oracle = new StubAnchorOracle();
        controller = new RiskController();
        verifier = new MockFdcVerifier();

        market = new PredictionMarket(block.timestamp + EXPIRY_OFFSET, address(verifier));

        amm = new BinaryPMAMM(
            address(token), address(market), address(oracle),
            address(controller), 0.50e18, 5000
        );

        oracle.setAnchorPrice(0.50e18);

        // Fund
        token.mint(alice, 100_000e18);
        vm.prank(alice);
        token.approve(address(amm), type(uint256).max);
        token.mint(address(this), 10_000e18);
        token.approve(address(amm), type(uint256).max);
        amm.deposit(10_000e18);
    }

    /// @dev Build a deterministic attestation payload.
    function _makeAttestation(
        address mkt,
        bool outcome,
        uint64 ts,
        uint256 nonce
    ) internal pure returns (bytes memory) {
        return abi.encode(mkt, outcome, ts, nonce);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 1 – resolve with valid attestation                       *
     * ────────────────────────────────────────────────────────────── */
    function test_resolve_with_valid_attestation() public {
        // Build attestation
        uint64 ts = uint64(market.expiry());
        bytes memory att = _makeAttestation(address(market), true, ts, 42);
        bytes32 attHash = keccak256(att);

        // Owner pre-sets expected values on the mock verifier
        verifier.setExpected(attHash, true, ts);

        // Warp to expiry
        vm.warp(market.expiry());

        // Anyone can resolve with the attestation
        market.resolveWithAttestation(att);

        assertTrue(market.resolved(), "should be resolved");
        assertTrue(market.outcome(), "outcome should be YES");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 2 – reverts on invalid attestation                       *
     * ────────────────────────────────────────────────────────────── */
    function test_resolve_reverts_invalid_attestation() public {
        // Set expected for a specific payload
        bytes memory validAtt = _makeAttestation(address(market), true, uint64(market.expiry()), 42);
        verifier.setExpected(keccak256(validAtt), true, uint64(market.expiry()));

        vm.warp(market.expiry());

        // Send a DIFFERENT payload (wrong nonce)
        bytes memory wrongAtt = _makeAttestation(address(market), true, uint64(market.expiry()), 999);

        vm.expectRevert(PredictionMarket.AttestationInvalid.selector);
        market.resolveWithAttestation(wrongAtt);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 3 – emergency owner resolution only after delay          *
     * ────────────────────────────────────────────────────────────── */
    function test_emergency_owner_resolution_only_after_delay() public {
        // Warp to expiry + delay - 1 second → should revert
        vm.warp(market.expiry() + market.EMERGENCY_DELAY() - 1);

        vm.expectRevert(PredictionMarket.EmergencyDelayNotMet.selector);
        market.resolve(true);

        // Warp 1 more second → should succeed
        vm.warp(market.expiry() + market.EMERGENCY_DELAY());
        market.resolve(true);

        assertTrue(market.resolved());
        assertTrue(market.outcome());
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 4 – claims work after FDC resolution                    *
     * ────────────────────────────────────────────────────────────── */
    function test_claims_work_after_fdc_resolution() public {
        // Alice buys YES and NO before expiry
        vm.prank(alice);
        amm.buyYes(10e18);
        vm.prank(alice);
        amm.buyNo(10e18);

        uint256 yesShares = amm.yesToken().balanceOf(alice);
        uint256 collBefore = token.balanceOf(alice);

        // Set up attestation for YES outcome
        uint64 ts = uint64(market.expiry());
        bytes memory att = _makeAttestation(address(market), true, ts, 1);
        verifier.setExpected(keccak256(att), true, ts);

        // Resolve via attestation
        vm.warp(market.expiry());
        market.resolveWithAttestation(att);

        // Alice claims — YES wins, so YES shares pay out, NO shares burn
        vm.prank(alice);
        amm.claimWinnings();

        assertEq(amm.yesToken().balanceOf(alice), 0, "YES tokens burned");
        assertEq(amm.noToken().balanceOf(alice), 0, "NO tokens burned");
        assertEq(token.balanceOf(alice), collBefore + yesShares, "YES payout received");
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 5 – attestation resolution emits correct event           *
     * ────────────────────────────────────────────────────────────── */
    function test_attestation_resolution_emits_fdc_event() public {
        uint64 ts = uint64(market.expiry());
        bytes memory att = _makeAttestation(address(market), false, ts, 7);
        verifier.setExpected(keccak256(att), false, ts);

        vm.warp(market.expiry());

        vm.expectEmit(false, false, false, true);
        emit PredictionMarket.MarketResolved(false, block.timestamp, "FDC");

        market.resolveWithAttestation(att);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 6 – cannot resolve before expiry via attestation         *
     * ────────────────────────────────────────────────────────────── */
    function test_attestation_reverts_before_expiry() public {
        uint64 ts = uint64(market.expiry());
        bytes memory att = _makeAttestation(address(market), true, ts, 1);
        verifier.setExpected(keccak256(att), true, ts);

        // Don't warp — still before expiry
        vm.expectRevert(PredictionMarket.NotExpired.selector);
        market.resolveWithAttestation(att);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 7 – cannot double-resolve                                *
     * ────────────────────────────────────────────────────────────── */
    function test_cannot_double_resolve() public {
        uint64 ts = uint64(market.expiry());
        bytes memory att = _makeAttestation(address(market), true, ts, 1);
        verifier.setExpected(keccak256(att), true, ts);

        vm.warp(market.expiry());
        market.resolveWithAttestation(att);

        // Second attempt reverts
        vm.expectRevert(PredictionMarket.AlreadyResolved.selector);
        market.resolveWithAttestation(att);
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 8 – reverts if verifier not set                          *
     * ────────────────────────────────────────────────────────────── */
    function test_reverts_if_verifier_not_set() public {
        PredictionMarket noVerifierMarket = new PredictionMarket(
            block.timestamp + 2 hours, address(0)
        );

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(PredictionMarket.VerifierNotSet.selector);
        noVerifierMarket.resolveWithAttestation(hex"deadbeef");
    }
}
