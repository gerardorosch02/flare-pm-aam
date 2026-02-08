# Consistency Audit

Cross-check of claims in `README.md` and `PROJECT_EVALUATION.md` against actual code, tests, and script output. Each item lists the claim, the conflicting source, and the proposed fix.

---

## 1. Test Count

### README.md

**Claim (line 99):** `65 tests across 9 suites`

**Actual (`forge test`):** 65 tests across 9 suites.

**Status:** CORRECT.

### PROJECT_EVALUATION.md

**Claim (line 10):** `passes 65 unit/fuzz tests`

**Actual:** 65 tests (56 unit + 9 fuzz).

**Issue:** Says "8 fuzz" in section 7 header (`Total: 64 tests (56 unit + 8 fuzz)`) but the actual count is 9 fuzz tests (including `testFuzz_riskScore_reverts_zero_anchor`) and 56 unit = 65 total. The "64" in section 7 is stale.

**Fix:** In `PROJECT_EVALUATION.md` line ~257 area, change:
```
**Total: 64 tests (56 unit + 8 fuzz)**
```
to:
```
**Total: 65 tests (56 unit + 9 fuzz)**
```

---

## 2. Demo Output Table vs Actual Logs

### README.md

**Claim (lines 88-93):** Demo table shows:

| Scenario | Anchor | Time left | Effect |
|---|---|---|---|
| 1 — Aligned | $0.05 | 2 h | Low R → low fee, high maxTrade |
| 2 — Divergent (anchor → $0.02) | $0.02 | 2 h | High relative divergence → fee doubles, maxTrade drops |
| 3 — Near expiry (5 min left) | $0.02 | 5 min | Time risk stacks on divergence → near-max fee, small trades |

**Actual demo output:**

| Scenario | Anchor | R | Fee | maxTrade | Price after |
|---|---|---|---|---|---|
| 1 | $0.05 | 0.275 | 58 | 78.0 | 0.0656 |
| 2 | $0.02 | 0.775 | 156 | 38.0 | 0.0300 |
| 3 | $0.02 | 0.799 | 160 | 36.1 | 0.0300 |

**Issue:** README says "fee doubles" for scenario 2. Actual: 58 → 156 bps (2.7× increase, not exactly "doubles"). This is close enough as informal language but the table lacks the actual numbers. The old README had exact numbers (97, 194, etc.) from the pre-refactor demo which are now stale.

**Fix:** Update README demo table to include actual numbers from the current demo:

```markdown
| Scenario | Anchor | Time left | R | Fee (bps) | Max trade | Price after |
|---|---|---|---|---|---|---|
| 1 — Aligned | $0.05 | 2 h | 0.275 | 58 | 78.0 | $0.0656 |
| 2 — Divergent (anchor → $0.02) | $0.02 | 2 h | 0.775 | 156 | 38.0 | $0.0300 |
| 3 — Near expiry (5 min left) | $0.02 | 5 min | 0.799 | 160 | 36.1 | $0.0300 |
```

### PROJECT_EVALUATION.md

**Claim (section 6, "Expected Outputs" table):** Shows old probability-mode values:

| Scenario | Anchor | R | Fee | Max Trade | Price After |
|---|---|---|---|---|---|
| 1 | 0.50 | 0.475 | ~97 | ~62.0 | ~0.5134 |
| 2 | 0.20 | 0.973 | ~194 | ~22.2 | ~0.5234 |
| 3 | 0.20 | 0.995 | ~199 | ~20.4 | ~0.5332 |

**Actual:** Demo now uses $0.05/$0.02 anchors and produces completely different numbers (see above).

**Fix:** Replace the entire "Expected Outputs (Local Mode)" table in PROJECT_EVALUATION.md with the actual current output values.

---

## 3. README Test Suite List

### README.md

**Claim (lines 99-100):** `65 tests across 9 suites: core AMM, sell path, FTSO adapter, oracle registry, attack simulation, position tokens, fee accounting, LP mechanics, resolution, and fuzz (256 runs each).`

**Issue:** Lists 10 items ("core AMM, sell path, FTSO adapter, oracle registry, attack simulation, position tokens, fee accounting, LP mechanics, resolution, and fuzz") but there are only 9 test files. "position tokens" and "fee accounting" are both in `YesToken.t.sol` — they aren't separate suites.

**Fix:** Change to:
```
65 tests across 9 suites: core AMM (BinaryPMAMM), sell path (SellYes), FTSO adapter (FtsoAnchorOracle), oracle registry (OracleRegistry), attack simulation (AttackSimulation), position tokens + fee accounting (YesToken), LP mechanics (Liquidity), resolution (Resolution), and fuzz (Fuzz, 256 runs each).
```

---

## 4. RiskController Description

### README.md

**Claim (contracts table, line 42):** `RiskController.sol | Configurable risk engine. Takes (price, anchor, timeToExpiry, collateral) → (R, feeBps, maxTrade). Divergence is relative to anchor.`

**Actual code:** `riskScore()` is `external view` (reads storage), not `pure`. The contract is `Ownable`. The claim "Configurable risk engine" is correct. The function signature matches.

**Status:** CORRECT.

### README.md — Design Notes

**Claim (line 109):** `R_div = clamp(|price − anchor| / (anchor × dMax), 0, 1)`

**Actual code (`RiskController.sol` lines 109-111):**
```solidity
uint256 relDiv = d * WAD / anchor;
uint256 rDiv = _clamp(relDiv * WAD / dMax, WAD);
```

This computes `(d / anchor) / dMax` which equals `d / (anchor * dMax / WAD)`. The README formula `|price − anchor| / (anchor × dMax)` is mathematically equivalent when `dMax` is in WAD. However, the README omits the WAD-scaling detail which could confuse a reader who tries to verify against code.

**Fix (optional):** Clarify the formula or add a note: `(all values in WAD fixed-point)`.

---

## 5. Divergence Formula in PROJECT_EVALUATION.md

### PROJECT_EVALUATION.md

**Claim (section 5, Sub-Score table):** `R_div (divergence) | clamp(|p − anchor| / dMax, 0, 1)`

**Actual code:** Divergence is now **relative**: `clamp(|price - anchor| / anchor / dMax, 0, 1)`. The table still shows the old absolute formula.

**Fix:** Change the R_div formula in the Sub-Score table to:
```
`clamp(|price − anchor| / (anchor × dMax), 0, 1)`
```

---

## 6. Stale "p" References in PROJECT_EVALUATION.md

### PROJECT_EVALUATION.md

**Issue (line ~101):** `After every trade, `p` is clamped to this range.`

The variable was renamed from `p` to `price`. This sentence still says `p`.

**Fix:** Change `p` to `price`.

---

## 7. RiskController Described as "Pure-math engine"

### PROJECT_EVALUATION.md

**Claim (contract inventory table):** `Pure-math risk engine.`

**Actual:** `riskScore()` and `params()` are `view` (not `pure`) since the configurable-parameters refactor. They read storage variables.

**Fix:** Change `Pure-math risk engine` to `Configurable risk engine` (matches README).

---

## 8. Future Work Section — Stale Items

### README.md

**Claim (Future Work):** Lists `ERC-1155 outcome tokens` as future work.

**Actual:** YesToken (ERC-20) is already implemented. The README's own contracts table lists it. However, the README Future Work says "NO token" not "ERC-1155 outcome tokens", so this specific item was already updated.

### PROJECT_EVALUATION.md

**Claim (Remaining Work table, item 4):** `Add a NO token (ERC-20) minted on buyNo / burned on sellNo`

**Status:** Still valid — NO token is genuinely not implemented. CORRECT.

### PROJECT_EVALUATION.md

**Claim (Remaining Work table, item 8):** `Improve seed-collateral flow in demo: use deposit() instead of direct mint to AMM`

**Actual:** The demo already uses `amm.deposit(10_000e18)` since the LP refactor. This item is now stale.

**Fix:** Remove item 8 from the Remaining Work table or mark it as completed.

---

## 9. Demo Command

### README.md & PROJECT_EVALUATION.md

**Claim:** `forge script script/Demo.s.sol --tc Demo -vvvv`

**Actual:** This command works. Verified.

**Status:** CORRECT.

### PROJECT_EVALUATION.md — Coston2 Command

**Claim:** `forge script script/Demo.s.sol --tc Demo -vvvv --fork-url https://coston2-api.flare.network/ext/C/rpc`

**Issue:** The `USE_REAL_FTSO` constant is `false` by default. Running this command with `--fork-url` will still use `StubAnchorOracle` because the code path is controlled by the compile-time constant, not the RPC URL. The docs correctly say "requires setting `USE_REAL_FTSO = true`" but the command alone is not sufficient.

**Status:** Already documented correctly (line says "Set USE_REAL_FTSO = true, then:"). No fix needed.

---

## 10. FTSO End-to-End Usage Verification

**Claim (README):** FTSO adapter is used end-to-end.

**Verification:**
- `test/FtsoAnchorOracle.t.sol::test_ammWorksWithFtsoOracle` deploys a `BinaryPMAMM` with `FlareFtsoV2AnchorOracle`, sets the mock FTSO price, and executes a `buyYes` trade.
- `test/FtsoAnchorOracle.t.sol::test_ftsoDivergenceDrivesHigherFee` reads anchor via `ftsoOracle.anchorPrice()` and verifies fee scaling.
- `test/OracleRegistry.t.sol::test_can_switch_oracle` switches from stub to FTSO-backed oracle and reads price.
- `script/Demo.s.sol` has a `USE_REAL_FTSO = true` path that deploys `FlareFtsoV2AnchorOracle`.

**Status:** CORRECT. FTSO is exercised end-to-end in tests and available in the demo script.

---

## 11. Deployed Addresses

### README.md

**Claim (lines 71-72):** Lists Coston2 deployment constants (FTSOv2 address, feed ID).

**Issue:** These are Flare system contract addresses, not deployed instances of this project. No project contracts have been deployed. The README does not claim they have been — it lists them as "Coston2 deployment constants" which is accurate.

### PROJECT_EVALUATION.md

**Claim (line ~408):** `No contracts have been deployed to Coston2 or mainnet at the time of this report.`

**Status:** CORRECT.

---

## 12. Naming/Units in Code Comments

### BinaryPMAMM.sol

**Issue:** Constructor NatSpec says `@param _oracle IAnchorOracle implementation (stub or FTSO).` — This is correct.

**Issue:** The `@return newPrice` on `buyYes`/`sellYes` is correct (was updated from `newP`).

**Status:** CORRECT.

### RiskController.sol

**Issue:** NatSpec on `riskScore` params says `@param price Current internal market price (WAD)` and `@param anchor Oracle anchor price (WAD). Must be > 0.` — Both correct.

**Status:** CORRECT.

---

## Summary of Required Fixes

| # | File | Issue | Severity |
|---|---|---|---|
| 1 | `PROJECT_EVALUATION.md` | Test count says "64 (56 unit + 8 fuzz)" but actual is 65 (56 + 9) | Medium |
| 2 | `README.md` | Demo table lacks actual numeric values from current demo output | Medium |
| 3 | `PROJECT_EVALUATION.md` | Demo "Expected Outputs" table has old probability-mode values (0.50/0.20 anchors, ~97/~194 fees) | High |
| 4 | `README.md` | Lists 10 suite descriptions but only 9 files exist | Low |
| 5 | `PROJECT_EVALUATION.md` | R_div Sub-Score formula still shows absolute divergence, not relative | Medium |
| 6 | `PROJECT_EVALUATION.md` | Stray `p` reference instead of `price` on line ~101 | Low |
| 7 | `PROJECT_EVALUATION.md` | RiskController described as "Pure-math engine" but functions are now `view` | Low |
| 8 | `PROJECT_EVALUATION.md` | Remaining Work item 8 (use `deposit()` in demo) is already done | Low |
