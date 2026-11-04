"""Audited storage-lock recovery: allowed only for quarantined local data, never for future schemas."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
stamp = 100 * 86400
function GetServerTime() return stamp end
messages, popups, logs, refreshes = {}, {}, {}, 0
StaticPopupDialogs = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) messages[#messages + 1] = text end }
function StaticPopup_Show(which, text) popups[#popups + 1] = { which = which, text = text } end
M = {}
function M:LogState(category, message, fields) logs[#logs + 1] = { category = category, message = message, fields = fields } end
function M:Refresh() refreshes = refreshes + 1 end
function purchase()
    return { itemID = 1, name = "Test", link = "|Hitem:1:0|h[Test]|h", quantity = 3,
        cost = 100, collected = 3, sold = 3, costSold = 100, confirmedAt = 86400 }
end
function account()
    return { spent = 100, purchases = {purchase()}, bought = {[42] = true}, sales = {}, reviews = {}, budgetHistory = {}, vendorReviews = {} }
end
function load(db, key)
    M.db = M:InitializeStorage(db)
    M.account = M:GetStoredAccount(key or "player")
    M.queue = { phase = "idle", message = M.account.storageLocked and ("Transactions locked: " .. M.account.storageLocked) or nil }
    return M.db
end
''')
module = lua.globals().M
lua.execute('M.defaults = { batchSize = 10, minProfit = 1, minReturn = 0, maxCost = 100000, budget = 1000000, reserve = 0 }')
for filename in ("Util.lua", "Storage.lua", "Recovery.lua"):
    lua.execute((ROOT / "MEGold" / filename).read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
-- 1. A locked, quarantined account can be recovered after confirmation, keeping samples and auditing.
local bad = account(); bad.purchases[1].quantity = 0
load({accounts = {player = bad}})
assert(M.account.storageLocked and M.account.purchases[1].quarantined and #M.account.quarantine == 1)
assert(M:RequestUnlock() and #popups == 1 and popups[1].which == "MEGOLD_UNLOCK_STORAGE")
assert(popups[1].text:find("purchases[1]", 1, true) and popups[1].text:find("invalid financial record", 1, true))
assert(M.account.storageLocked) -- nothing changes until the user accepts
StaticPopupDialogs.MEGOLD_UNLOCK_STORAGE.OnAccept()
assert(not M.account.storageLocked and not M.db.storageLocked and #M.account.quarantine == 1)
assert(#M.account.recoveries == 1 and M.account.recoveries[1].quarantined == 1 and M.account.recoveries[1].at == stamp)
assert(M.account.recoveries[1].paths[1]:find("purchases[1]", 1, true) and M.queue.message == nil)
assert(logs[#logs].category == "recovery" and refreshes > 0)
-- Not re-locked on the next load: quarantined placeholders are valid records.
local db = M.db
load(db)
assert(not M.account.storageLocked and #M.account.recoveries == 1 and #M.account.quarantine == 1)
-- And unlocking an unlocked account is refused.
local ok, reason = M:RequestUnlock()
assert(not ok and reason:find("not locked", 1, true))

-- 2. Pending purchase / vendor intents block recovery.
bad = account(); bad.purchases[1].quantity = 0
load({accounts = {player = bad}})
M.account.pending = {itemID = 1, quantity = 1, cost = 1, commodity = true, link = "|Hitem:1|h[x]|h"}
ok, reason = M:UnlockStorage()
assert(not ok and reason:find("purchase is unresolved", 1, true) and M.account.storageLocked)
M.account.pending = nil
M.account.vendorPending = {link = "|Hitem:1:0|h[Test]|h", quantity = 1}
ok, reason = M:RequestUnlock()
assert(not ok and reason:find("vendor sale", 1, true) and M.account.storageLocked and #popups == 1)
M.account.vendorPending = nil
assert(M:UnlockStorage() and not M.account.storageLocked)

-- 3. Future / unsupported schema locks stay locked.
local future = {schemaVersion = 500, accounts = {player = {unknown = {gold = 1}}}}
load(future)
assert(M.db.storageLocked and M.account.storageLocked)
ok, reason = M:UnlockStorage()
assert(not ok and reason:find("unsupported", 1, true) and M.db.storageLocked and M.account.storageLocked)
assert(M.db.futureData == future and not M.account.recoveries or #M.account.recoveries == 0)
ok = M:RequestUnlock()
assert(not ok and #popups == 1)

-- 4. A db-level (settings) lock is cleared for non-future schemas.
load({settings = {budget = "oops"}, accounts = {player = account()}})
assert(M.db.storageLocked and M.account.storageLocked and #M.db.quarantine == 1)
assert(M:RequestUnlock() and popups[#popups].text:find("settings.budget", 1, true))
assert(M:UnlockStorage())
assert(not M.db.storageLocked and not M.account.storageLocked and #M.db.quarantine == 1)
assert(M.account.recoveries[1].dbReason ~= nil)
load(M.db)
assert(not M.db.storageLocked and not M.account.storageLocked and M.db.settings.budget == 1000000)

-- 5. Data that would simply lock again is refused instead of cleared.
bad = account()
bad.sales = {{ link = "|Hitem:1:0|h[Test]|h", quantity = 3, proceeds = 300, flipQuantity = 3,
    flipProceeds = 300, cost = 100, at = 86400, allocations = {{purchase = 1, quantity = 3, cost = 100}} }}
bad.purchases[1].sold, bad.purchases[1].costSold = 1, 30
load({accounts = {player = bad}})
assert(M.account.storageLocked)
ok, reason = M:UnlockStorage()
assert(not ok and reason:find("would lock again", 1, true) and M.account.storageLocked)

-- 6. The audit list is bounded to 200.
bad = account(); bad.purchases[1].quantity = 0
load({accounts = {player = bad}})
local first = M.account
first.recoveries = {}
for i = 1, 205 do first.recoveries[i] = {at = i, quarantined = 0, paths = {}} end
assert(M:UnlockStorage())
assert(#first.recoveries == 200 and first.recoveries[1].at == 7 and first.recoveries[200].at == stamp)

-- 7. Malformed saved recoveries are quarantined by validation.
bad = account(); bad.recoveries = "oops"
load({accounts = {player = bad}})
assert(M.account.storageLocked and type(M.account.recoveries) == "table")
''')
print("PASS: storage recovery (confirmation, audit, pending/future refusal, relock safety, bounds)")
