"""Pre-fetch: read-only searching of the best deals after a scan, with a clear commit point."""
from support import make_queue_runtime

lua, module = make_queue_runtime()
lua.execute('''
-- Searches only; nothing is quoted, bought or reserved until a buy click.
reset(); M.db.settings.prefetch = 1
M:Prefetch()
assert(M.queue.phase == "searching" and M.queue.prefetch and #searches == 1)
assert(not M:QueueBusy(), "a pre-fetched batch must not block scans or demos")
M:QueueResults({itemID = 1})
assert(M.queue.phase == "ready" and M.queue.message:find("(pre-fetched)", 1, true))
assert(#bids == 0 and M.account.spent == 0 and not M.account.pending)

-- Discarding returns to a clean idle queue.
M:DiscardPrefetch()
assert(M.queue.phase == "idle" and not M.queue.prefetch and #M.queue.rows == 0 and not M.queue.ready)
M:DiscardPrefetch()   -- idempotent

-- Switched off, or nothing to do: completely silent.
reset(); M.db.settings.prefetch = 0; M:Prefetch()
assert(M.queue.phase == "idle" and #searches == 0)
reset(); M.db.settings.prefetch = 1; M.results = {}; M.status = "before"; M:Prefetch()
assert(M.queue.phase == "idle" and #searches == 0 and M.status == "before" and M.queue.message == nil)
reset(); M.db.settings.prefetch = 1; M.ahOpen = false; M:Prefetch()
assert(M.queue.phase == "idle" and #searches == 0 and M.queue.message == nil)
reset(); M.db.settings.prefetch = 1; M.account.pending = { itemID = 1 }; M:Prefetch()
assert(M.queue.phase == "idle" and #searches == 0)
reset(); M.db.settings.prefetch = 1; M.CanTransact = function() return false, "locked" end; M:Prefetch()
assert(M.queue.phase == "idle" and #searches == 0 and M.status ~= "locked")
M.CanTransact = function() return true end

-- A batch already in progress is never replaced by a pre-fetch.
reset(); M.db.settings.prefetch = 1; M:BuildBatch(); assert(M.queue.phase == "searching" and not M.queue.prefetch)
M:Prefetch(); assert(#searches == 1 and not M.queue.prefetch)

-- Buying commits the batch: the flag clears and the normal rules apply.
reset(); M.db.settings.prefetch = 1; M:Prefetch(); M:QueueResults({itemID = 1})
M:BuyNext()
assert(#bids == 1 and not M.queue.prefetch and M:QueueBusy())
M:PurchaseConfirmed(42)
assert(M.account.spent == 300 and M.queue.phase == "idle" and not M.queue.prefetch)

-- A manual Prepare replaces a pre-fetched batch with a normal, committed-to-the-click one.
reset(); M.db.settings.prefetch = 1; M:Prefetch(); M:QueueResults({itemID = 1})
M:BuildBatch()
assert(M.queue.phase == "searching" and not M.queue.prefetch and #searches == 2)
M:QueueResults({itemID = 1})
assert(M.queue.phase == "ready" and not M.queue.message:find("(pre-fetched)", 1, true))

-- Skipping through a pre-fetched batch keeps it pre-fetched until it ends, then it goes idle.
reset(); M.db.settings.prefetch = 1; M:Prefetch(); M:QueueResults({itemID = 1})
M:SkipDeal()
assert(M.queue.phase == "idle" and not M.queue.prefetch)

-- Closing the AH drops it.
reset(); M.db.settings.prefetch = 1; M:Prefetch(); M:QueueResults({itemID = 1})
M.ahOpen = false; M:CloseQueue()
assert(M.queue.phase == "idle" and not M.queue.prefetch)

-- A stale search timeout from a discarded pre-fetch cannot block the next search.
reset(); M.db.settings.prefetch = 1; M:Prefetch(); M:DiscardPrefetch(); M:BuildBatch()
timers[1]()
assert(M.queue.phase == "searching", "old timeout must be a no-op")
''')
print("PASS: pre-fetch is read-only, switchable, discardable, committed only by a buy click and silent when idle")
