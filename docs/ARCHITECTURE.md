# MEGold architecture and invariants

## Client boundary

`Client.lua` defines the modern auction contract and groups APIs under `Auction`,
`Items`, and `Bags`. It enables each feature only when the Forever interface family
and every required function are present. Other game clients are explicitly unsupported.
Code must check `Supports` for read-only background work and `CanTransact` before
spending or selling. Transactions additionally require a stable character GUID and
validated, unlocked financial storage. The version comes from TOC metadata.

## Domain modules and UI

`Rules.lua` is a pure vendor-profit strategy: integer copper, whole-lot purchase cost,
finite balances, and supported numeric ranges. `Queue.lua` coordinates item search and
buying; `Commodities.lua` owns quote/confirm behavior. `State.lua` owns request deadlines,
safe stop requests, phase names, and purchase-hold transitions. `Vendor.lua` coordinates
bag evidence, splitting and receipt reconciliation. `Profit.lua` owns allocations,
receipts and cached totals; `Inventory.lua` conservatively revokes eligibility after
unexplained bag decreases. UI files display state and call domain methods.

Modules share the addon's namespace; domain records and contracts below are the boundary.
They are not independent object instances. Further strategies should supply valuation
rules and client adapters rather than duplicating purchase/accounting flows.

`Util.lua` (loaded right after `Core.lua`) holds the shared `M.Integer(value, minimum, maximum)`
validator (default minimum 0, default maximum 2^53-1; rejects NaN, infinities and fractions),
`M.ItemIdentity(link)`, and `M.SettingsSchema`, the one list of numeric settings
(`key, label, minimum, maximum`) used by both `Settings.lua` (UI and `ValidateSettings`) and
`Storage.lua` (load validation). Defaults come from `M.defaults` in `Core.lua`; Storage keeps no
fallback copy, so test fixtures that load Storage must define `M.defaults`.

## Buying state transitions

| Phase | Allowed next actions |
|---|---|
| idle | Prepare a batch |
| throttled | Wait for client search availability or skip |
| searching | Accept matching results, request another page, or time out |
| paging | Wait for a larger result cache or final-page flag; duplicate events do nothing |
| ready | Refresh stale item results, buy an item, or request a commodity quote |
| quoting | Accept or reject a firm server quote |
| quoted | Confirm a still-valid commodity quote with a player click |
| purchasing | Accept matching confirmation; never submit another purchase |
| uncertain | Reconcile explicitly before any retry |
| blocked | Skip the deal or finish the batch |

Search requests have identity tokens. Each page has its own deadline, and no search
can request more than 50 extra pages. A timeout from an earlier page/request cannot
expire the current request. Global server events carry limited identity: matching
item IDs and fresh price checks supplement tokens; tokens do not add server guarantees.

## Financial records

- Purchase: itemID, exact link, quantity, total cost, collected/sold quantities,
  costSold, optional held flag and confirmation timestamps.
- Sale allocation: stable purchase array index, quantity and allocated integer cost.
- Receipt: exact link, quantity, proceeds, flip quantity/proceeds, allocated cost,
  purchase allocations, timestamp and optional reversed flag.
- Pending intent: persisted-in-memory request details before calling a purchase or sale API.
  WoW flushes SavedVariables on normal logout/reload; this is not a crash-safe disk journal.

Automatic vendor review reserves explicit **unheld** purchase quantities. The sender and
receipt handler validate the same reservation. Manual sales can use held-inclusive FIFO
attribution for accounting, without making held quantities eligible for automatic sales.
Every in-flight automatic sale has its own token; batch identity alone is insufficient.

The invariants are `0 <= sold <= collected <= quantity` and
`0 <= costSold <= total purchase cost`. Partial-sale cost allocation uses remaining cost
and remaining quantity. Buyback reversal restores the original allocation. Profit is
sale proceeds minus allocated purchase cost, not purchases or unsold expected value.
Cache invalidation occurs on receipts, reversals and history maintenance.

## Storage and retention

`Storage.lua` validates settings, ledgers, pending intents, inventory/buyback references,
diagnostics and schema versions. Invalid financial data is quarantined and locks
transactions; defaulting missing or malformed money must not restore buying capacity.
Newer unknown schemas are preserved under `futureData` behind a locked UI shell.
Character initialization waits for a stable GUID instead of creating a temporary key.

`Recovery.lua` (`/meg unlock`) is the only path that clears `storageLocked`. It refuses when
`pending`/`vendorPending`/`vendorRun` exist, when the db is a future/unsupported schema
(`futureData`, `future-preserved`, or `schemaVersion` above `STORAGE_SCHEMA`), and when
`ValidateAccount` on a lock-free copy would lock again (data not already quarantined). After
a StaticPopup confirmation it appends to `account.recoveries` (bounded to 200, validated on
load), keeps `quarantine` samples, clears the account lock and the db-level lock, and logs
via `LogState`. Quarantined placeholders are valid records, so the next load does not re-lock.
A corrupted `spent` counter stays at its maximum; recovery never restores buying capacity.

## Deal ranking

`M.results` is ordered by `CompareDeals`: profit desc, return desc, cost asc, then
`snapshotIndex`. `ValueRow` appends unsorted and flags `resultsDirty`; `SortResults` runs at
1000-row progress checkpoints, scan completion, `StopScan`, `Refilter`, `Demo` and always in
`BuildBatch`, so batches buy the best deals. Mid-scan pages may show an unsorted tail.

## Scan performance

`ReadSnapshot` processes listings in frame slices. With `debugprofilestop` it works for about
8 ms per frame (checked once per row, never fewer than 25 rows so slow clients progress);
without it, it falls back to fixed 100-row chunks so tests stay deterministic. Rows are built
directly from `pcall` returns without a per-row temporary result table.

`ScanProgress` still sorts and logs at 1000-row buckets, but `SetStatus` (which refreshes the
window) is throttled to bucket changes, the transition to completion, the last pending row
resolving, and every 20th call otherwise. The final status text is always emitted.

Memory tradeoff: `self.candidates` retains every valued row so `Refilter` can loosen or
tighten filters in both directions without a rescan. Rows are plain tables with no closures:
`name`, `quality`, `vendor`, `quantity`, `cost`, `itemID`, `link`, `snapshotIndex`, `valued`,
plus `value`/`profit`/`roi` recomputed on each `Refilter`. Each candidate costs roughly one
12-field table plus its link string, so a very large auction house (hundreds of thousands of
valued rows) holds tens of megabytes until the next scan, `Demo` or reload. Invalid or
unvalued rows are never retained. Dropping fields such as `link` would break exact-variant
pricing, tooltips and queue identity checks, so they are kept deliberately.

`Inventory.lua` debounces `BAG_UPDATE_DELAYED`, `PLAYER_ENTERING_WORLD` and `MERCHANT_CLOSED`:
the first event schedules a single 0.5 s timer (token-guarded) and later events in the window
add nothing. Merchant/vendor-run/uncertainty gating is evaluated when the timer fires.
`ReconcileInventory` computes each purchase's `ItemIdentity` once per pass.

Maintenance runs at character initialization and normal logout. Receipts older than
30 days may be summarized only when they are not referenced by current buyback or pending
state. Settled, unreferenced purchases become compact tombstones. Array indexes remain
stable; these arrays are **not fully bounded in length**. Audit lists retain 200 records;
auction duplicate guards expire after 30 days. Archive summaries retain lifetime totals.

## Verification boundary

Lua 5.1 tests use explicit API contracts, controlled timers and strict UI doubles.
They verify state, accounting and wiring; they cannot verify real visuals, protected
action behavior, server throttling, or actual event ordering. Use the live test checklist
before treating the addon as production-ready.
