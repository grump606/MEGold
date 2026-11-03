"""Real Lua accounting and vendor flow with deterministic inventory state."""
from support import ROOT, make_vendor_runtime

lua, module = make_vendor_runtime()

lua.execute('''
vendorReset(100)
local purchase = addPurchase(100, 1, 100)
local a = M:RecordVendorSale(purchase.link, 99, 9900, 99)
local b = M:RecordVendorSale(purchase.link, 1, 100, 1)
assert(M:GetProfitTally().cost == 1)
assert(M:ReverseVendorSale(a))
assert(not M:ReverseVendorSale(a))
M:RecordVendorSale(purchase.link, 99, 9900, 99)
assert(M:GetProfitTally().cost == 1 and purchase.sold == 100)
assert(not M:RecordVendorSale(purchase.link, 1, 100, 1))
assert(M:GetProfitTally().profit == 9999)

vendorReset(10)
bags[1].stackCount, funds = 7, funds + 300
buyback = {{link = bags[1].hyperlink, quantity = 3, price = 300}}
M:ObserveVendor()
assert(M:GetProfitTally().otherProceeds == 300)
M:ObserveVendor(); assert(#M.account.sales == 1) -- duplicate event
purchase = addPurchase(3, 100, 3)
bags[1].stackCount, funds = 5, funds + 200
table.insert(buyback, {link = purchase.link, quantity = 2, price = 200})
M:ObserveVendor()
assert(M:GetProfitTally().cost == 66 and M:GetProfitTally().profit == 134)
bags[1].stackCount, funds = 7, funds - 200
table.remove(buyback)
M:ObserveVendor()
assert(M:GetProfitTally().profit == 0 and M:GetProfitTally().otherProceeds == 300)
assert(purchase.sold == 0 and purchase.costSold == 0)

-- A mixed stack is split, exactly three flips are sold, seven personal units remain.
vendorReset(10); purchase = addPurchase(3, 100, 3)
local review = M:BuildVendorReview()
assert(#review == 1 and review[1].quantity == 3 and review[1].stackCount == 10)
M:StartVendorSale()
assert(bags[1].stackCount == 7 and bags[2].stackCount == 3 and M.vendorRun.phase == "splitting")
timers[#timers]() -- split verification and sale request
assert(bags[1].stackCount == 7 and not bags[2] and M.account.vendorPending)
M:ObserveVendor()
assert(purchase.sold == 3 and M:GetProfitTally().profit == 200 and not M.account.vendorPending)
timers[#timers]() -- advance after verified receipt
assert(not M.vendorRun)

vendorReset(10); purchase = addPurchase(3, 100, 0)
assert(#M:BuildVendorReview() == 0)
assert(M:MarkCollected(purchase))
assert(#M:BuildVendorReview() == 1)
purchase.held = true; assert(#M:BuildVendorReview() == 0)
purchase.held = false; M.db.settings.neverSell[1] = true
assert(#M:BuildVendorReview() == 0)
M.db.settings.neverSell[1] = nil; M.db.settings.sellRarities[1] = false
assert(#M:BuildVendorReview() == 0)
M.db.settings.sellRarities[1] = true; bags[1].isBound = true
assert(#M:BuildVendorReview() == 0)
bags[1].isBound = nil; bags[1].isLocked = true
assert(#M:BuildVendorReview() == 0)

-- A reload between the sale request and receipt locks further selling.
vendorReset(3); purchase = addPurchase(3, 100, 3)
M:BuildVendorReview(); M:StartVendorSale(); M:InitializeQueue()
assert(M.account.vendorUncertain and M.account.vendorPending)
M:ExcludeUncertainVendorActivity()
assert(not M.account.vendorUncertain and not M.account.vendorPending and purchase.held and purchase.collected == 0)
assert(M:GetProfitTally().profit == 0)

-- Money and bag events arriving separately must not double-count or advance the baseline early.
vendorReset(3)
funds = funds + 300; M:ObserveVendor()
assert(M.vendorSnapshot.money == 10000)
bags[1] = nil; buyback = {{link = "|Hitem:1:0|h[Test]|h", quantity = 3, price = 300}}
M:ObserveVendor()
assert(M:GetProfitTally().otherProceeds == 300)
vendorReset(10); purchase = addPurchase(3, 100, 3)
M:ReconcileInventory(M:BagTotals())
bags[1].stackCount = 9
M:ReconcileInventory(M:BagTotals())
assert(purchase.held and purchase.collected == 0 and M:AvailableFlips(purchase.link) == 0)
vendorReset(3); purchase = addPurchase(3, 100, 3); purchase.held = true
assert(#M:BuildVendorReview() == 0)
bags[1] = nil; funds = funds + 300
buyback = {{link = purchase.link, quantity = 3, price = 300}}
M:ObserveVendor()
assert(M:GetProfitTally().profit == 200) -- manual sale of held flips still has known cost
vendorReset(3); purchase = addPurchase(3, 100, 3)
for i = 1, 12 do buyback[i] = {link = purchase.link, quantity = 3, price = 300} end
M.vendorSnapshot.rows = M:ReadBuyback()
M:BuildVendorReview(); M:StartVendorSale(); M:ObserveVendor()
assert(M:GetProfitTally().profit == 200 and not M.account.vendorUncertain)
''')
print("PASS: separate tallies, exact cost conservation, buyback reversal, mixed-stack splitting, collection/rarity/hold protections, and reload recovery")
