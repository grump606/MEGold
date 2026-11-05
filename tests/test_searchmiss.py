"""A failed item search records why nothing matched, without affecting the buying outcome."""
from support import make_queue_runtime

lua, module = make_queue_runtime()
lua.execute('''
reset()
local logged
function M:LogState(category, message, fields) if category == "search-miss" then logged = fields end end
M:BuildBatch()
C_AuctionHouse.GetReplicateItemInfo = function() return "Test of Magic", nil, 1, 1, nil, 14, 0 end
C_AuctionHouse.GetItemKeyInfo = function() return { itemName = "Test", isCommodity = false } end
M.queue.rows[1].snapshotIndex = 3
results = {
    { auctionID = 1, itemLink = "|Hitem:99:0|h[Other]|h", quantity = 5, buyoutAmount = 300 },   -- other variant
    { auctionID = 2, itemLink = "|Hitem:1:0|h[Test]|h", quantity = 4, buyoutAmount = 300 },     -- wrong quantity
    { auctionID = 3, itemLink = "|Hitem:1:0|h[Test]|h", quantity = 5, buyoutAmount = 301 },     -- over the cap
    { auctionID = 4, itemLink = "|Hitem:1:0|h[Test]|h", quantity = 5, buyoutAmount = 300, containsOwnerItem = true },
}
M:QueueResults({itemID = 1})
assert(M.queue.phase == "blocked" and #bids == 0)
assert(logged and logged.results == 4 and logged.otherIdentity == 1 and logged.otherQuantity == 1)
assert(logged.overPrice == 1 and logged.ownerOrAccount == 1 and logged.failsProfit == 0)
assert(logged.wantedLink == "item:1:0" and logged.wantedQuantity == 5 and logged.wantedCost == 300)
assert(logged.keyName == "Test" and logged.listedName == "Test of Magic" and logged.listedLevel == "14")
assert(logged.sample1:find("item:99:0", 1, true))   -- the fixture key carries no level/suffix fields

-- A failing diagnostic cannot change the outcome.
reset(); M:BuildBatch()
function M:LogState(category) if category == "search-miss" then error("log failed") end end
results = {}
M:QueueResults({itemID = 1})
assert(M.queue.phase == "blocked" and #bids == 0)
''')
print("PASS: failed item searches record a reason breakdown and the diagnostics cannot disturb buying")
