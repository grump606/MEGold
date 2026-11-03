"""Regression coverage for reserved sale quantities and sale-specific callbacks."""
from support import make_vendor_runtime

lua, module = make_vendor_runtime()
lua.execute('''
-- Automatic selling must consume the unheld purchase it reviewed, not an older held lot.
vendorReset(10)
local held = addPurchase(3, 100, 3); held.held = true
local sellable = addPurchase(3, 150, 3)
M:BuildVendorReview()
assert(#M.vendorReview == 1 and M.vendorReview[1].allocations[1].purchase == 2)
M:StartVendorSale(); timers[#timers](); M:ObserveVendor()
assert((held.sold or 0) == 0 and sellable.sold == 3)
assert(M:AvailableFlips(sellable.link) == 0 and M:GetProfitTally().cost == 150)
timers[#timers]()
assert(#M:BuildVendorReview() == 0 and bags[1].stackCount == 7)

-- Review rows reserve distinct portions even when multiple stacks use the same purchase.
vendorReset(3); bags[2] = item(3)
M.vendorSnapshot.totals = M:BagTotals()
local purchase = addPurchase(6, 200, 6)
M:BuildVendorReview()
assert(#M.vendorReview == 2)
assert(M.vendorReview[1].allocations[1].quantity == 3 and M.vendorReview[2].allocations[1].quantity == 3)
M:StartVendorSale()
local firstTimeout = timers[#timers]
local firstToken = M.vendorRun.activeSale.token
M:ObserveVendor(); timers[#timers]()
local secondToken = M.vendorRun.activeSale.token
assert(secondToken ~= firstToken and M.account.vendorPending.token == secondToken)
local observe = M.ObserveVendor
M.ObserveVendor = function() error("old timeout must not inspect a newer sale") end
firstTimeout()
M.ObserveVendor = observe
assert(not M.account.vendorUncertain and M.vendorRun.activeSale.token == secondToken)
M:ObserveVendor(); M:ObserveVendor()
assert(purchase.sold == 6 and #M.account.sales == 2 and M:GetProfitTally().cost == 200)
firstTimeout() -- a duplicate/late callback remains harmless after confirmation
assert(not M.account.vendorUncertain)

-- Changed held state between review and purchase prevents sending a sale.
vendorReset(3); purchase = addPurchase(3, 100, 3)
M:BuildVendorReview(); purchase.held = true; M:StartVendorSale()
assert(not M.vendorRun and #buyback == 0 and not M.account.vendorPending)

-- An invalid explicit allocation is rejected atomically, never replaced by held-inclusive FIFO.
vendorReset(3); held = addPurchase(3, 100, 3); held.held = true
local receipt = M:RecordVendorSale(held.link, 3, 300, 3, {{purchase = 1, quantity = 3}})
assert(not receipt and not held.sold and not M.account.sales)
receipt = M:RecordVendorSale(held.link, 3, 300, 3)
assert(receipt and held.sold == 3) -- manual sales retain known held-purchase costs

-- Missing/reordered bag and money evidence cannot commit an automatic receipt early.
vendorReset(3); purchase = addPurchase(3, 100, 3)
local sell = C_Container.UseContainerItem
C_Container.UseContainerItem = function() end
M:BuildVendorReview(); M:StartVendorSale()
local timeout = timers[#timers]
buyback = {{link = purchase.link, quantity = 3, price = 300}}
M:ObserveVendor(); assert(not purchase.sold and M.account.vendorPending)
funds = funds + 300
M:ObserveVendor(); assert(not purchase.sold and M.account.vendorPending)
bags[1] = nil
M:ObserveVendor(); M:ObserveVendor()
assert(purchase.sold == 3 and #M.account.sales == 1 and not M.account.vendorPending)
timeout(); assert(not M.account.vendorUncertain)
C_Container.UseContainerItem = sell

-- Cache identity is stable until a financial mutation, and buybacks invalidate it.
vendorReset(3); purchase = addPurchase(3, 100, 3)
local initial = M:GetProfitTally()
assert(rawequal(initial, M:GetProfitTally()))
receipt = M:RecordVendorSale(purchase.link, 3, 300, 3)
local sold = M:GetProfitTally()
assert(not rawequal(initial, sold) and sold.profit == 200)
assert(M:ReverseVendorSale(receipt))
assert(M:GetProfitTally().profit == 0 and not rawequal(sold, M:GetProfitTally()))
M.account.saleArchive = {flipProceeds = 500, cost = 100, otherProceeds = 70, flipQuantity = 5, otherQuantity = 2}
M:InvalidateProfitTally(M.account)
assert(M:GetProfitTally().profit == 400 and M:GetProfitTally().otherProceeds == 70)

-- Malformed-storage and unavailable-client gates disable vendor review before API mutation.
vendorReset(3); addPurchase(3, 100, 3)
M.account.storageLocked = "invalid record"
assert(not M:BuildVendorReview())
M.vendorReview = {{}}
M:StartVendorSale(); assert(not M.vendorRun)
''')
print("PASS: held allocation, per-sale token isolation, reordered evidence, atomic plans, tally cache and vendor safety gates")
