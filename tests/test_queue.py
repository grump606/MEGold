"""Queue lifecycle tests against real Lua and a deterministic auction fixture."""
from support import ROOT, make_queue_runtime

lua, module = make_queue_runtime()
lua.execute('''
reset(); ready()
M:BuyNext(); M:BuyNext()
assert(#bids == 1 and M.account.spent == 0)
M:PurchaseConfirmed(999)
assert(M.account.pending and #M.account.purchases == 0)
M:PurchaseConfirmed(42); M:PurchaseConfirmed(42)
assert(M.account.spent == 300 and #M.account.purchases == 1)
assert(M.queue.phase == "idle")
-- Already purchased IDs cannot be bought again from a stale snapshot.
M:BuildBatch(); M:QueueResults({itemID = 1})
assert(M.queue.phase == "blocked")

reset(); ready(); M:BuyNext()
timers[#timers]()
assert(M.queue.phase == "uncertain")
M:SkipDeal(); M:BuildBatch(); M:BuyNext()
assert(#bids == 1)
M:InitializeQueue()
assert(M.queue.phase == "uncertain" and M.account.pending)
M:PurchaseConfirmed(42)
assert(#M.account.purchases == 1 and not M.account.pending)

reset(); ready(); M.db.settings.reserve = 9900; M:BuyNext()
assert(#bids == 0 and M.queue.phase == "blocked")
reset(); ready(); results[1].buyoutAmount = 301; M:BuyNext()
assert(#bids == 0 and M.queue.phase == "searching")
reset(); ready(); now = 111; M:BuyNext()
assert(#bids == 0 and M.queue.phase == "searching")
reset(); ready(); M.ahOpen = false; M:CloseQueue(); M:BuyNext()
assert(#bids == 0 and M.queue.phase == "idle")

reset(); commodity = true; M:BuildBatch(); M:QueueResults({itemID = 1})
assert(M.queue.phase == "searching" and #bids == 0)
reset(); throttle = false; M:BuildBatch()
assert(M.queue.phase == "throttled" and #searches == 0)
throttle = true; M:SendQueueSearch()
assert(#searches == 1)
reset(); M.db.settings.budget = 500
M.results[2] = M.results[1]
M:BuildBatch()
assert(#M.queue.rows == 1)
reset(); results[1].itemLink = "|Hitem:1:99|h[Different variant]|h"
M:BuildBatch(); M:QueueResults({itemID = 1})
assert(M.queue.phase == "blocked")
reset(); results[1].containsAccountItem = true
M:BuildBatch(); M:QueueResults({itemID = 1})
assert(M.queue.phase == "blocked")
reset(); M.results[1].demo = true; M:BuildBatch()
assert(M.queue.phase == "idle" and #searches == 0)
''')
print("PASS: queue confirmation, timeout/reload locks, budget, stale prices, variants, throttle, demo and commodity exclusion")
