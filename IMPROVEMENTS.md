# MEGold — remaining improvements

Saved November 3, 2026. Work is paused at the user's request.

## Current state

- Latest packaged build: `releases/MEGold-0.6.0.zip`.
- Eleven isolated Lua 5.1 test scripts pass (`python tests/run_all.py`).
- No actual Forever client validation has been completed.
- The latest review reproduced two remaining bugs; neither is fixed yet.
- Automatic vendor selling should not receive production approval until the P1 issue
  below is fixed and live checks pass.

## Priority 1 — inventory baseline race

**Confirmed bug:** opening a merchant before delayed inventory reconciliation can
preserve stale flip-sale eligibility and allow personal stock to be sold.

Inventory reconciliation waits 0.5 seconds and skips processing while a merchant is
open. Merchant opening creates a new snapshot; subsequent observation can overwrite
the older baseline without checking the preceding inventory decrease.

Reproduction:

1. Start with ten identical units in bags; three are marked collected tracked flips.
2. Remove three units outside a verified vendor sale.
3. Open a merchant before the delayed inventory callback runs.
4. Build the vendor review.
5. Current behavior: three units remain eligible instead of the purchase being held
   for inventory review.

Relevant locations at review time:

- `MEGold/Inventory.lua:30` — delayed reconciliation.
- `MEGold/Vendor.lua:328` — merchant snapshot initialization.
- `MEGold/Vendor.lua:125` — inventory baseline replacement.
- `MEGold/Profit.lua:25` — collection confirmation also replaces the baseline.

Required fix: reconcile unexplained decreases before replacing any inventory baseline.
Distinguish verified sale/collection evidence from arbitrary snapshot adoption. Check
collection confirmation as another possible way to mask an unrelated pending decrease.

## Priority 2 — collection capability gate

**Confirmed bug:** `MarkCollected` calls `BagTotals` without checking whether the
inventory API contract is available. With missing bag APIs, it raises a nil-function
error despite the new client capability system.

- `MEGold/Profit.lua:10` — domain entry point lacks the capability check.
- `MEGold/Ledger.lua:127` — collection button remains enabled in this situation.

Required fix: gate the method and button on inventory capabilities as well as storage
and transaction state. Domain checks must protect direct calls, not just button clicks.

## Priority 3 — integration regression coverage

Add tests for real registered handlers and controlled delayed callbacks covering:

- Bag decrease, then merchant opening before reconciliation.
- Bag decrease, then collection confirmation for another purchase.
- Baseline changes during merchant closure and re-opening.
- Collection confirmation when inventory APIs are missing.
- Repeated or reordered events must not restore revoked sale eligibility.

Existing tests pass but do not cover these cases. Use fresh fixtures from
`tests/support.py`; do not import test modules that execute other tests.

## Priority 4 — live client verification

Complete `docs/LIVE_TEST_CHECKLIST.md` when Forever is accessible. Validate actual
scan results, purchase restrictions, server throttling, commodity quotes, vendor
timing, mixed stacks, holds, buybacks, reload recovery, competing addons and UI layout.
Retain `/meg logs` reports for failures. Begin with inexpensive single transactions.

## Priority 5 — state and identity cleanup

- Enforce allowed state transitions through central helpers. `State.lua` currently
  declares phases, while modules still assign raw phase strings directly.
- Consolidate item-identity parsing currently duplicated across modules.
- Split vendor evidence reconciliation into smaller functions with explicit contracts.
- Continue reducing implicit mutation through the shared addon namespace.

## Priority 6 — performance and history

- Benchmark realistic large purchase/sale histories and bursts of inventory events.
- Consider purchase indexes and debounced inventory reconciliation.
- Historical arrays retain compact tombstones, so their lengths remain unbounded.
- Consider stable record IDs for future compaction; preserve purchase allocations,
  active buyback references and lifetime totals through any migration.

## Most recent review ratings

| Dimension | Rating |
|---|---|
| Correctness | Needs Work |
| Security | Acceptable |
| Performance | Acceptable |
| Readability | Acceptable |
| Maintainability | Acceptable |

The earlier held-allocation and stale-sale-timeout bugs are fixed and have regression
coverage. Other completed improvements include bounded scanner retries, pagination,
schema validation/quarantine, client gates, profit caching, history summarization,
strict UI doubles, and isolated test execution.

## Resume point

Read this file, `docs/ARCHITECTURE.md`, and the affected modules. Fix priorities 1 and
2 with regression tests, run `python tests/run_all.py`, update documentation/changelog,
and package a new preview. Do not claim live verification or production readiness from
simulated tests alone. Line numbers above are references to version 0.6 and may shift.
