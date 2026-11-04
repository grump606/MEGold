"""Deal ranking: results sort by profit, return, cost, snapshot order; batches buy the best deals."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from support import make_queue_runtime

lua, module = make_queue_runtime()
for filename in ("Scanner.lua", "Settings.lua"):
    lua.execute((ROOT / "MEGold" / filename).read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
local function link(id) return "|Hitem:" .. id .. ":0|h[Test]|h" end
local function row(index, quantity, cost)
    return { itemID = 1, link = link(1), quantity = quantity, cost = cost, snapshotIndex = index }
end
-- vendor price is 100 per unit in the shared fixture, so profit = 100 * quantity - cost.

-- Comparator tie-breaks: profit, then return, then lower cost, then snapshot order.
local a = { profit = 200, roi = 10, cost = 50, snapshotIndex = 5 }
local b = { profit = 100, roi = 99, cost = 1, snapshotIndex = 1 }
assert(M.CompareDeals(a, b) and not M.CompareDeals(b, a))
local c = { profit = 200, roi = 20, cost = 50, snapshotIndex = 9 }
assert(M.CompareDeals(c, a))
local d = { profit = 200, roi = 20, cost = 40, snapshotIndex = 9 }
assert(M.CompareDeals(d, c))
local e = { profit = 200, roi = 20, cost = 40, snapshotIndex = 3 }
assert(M.CompareDeals(e, d) and not M.CompareDeals(d, e) and not M.CompareDeals(e, e))

-- BuildBatch picks the best deals, not the first in snapshot order.
reset()
M.db.settings.batchSize = 2
M.results = {
    { name = "low", itemID = 1, link = link(1), vendor = 100, quality = 1, quantity = 5, cost = 450, profit = 50, roi = 11, snapshotIndex = 0 },
    { name = "mid", itemID = 1, link = link(1), vendor = 100, quality = 1, quantity = 5, cost = 300, profit = 200, roi = 66, snapshotIndex = 1 },
    { name = "best", itemID = 1, link = link(1), vendor = 100, quality = 1, quantity = 5, cost = 100, profit = 400, roi = 400, snapshotIndex = 2 },
}
M:BuildBatch()
assert(#M.queue.rows == 2)
assert(M.queue.rows[1].name == "best" and M.queue.rows[2].name == "mid")
assert(M.results[1].name == "best" and M.results[3].name == "low") -- UI order matches the buy order

-- Rows are only appended while scanning; sorting happens at checkpoints, not per insert.
reset()
local sorts, realSort = 0, table.sort
table.sort = function(...) sorts = sorts + 1; return realSort(...) end
M.db.settings.maxCost, M.db.settings.budget = 1000000, 100000000
M.results, M.candidates = {}, {}
M.scan = { phase = "processing", pendingByItem = {}, failedItems = {}, pendingCount = 0,
    failedRows = 0, invalidRows = 0, checked = 0, total = 600 }
for i = 0, 599 do
    assert(M:ValueRow(row(i, 2 + (i * 7) % 11, 150)))
end
assert(#M.results == 600 and sorts == 0 and M.resultsDirty)
M.scan.checked = 600
M:ScanProgress()
assert(sorts == 1 and not M.resultsDirty and M.scan == nil)
for i = 2, #M.results do
    local x, y = M.results[i - 1], M.results[i]
    assert(x.profit > y.profit or (x.profit == y.profit and x.snapshotIndex < y.snapshotIndex))
end
-- A scan stopped mid-way still leaves a sorted list before a batch is built.
M.scan = { phase = "processing", pendingByItem = {}, failedItems = {}, pendingCount = 0,
    failedRows = 0, invalidRows = 0, checked = 0, total = 10 }
M.results, M.candidates = {}, {}
for i = 0, 5 do M:ValueRow(row(i, 2 + i, 150)) end
M:StopScan()
assert(M.results[1].quantity == 7 and M.results[6].quantity == 2)
table.sort = realSort

-- Refilter re-ranks after setting changes; ties keep snapshot order.
reset()
M.candidates = {}
for i = 0, 5 do
    M.candidates[#M.candidates + 1] = { name = "r" .. i, itemID = 1, link = link(1), vendor = 100, quality = 1,
        quantity = 3 + (i % 3), cost = 100, snapshotIndex = i }
end
M:Refilter()
assert(#M.results == 6 and M.page == 1)
assert(M.results[1].quantity == 5 and M.results[1].snapshotIndex == 2 and M.results[2].snapshotIndex == 5)
M.db.settings.minProfit = 300
M:Refilter()
assert(#M.results == 4 and M.results[1].quantity == 5 and M.results[4].quantity == 4)

-- Demo results are ranked too.
M.Show = function() end
M.db.settings.minProfit = 1
M:Demo()
for i = 2, #M.results do assert(M.results[i - 1].profit >= M.results[i].profit) end
''')
print("PASS: deal ranking (comparator, batch selection, checkpoint sorting, refilter, demo)")
