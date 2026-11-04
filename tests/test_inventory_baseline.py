"""Inventory baseline race regressions using the real registered event handlers."""
from support import make_vendor_runtime

lua, module = make_vendor_runtime(capture_events=True)
lua.execute('''
function M:ShowVendor() end
local function setup(stack)
    vendorReset(stack)
    M.merchantOpen, M.vendorSnapshot = false, nil
    M.account.inventoryTotals = M:BagTotals()
end
function other(quantity)
    return { hyperlink = "|Hitem:2:0|h[Other]|h", itemID = 2, stackCount = quantity }
end
function otherPurchase(quantity, collected)
    local p = {name = "Other", itemID = 2, link = "|Hitem:2:0|h[Other]|h", quantity = quantity, cost = 80, collected = collected}
    table.insert(M.account.purchases, p)
    return p
end
function assertRevoked(p)
    assert(p.collected == (p.sold or 0) and p.held and p.inventoryReview, "eligibility not revoked")
end
function assertNoSale()
    M:BuildVendorReview()
    for _, row in ipairs(M.vendorReview) do
        assert(M.ItemIdentity(row.link) ~= "item:1:0", "consumed flips remained sell-eligible")
    end
end

-- 1. Ten units in bags, three tracked; remove three, open merchant before the 0.5s callback.
setup(10)
local flip = addPurchase(3, 150, 3)
bags[1].stackCount = 7
fireEvent("BAG_UPDATE_DELAYED")
fireEvent("MERCHANT_SHOW")
runTimers() -- delayed reconciliation is skipped while the merchant is open
assertRevoked(flip); assertNoSale()
-- Repeated/reordered events cannot restore eligibility.
fireEvent("MERCHANT_SHOW"); fireEvent("MERCHANT_UPDATE"); fireEvent("BAG_UPDATE_DELAYED")
fireEvent("MERCHANT_CLOSED"); fireEvent("MERCHANT_SHOW"); fireEvent("PLAYER_MONEY")
bags[1].stackCount = 10 -- items reappear: still requires explicit collection
fireEvent("BAG_UPDATE_DELAYED"); runTimers(); runTimers()
assertRevoked(flip); assertNoSale()

-- 2. Decrease, then collection confirmation of an unrelated purchase must not adopt the baseline.
setup(10)
flip = addPurchase(3, 150, 3)
local second = otherPurchase(4, 0)
bags[1].stackCount = 7
bags[2] = other(4)
assert(M:MarkCollected(second) and second.collected == 4)
assertRevoked(flip); assertNoSale()
assert(M:MarkCollected(second) == false) -- repeated confirmation is inert
assertRevoked(flip)

-- 3. Same-item collection cannot be satisfied by units that revoked flips already lost.
setup(10)
flip = addPurchase(3, 150, 3)
local again = addPurchase(8, 250, 0)
bags[1].stackCount = 7
assert(not M:MarkCollected(again) and again.collected == 0)
assertRevoked(flip)

-- 4. Closing and re-opening the merchant: a decrease while closed is reconciled on re-open.
setup(10)
flip = addPurchase(3, 150, 3)
fireEvent("MERCHANT_SHOW"); runTimers()
assert(M.merchantOpen and flip.collected == 3 and not flip.held)
fireEvent("MERCHANT_CLOSED")
assert(not M.merchantOpen)
bags[1].stackCount = 7
fireEvent("BAG_UPDATE_DELAYED")
fireEvent("MERCHANT_SHOW") -- before the callback
runTimers()
assertRevoked(flip); assertNoSale()

-- 5. A verified sale of one item must not adopt an unrelated item's concurrent loss.
vendorReset(3); M.merchantOpen = true
bags[2] = other(4)
flip = addPurchase(3, 150, 3)
local unrelated = otherPurchase(4, 4)
M.vendorSnapshot = {rows = {}, money = funds, totals = M:BagTotals()}
M.account.inventoryTotals = M.vendorSnapshot.totals
bags[1], bags[2].stackCount = nil, 2
buyback = {{link = flip.link, quantity = 3, price = 300}}
funds = funds + 300
M:ObserveVendor()
assert(flip.sold == 3 and #M.account.sales == 1, "verified sale was still recorded")
assertRevoked(unrelated)
assert(M.account.inventoryTotals["item:2:0"] == 2)

-- 6. A clean verified sale does not hold anything (no false positives).
vendorReset(3); flip = addPurchase(3, 150, 3)
M.account.inventoryTotals = M:BagTotals()
M:BuildVendorReview(); M:StartVendorSale(); runTimers()
M:ObserveVendor()
assert(flip.sold == 3 and not flip.held and M.account.inventoryTotals["item:1:0"] == nil)
''')
print("PASS: inventory decreases are reconciled before merchant, sale and collection baselines are adopted")
