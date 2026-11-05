# Changelog

## 0.6.1
- Fixed live Forever build 70790 UI failures caused by the removed global coin formatter.
- All money displays use the modern currency API, with legacy and plain-text fallbacks.
- Added modern-only UI/scan-start regression coverage; 19 isolated test scripts pass.

## Unreleased
- Purchase window capture: for 20 s after each buy click or quote confirmation, MEGold logs the relevant client events (name and simple arguments, at most 60) so this client's real purchase-confirmation events can be identified. Bounded, silent when diagnostics are paused.
- Gold evidence: the gold held at the request is saved with the pending purchase. Transactions shows whether your gold fell by exactly the cost, did not change, or changed by something else, and an unconfirmed purchase logs `goldChange`. Evidence only; you still confirm or reject it.
- Scan cooldown estimate: the status line shows "Next scan in about Xm Ys" (15 min, from the last accepted snapshot; saved across reloads) and "Scan ready" afterwards. Observed live: requests were ignored up to 14 min 53 s and accepted again by 18 min 30 s. It is display-only and never blocks a scan.
- Deal list now uses aligned columns (Item, Qty, Cost, Vendor, Profit, Return) with a matching header; numbers are right-aligned and long names are cut instead of wrapping.
- A failed item search now logs a `search-miss` entry (results returned, why each was rejected, sample item identities, search-key level/suffix) to diagnose lots that are listed but not found. Read-only.
- Snapshot wait raised from 30 s to 2 minutes, since the real server cooldown and response time are unknown. The status line states the wait, and the timeout message no longer assumes a cooldown.
- The status line shows the age of the displayed deals ("Snapshot 45s old"; green under 30 s, yellow under 2 min, red beyond), ticking once a second. Age counts from the scan request, so a slow response never looks fresher. Quote and purchase log entries record `snapshotAge`.
- Pre-fetch: when a scan completes, MEGold searches the best deals automatically (read-only) so the first purchase is ready when you look at the list. Nothing is quoted, bought or reserved until you click buy; a new scan, demo, manual Prepare or closing the AH discards it. Setting "Pre-fetch deals" (1 on, 0 off). Item lots older than 10 s are still re-searched at the buy click.
- Vendor sale recording is all-or-nothing: if a later buyback row cannot be allocated, earlier receipts from the same observation are reversed. Own-sale detection no longer errors when the run index is past the end.
- Fixed inventory baseline race: bag decreases are reconciled before merchant, sale or collection baselines are adopted; verified sales only excuse the quantities they explain.
- Fixed `MarkCollected` raising a nil-function error when bag APIs are missing; the Ledger collect button is gated on inventory support.
- Deals are now ranked by profit, return, then lower cost; Prepare Batch buys the best deals first.
- Added audited `/meg unlock` recovery for storage locks (refuses pending transactions, future schemas and locks that would re-trigger).
- Scan snapshot reads are time-budgeted (about 8 ms per frame) with a fixed-chunk fallback.
- Scan sorting is amortized (final sort plus mid-scan sorts only on 2x result growth): 100k-row benchmark 101 sorts -> 6, scan 1.06 s -> 0.48 s.
- Non-deal candidate rows are slimmed to 7 fields (name/value/profit/roi only on results, filled by `Refilter`): retained memory 730 -> 428 B/row. `Refilter` hoists balance lookups out of its loop.
- Added `tests/bench_scan.py` scan benchmark (not part of the test run).
- Scan progress status updates are throttled instead of refreshing the window on every row.
- Inventory reconciliation is debounced (single 0.5 s timer) and computes item identities once per pass.
- Split `ObserveVendor` into smaller steps with dedicated regression tests.
- Added CI workflow and `.luacheckrc` configuration.
- Release zips are no longer tracked in git (`releases/` moved out of the repository).
- Deduplicated helpers: shared `Integer`/`ItemIdentity` and a single numeric settings schema live in `Util.lua`, consumed by Settings and Storage.
- Added regression tests for the above (18 isolated scripts).

## 0.6.0
- Fixed automatic sale allocation consuming older held purchases; review reserves exact purchase quantities.
- Fixed earlier sale timers timing out later sales in the same batch with per-sale tokens.
- Added indexed/deduplicated scanner loading, bounded retries, expiry and invalid-data checks.
- Added item/commodity pagination with duplicate-event suppression, page deadlines and request limits.
- Added versioned saved-data validation, quarantine locks and preservation of unknown future schemas.
- Added safe history summarization while preserving buyback references and lifetime profit totals.
- Added explicit Forever API contracts, capability gates and deferred stable-GUID initialization.
- Cached profit tallies, skipped hidden-window redraws and centralized hold/stop transitions.
- Replaced permissive UI doubles and test-module imports with strict, independent fixtures.
- Added eleven isolated Lua 5.1 test scripts, pinned test dependency and a live validation checklist.

## 0.5.0
- Persistent 500-entry diagnostic ring with client/build/interface and API capability details.
- Scan, queue, quote, purchase, vendor receipt, recovery and addon-error logging.
- Diagnostics window with copyable reports, refresh, pause/resume and clear controls.
- `/meg logs` and `/meg diagnostics`; no automatic uploads.
- Sampled scan progress and bounded messages prevent repetitive logging from growing without limit.
- Tests cover retention/order, persistence, paused recording, error forwarding and viewer construction.

## 0.4.0
- Separate tracked flip proceeds, allocated purchase costs, realized profit and other vendor proceeds.
- Explicit collection verification and per-purchase holds.
- Vendor review with saved rarity filters, temporary exclusions and Never Sell IDs.
- Automatically split tracked quantities from mixed stacks; sequential verified vendor sales.
- Buyback reversals, exact partial-sale cost allocation, inventory loss protections and reload recovery.
- Explicit review for vendor activity that cannot be reconciled without guessing.
- Lua 5.1 startup/UI-wiring tests and simulated vendor integration tests.

## 0.3.0
- Commodity price-tier totals, firm server quotes, and click confirmation.
- Price caps, expiry checks, and detection of other commodity buying UI activity.
- Transactions window, purchase history, reviewed pending transactions, and budget reset.
- Editable buying exclusions and persistent Never Sell IDs.
- Tests for quotes, recovery and conflicting UI actions.

## 0.2.0
- Refreshed individual auction IDs, click-driven buying batches, persistent purchase intents.
- Confirmed-spend ledger, stale quote checks and uncertain-purchase locks.
- Saved numeric and rarity filters with reversible refiltering.

## 0.1.0
- Snapshot scanner, vendor-profit rules, paged results and demo mode.
