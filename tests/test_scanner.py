"""Scanner regressions run actual Lua 5.1 with a deterministic item-data clock."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
M = {}
now, timers, listingRows, cache, requests, reads = 0, {}, {}, {}, {}, 0
local serial = 0
C_Timer = { After = function(delay, callback)
    serial = serial + 1
    timers[#timers + 1] = {at = now + delay, callback = callback, serial = serial}
end }
function advance(to)
    while true do
        table.sort(timers, function(a,b) return a.at == b.at and a.serial < b.serial or a.at < b.at end)
        if #timers == 0 or timers[1].at > to then now = to; return end
        local timer = table.remove(timers, 1); now = timer.at; timer.callback()
    end
end
function GetMoney() return 10000000 end
function M:QueueBusy() return false end
function M:SetStatus(message) self.status = message end
function M:Show() end
C_Item = {
    GetItemInfo = function(link)
        reads = reads + 1
        local id = tonumber(link:match("item:(%d+)"))
        if cache[id] then return "Item " .. id, link, 1, nil, nil, nil, nil, nil, nil, nil, cache[id] end
    end,
    RequestLoadItemDataByID = function(id) requests[id] = (requests[id] or 0) + 1 end,
}
C_AuctionHouse = {
    ReplicateItems = function() end,
    GetNumReplicateItems = function() return #listingRows end,
    GetReplicateItemLink = function(index)
        local row = listingRows[index + 1]
        if row.linkMissing then return nil end
        return "|Hitem:" .. row.id .. ":0|h[Test]|h"
    end,
    GetReplicateItemInfo = function(index)
        local row = listingRows[index + 1]
        return "Item", nil, row.quantity or 5, 1, nil, nil, nil, nil, nil, row.cost or 300,
            nil, nil, nil, nil, nil, nil, row.id
    end,
}
function reset(rows)
    now, timers, listingRows, cache, requests, reads = 0, {}, rows, {}, {}, 0
    M.scan, M.account, M.results, M.candidates = nil, {spent = 0}, {}, {}
    M.ahOpen = true
    M.db = {settings = {minProfit = 1, minReturn = 0, maxCost = 100000,
        budget = 10000000, reserve = 0, ignored = {}, buyRarities = {}}}
end
''')
module = lua.globals().M
for source in ("Rules.lua", "Scanner.lua"):
    lua.execute((ROOT / "MEGold" / source).read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
-- A missing/unsupported client adapter blocks scanning before calling any API.
reset({{id = 1}})
M.Supports = function() return false, "adapter unavailable" end
M:StartScan(); assert(not M.scan and M.status == "adapter unavailable")
M.Supports = nil

-- Requests deduplicate by item ID and an event touches only that ID's rows.
reset({{id = 1}, {id = 1}, {id = 2}})
M:StartScan(); M:ReadSnapshot()
assert(requests[1] == 1 and requests[2] == 1 and M.scan.pendingCount == 3)
cache[1] = 100
local prior = reads
M:RetryPending(1, true)
assert(reads - prior == 2 and #M.results == 2 and M.scan.pendingCount == 1)
M:RetryPending(1, true)
assert(#M.results == 2)
cache[2] = 100; M:RetryPending(2, true)
assert(not M.scan and #M.results == 3)
advance(30)
assert(#M.results == 3)

-- No events at all: requests stop after three attempts and the scan becomes restartable.
reset({{id = 1}, {id = 1}})
M:StartScan(); M:ReadSnapshot(); advance(30)
assert(not M.scan and requests[1] == 3 and M.lastScan.unavailable == 2)
M:StartScan(); assert(M.scan and M.scan.phase == "waiting")

-- Explicit failure events retry, but duplicate events cannot multiply requests/timers.
reset({{id = 1}})
M:StartScan(); M:ReadSnapshot()
M:RetryPending(1, false); M:RetryPending(1, false)
advance(1); assert(requests[1] == 2)
M:RetryPending(1, false); advance(2); assert(requests[1] == 3)
M:RetryPending(1, false)
assert(not M.scan and M.lastScan.unavailable == 1)
advance(30); assert(requests[1] == 3)

-- Timers and events from a cancelled generation do not mutate a fresh scan.
reset({{id = 1}})
M:StartScan(); M:ReadSnapshot(); M:StopScan()
listingRows = {{id = 2}}; cache[2] = 100
M:StartScan(); local fresh = M.scan
M:RetryPending(1, true); advance(6)
assert(M.scan == fresh and requests[1] == 1)
M:ReadSnapshot(); assert(not M.scan and #M.results == 1 and M.results[1].itemID == 2)

-- Chunk cancellation prevents queued work from processing the rest of the snapshot.
local rows = {}
for i = 1, 250 do rows[i] = {id = 1} end
reset(rows); cache[1] = 100
M:StartScan(); M:ReadSnapshot()
assert(M.scan.checked == 100 and #M.results == 100)
M:StopScan(); advance(30)
assert(not M.scan and #M.results == 100)

-- Invalid numbers and unsafe vendor products cannot become buy opportunities.
reset({{id = 1, cost = 0/0}, {id = 2, quantity = math.huge}, {id = 3}})
cache[3] = math.huge
M:StartScan(); M:ReadSnapshot()
assert(not M.scan and #M.results == 0 and M.lastScan.invalid == 3)
reset({{id = 1}}); cache[1] = -1
M:StartScan(); M:ReadSnapshot()
assert(not M.scan and #M.results == 0 and M.lastScan.invalid == 1)

-- Missing links and API failures also have bounded recovery.
reset({{id = 1, linkMissing = true}}); cache[1] = 100
M:StartScan(); M:ReadSnapshot(); advance(30)
assert(not M.scan and M.lastScan.unavailable == 1 and requests[1] == 3)
reset({{id = 1}})
local originalRequest = C_Item.RequestLoadItemDataByID
C_Item.RequestLoadItemDataByID = function(id)
    requests[id] = (requests[id] or 0) + 1
    error("item request failed")
end
M:StartScan(); M:ReadSnapshot(); advance(30)
assert(not M.scan and requests[1] == 3 and M.lastScan.unavailable == 1)
C_Item.RequestLoadItemDataByID = originalRequest

-- A mismatched replicate link is rejected rather than priced under a different ID.
reset({{id = 1}}); cache[2] = 100
local originalLink = C_AuctionHouse.GetReplicateItemLink
C_AuctionHouse.GetReplicateItemLink = function() return "|Hitem:2:0|h[Other]|h" end
M:StartScan(); M:ReadSnapshot()
assert(not M.scan and #M.results == 0 and M.lastScan.invalid == 1)
C_AuctionHouse.GetReplicateItemLink = originalLink
''')
print("PASS: indexed/deduplicated scanner requests, bounded retries, missing-data expiry, cancellation and invalid data")
