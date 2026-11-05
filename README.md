# MEGold

Personal vendor-flip addon for WoW Forever. Version 0.6 hardens transaction safety,
saved-data recovery, scanning and test coverage. It remains a preview pending live testing.

## Disclaimer and AI assistance

**Use at your own risk.** MEGold is experimental software provided as is, without
warranties. Bugs or unexpected game-client behavior may cause incorrect results,
loss of in-game gold or items, or loss of saved data. Back up your settings and test
with small quantities before relying on it.

**Created with AI assistance.** The code, tests and documentation were developed with
assistance from AI tools. AI-assisted development and automated tests do not guarantee
correctness, security, compatibility, or compliance with Blizzard's rules.

MEGold is an independent personal project and is not affiliated with, endorsed by,
or certified by Blizzard Entertainment. You are responsible for following the rules
applicable to your game and account.

## Install

Built zips are distributed via GitHub Releases and are not tracked in the repository.

Copy the `MEGold` folder into your Forever client's `Interface/AddOns` folder.
Enable it in the AddOns menu. Interface 16001 targets the known beta API and must be
checked against the launch client. No game installation is modified by this repository.
Features require the Forever interface family and their complete API contract; unsupported
clients or missing APIs disable the affected actions. Character state initializes only
after a stable player GUID is available.

Deals are ranked by profit, then return, then lower cost, and batches buy the best first.
Opening the auction house adds a MEGold tab to its window (`/meg` selects it). With the AH closed, or if the tab cannot be created, `/meg` or `/megold` opens a standalone window. `/meg demo` displays clearly labeled sample deals without
contacting the auction house. Open an auctioneer and press **Scan AH** for real data.
Use **Stop** to cancel local processing. The server may impose a full-scan cooldown.
Hover results for item tooltips; Previous/Next batch shows groups of ten.
The status line shows how old the deals are and roughly when the next scan will be allowed. The server may take a while to answer a scan,
so MEGold waits up to two minutes for the snapshot. When a scan finishes, the best deals are
searched automatically (read-only, setting "Pre-fetch deals") so the first buy is ready; nothing is
bought until you click.
Press **Filters** to edit profit, return, purchase cap, budget, reserve, batch size,
and buying rarities. Money fields use copper. Saved filters immediately recheck all
loaded candidates, including previously hidden deals. Confirmed spending counts toward
the character's budget and persists across reloads. **Transactions → Start new budget**
resets spending after the buying batch is finished, while retaining purchase history.
Buying ignore lists and Never Sell lists accept item IDs separated by commas or spaces.
Never Sell IDs exclude items from automatic vendor selling.

## Buying individual item lots

Press **Prepare buying batch** to pause local scanning and select up to the configured
batch size within the remaining budget. Each lot is searched again for a real auction
ID, matching item link/variant and quantity, at no more than its snapshot cost.
Press **Buy Next** for each purchase. Successful server confirmation records the purchase
and refreshes the next deal. **Skip deal** advances past missing or unwanted deals.
Quotes older than ten seconds trigger another search and require a new click.
Item searches request additional pages when the current page has no eligible lot.
Commodity searches request more results when quantity is insufficient. Duplicate page
events do not send duplicate requests; page requests have their own timeouts and a
50-page bound. These refreshes do not guarantee that deals remain available.
For commodities, the addon totals available price tiers for the selected quantity.
**Get Quote** requests a firm server quote; **Confirm Buy** purchases it with another click.
The total must remain within the original snapshot price and all current profit/budget
limits. Expired quotes require another request. Changing quotes through another buying
UI invalidates MEGold's quote; conflicted in-flight purchases require manual review.

Transactions are stored under `MEGoldDB.accounts`, keyed by character GUID. Confirmed
purchases record exact links, quantities, costs and timestamps. If a purchase times out,
throws an error, or reloads before confirmation, further buying locks rather than retrying.
A matching late confirmation can resolve it. **Transactions** shows the pending item,
quantity, cost and purchase history. After checking mail, inventory and gold, use
**Verified purchased** or **Verified not purchased** and confirm the review dialog.
Review controls remain disabled while the transaction is still waiting for its response.
Manual decisions are recorded, and confirmed manual purchases count toward the budget.
The addon has not yet been tested in the actual Forever client.

Profit = exact-link vendor unit price × quantity − full lot buyout.
Missing item data never becomes a confirmed opportunity. Load requests are deduplicated
by item ID and expire after three bounded attempts, releasing the scan for a later retry.
Listings are snapshots and may already be unavailable.

Demo data cannot enter the purchase queue. This version spends real gold when
**Buy Next** or **Confirm Buy** is clicked and sells reviewed flips at an open merchant.

## Collection and vendor selling

After collecting purchase mail, open **Transactions** (`/meg ledger`) and press
**Collected…** on each purchase you have collected. Confirm the review. The complete
unallocated lot must be present in your bags. This explicit collection step prevents
matching personal items from being treated as an uncollected auction purchase.
Automatic mailbox provenance is not implemented.

**Hold for AH** excludes a purchase from automatic selling. Release its hold when ready.
Automatic review reserves exact quantities from specific unheld purchases. Its receipt
must consume those same quantities, so an older held purchase cannot be selected by FIFO.
If items leave your bags outside a verified vendor sale (including bank deposits or
consumption), affected collected purchases are unmarked and held for another review.

Opening a merchant displays **Review vendor flips**; reopen it with `/meg vendor`.
Choose selling rarities (Poor/Common initially), press **Review flips**, and inspect
the exact quantities, expected proceeds and bag locations. Uncheck rows to exclude
them temporarily. **Sell reviewed flips** processes selected stacks sequentially.
Mixed stacks split automatically into a free general-purpose bag slot; personal units
remain in the original stack. If no suitable slot exists, selling stops.
Locked, bound, equipment-set, held, Never Sell and zero-value items are excluded.
Changes to inventory or eligibility stop selling and require another review.

## Profit tally

The main window, Transactions and vendor review show persistent character totals:

- **Flip sale proceeds:** money received from collected tracked purchases.
- **Allocated purchase cost:** costs from the reserved purchases sold by Sell Flips;
  manual sales use known collected purchases in FIFO order, including held purchases.
- **Realized flip profit:** flip proceeds minus those costs.
- **Other vendor proceeds:** sales with no collected tracked cost attribution. These are
  proceeds, not claimed profit; they may include untracked or unmarked purchases.

Unsold purchases do not earn profit. Cost allocation conserves integer copper across
partial sales. Vendor buybacks reverse identifiable recorded receipts and restore flip
quantities. Holds prevent automatic sales but do not hide the known cost of a manual sale.
Budget resets do not erase the profit tally or purchase history.

## Saved-data validation and history

Saved settings, purchase/sale records, pending intents and diagnostics are validated on
startup. Malformed financial records are quarantined and transactions are locked rather
than silently resetting spending or protection limits. Diagnostics include the schema
and lock reason. Unknown newer schemas are preserved under `futureData` behind a locked
view. Retain a backup and the diagnostic report if a storage lock appears.

`/meg unlock` offers an audited recovery for locks caused by quarantined records: it lists
the quarantined paths and reasons, asks for confirmation, keeps the quarantine samples and
records an entry in `account.recoveries` (last 200). It refuses while a purchase or vendor
sale is unresolved and for unsupported/newer-schema locks. It does not restore spending
capacity: a corrupt spent counter stays at its maximum, so buying stays budget-blocked.

After 30 days, settled receipts with no active buyback/pending references can be summarized
into lifetime totals. Settled unreferenced purchases become compact placeholders. Stable
array indexes are retained, so historical arrays are not fully bounded in length. Recent
audit histories retain 200 entries, and duplicate-auction timestamps expire after 30 days.
Unsettled and protected records are retained. Maintenance runs at initialization/logout.

Receipts require matching vendor buyback, bag and gold changes. Repairs, purchases,
loot gold and unmatched money changes are not counted as vendor sales. Ambiguous
activity locks automatic selling and remains excluded from totals. **Review accounting…**
lets you explicitly exclude the unresolved activity and resume: remaining collected
flips are unmarked and held until you verify them. Reloads during a sale also require
review. The tally covers observed activity while MEGold is enabled, not past game history.

## Diagnostic log

Open **Diagnostics** in the main window, or type `/meg logs` (`/meg diagnostics` also works).
Press **Refresh report**, then **Select all / copy** and Ctrl+C to copy the report.
The viewer is a snapshot so incoming events do not interrupt text selection. It also
provides **Pause recording**, **Resume recording**, and **Clear log** controls.

Recording starts enabled. The latest 500 entries are retained in a bounded ring inside
`MEGoldDB.diagnostics`, alongside the other saved settings. WoW writes SavedVariables
on a normal logout or `/reload`; a crash can lose entries not yet written. Paused logging
stays paused through reloads. Clearing the log preserves recording preferences and history
outside diagnostics, including purchases and profit totals.

Reports include addon/client/build/interface versions, auction API capabilities, current
transaction phases, sampled scan progress, search and throttle events, commodity quotes,
purchase intent and confirmation, vendor receipts/buybacks, manual reviews and API errors.
Addon Lua errors after startup are logged while forwarding to the existing error handler.
Routine entries exclude chat and player-name payloads. Error messages and stacks are
included as received and may contain context worth reviewing before sharing.
No report is uploaded automatically. The addon cannot write an arbitrary standalone log file.

For a failed live test: open `/meg logs` promptly, refresh, copy the report, and retain it
before clearing the log or performing many more scans. It is bounded, so older events roll off.

## Validation

Install the pinned development dependency with
`python -m pip install --target .test-deps -r tests/requirements-dev.txt`, then run
`python tests/run_all.py`. The runner executes eleven test scripts in separate processes.
Shared factories create fresh deterministic Lua 5.1 environments without importing other
test modules or executing unrelated tests.

Coverage includes numeric rules, partial client APIs, deferred character startup, queue
recovery, paginated searches, duplicate/reordered events, page/sale timer identity, missing
item data, malformed/future storage, archival, held purchases, mixed stacks, buybacks,
profit caching and diagnostics. UI doubles reject unknown methods; they verify wiring,
not real visual quality or protected-action behavior.

See [architecture and invariants](docs/ARCHITECTURE.md) and the
[live test checklist](docs/LIVE_TEST_CHECKLIST.md). Live-client scan, purchase, merchant
timing and visual validation remain pending until the client is accessible.
