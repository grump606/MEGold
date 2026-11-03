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
