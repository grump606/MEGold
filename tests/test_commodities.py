"""Commodity firm quotes, attribution and recovery use the actual Lua implementation."""
from support import ROOT, make_queue_runtime

lua, module = make_queue_runtime()

lua.execute('''
quoteRequests, confirms, cancels, quoteSeconds = 0, 0, 0, 20
tiers = { {quantity = 2, unitPrice = 50}, {quantity = 3, unitPrice = 60} }
C_AuctionHouse.GetNumCommoditySearchResults = function() return #tiers end
C_AuctionHouse.GetCommoditySearchResultInfo = function(id, index) return tiers[index] end
C_AuctionHouse.StartCommoditiesPurchase = function() quoteRequests = quoteRequests + 1 end
C_AuctionHouse.ConfirmCommoditiesPurchase = function() confirms = confirms + 1 end
C_AuctionHouse.CancelCommoditiesPurchase = function() cancels = cancels + 1 end
C_AuctionHouse.GetQuoteDurationRemaining = function() return quoteSeconds end
function hooksecurefunc(target, name, callback)
    local original = target[name]
    target[name] = function(...)
        local value = original(...)
        callback(...)
        return value
    end
end
local original = C_Item.GetItemInfo
C_Item.GetItemInfo = function(link)
    if type(link) == "number" then link = "|Hitem:" .. link .. ":0|h[Test]|h" end
    return original(link)
end
function commodityReady()
    reset(); commodity = true
    quoteRequests, confirms, cancels, quoteSeconds = 0, 0, 0, 20
    tiers = { {quantity = 2, unitPrice = 50}, {quantity = 3, unitPrice = 60} }
    M:BuildBatch(); M:CommodityResults(1)
    assert(M.queue.phase == "ready" and M.queue.ready.cost == 280)
end
''')
lua.execute((ROOT / "MEGold" / "Commodities.lua").read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
commodityReady(); M:BuyNext()
assert(quoteRequests == 1 and not M.account.pending)
M:CommodityQuote(56, 280)
assert(M.queue.phase == "quoted")
M:ConfirmCommodity(); M:ConfirmCommodity()
assert(confirms == 1 and M.account.pending and M.account.spent == 0)
M:CommodityPurchased(2, 5); M:CommodityPurchased(1, 4)
assert(M.account.pending and #M.account.purchases == 0)
M:CommodityPurchased(1, 5); M:CommodityPurchased(1, 5)
assert(not M.account.pending and #M.account.purchases == 1 and M.account.spent == 280)

commodityReady(); M:BuyNext(); M:CommodityQuote(61, 305)
assert(M.queue.phase == "blocked" and confirms == 0 and cancels == 1)
commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280)
quoteSeconds = 0; M:ConfirmCommodity()
assert(confirms == 0 and M.queue.phase == "ready")
commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280)
M.db.settings.minProfit = 221; M:ConfirmCommodity()
assert(confirms == 0 and M.queue.phase == "blocked")
commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280); M:ConfirmCommodity()
timers[#timers]()
assert(M.queue.phase == "uncertain")
M.account.pending.conflicted = true; M:CommodityPurchased(1, 5)
assert(M.account.pending)

commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280); M:SkipDeal()
assert(cancels == 1 and confirms == 0 and M.queue.phase == "idle")
commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280)
M.ahOpen = false; M:CloseQueue()
assert(cancels == 1 and M.queue.phase == "idle")
reset(); commodity = true; tiers = {{quantity = 1, unitPrice = 50}}
M:BuildBatch(); M:CommodityResults(1)
assert(M.queue.phase == "blocked")
commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280)
C_AuctionHouse.StartCommoditiesPurchase(2, 1)
assert(M.queue.phase == "blocked" and not M.queue.ownsQuote)
M:ConfirmCommodity(); assert(confirms == 0)
commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280); M:ConfirmCommodity()
C_AuctionHouse.ConfirmCommoditiesPurchase(2, 1)
assert(M.account.pending.conflicted and M.queue.phase == "uncertain")
M:CommodityPurchased(1, 5); assert(M.account.pending)
''')

lua.execute('StaticPopupDialogs = {}')
lua.execute((ROOT / "MEGold" / "Ledger.lua").read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
M.ShowLedger = function() end
commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280); M:ConfirmCommodity()
local entry = M.account.pending
M:ResolvePending(entry, true) -- cannot manually resolve a purchase still in flight
assert(M.account.pending)
M.queue.phase = "uncertain"
M:ResolvePending({}, true)
assert(M.account.pending)
M:ResolvePending(entry, true)
assert(not M.account.pending and M.account.spent == 280 and #M.account.purchases == 1)
assert(M.account.purchases[1].confirmation == "manual review")
commodityReady(); M:BuyNext(); M:CommodityQuote(56, 280); M:ConfirmCommodity()
entry = M.account.pending; M.queue.phase = "uncertain"
M:ResolvePending(entry, false)
assert(not M.account.pending and M.account.spent == 0 and #M.account.reviews == 1)
''')
print("PASS: tier totals, firm caps, quote expiry, transaction matching, cancellation, and manual reconciliation")
