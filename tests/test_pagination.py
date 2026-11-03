"""Search pages, duplicate events, and request-scoped deadlines under Lua 5.1."""
from support import ROOT, make_queue_runtime

lua, module = make_queue_runtime()
lua.execute('''
function resetPages()
    reset(); results, pages, full = {}, 0, false
    C_AuctionHouse.HasFullItemSearchResults = function() return full end
    C_AuctionHouse.RequestMoreItemSearchResults = function() pages = pages + 1 end
end
resetPages(); M:BuildBatch()
local initialTimeout = timers[#timers]
M:QueueResults({itemID = 1})
assert(pages == 1 and M.queue.phase == "paging")
local pageTimeout = timers[#timers]
M:QueueResults({itemID = 1}); M:QueueResults({itemID = 1})
assert(pages == 1) -- duplicate partial-cache events must not send more requests
initialTimeout()
assert(M.queue.phase == "paging") -- an older deadline cannot expire a new page
results = {{auctionID = 42, itemLink = "|Hitem:1:0|h[Test]|h", quantity = 5, buyoutAmount = 300}}
full = true; M:QueueResults({itemID = 1})
assert(M.queue.phase == "ready")
pageTimeout(); assert(M.queue.phase == "ready")

resetPages(); M:BuildBatch(); M:QueueResults({itemID = 1})
timers[#timers]()
assert(M.queue.phase == "blocked") -- a genuinely missing page still times out

resetPages(); M:BuildBatch()
for i = 1, 51 do
    table.insert(results, {auctionID = i, itemLink = "|Hitem:1:99|h[Other variant]|h", quantity = 5, buyoutAmount = 300})
    M:QueueResults({itemID = 1})
end
assert(pages == 50 and M.queue.phase == "blocked")

resetPages(); throttle = false; M:BuildBatch()
assert(#searches == 0)
throttle = true; M:SendQueueSearch(); M:QueueResults({itemID = 1})
assert(pages == 1)
''')
lua.execute('''
C_AuctionHouse.GetNumCommoditySearchResults = function() return #tiers end
C_AuctionHouse.GetCommoditySearchResultInfo = function(_, index) return tiers[index] end
C_AuctionHouse.HasFullCommoditySearchResults = function() return full end
C_AuctionHouse.RequestMoreCommoditySearchResults = function() pages = pages + 1 end
local original = C_Item.GetItemInfo
C_Item.GetItemInfo = function(value)
    if type(value) == "number" then value = "|Hitem:1:0|h[Test]|h" end
    return original(value)
end
''')
lua.execute((ROOT / "MEGold" / "Commodities.lua").read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
resetPages(); commodity = true; tiers = {{quantity = 2, unitPrice = 50}}
M:BuildBatch(); M:CommodityResults(1)
assert(pages == 1 and M.queue.phase == "paging")
M:CommodityResults(1); assert(pages == 1)
table.insert(tiers, {quantity = 3, unitPrice = 60})
full = true; M:CommodityResults(1)
assert(M.queue.phase == "ready" and M.queue.ready.cost == 280)
''')
print("PASS: item/commodity pagination, duplicate-event suppression, per-page deadlines, throttle and page bounds")
