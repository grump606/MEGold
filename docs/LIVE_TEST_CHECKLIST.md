# Live Forever verification

Record the client build from `/meg logs`. Start with one inexpensive deal and retain
the report if any step fails. Stop a test on a Lua error or unexplained financial change.

1. Back up the character's existing MEGold SavedVariables; verify startup, settings,
   logs, character switching and a normal `/reload`. No migration should unlock
   quarantined financial data or reset spending.
2. Scan a small auction market. Verify exact item links, quantities, copper prices,
   vendor unit values, pending-data expiry and a subsequent successful rescan.
3. Exercise an item with multiple result pages; compare addon and default AH listings.
   Confirm throttled requests recover without duplicate buys.
4. Buy one individual item; confirm auction ID, gold decrease, mail quantity and ledger.
   Repeat with a commodity using quote and confirmation. Reject a changed price.
5. Close the AH while searching, quoting and awaiting confirmation; check that delayed
   events never cause a second purchase. Test reload recovery at an uncertain transaction.
6. Collect mail and mark the corresponding lot collected. Create a mixed stack and
   verify the review splits only the eligible quantity, preserving personal units.
7. Put an older identical purchase on Hold for AH, leave a newer one eligible, and sell
   the newer quantity. Verify the older hold and eligible remaining counts are unchanged
   except for the intended sale.
8. Sell two successive stacks with normal latency. Confirm old timers never interrupt
   later sales. Test Stop selling, vendor closure, full bags and a cursor already occupied.
9. Verify Poor/Common defaults, higher-rarity opt-in, Never Sell IDs, equipment sets,
   bound/locked items and changes made after the review.
10. Verify partial-sale cost, other vendor proceeds, manual held-item sale and buyback
    reversal. Concurrent repairs/purchases must not be reported as additional profit.
11. Move or consume tracked items outside a verified sale. Confirm the affected purchase
    is held for collection review rather than leaving a stale automatic-sale allowance.
12. Inspect all windows at the user's actual resolution/UI scale and with other auction
    addons enabled. Copy diagnostics and confirm no unexpected player details appear.

Live checks are pending until the client is accessible; automated test results do not
mark these steps complete.

## Snapshot age and pre-fetch
- After a scan the status line shows "Snapshot Ns old" and it counts up every second (green, then yellow, then red).
- Scan again inside the cooldown: MEGold waits up to 2 minutes before reporting no snapshot. Note how long real cooldown responses take.
- When a scan finishes with deals and pre-fetch is on, the first deal shows "(pre-fetched)" and Buy Next / Get Quote works without pressing Prepare.
- Press Scan again after a pre-fetch: it starts normally. Set "Pre-fetch deals" to 0 in Filters: no automatic searching after a scan.
- In /meg logs, quote-request and purchase-intent entries include snapshotAge.

## Auction House tab
- Open the AH: a MEGold tab appears beside the stock tabs and the default tab is unchanged.
- Click the tab: the deal list, buttons and both status lines fit inside the AH window with no overlap or clipping.
- Switch between stock tabs and MEGold repeatedly, then open your bags and use an item: no taint/blocked-action errors.
- Scan, prepare a batch, and buy from the tab; close the AH mid-batch and confirm the queue stops.
- `/meg` with the AH closed opens the standalone window.
