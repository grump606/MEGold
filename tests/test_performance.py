"""Performance behavior: time-budgeted snapshot reads, throttled progress UI, debounced inventory reconcile."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from support import make_queue_runtime, make_vendor_runtime

# ---- Scanner ----
lua, module = make_queue_runtime()
for filename in ("Scanner.lua", "Settings.lua"):
    lua.execute((ROOT / "MEGold" / filename).read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
local listing = 0
C_AuctionHouse.GetNumReplicateItems = function() return listing end
C_AuctionHouse.GetReplicateItemLink = function(i) return "|Hitem:" .. (i % 7 + 1) .. ":0|h[Test]|h" end
C_AuctionHouse.GetReplicateItemInfo = function(i)
    return "Item", nil, 5, 1, nil, nil, nil, nil, nil, 100 + (i % 50), nil, nil, nil, nil, nil, nil, i % 7 + 1
end
local statuses, logs = 0, 0
function M:SetStatus(message) statuses = statuses + 1; self.status = message end
function M:LogState(kind) if kind == "scan-progress" then logs = logs + 1 end end
function begin(total)
    reset()
    M.db.settings.maxCost, M.db.settings.budget = 1000000, 100000000
    listing, statuses, logs = total, 0, 0
    M.results, M.candidates, M.resultsDirty = {}, {}, false
    M.scan = { phase = "waiting", pendingByItem = {}, failedItems = {}, pendingCount = 0,
        failedRows = 0, invalidRows = 0, checked = 0, total = 0 }
    M.generation = (M.generation or 0) + 1
end
function drain()
    local frames = 0
    while #timers > 0 do
        local pending = timers; timers = {}
        for _, cb in ipairs(pending) do cb() end
        frames = frames + 1
    end
    return frames
end

-- Fallback (no debugprofilestop): fixed 100-row chunks, deterministic.
assert(debugprofilestop == nil)
begin(2500)
M:ReadSnapshot()
assert(M.scan.checked == 100)
local frames = 1 + drain()
assert(frames == 25 and #M.results == 2500 and M.lastScan.total == 2500 and not M.scan)

-- Time budget: a fake clock advancing 1ms per call is only consulted after MIN_ROWS (25) rows, so an 8-tick budget ends the frame at 32 rows.
local ticks = 0
debugprofilestop = function() ticks = ticks + 1; return ticks end
begin(1000)
M:ReadSnapshot()
assert(M.scan.checked == 32, M.scan.checked)
frames = 1 + drain()
assert(frames == 32 and #M.results == 1000 and M.lastScan.total == 1000, frames .. "|" .. #M.results)

-- A fast clock (nothing ever reaches the budget) processes the whole snapshot in one frame.
debugprofilestop = function() return 0 end
begin(5000)
M:ReadSnapshot()
assert(M.scan == nil and #M.results == 5000 and M.lastScan.total == 5000 and #timers == 0)

-- A slow clock (each call costs 20ms) still makes progress: exactly MIN_ROWS per frame.
local slow = 0
debugprofilestop = function() slow = slow + 20; return slow end
begin(100)
M:ReadSnapshot()
assert(M.scan.checked == 25)
drain()
assert(#M.results == 100 and M.lastScan.total == 100)

-- Progress UI is throttled: far fewer SetStatus calls than frames/rows, final status is exact.
debugprofilestop = nil
begin(3000)
M:ReadSnapshot(); drain()
assert(statuses <= 5, statuses)
assert(M.status == "3000/3000 listings checked | 3000 deals | 0 awaiting item data | 0 unavailable | 0 invalid", M.status)
assert(logs >= 3) -- log buckets (0,1,2,3 thousand) and completion are still recorded

-- Per-row table churn: candidate rows keep only the fields the UI, queue and Refilter use.
local row = M.candidates[1]
local allowed = { name=1, quantity=1, quality=1, cost=1, itemID=1, link=1, snapshotIndex=1,
    vendor=1, value=1, profit=1, roi=1 }
for k in pairs(row) do assert(allowed[k], k) end
local function fieldCount(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- Non-deal candidates stay slim (<= 8 fields: one 8-node hash part) and carry no result fields.
begin(500)
M.db.settings.minProfit = 1000000
M:ReadSnapshot(); drain()
assert(#M.candidates == 500 and #M.results == 0)
for _, c in ipairs(M.candidates) do
    assert(fieldCount(c) <= 8, fieldCount(c))
    assert(c.name == nil and c.value == nil and c.profit == nil and c.valued == nil)
end
-- Refilter fills name/value/profit/roi only for rows that become deals, and strips them again.
M.db.settings.minProfit = 1
M:Refilter()
assert(#M.results == 500)
for _, r in ipairs(M.results) do assert(type(r.name) == "string" and r.profit and r.value and r.roi) end
M.db.settings.minProfit = 1000000
M:Refilter()
for _, c in ipairs(M.candidates) do assert(c.name == nil and c.profit == nil and c.roi == nil) end
M.db.settings.minProfit = 1

-- Sort count stays logarithmic for a large scan where nearly every row is a deal.
local sorts, realSort = 0, table.sort
table.sort = function(...) sorts = sorts + 1; return realSort(...) end
begin(20000)
M:ReadSnapshot(); drain()
table.sort = realSort
assert(#M.results == 20000 and not M.resultsDirty)
assert(sorts <= math.log(20000) / math.log(2) + 3, sorts)
for i = 2, #M.results do assert(not M.CompareDeals(M.results[i], M.results[i - 1])) end

-- Refilter still works in both directions from the retained candidates, without rescanning.
local before = #M.results
M.db.settings.minProfit = 1000000
M:Refilter(); assert(#M.results == 0 and #M.candidates == before)
M.db.settings.minProfit = 1
M:Refilter(); assert(#M.results == before)

-- Pending item data resolving late still reports a correct final status.
begin(2)
local ready = false
C_Item.GetItemInfo = function(link)
    if not ready then return nil end
    return "Test", link, 1, nil, nil, nil, nil, nil, nil, nil, 100
end
C_Item.RequestLoadItemDataByID = function() end
M:ReadSnapshot()
assert(M.scan.pendingCount == 2 and M.status:find("2 awaiting item data"))
ready = true
M:RetryPending(1, true); M:RetryPending(2, true)
assert(M.scan == nil and M.lastScan.deals == 2 and M.status:find("0 awaiting item data"))
''')
print("PASS: time-budgeted scan frames, fixed-chunk fallback, throttled progress and slim candidates")

# ---- Inventory debounce ----
lua, module = make_vendor_runtime(capture_events=True)
lua.execute('''
local reconciles, refreshes = 0, 0
local original = M.ReconcileInventory
function M:ReconcileInventory(...) reconciles = reconciles + 1; return original(self, ...) end
function M:Refresh() refreshes = refreshes + 1 end
vendorReset(10)
M.merchantOpen = false
M.account.inventoryTotals = M:BagTotals()

-- A burst of events schedules exactly one 0.5s timer and one reconcile.
local before = #timers
for i = 1, 20 do fireEvent("BAG_UPDATE_DELAYED") end
fireEvent("PLAYER_ENTERING_WORLD"); fireEvent("MERCHANT_CLOSED")
assert(#timers - before == 1, #timers - before)
runTimers()
assert(reconciles == 1 and refreshes == 1)
-- After it fires, a new event schedules again.
fireEvent("BAG_UPDATE_DELAYED"); runTimers()
assert(reconciles == 2)

-- Gating is checked when the timer fires.
fireEvent("BAG_UPDATE_DELAYED"); M.merchantOpen = true; runTimers()
assert(reconciles == 2)
M.merchantOpen = false
fireEvent("BAG_UPDATE_DELAYED"); M.account.vendorUncertain = {reason = "x"}; runTimers()
assert(reconciles == 2)
M.account.vendorUncertain = nil
fireEvent("BAG_UPDATE_DELAYED"); M.vendorRun = {}; runTimers()
assert(reconciles == 2)
M.vendorRun = nil

-- Behavior preserved: an unexplained decrease still revokes eligibility via the debounced path.
local flip = addPurchase(3, 150, 3)
bags[1].stackCount = 7
for i = 1, 5 do fireEvent("BAG_UPDATE_DELAYED") end
runTimers()
assert(flip.held and flip.collected == 0)

-- Identity matching happens once per purchase per pass (not per nested loop).
local calls, realIdentity = 0, M.ItemIdentity
M.ItemIdentity = function(link) calls = calls + 1; return realIdentity(link) end
M.account.purchases = {}
for i = 1, 10 do addPurchase(1, 10, 1) end
local totals = M:BagTotals()
calls = 0
M:ReconcileInventory(totals)
assert(calls == 10, calls)
M.ItemIdentity = realIdentity
''')
print("PASS: debounced inventory reconcile, gating and single identity pass")
