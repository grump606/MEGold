# MEGold implementation plan

Personal WoW Forever addon. Primary strategy: purchase buyouts below NPC vendor value.
Expandable strategy modules; all monetary calculations use integer copper.

## Agreed behavior

- Scan AH and expose opportunities as soon as the server supplies enough data.
- Default batch: 10 deals, not 10 individual units.
- Buy with real player input; revalidate before purchase. Do not promise unattended batches.
- Filter by profit, percentage return, purchase cap, session budget, gold reserve, rarity, and ignore list.
- Separate commodity quotes from individual auction lots. Never buy across a price cap.
- Record confirmed purchases only; pause uncertain transactions and reconcile before retrying.
- Track collection and vendor sale separately. Expected profit is not realized profit.
- Vendor review permits rarity selection; default Poor/Common. Permanent Never Sell list.
- Track flip quantities conservatively when inventory merges. Never infer ownership from item ID alone.
- Allow items to be held for future AH resale.

## Architecture and milestones

1. Foundation and scanner preview: TOC, saved settings, client checks, item-link valuation,
   cancellable snapshot processing, pending item data, ten-row batches, demo UI.
2. Scan validation: verify Forever replication support/cooldown, item variants, commodity
   representation, inaccessible item data, error paths and throttles in the actual client.
   Add an incremental discovery adapter only if the client supports it reliably.
3. Settings UI and request scheduler: edit all rules, persist settings, prioritize live
   refreshes over discovery; expire old quotes and deduplicate listings.
4. Buy queue: obtain real auction IDs through fresh searches (snapshot indexes are NOT IDs),
   quote commodities, refresh eligibility, reserve budget, player-click purchase,
   success/failure/timeout reconciliation, no duplicate retries.
5. Ledger: character/realm/market keys; confirmed purchase cost, mailbox collection,
   quantity held/sold, realized proceeds, reload recovery and held-for-resale status.
6. Vendor workflow: review bag locations and exact links, rarity controls, Never Sell,
   quantity caps, inventory ambiguity exclusions, verified sale acknowledgments.
7. Launch verification and packaging: scan, item and commodity purchase, AH closure,
   disconnect/reload, mailbox merging, partial sales, unavailable deals, budget boundaries.

## Current implementation boundary

0.6 supports click-driven buying, firm commodity quotes, vendor review, profit tallies and diagnostics.
Editable numeric and rarity filters are implemented with validation and saved settings.
Retained candidates allow changing filters in both directions without rescanning.
Queue handles throttling, stale quotes, batch budget reservation, exact-link matching,
confirmed spending, duplicate auction IDs, closure, timeout and reload locks.
Searches request additional item/commodity pages when required, with duplicate-event
suppression, per-page deadlines and a 50-page limit.
Commodity totals use sorted price tiers; firm quotes must pass the original deal cap
and current filters. Quotes require explicit confirmation and cannot be used after expiry.
Hooks detect a different UI replacing or cancelling shared commodity quotes.
Transaction review provides audited manual resolution and budget reset controls.
Buying ignore lists and Never Sell IDs are editable in Filters.
Collection uses explicit per-purchase verification, capped by unallocated exact-link bag quantities.
Vendor review offers saved rarity controls, per-review exclusions, Never Sell IDs and purchase holds.
Mixed stacks automatically split only eligible flip quantities into a free general-purpose bag slot.
Sequential sales revalidate inventory and stop on ambiguity, repair/combat/cursor changes or closure.
Receipts reconcile buyback, exact-link inventory quantities and gold; identifiable buybacks reverse them.
Profit is tracked separately from other/untracked vendor proceeds using FIFO cost allocation.
Automatic sales reserve specific unheld purchase quantities and validate those same
allocations at receipt time; manual sales retain held-inclusive FIFO attribution.
Each vendor sale has its own immutable token, independent of its surrounding batch.
Partial sales and buybacks conserve integer copper. Budget resets retain all sale history.
Unverified bag decreases remove affected quantities from sale eligibility and put purchases on hold.
Pending vendor intent survives reload; unresolved vendor activity requires explicit review.
Diagnostics retain 500 bounded entries in SavedVariables with version/API metadata,
sampled scan progress, transaction phases and addon-scoped errors. Reports can be copied
in game; recording can be paused and logs cleared without touching financial history.
Automatic mailbox attribution remains a future enhancement. Collection is never inferred solely from item ID.
Ledger purchase intent and confirmed purchases persist per character GUID.
Replication produces a server snapshot, not guaranteed streaming listings. Processing
results progressively does not reduce the server's initial snapshot latency.

Versioned storage validates and quarantines malformed financial data behind transaction
locks; unknown future schemas are preserved. Safe 30-day history summarization retains
lifetime totals and active buyback references. Stable-index tombstones remain, so array
length is not fully bounded. Client adapters gate unsupported APIs and initialization
waits for a stable character GUID. UI rendering skips hidden windows, and profit totals
are cached until a financial mutation. See docs/ARCHITECTURE.md for record invariants.

## Source baseline

Forever interface 16001; verify on launch with GetBuildInfo().
Blizzard API source mirror:
https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/AuctionHouseDocumentation.lua
Snapshot API uses zero-based indexes. Vendor price is return 11 of C_Item.GetItemInfo.
Source declarations establish signatures, not successful execution on the live client.

## Verification status

Eleven isolated Lua 5.1 test scripts cover rules, client gates, queue/pagination, scanner,
storage migration/archival, vendor accounting, regression cases, diagnostics and strict UI wiring.
Live Forever compatibility, real merchant timing, auction throttling and visual layout remain unverified.
No game installation has been modified. Release archives contain the addon folder and documentation.
