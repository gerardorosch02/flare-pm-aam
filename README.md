# Flare PM-AMM

Binary prediction market AMM with risk-adjusted fees and trade limits driven by Flare's FTSOv2 oracle.

## Problem

Binary prediction markets need an automated market maker, but a naive AMM has no external reference price. An attacker can push the internal price to an extreme with a sequence of trades, extract value, and leave the pool mispriced. Without a trusted anchor, the AMM cannot distinguish organic price discovery from manipulation.

## Solution

We built a prediction market AMM that reads a live FTSOv2 price feed as a trusted anchor and uses the *relative* divergence between its internal market price and the anchor to dynamically adjust three defence parameters:

- **Fee** — scales from 5 to 200 bps as risk increases.
- **Max trade size** — shrinks from 100 to 20 tokens as risk increases.
- **Depth** — deepens the book so each trade moves the price less under high risk.

The internal market price is clamped to a configurable band around the oracle anchor (default ±50%), preventing the price from drifting into unrealistic territory.

## Architecture

```
BinaryPMAMM ──▶ RiskController     PredictionMarket
  buy/sell       riskScore()         timeToExpiry()
  price state    params()            resolve()
      │
      │ IAnchorOracle (interface)
      ▼
StubAnchorOracle          FlareFtsoV2AnchorOracle          OracleRegistry
  (local/test)              (Coston2/mainnet)                (hot-swap)
                                    │
                                    ▼
                           Flare FTSOv2 on-chain
                         getFeedByIdInWei(feedId)
```

| Contract | Role |
|---|---|
| `BinaryPMAMM.sol` | Core AMM. Holds collateral, executes buyYes/sellYes/buyNo/sellNo, updates internal market price. Depends only on `IAnchorOracle`. |
| `RiskController.sol` | Configurable risk engine. Takes `(price, anchor, timeToExpiry, collateral)` → `(R, feeBps, maxTrade)`. Divergence is relative to anchor. |
| `PredictionMarket.sol` | Lifecycle. Stores expiry, countdown. Dual resolution: FDC attestation (primary) + emergency owner (24h delay fallback). |
| `oracle/FlareFtsoV2AnchorOracle.sol` | Production FTSO adapter. Reads `getFeedByIdInWei`, validates value > 0 and staleness < 5 min. |
| `oracle/OracleRegistry.sol` | Ownable proxy. Owner hot-swaps between stub and FTSO adapters at runtime. |
| `YesToken.sol` | ERC-20 YES position token. Minted on buyYes, burned on sellYes/claim. Only AMM can mint/burn. |
| `NoToken.sol` | ERC-20 NO position token. Minted on buyNo, burned on sellNo/claim. Only AMM can mint/burn. |
| `LPToken.sol` | ERC-20 LP share token. Minted on deposit, burned on withdraw. Only AMM can mint/burn. |

## Flare Protocol Usage

### FTSO v2 (used)

FTSO is the sole external data source. The adapter calls `getFeedByIdInWei(feedId)` on Flare's enshrined FTSOv2 contract and returns the price in 1e18 WAD format.

| What | How | Where |
|---|---|---|
| Anchor price | `getFeedByIdInWei(ETH_USD)` → 1e18 value | `FlareFtsoV2AnchorOracle.anchorPrice()` |
| Relative divergence risk | `R_div = \|price − anchor\| / (anchor × dMax)` (50% of risk score) | `RiskController.riskScore()` |
| Fee scaling | `feeBps = 5 + R × 195` | `RiskController.params()` |
| Trade throttling | `maxTrade = 100 × (1 − 0.8 × R)` | `RiskController.params()` |
| Price band clamping | `price ∈ [anchor × (1−band), anchor × (1+band)]` | `BinaryPMAMM._clampPrice()` |
| Staleness guard | Reverts if feed timestamp > 5 min old | `FlareFtsoV2AnchorOracle` |
| Zero-value guard | Reverts if feed returns 0 / anchor == 0 | `FlareFtsoV2AnchorOracle` + `RiskController` |

Coston2 deployment constants:
- FTSOv2 address: `0x3d893C53D9e8056135C26C8c638B76C8b60Df726`
- ETH/USD feed ID: `0x014554482f55534400000000000000000000000000`

### FDC (implemented as mock verifier)

Market resolution is trust-minimized via an `IFdcVerifier` interface. Anyone can call `resolveWithAttestation(bytes)` after expiry — the attestation is verified on-chain by the verifier contract. The owner `resolve(bool)` path is retained as an emergency fallback, gated by a 24-hour delay after expiry.

**Current implementation:** `MockFdcVerifier` accepts a pre-set attestation hash (keccak256 of `abi.encode(market, outcome, timestamp, nonce)`). In production, this would be replaced by a contract that calls `FtsoV2Interface.verifyFeedData(FeedDataWithProof)` to verify Flare's Merkle-proven feed data.

| What | How | Where |
|---|---|---|
| Attestation verification | `IFdcVerifier.verify(bytes)` → `(ok, outcome, timestamp)` | `src/fdc/IFdcVerifier.sol` |
| Mock verifier | Owner sets expected hash + outcome; `verify` checks `keccak256(attestation) == expectedHash` | `src/fdc/MockFdcVerifier.sol` |
| Primary resolution | `resolveWithAttestation(bytes)` — callable by anyone after expiry | `src/PredictionMarket.sol` |
| Emergency fallback | `resolve(bool)` — owner-only, requires expiry + 24h delay | `src/PredictionMarket.sol` |

### Secure Random (not yet implemented)

FTSO secure random could seed fair initial pricing. Listed under Future Work.

## Demo

```bash
forge script script/Demo.s.sol --tc Demo -vvvv
```

The script deploys the full stack with a realistic ETH/USD price ($2500) and executes three 10-token `buyYes` trades under different conditions:

| Scenario | Action | Anchor | Time left | R | Fee (bps) | Max trade | Price after |
|---|---|---|---|---|---|---|---|
| 1 — Aligned | buyYes | $2500 | 2 h | 0.275 | 58 | 78 | $2500.02 |
| 2 — Divergent | buyYes | $1000 | 2 h | 0.775 | 156 | 38 | $1500 (clamped) |
| 3 — NO side | buyNo | $2500 | 2 h | 0.775 | 156 | 38 | $1499.99 (down) |
| 4 — Near expiry | buyYes | $2500 | 5 min | 0.799 | 160 | 36 | $1500 (unmoved) |

Observations: fee goes 58 → 156 → 160, maxTrade drops 78 → 38 → 36. Scenario 3 shows buyNo pushing price DOWN (symmetric to buyYes). Scenario 4's deep book absorbs the trade entirely.

### Verified on Coston2 fork

The demo has been verified against a live Coston2 fork (chain ID 114):

```bash
forge script script/Demo.s.sol --tc Demo -vvvv \
  --fork-url https://coston2-api.flare.network/ext/C/rpc
```

All 14 transactions simulate successfully against the live Coston2 state. The output is identical to the local run, confirming the contracts are Coston2-compatible.

### Live deployment

To deploy to Coston2 with a funded wallet:

```bash
# 1. Get testnet C2FLR from https://faucet.flare.network/coston2
# 2. Export your private key
export PRIVATE_KEY=0x...

# 3. Deploy and broadcast
forge script script/Demo.s.sol --tc Demo \
  --fork-url https://coston2-api.flare.network/ext/C/rpc \
  --broadcast --private-key $PRIVATE_KEY
```

To use the live FTSO feed instead of `StubAnchorOracle`, set `USE_REAL_FTSO = true` in `script/Demo.s.sol` line 38 before running.

## How to Run Locally

```bash
forge install
forge build
forge test -vvv
forge script script/Demo.s.sol --tc Demo -vvvv
```

84 tests across 11 suites: core AMM, sell path, NO token, FTSO adapter, oracle registry, attack simulation, YES position tokens, fee accounting, LP mechanics, resolution, and fuzz (256 runs each).

### Frontend Demo

A single-page frontend (`frontend/index.html`) lets you interact with the AMM visually. It connects to a local Anvil node and provides:

- **Risk gauge** — real-time semicircle showing R, fee, max trade, and divergence.
- **Trade panel** — buy YES / buy NO with live price updates.
- **Oracle slider** — drag to simulate FTSO price changes ($500–$5000) and watch risk parameters respond instantly.

```bash
# Terminal 1: start Anvil
anvil

# Terminal 2: deploy contracts
forge script script/DeployLocal.s.sol --tc DeployLocal --broadcast \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Terminal 3: serve frontend
cd frontend && python -m http.server 3000
# Open http://localhost:3000
```

## Design Notes

**Units:** Both `price` (internal market price) and `anchor` (oracle price) are in WAD (1e18). Divergence is computed as a *relative* deviation: `|price − anchor| / anchor`.

**Risk score** (0 = safe, 1 = max risk):

```
R = 0.5 × R_div + 0.3 × R_time + 0.2 × R_liq

R_div  = clamp(|price − anchor| / (anchor × dMax), 0, 1)  ← relative FTSO divergence
R_time = clamp((24h − timeToExpiry) / 24h, 0, 1)           ← time decay
R_liq  = clamp((1000 − totalPool) / 1000, 0, 1)            ← liquidity risk
```

**Fee and trade-size curves:**

```
feeBps    = 5 + R × 195                        →  5 bps (safe) to 200 bps (max risk)
maxTrade  = 100 × (1 − 0.8 × R)                →  100 tokens (safe) to 20 tokens (max risk)
baseDepth = max(anchor × DEPTH_MULTIPLIER, 1)   →  scales with oracle price level
depth     = baseDepth × (1 + R)                 →  baseDepth (safe) to 2×baseDepth (max risk)
```

`DEPTH_MULTIPLIER = 200` ensures that trade impact is proportional to the asset's price. A 10-token trade on ETH/USD ($2500) produces the same *relative* impact as a 10-token trade on FLR/USD ($0.05) — both move the price by roughly `afterFee / (anchor × 200)`.

**Price band:** `price` is clamped to `[anchor × (1 − bandBps/10000), anchor × (1 + bandBps/10000)]` each trade. Default `bandBps = 5000` (±50%).

## Future Work

- **Real FDC verifier** — replace `MockFdcVerifier` with a contract calling `FtsoV2Interface.verifyFeedData()` for production Merkle-proof verification.
- **FTSO secure random** — seed initial market pricing with Flare's enshrined random number.
- **Slippage protection** — add `minOutput` / `maxPrice` params on trades.
- **Multi-market factory** — deploy markets from a factory contract.

## Feedback Building on Flare

FTSOv2's `getFeedByIdInWei` returning prices pre-scaled to 18 decimals made integration straightforward — no decimal conversion logic needed. The Coston2 `TestFtsoV2Interface` being a view function (no fee) made local testing simple via `staticcall`. The feed ID system (bytes21) is clean and self-documenting.

What would improve the developer experience:
- A Foundry-native install path (`forge install`) for the periphery contracts.
- Documentation on how `getFeedByIdInWei` behaves when a feed has never been initialised.
- A Foundry mock/stub of `TestFtsoV2Interface` shipped in the periphery package.
