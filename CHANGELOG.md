# Changelog

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
