# Flare PM-AMM — Project Evaluation & Progress Report

---

## 1) Executive Summary

- **What we built:** A binary prediction-market AMM that uses Flare's FTSOv2 oracle as a trusted anchor to dynamically adjust fees, trade limits, and market depth in real time.
- **Problem solved:** Naive prediction-market AMMs have no external reference price, leaving them vulnerable to manipulation; this AMM makes manipulation progressively more expensive the further the internal price diverges from the oracle anchor.
- **Flare protocols used:** FTSOv2 (`getFeedByIdInWei`) is fully integrated as the live price anchor; FDC and Secure Random are acknowledged as future work and are **not** implemented.
- **Current status:** The project compiles, passes 65 unit/fuzz tests, and ships a runnable demo script that exercises three risk scenarios on a local Anvil fork (with a toggle for live Coston2).
- **Biggest remaining gap:** FDC verifier is a mock (keccak256 hash check); production needs real Merkle proof verification via `verifyFeedData`.

---

## 2) Architecture Overview

### ASCII Diagram

```
┌─────────────┐       ┌────────────────┐       ┌──────────────────┐
│ BinaryPMAMM  │──────▶│ RiskController │       │ PredictionMarket │
│  buy/sell    │       │  riskScore()   │       │  timeToExpiry()  │
│  deposit/    │       │  params()      │       │  resolve()       │
│  withdraw    │       └────────────────┘       └──────────────────┘
│  claimWinnings│
└──────┬───────┘
       │ IAnchorOracle
       ▼
┌──────────────────────┐
│   OracleRegistry     │◄── owner hot-swaps
│   (proxy)            │
└──────┬───────┬───────┘
       │       │
       ▼       ▼
┌──────────┐  ┌──────────────────────────┐
│ StubOracle│  │ FlareFtsoV2AnchorOracle  │
│ (test)    │  │ (Coston2 / mainnet)      │
└──────────┘  └───────────┬──────────────┘
                          │
                          ▼
                  Flare FTSOv2 on-chain
                  getFeedByIdInWei(feedId)
```

### Contract Inventory

| Contract | File Path | Responsibility | Key Functions |
|---|---|---|---|
| `BinaryPMAMM` | `src/BinaryPMAMM.sol` | Core AMM. Holds collateral, executes buys/sells, manages LP deposits, handles post-resolution claims. | `buyYes()`, `sellYes()`, `deposit()`, `withdraw()`, `claimWinnings()`, `withdrawFees()` |
| `RiskController` | `src/RiskController.sol` | Pure-math risk engine. Computes composite risk score and maps it to fee and trade-size parameters. Owner-configurable. | `riskScore()`, `params()`, `setRiskParams()`, `setFeeParams()` |
| `PredictionMarket` | `src/PredictionMarket.sol` | Market lifecycle. Stores expiry timestamp and owner-resolved outcome. | `timeToExpiry()`, `resolve()` |
| `YesToken` | `src/YesToken.sol` | ERC-20 position token for YES shares. Only the AMM can mint/burn. | `mint()`, `burn()` |
| `LPToken` | `src/LPToken.sol` | ERC-20 LP share token. Only the AMM can mint/burn. | `mint()`, `burn()` |
| `FlareFtsoV2AnchorOracle` | `src/oracle/FlareFtsoV2AnchorOracle.sol` | Production FTSO adapter. Reads `getFeedByIdInWei`, validates non-zero value and staleness < configurable threshold. | `anchorPrice()` |
| `OracleRegistry` | `src/oracle/OracleRegistry.sol` | Owner-switchable oracle proxy implementing `IAnchorOracle`. Allows hot-swapping between Stub and FTSO adapters at runtime. | `setOracle()`, `anchorPrice()` |
| `StubAnchorOracle` | `src/OracleAdapter.sol` | Simple owner-settable oracle for local testing and bootstrapping. | `setAnchorPrice()`, `anchorPrice()` |
| `IAnchorOracle` | `src/OracleAdapter.sol` | Interface that every oracle adapter must satisfy. | `anchorPrice()` |
| `IFtsoV2` | `src/flare/IFtsoV2.sol` | Minimal Flare FTSOv2 interface (subset). | `getFeedByIdInWei()` |

---

## 3) Flare Protocol Usage

### Integration Matrix

| Protocol | Status | File Path(s) | Impact on AMM Logic |
|---|---|---|---|
| **FTSO v2** | **Fully implemented** | `src/oracle/FlareFtsoV2AnchorOracle.sol`, `src/flare/IFtsoV2.sol` | Provides the anchor price used to compute divergence risk (`R_div`). Divergence drives fee scaling, trade throttling, and depth deepening. |
| **FDC** | **Mock implemented** | `src/fdc/IFdcVerifier.sol`, `src/fdc/MockFdcVerifier.sol` | `resolveWithAttestation(bytes)` verifies attestation via `IFdcVerifier`. Mock verifier uses keccak256 hash check. Production would use `FtsoV2Interface.verifyFeedData()`. Owner `resolve(bool)` retained as emergency fallback with 24h delay. |
| **Secure Random (RNG)** | **Not implemented** | — | Listed as future work for fair initial pricing to prevent front-running at market creation. |
| **FAssets** | **Not implemented** | — | Not referenced in the codebase or README. |

### FTSO v2 — Detail

| Aspect | Implementation Detail | Location |
|---|---|---|
| Anchor price retrieval | `staticcall` to `getFeedByIdInWei(feedId)` on the FTSOv2 contract; returns `(uint256 value, uint64 timestamp)` already scaled to 1e18 (WAD). | `src/oracle/FlareFtsoV2AnchorOracle.sol` lines 62–67 |
| Zero-value guard | Reverts with `FtsoValueZero()` if the returned value is 0. | `src/oracle/FlareFtsoV2AnchorOracle.sol` line 70 |
| Staleness guard | Reverts with `FtsoStalePrice(feedTimestamp, currentTimestamp)` if `block.timestamp > timestamp + maxStaleness`. Default `maxStaleness` is 5 minutes. | `src/oracle/FlareFtsoV2AnchorOracle.sol` lines 73–75 |
| Feed call failure | Reverts with `FtsoCallFailed()` if the `staticcall` returns `ok == false`. | `src/oracle/FlareFtsoV2AnchorOracle.sol` line 65 |
| Coston2 constants | FTSOv2 address: `0x3d893C53D9e8056135C26C8c638B76C8b60Df726`; ETH/USD feed ID: `0x014554482f55534400000000000000000000000000` | `script/Demo.s.sol` lines 41–44 |

FDC and Secure Random are **only mentioned in the README's Future Work section**. There is zero code for either protocol. This is clearly stated.

---

## 4) AMM Design

### State Variables

| Variable | Type | Location | Description |
|---|---|---|---|
| `price` | `uint256` | `src/BinaryPMAMM.sol` | Current internal market price in WAD (1e18). Set via constructor param `_initialPrice`. |
| `collateralBalance` | `uint256` | `src/BinaryPMAMM.sol` line 29 | Collateral backing outstanding YES positions (after fees). |
| `accumulatedFees` | `uint256` | `src/BinaryPMAMM.sol` line 30 | Fee revenue accumulated from trades, withdrawable by `feeRecipient`. |
| `lpTotalDeposits` | `uint256` | `src/BinaryPMAMM.sol` line 31 | Total collateral deposited by liquidity providers. |

### Price Representation

- `price` is a fixed-point WAD value (18 decimal places), representing the internal market price. It is clamped to a dynamic band derived from the oracle anchor: `[anchor*(1-bandBps/10000), anchor*(1+bandBps/10000)]` (default ±50%).
- After every trade, `p` is clamped to this range.

### How Trades Update `p`

**Buy YES:**

```
baseDepth = max(anchor × DEPTH_MULTIPLIER, MIN_BASE_DEPTH)
depth  = baseDepth × (1 + α × R)        // deeper book when R is high
impact = afterFee × WAD / depth
price  = clampToAnchorBand(price + impact)  // price moves UP
```

**Sell YES:**

```
baseDepth = max(anchor × DEPTH_MULTIPLIER, MIN_BASE_DEPTH)
depth  = baseDepth × (1 + α × R)
impact = afterFee × WAD / depth
price  = clampToAnchorBand(price − impact)  // price moves DOWN
```

Where `DEPTH_MULTIPLIER = 200`, `MIN_BASE_DEPTH = 1e18`, `α (ALPHA) = 1e18`, and `R` is the composite risk score. Depth scales with the oracle anchor price so that trade impact is proportional regardless of the asset's absolute price level.

### Fee Computation

```
fee      = collateralIn × feeBps / 10_000
afterFee = collateralIn − fee
```

`feeBps` is computed by `RiskController.params(R)`:

```
feeBps = feeMin + R × (feeMax − feeMin) / WAD
       = 5 + R × 195 / 1e18
```

Range: **5 bps** (R = 0) to **200 bps** (R = 1).

### Max Trade Computation

```
maxTrade = baseMax × (WAD − β × R) / WAD
         = 100e18 × (1 − 0.80 × R)
```

Range: **100 tokens** (R = 0) to **20 tokens** (R = 1).

### Depth / Virtual Liquidity (Damping)

```
baseDepth = max(anchor × 200, 1e18)
depth = baseDepth × (WAD + ALPHA × R) / WAD
      = 500 × (1 + R)
```

Range: **baseDepth** (R = 0) to **2 × baseDepth** (R = 1), where `baseDepth = anchor × 200`. Higher depth means each token of trade moves the price less, absorbing manipulation during risky periods. Depth scales with the oracle price level so impact is proportional across assets.

---

## 5) Risk Engine

### Composite Risk Score `R`

`R` is a weighted sum of three sub-scores, each clamped to `[0, 1]`:

```
R = w1 × R_div + w2 × R_time + w3 × R_liq
```

Clamped to `[0, 1e18]` (WAD-scaled).

### Sub-Score Definitions

| Sub-Score | Formula | Inputs | Default Constants |
|---|---|---|---|
| `R_div` (divergence) | `clamp(\|p − anchor\| / dMax, 0, 1)` | `p` (AMM price, WAD), `anchor` (FTSO price, WAD) | `dMax = 0.10e18` (10%) |
| `R_time` (time decay) | `clamp((tMax − timeToExpiry) / tMax, 0, 1)` | `timeToExpiry` (seconds) | `tMax = 86400` (24 hours) |
| `R_liq` (liquidity) | `clamp((lTarget − collateral) / lTarget, 0, 1)` | `collateral` = `totalPool()` (WAD-scaled tokens) | `lTarget = 1000e18` |

### Weights

| Weight | Default | Meaning |
|---|---|---|
| `w1` | `0.50e18` (50%) | Divergence from oracle — the dominant risk signal |
| `w2` | `0.30e18` (30%) | Proximity to expiry — markets are riskier near settlement |
| `w3` | `0.20e18` (20%) | Low liquidity — thin pools are easier to manipulate |

Weights must sum to exactly `1e18`. Enforced by `setRiskParams()`.

### Mapping `R` to AMM Parameters

| Parameter | Formula | R = 0 (safe) | R = 1 (max risk) |
|---|---|---|---|
| `feeBps` | `5 + R × 195 / WAD` | 5 bps | 200 bps |
| `maxTrade` | `100e18 × (1 − 0.80 × R)` | 100 tokens | 20 tokens |
| `depth` | `baseDepth × (1 + R)` | baseDepth | 2 × baseDepth |

All constants are defined in:
- `src/RiskController.sol` (risk parameters, fee parameters — constructor defaults, lines 37–48)
- `src/BinaryPMAMM.sol` (depth constants — lines 34–38)

All risk and fee parameters are **owner-configurable** via `setRiskParams()` and `setFeeParams()` on `RiskController`.

---

## 6) Demo Walkthrough

### Script

| File | Description |
|---|---|
| `script/Demo.s.sol` | Deploys the full stack (token, oracle, market, controller, AMM), seeds the AMM with 10 000 tokens, then runs three buy-YES scenarios under different risk conditions. |

The script has two modes controlled by the `USE_REAL_FTSO` constant:
- `false` (default): local Anvil with `StubAnchorOracle` — full control over anchor price and time.
- `true`: Coston2 testnet with live FTSOv2 feed.

### Commands

**Local (default):**

```bash
forge script script/Demo.s.sol --tc Demo -vvvv
```

**Coston2 testnet (requires setting `USE_REAL_FTSO = true` in `script/Demo.s.sol` line 38):**

```bash
forge script script/Demo.s.sol --tc Demo -vvvv \
  --fork-url https://coston2-api.flare.network/ext/C/rpc
```

### Expected Outputs (Local Mode)

Each scenario executes a 10-token `buyYes` trade.

| Scenario | Anchor | Time Left | R (approx) | Fee (bps) | Max Trade | Price After |
|---|---|---|---|---|---|---|
| 1 — Aligned anchor | 0.50 | 2 hours | 0.475 | ~97 | ~62.0 | ~0.5134 |
| 2 — Divergent anchor (→ 0.20) | 0.20 | 2 hours | 0.973 | ~194 | ~22.2 | ~0.5234 |
| 3 — Near expiry (5 min left) | 0.20 | 5 min | 0.995 | ~199 | ~20.4 | ~0.5332 |

### What the Demo Proves

1. **Scenario 1 → 2:** When the oracle anchor diverges from the AMM price (0.50 vs 0.20), the risk score jumps from ~0.475 to ~0.973. The fee doubles from ~97 bps to ~194 bps, and `maxTrade` drops from ~62 to ~22 tokens. Manipulation becomes 2× more expensive and 3× smaller.
2. **Scenario 2 → 3:** When time-to-expiry drops from 2 hours to 5 minutes, the already-high risk score climbs further to ~0.995. The depth increase causes the same 10-token trade to move the price less than in scenario 2.
3. **Overall:** The same trade size yields progressively worse execution as risk increases — the AMM self-adjusts its defences in real time.

---

## 7) Test Coverage

### Test Files

| # | File | Tests | Scenarios Covered |
|---|---|---|---|
| 1 | `test/BinaryPMAMM.t.sol` | 3 | Fee increases with oracle divergence; maxTrade decreases with divergence; buy moves price less near expiry (depth damping). |
| 2 | `test/FtsoAnchorOracle.t.sol` | 5 | FTSO adapter returns correct WAD value; tracks price updates; implements `IAnchorOracle` interface; full AMM integration with FTSO-backed oracle; FTSO divergence drives higher fees end-to-end. |
| 3 | `test/OracleRegistry.t.sol` | 5 | Hot-swap between stub and FTSO oracles; revert on zero-value FTSO data; revert on stale FTSO timestamp; revert on FTSOv2 call failure; revert when no oracle set; only-owner access control; event emission on switch. |
| 4 | `test/AttackSimulation.t.sol` | 3 | Pump attack raises fee progressively; divergence shrinks maxTrade by >20%; near-expiry compounds the defence (higher R, higher fee). |
| 5 | `test/Fuzz.t.sol` | 9 | `riskScore` always in `[0, 1e18]`; `feeBps` always in `[feeMin, feeMax]`; `maxTrade` always in `[floor, baseMax]`; relative divergence monotonicity; fee monotonicity; maxTrade anti-monotonicity; `buyYes` keeps price within anchor-derived band; `setRiskParams` rejects weights that do not sum to 1e18; `riskScore` reverts when anchor == 0. |
| 6 | `test/SellYes.t.sol` | 10 | Sell moves price down; burns YES tokens and returns collateral; fee accounting on sell; collateralBalance decreases; sell is symmetric with buy; large sell clamps price to anchor-derived minimum; SellYesExecuted event; BuyYesExecuted event; MarketResolved event; InsufficientCollateral revert path. |
| 7 | `test/Liquidity.t.sol` | 10 | First LP deposit mints 1:1; second deposit proportional; full withdrawal returns exact deposit; partial withdrawal; LP deposit lowers `R_liq`; withdraw reverts without shares; zero deposit reverts; zero withdraw reverts; only AMM can mint/burn LP tokens; LP can exit after round-trip trades. |
| 8 | `test/Resolution.t.sol` | 10 | `buyYes` reverts after resolution; `sellYes` reverts after resolution; YES-outcome claim pays 1:1; multi-user claims; NO-outcome burns tokens without payout; claim reverts before resolution; claim reverts with no position; double-claim reverts; WinningsClaimed event (YES); WinningsClaimed event (NO). |
| 9 | `test/YesToken.t.sol` | 10 | `sellYes` reverts without position; reverts when selling more than balance; `buyYes` mints correct YES tokens (minus fee); sell burns tokens and pays collateral; drain attack blocked (no position = revert); only AMM can mint/burn; fee accounting (`fees + collateralBalance == collateralIn`); fee withdrawal; only feeRecipient can withdraw; withdraw reverts when zero fees. |

**Total: 64 tests (56 unit + 8 fuzz)**

### Command to Run All Tests

```bash
forge test -vvv
```

---

## 8) Security / Safety Review (MVP-Level)

### Protections Present

| Protection | Mechanism | Location |
|---|---|---|
| Reentrancy guard | OpenZeppelin `ReentrancyGuard` on `buyYes`, `sellYes`, `deposit`, `withdraw`, `claimWinnings`, `withdrawFees` | `src/BinaryPMAMM.sol` |
| Price clamping | `price` is clamped to anchor-derived band `[anchor*(1-bandBps/10000), anchor*(1+bandBps/10000)]` after every trade | `src/BinaryPMAMM._clampPrice()` |
| Risk-score clamping | All sub-scores and the composite `R` are clamped to `[0, 1e18]` | `src/RiskController.sol` lines 99, 119 |
| Position token gating | `sellYes` burns tokens from the caller — reverts via OZ `ERC20InsufficientBalance` if the caller does not hold enough | `src/BinaryPMAMM.sol` line 177 |
| Oracle staleness validation | `FlareFtsoV2AnchorOracle` reverts if feed age > `maxStaleness` | `src/oracle/FlareFtsoV2AnchorOracle.sol` lines 73–75 |
| Oracle zero-value validation | Reverts if FTSOv2 returns 0 | `src/oracle/FlareFtsoV2AnchorOracle.sol` line 70 |
| Access control | `PredictionMarket.resolve()` and `OracleRegistry.setOracle()` are `onlyOwner`; `RiskController` setters are `onlyOwner` | Multiple |
| Fee-recipient restriction | Only `feeRecipient` (deployer) can call `withdrawFees()` | `src/BinaryPMAMM.sol` line 248 |
| Safe ERC-20 transfers | All token transfers use OpenZeppelin `SafeERC20` | `src/BinaryPMAMM.sol` |
| Weight invariant enforcement | `setRiskParams` reverts if `w1 + w2 + w3 != 1e18` | `src/RiskController.sol` line 62 |

### Identified Risks (Not Yet Mitigated)

| Risk | Severity | Notes |
|---|---|---|
| **Oracle lag / manipulation** | Medium | If the FTSOv2 feed is delayed up to 5 minutes, the anchor may lag behind the true market. Staleness guard limits but does not eliminate this window. |
| ~~No NO token~~ | ~~Resolved~~ | NO token (`NoToken.sol`) is now implemented with `buyNo`/`sellNo` and symmetric resolution claims. |
| ~~Centralised resolution~~ | ~~Mitigated~~ | Primary resolution is now via `resolveWithAttestation(bytes)` verified by `IFdcVerifier`. Owner `resolve(bool)` is retained as emergency fallback but gated by a 24-hour delay after expiry. |
| **LP impermanent loss** | Medium | LP deposits are exposed to adverse selection by informed traders. No rebalancing or IL protection mechanism exists. |
| **Seed collateral accounting** | Low | The demo script mints tokens directly to the AMM (`token.mint(address(amm), 10_000e18)`) without updating `collateralBalance` or `lpTotalDeposits`. This "phantom" collateral backs sells in the demo but is not tracked by the AMM's accounting. In production, all capital should enter via `deposit()`. |
| **Integer rounding** | Low | WAD-math divisions truncate. In extreme edge cases (very small trades), rounding could favour one side. Standard for Solidity fixed-point math; no mitigation beyond awareness. |
| **`feeRecipient` is immutable** | Low | Set to the deployer at construction time. Cannot be changed. A future upgrade would need a setter or governance mechanism. |

---

## 9) Hackathon Submission Readiness

### Checklist

| Criterion | Status | Notes |
|---|---|---|
| Repo scannable for judges? | **Yes** | Clean `src/`, `test/`, `script/` layout. No extraneous files in source directories. |
| README sufficient? | **Yes** | Contains architecture diagram, contract table, Flare protocol usage table, demo instructions, test commands, design notes, and explicit future work section. |
| Flare protocol usage unambiguous? | **Yes** | FTSOv2 usage is documented with file paths, function calls, and Coston2 constants. FDC and RNG are explicitly listed as "not yet implemented." |
| Tests pass? | **Yes** | 64 tests across 9 files, including 8 fuzz tests. All green as of last run. |
| Demo runnable with a single command? | **Yes** | `forge script script/Demo.s.sol --tc Demo -vvvv` |

### Top 3 Things That Could Cause a Judging Failure

1. **README says "Run all 16 tests" but the repo now has 64 tests.** The stale count could confuse judges into thinking most tests are missing. Fix: update the README.
2. **No deployed contract addresses.** If judges expect a live Coston2 deployment URL or verified contract on the explorer, this is absent. The demo runs locally only (unless the Coston2 mode is enabled and a deployer key is provided).
3. ~~No NO token~~ — Resolved. Both YES and NO tokens are now implemented with symmetric trading and resolution.

---

## 10) Remaining Work (Timeboxed)

| # | Task | Est. Time | Impact | Suggested Owner |
|---|---|---|---|---|
| 1 | Update README test count from 16 to 64 | 2 min | High | Person A |
| 2 | Deploy full stack to Coston2 and record contract addresses in README | 20 min | High | Person A |
| 3 | Run demo on Coston2 fork (`USE_REAL_FTSO = true`) and paste output into README | 10 min | High | Person A |
| ~~4~~ | ~~Add a NO token~~ | ~~Done~~ | ~~N/A~~ | ~~Completed~~ |
| 5 | Implement FDC-based market resolution (replace `onlyOwner` resolve) | 90 min | Medium | Person B |
| 6 | Add natspec / comments on all public functions for judge-readability | 15 min | Medium | Person A |
| 7 | Add a `setFeeRecipient` setter or make it configurable | 10 min | Low | Person A |
| 8 | Improve seed-collateral flow in demo: use `deposit()` instead of direct `mint` to AMM | 10 min | Medium | Person B |
| 9 | Add FTSO Secure Random for fair initial pricing | 45 min | Low | Person B |
| 10 | Write a brief "How to verify on Coston2 explorer" section in README | 10 min | Medium | Person A |

---

## 11) Appendix

### Repo Tree (Top-Level)

```
flare-pm-amm/
├── foundry.toml
├── README.md
├── PROJECT_EVALUATION.md
├── src/
│   ├── BinaryPMAMM.sol
│   ├── RiskController.sol
│   ├── PredictionMarket.sol
│   ├── YesToken.sol
│   ├── LPToken.sol
│   ├── OracleAdapter.sol        (IAnchorOracle + StubAnchorOracle)
│   ├── flare/
│   │   └── IFtsoV2.sol
│   └── oracle/
│       ├── FlareFtsoV2AnchorOracle.sol
│       └── OracleRegistry.sol
├── test/
│   ├── BinaryPMAMM.t.sol
│   ├── FtsoAnchorOracle.t.sol
│   ├── OracleRegistry.t.sol
│   ├── AttackSimulation.t.sol
│   ├── Fuzz.t.sol
│   ├── SellYes.t.sol
│   ├── Liquidity.t.sol
│   ├── Resolution.t.sol
│   └── YesToken.t.sol
├── script/
│   └── Demo.s.sol
└── lib/
    ├── forge-std/
    └── openzeppelin-contracts/
```

### Key Constants

| Constant | Value | Defined In |
|---|---|---|
| `WAD` | `1e18` | `src/BinaryPMAMM.sol`, `src/RiskController.sol` |
| `DEPTH_MULTIPLIER` | `200` | `src/BinaryPMAMM.sol` |
| `MIN_BASE_DEPTH` | `1e18` | `src/BinaryPMAMM.sol` |
| `ALPHA` | `1e18` | `src/BinaryPMAMM.sol` line 36 |
| `bandBps` | `5000` (±50%) | `src/BinaryPMAMM.sol` constructor param |
| Price bounds | Dynamic: `anchor*(1±bandBps/10000)` | `src/BinaryPMAMM._clampPrice()` |
| `dMax` (default) | `0.10e18` (10%) | `src/RiskController.sol` line 38 |
| `tMax` (default) | `86400` (24 hours) | `src/RiskController.sol` line 39 |
| `lTarget` (default) | `1000e18` | `src/RiskController.sol` line 40 |
| `w1` (default) | `0.50e18` | `src/RiskController.sol` line 41 |
| `w2` (default) | `0.30e18` | `src/RiskController.sol` line 42 |
| `w3` (default) | `0.20e18` | `src/RiskController.sol` line 43 |
| `feeMin` (default) | `5` bps | `src/RiskController.sol` line 44 |
| `feeMax` (default) | `200` bps | `src/RiskController.sol` line 45 |
| `baseMax` (default) | `100e18` | `src/RiskController.sol` line 46 |
| `beta` (default) | `0.80e18` | `src/RiskController.sol` line 47 |
| `DEFAULT_MAX_STALENESS` | `300` (5 minutes) | `src/oracle/FlareFtsoV2AnchorOracle.sol` line 40 |
| `COSTON2_FTSO_V2` | `0x3d893C53D9e8056135C26C8c638B76C8b60Df726` | `script/Demo.s.sol` line 42 |
| `ETH_USD_FEED` | `0x014554482f55534400000000000000000000000000` | `script/Demo.s.sol` line 42 |

### Deployed Addresses

No contracts have been deployed to Coston2 or mainnet at the time of this report. The demo runs on a local Anvil instance by default.
