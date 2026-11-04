"""Saved-data migration, fail-closed validation and reference-safe archival under Lua 5.1."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
stamp = 100 * 86400
function GetServerTime() return stamp end
M = {}
function purchase()
    return { itemID = 1, name = "Test", link = "|Hitem:1:0|h[Test]|h", quantity = 3,
        cost = 100, collected = 3, sold = 3, costSold = 100, confirmedAt = 86400 }
end
function account()
    return { spent = 100, purchases = {purchase()}, bought = {[42] = true}, sales = {}, reviews = {}, budgetHistory = {}, vendorReviews = {} }
end
function sale()
    return { link = "|Hitem:1:0|h[Test]|h", quantity = 3, proceeds = 300, flipQuantity = 3,
        flipProceeds = 300, cost = 100, at = 86400, allocations = {{purchase = 1, quantity = 3, cost = 100}} }
end
''')
module = lua.globals().M
lua.execute('M.defaults = { batchSize = 10, minProfit = 1, minReturn = 0, maxCost = 100000, budget = 1000000, reserve = 0 }')
for filename in ("Util.lua", "Storage.lua"):
    lua.execute((ROOT / "MEGold" / filename).read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
local db = M:InitializeStorage(nil)
assert(db.schemaVersion == 1 and db.settings.batchSize == 10)
assert(not db.storageLocked and M:GetStoredAccount("new").spent == 0)
db.settings.sellRarities[0] = false
local other = M:InitializeStorage(nil)
assert(other.settings.sellRarities[0] == true) -- defaults are not shared mutable tables

db = M:InitializeStorage({settings = {budget = "oops", neverSell = {[1] = "true"}}})
assert(db.storageLocked and M:GetStoredAccount("new").storageLocked)
assert(db.settings.budget == 1000000 and #db.quarantine == 2)
local future = {schemaVersion = 500, accounts = {new = {unknownFinancialStructure = {gold = 123}}}}
db = M:InitializeStorage(future)
assert(db.schemaVersion == 500 and db.storageLocked)
assert(db.futureData == future and future.accounts.new.unknownFinancialStructure.gold == 123)
assert(not future.storageLocked and not future.settings)
local reopened = M:InitializeStorage(db)
assert(reopened.futureData == future and reopened.futureData ~= db)
assert(M:GetStoredAccount("new").storageLocked)
db = M:InitializeStorage({accounts = {player = account()}})
assert(not db.storageLocked and not M:GetStoredAccount("player").storageLocked)

local bad = account(); bad.spent = -1
local validated = M:ValidateAccount(bad)
assert(validated.storageLocked and validated.spent > 100000000000)
bad = account(); bad.purchases[1].quantity = 0
validated = M:ValidateAccount(bad)
assert(validated.storageLocked and validated.purchases[1].quarantined)
assert(#validated.purchases == 1) -- array identities remain stable
bad = account(); bad.pending = {itemID = 1, quantity = 1, cost = 1, link = "|Hitem:1|h[x]|h"}
validated = M:ValidateAccount(bad)
assert(validated.storageLocked and not validated.pending)
bad = account(); bad.pending = {itemID = 1, quantity = 1, cost = 1, commodity = true, link = "|Hitem:1|h[x]|h"}
validated = M:ValidateAccount(bad)
assert(not validated.storageLocked and validated.pending)
bad = account(); bad.purchases[1].sold = 4
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.bought = {[9000000000] = true}
assert(not M:ValidateAccount(bad).storageLocked) -- auction IDs are not 32-bit item IDs
bad = account(); bad.vendorPending = {link = purchase().link, quantity = 3, token = 1,
    expectedProceeds = 300, allocations = {{purchase = 1, quantity = 2}}}
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.vendorPending = {link = purchase().link, quantity = 3, token = 1,
    expectedProceeds = 300, allocations = {{purchase = 1, quantity = 3}}}
assert(not M:ValidateAccount(bad).storageLocked)
bad = account(); bad.vendorPending = {link = purchase().link, quantity = 3, token = 1, expectedProceeds = 300, at = 0/0}
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.sales = {{archived = "yes", reversed = true}}
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.vendorUncertain = {reason = {}}
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.archivedAuditCounts = {reviews = "oops"}
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.sales = {sale()}; bad.sales[1].allocations[1].purchase = 99
validated = M:ValidateAccount(bad)
assert(validated.storageLocked and validated.sales[1].quarantined)
bad = account(); bad.sales = {sale()}; bad.buybackRows = {{link = purchase().link, quantity = 3, price = 300, receipt = 99}}
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.sales = false
assert(M:ValidateAccount(bad).storageLocked)
for _, field in ipairs({"name", "status", "confirmation"}) do
    bad = account(); bad.pending = {itemID = 1, quantity = 1, cost = 1, commodity = true, link = "|Hitem:1|h[x]|h"}
    bad.pending[field] = {}
    validated = M:ValidateAccount(bad)
    assert(validated.storageLocked and not validated.pending)
end
bad = account(); bad.purchases[1].itemID = 2
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.pending = {itemID = 2, quantity = 1, cost = 1, commodity = true, link = "|Hitem:1|h[x]|h"}
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.purchases[1].sold = false
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.sales = {sale(), sale()}
assert(M:ValidateAccount(bad).storageLocked) -- duplicated receipt cannot spend its purchase twice
bad = account(); bad.sales = {sale()}; bad.purchases[1].quantity = 6; bad.purchases[1].sold = 3; bad.purchases[1].collected = 6; bad.purchases[1].costSold = 50
assert(M:ValidateAccount(bad).storageLocked) -- receipts exceed accounted purchase cost
bad = account(); bad.sales = {sale()}; bad.sales[1].quantity = 6; bad.sales[1].flipQuantity = 6; bad.sales[1].cost = 200
bad.sales[1].allocations[2] = {purchase = 1, quantity = 3, cost = 100}
assert(M:ValidateAccount(bad).storageLocked) -- duplicated allocation within a receipt
bad = account(); bad.sales = {sale()}; bad.sales[1].link = "|Hitem:1:99|h[Another variant]|h"
assert(M:ValidateAccount(bad).storageLocked)
bad = account(); bad.sales = {sale()}; bad.sales[1].reversed = true
bad.purchases[1].sold = 0; bad.purchases[1].costSold = 0
assert(not M:ValidateAccount(bad).storageLocked) -- reversed allocations do not count as active sold units
bad = account(); bad.sales = {sale()}; bad.sales[1].quantity = 1; bad.sales[1].flipQuantity = 1; bad.sales[1].cost = 33
bad.sales[1].allocations = {{purchase = 1, quantity = 1, cost = 33}}
assert(not M:ValidateAccount(bad).storageLocked) -- other sold units may already be archived

db = M:InitializeStorage({diagnostics = {enabled = false, entries = {
    {sequence = 2, at = 100, category = "test", message = "second"},
    {sequence = 1, at = 100, category = "test", message = "first"},
    {sequence = "invalid", at = 100, category = "test", message = "bad"},
}, next = "corrupt", count = 999}})
assert(db.diagnostics.count == 2 and db.diagnostics.entries[1].message == "first")
assert(db.diagnostics.next == 3 and not db.diagnostics.enabled)

local a = M:ValidateAccount(account()); a.sales = {sale()}
a.buybackRows = {{link = purchase().link, quantity = 3, price = 300, receipt = 1}}
M:MaintainHistory(a)
assert(not a.sales[1].archived and not a.purchases[1].archived) -- live buyback protects both
a.buybackRows = {}
M:MaintainHistory(a)
assert(a.sales[1].archived and a.purchases[1].archived)
assert(a.saleArchive.flipProceeds == 300 and a.saleArchive.cost == 100)
assert(#a.sales == 1 and #a.purchases == 1) -- references stay stable
M:MaintainHistory(a)
assert(a.saleArchive.flipProceeds == 300) -- idempotent archival
assert(a.bought[42] == stamp)
stamp = stamp + 31 * 86400
M:MaintainHistory(a)
assert(a.bought[42] == nil)
local locked = account(); locked.storageLocked = "review needed"; locked.sales = {sale()}
M:MaintainHistory(locked); assert(not locked.sales[1].archived)
local pending = account(); pending.pending = {}; pending.sales = {sale()}
M:MaintainHistory(pending); assert(not pending.sales[1].archived)
assert(not M:ValidateAccount(a).storageLocked) -- archived schema reloads cleanly
''')
print("PASS: saved-data migration, financial validation/quarantine locks, diagnostic repair, safe archival and bounded duplicate guards")
