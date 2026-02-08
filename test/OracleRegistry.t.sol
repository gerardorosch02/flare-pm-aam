// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {StubAnchorOracle} from "../src/OracleAdapter.sol";
import {FlareFtsoV2AnchorOracle} from "../src/oracle/FlareFtsoV2AnchorOracle.sol";
import {OracleRegistry} from "../src/oracle/OracleRegistry.sol";

/* ═══════════════════════════════════════════════════════════════════ *
 *  Mock FTSOv2 – configurable value AND timestamp                    *
 * ═══════════════════════════════════════════════════════════════════ */
contract ConfigurableMockFtsoV2 {
    uint256 private _value;
    uint64  private _timestamp;

    function set(uint256 value_, uint64 timestamp_) external {
        _value = value_;
        _timestamp = timestamp_;
    }

    /// @dev Matches FtsoV2Interface.getFeedByIdInWei signature.
    function getFeedByIdInWei(
        bytes21 /* _feedId */
    ) external view returns (uint256, uint64) {
        return (_value, _timestamp);
    }
}

/* ═══════════════════════════════════════════════════════════════════ *
 *  Mock FTSOv2 that always reverts                                   *
 * ═══════════════════════════════════════════════════════════════════ */
contract RevertingMockFtsoV2 {
    function getFeedByIdInWei(bytes21) external pure returns (uint256, uint64) {
        revert("boom");
    }
}

/* ═══════════════════════════════════════════════════════════════════ *
 *  Test suite                                                        *
 * ═══════════════════════════════════════════════════════════════════ */
contract OracleRegistryTest is Test {
    // ETH/USD feed ID
    bytes21 constant ETH_USD = bytes21(0x014554482f55534400000000000000000000000000);

    StubAnchorOracle       stub;
    ConfigurableMockFtsoV2 mockFtso;
    FlareFtsoV2AnchorOracle ftsoOracle;
    OracleRegistry         registry;

    function setUp() public {
        // ── Stub oracle (local dev) ──
        stub = new StubAnchorOracle();
        stub.setAnchorPrice(0.50e18);

        // ── Mock FTSOv2 (testnet-like) ──
        mockFtso = new ConfigurableMockFtsoV2();
        mockFtso.set(0.65e18, uint64(block.timestamp));  // valid, fresh
        ftsoOracle = new FlareFtsoV2AnchorOracle(
            address(mockFtso),
            ETH_USD,
            5 minutes  // maxStaleness
        );

        // ── Registry starts with the stub ──
        registry = new OracleRegistry(address(stub));
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 1 – can switch oracle                                   *
     * ────────────────────────────────────────────────────────────── */
    function test_can_switch_oracle() public {
        // Registry currently points at stub (price = 0.50e18)
        assertEq(registry.anchorPrice(), 0.50e18, "should return stub price");

        // Switch to the FTSO-backed oracle (price = 0.65e18)
        registry.setOracle(address(ftsoOracle));

        assertEq(
            registry.anchorPrice(),
            0.65e18,
            "should return FTSO price after switch"
        );

        // Switch back to stub
        stub.setAnchorPrice(0.42e18);
        registry.setOracle(address(stub));

        assertEq(
            registry.anchorPrice(),
            0.42e18,
            "should return updated stub price after switching back"
        );
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 2 – reverts on invalid FTSO data (zero value)           *
     * ────────────────────────────────────────────────────────────── */
    function test_reverts_on_invalid_ftso_data() public {
        // ── 2a. Zero value ──────────────────────────────────────
        mockFtso.set(0, uint64(block.timestamp)); // value = 0, timestamp fresh
        registry.setOracle(address(ftsoOracle));

        vm.expectRevert(FlareFtsoV2AnchorOracle.FtsoValueZero.selector);
        registry.anchorPrice();

        // ── 2b. Stale timestamp ─────────────────────────────────
        // Set a valid value but an old timestamp
        mockFtso.set(0.50e18, uint64(block.timestamp));
        // Warp 10 minutes into the future → feed is now stale (maxStaleness=5min)
        vm.warp(block.timestamp + 10 minutes);

        vm.expectRevert(
            abi.encodeWithSelector(
                FlareFtsoV2AnchorOracle.FtsoStalePrice.selector,
                uint64(block.timestamp - 10 minutes), // feed timestamp (old)
                block.timestamp                        // current timestamp
            )
        );
        registry.anchorPrice();

        // ── 2c. FTSOv2 call itself reverts ──────────────────────
        RevertingMockFtsoV2 badFtso = new RevertingMockFtsoV2();
        FlareFtsoV2AnchorOracle badOracle = new FlareFtsoV2AnchorOracle(
            address(badFtso), ETH_USD, 5 minutes
        );
        registry.setOracle(address(badOracle));

        vm.expectRevert(FlareFtsoV2AnchorOracle.FtsoCallFailed.selector);
        registry.anchorPrice();
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 3 – registry reverts when no oracle is set              *
     * ────────────────────────────────────────────────────────────── */
    function test_reverts_when_oracle_not_set() public {
        OracleRegistry emptyRegistry = new OracleRegistry(address(0));

        vm.expectRevert(OracleRegistry.OracleNotSet.selector);
        emptyRegistry.anchorPrice();
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 4 – only owner can switch oracle                        *
     * ────────────────────────────────────────────────────────────── */
    function test_only_owner_can_switch() public {
        address nobody = makeAddr("nobody");

        vm.prank(nobody);
        vm.expectRevert();   // OwnableUnauthorizedAccount
        registry.setOracle(address(ftsoOracle));
    }

    /* ────────────────────────────────────────────────────────────── *
     *  Test 5 – emits event on oracle switch                        *
     * ────────────────────────────────────────────────────────────── */
    function test_emits_event_on_switch() public {
        vm.expectEmit(true, true, false, false);
        emit OracleRegistry.OracleUpdated(address(stub), address(ftsoOracle));

        registry.setOracle(address(ftsoOracle));
    }
}
