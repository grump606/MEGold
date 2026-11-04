"""Characterization tests for ObserveVendor paths (identical ring, ambiguous removal, mismatch, reversal)."""
from support import make_vendor_runtime

lua, module = make_vendor_runtime()
lua.execute('''
local LINK = "|Hitem:1:0|h[Test]|h"
local function snapshotRef() return M.vendorSnapshot end

-- 1. Unchanged identical full ring, nothing moved: snapshot is re-committed (same content), no sale.
vendorReset(3); addPurchase(3, 100, 3)
for i = 1, 12 do buyback[i] = {link = LINK, quantity = 3, price = 300} end
M.vendorSnapshot.rows = M:ReadBuyback()
M:ObserveVendor()
assert(#snapshotRef().rows == 12 and not M.account.vendorUncertain and #(M.account.sales or {}) == 0)
local snap = snapshotRef()

-- 2. Identical ring, money changed only: wait for bag event (no commit, no uncertainty).
funds = funds + 300
M:ObserveVendor()
assert(snapshotRef() == snap and not M.account.vendorUncertain)

-- 3. Identical ring, gold gained and bags lost: cannot identify the sale -> uncertain.
bags[1] = nil
M:ObserveVendor()
assert(M.account.vendorUncertain and M.account.vendorUncertain.reason:find("identical buyback"))
assert(snapshotRef() == snap and #(M.account.sales or {}) == 0)

-- 4. Ambiguous removal: two identical rows, one disappears -> never guess, nothing changes.
vendorReset(3); local p = addPurchase(3, 100, 3)
buyback = {{link = LINK, quantity = 1, price = 100}, {link = LINK, quantity = 1, price = 100}}
M.vendorSnapshot.rows = M:ReadBuyback()
M.vendorSnapshot.rows[1].receipt, M.vendorSnapshot.rows[2].receipt = "r1", "r2"
snap = snapshotRef()
table.remove(buyback)
funds = funds - 100; bags[1].stackCount = bags[1].stackCount + 1
local reversed = 0
local origReverse = M.ReverseVendorSale
M.ReverseVendorSale = function(...) reversed = reversed + 1; return origReverse(...) end
M:ObserveVendor()
M.ReverseVendorSale = origReverse
assert(reversed == 0 and snapshotRef() == snap and not M.account.vendorUncertain)

-- 5. Reversal with incomplete evidence (bags not yet back) leaves everything alone;
--    once both money and bags match, the receipt is reversed and receipts carry over.
vendorReset(10); p = addPurchase(3, 100, 3)
bags[1].stackCount, funds = 7, funds + 300
buyback = {{link = LINK, quantity = 3, price = 300}}
M:ObserveVendor()
assert(p.sold == 3 and #(M.account.sales or {}) == 1)
local rowsAfterSale = M.vendorSnapshot.rows
table.remove(buyback)
funds = funds - 300
M:ObserveVendor()
assert(M.vendorSnapshot.rows == rowsAfterSale and p.sold == 3, "reversal must wait for bag gain")
bags[1].stackCount = 10
M:ObserveVendor()
assert(p.sold == 0 and #M.vendorSnapshot.rows == 0 and M.vendorSnapshot.money == funds)

-- 6. Reconcile receives exactly the explained sale quantities, before the baseline is replaced.
vendorReset(10); p = addPurchase(3, 100, 3)
local calls = {}
local origReconcile = M.ReconcileInventory
M.ReconcileInventory = function(self, totals, explained)
    calls[#calls + 1] = {totals = totals, explained = explained, baseline = M.vendorSnapshot}
    return origReconcile(self, totals, explained)
end
local before = snapshotRef()
bags[1].stackCount, funds = 7, funds + 300
buyback = {{link = LINK, quantity = 3, price = 300}}
M:ObserveVendor()
assert(#calls == 1 and calls[1].explained["item:1:0"] == 3 and calls[1].baseline == before)
assert(calls[1].totals["item:1:0"] == 7 and M.vendorSnapshot ~= before)
-- Reversal and unchanged commits pass no explained quantities.
table.remove(buyback); funds = funds - 300; bags[1].stackCount = 10
M:ObserveVendor()
assert(#calls == 2 and calls[2].explained == nil)
M.ReconcileInventory = origReconcile

-- 7. Active sale whose response does not match its reservation -> uncertain, run cleared.
vendorReset(3); p = addPurchase(3, 100, 3)
M:BuildVendorReview(); M:StartVendorSale()
assert(M.vendorRun and M.vendorRun.activeSale and M.account.vendorPending)
M.account.vendorPending.token = {}
M:ObserveVendor()
assert(M.account.vendorUncertain and M.account.vendorUncertain.reason:find("did not match"))
assert(M.vendorRun == nil and (p.sold or 0) == 0 and #(M.account.sales or {}) == 0)

-- 8. Sale evidence incomplete (money arrived, bags not): nothing recorded, no uncertainty.
vendorReset(3); p = addPurchase(3, 100, 3)
funds = funds + 300
buyback = {{link = LINK, quantity = 3, price = 300}}
M:ObserveVendor()
assert((p.sold or 0) == 0 and not M.account.vendorUncertain and #M.vendorSnapshot.rows == 0)

-- 9. Own sale with a full ring of identical entries advances the run.
vendorReset(3); p = addPurchase(3, 100, 3)
for i = 1, 12 do buyback[i] = {link = LINK, quantity = 3, price = 300} end
M.vendorSnapshot.rows = M:ReadBuyback()
M:BuildVendorReview(); M:StartVendorSale(); M:ObserveVendor()
assert(p.sold == 3 and not M.account.vendorPending and not M.account.vendorUncertain)
assert(M.vendorRun.phase == "next" and M.vendorRun.index == 2)

-- 4b. Ambiguous removal inside a ring ([X,A,A,Y] -> [X,A,Y]) must not fall through to new-sale recording,
--     even when the gold change would match the remaining rows' total.
vendorReset(10); p = addPurchase(3, 100, 3)
local function row(id, price) return {link = "|Hitem:" .. id .. ":0|h[T]|h", quantity = 1, price = price} end
buyback = {row(1, 100), row(1, 100), row(1, 100), row(1, 100)}
M.vendorSnapshot.rows = M:ReadBuyback()
snap = snapshotRef()
buyback = {row(1, 100), row(1, 100), row(1, 100)}
M:ObserveVendor()
assert(snapshotRef() == snap, "snap"); assert(#(M.account.sales or {}) == 0, "sales"); assert((p.sold or 0) == 0, "sold")
''')
print("PASS: ObserveVendor identical ring, ambiguous removal, reversal, explained quantities and sale-mismatch paths")
