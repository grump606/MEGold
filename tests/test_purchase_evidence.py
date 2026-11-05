"""Purchase gold evidence, the bounded event capture, and the unconfirmed-purchase log."""
from pathlib import Path
import sys
from support import ROOT, make_queue_runtime

sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime

# ---- Queue integration: gold is recorded at the request, capture starts, and the timeout logs evidence.
lua, module = make_queue_runtime()
lua.execute('''
reset(); ready()
local label, money
function M:BeginPurchaseCapture(l, m) label, money = l, m end
local logged
function M:LogState(category, message, fields) if category == "purchase-unconfirmed" or category == "purchase-intent" then logged = fields end end
M:BuyNext()
assert(label == "item-buyout" and money == 10000 and M.account.pending.moneyBefore == 10000)
funds = 9600                                  -- the bid took the gold but no event arrives
timers[#timers]()
assert(M.queue.phase == "uncertain" and logged.goldChange == -400 and logged.moneyBefore == 10000)
M:PurchaseConfirmed(42)
assert(M.account.purchases[1].moneyBefore == nil, "history records stay lean")

-- Without the capture module the purchase still proceeds.
reset(); ready(); M.BeginPurchaseCapture = nil
M:BuyNext(); assert(#bids == 1 and M.queue.phase == "purchasing")
''')

# ---- Event capture: relevant events only, bounded, self-ending, restart-safe.
cap = LuaRuntime(unpack_returned_tuples=True)
cap.execute('''
M, frames, timers, now, money = {}, {}, {}, 0, 10000
function CreateFrame()
    local f = {}
    function f:RegisterEvent() end
    function f:SetScript(name, fn) self[name] = fn end
    function f:RegisterAllEvents() self.all = true end
    function f:UnregisterAllEvents() self.all = false end
    frames[#frames + 1] = f
    return f
end
function GetTime() return now end
function GetServerTime() return 1000 end
function GetMoney() return money end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
''')
module = cap.globals().M
for name in ("Util.lua", "Diagnostics.lua"):
    cap.execute((ROOT / "MEGold" / name).read_text(encoding="utf-8"), "MEGold", module)
cap.execute('''
M.diagnostics = { enabled = true, entries = {}, next = 1, count = 0, sequence = 0, dropped = 0 }
local function entries() local out = {} for i = 1, M.diagnostics.count do out[#out + 1] = M.diagnostics.entries[i] end return out end

M:BeginPurchaseCapture("item-buyout", 10400)
local frame = M.captureFrame
assert(frame.all == true)
frame.OnEvent(frame, "UNIT_AURA", "player")                    -- irrelevant noise is dropped
frame.OnEvent(frame, "PLAYER_MONEY")
frame.OnEvent(frame, "CHAT_MSG_SYSTEM", "You won an auction for [Stave]")
frame.OnEvent(frame, "AUCTION_HOUSE_PURCHASE_COMPLETED", 42, { itemID = 1 })
local list = entries()
assert(#list == 4 and list[1].message == "Purchase event capture started")
assert(list[2].message == "PLAYER_MONEY" and list[3].context:find("arg1=You won an auction", 1, true))
assert(list[4].message == "AUCTION_HOUSE_PURCHASE_COMPLETED" and list[4].context:find("arg2=table", 1, true))
assert(list[4].context:find("arg1=42", 1, true))
timers[1]()
assert(frame.all == false and frame.token == nil)
list = entries()
assert(list[#list].message == "Purchase event capture ended" and list[#list].context:find("moneyChange=-400", 1, true))
frame.OnEvent(frame, "PLAYER_MONEY"); assert(#entries() == #list, "nothing is logged after the window")

-- Bounded: a flood of events cannot overrun the log.
M.diagnostics = { enabled = true, entries = {}, next = 1, count = 0, sequence = 0, dropped = 0 }
timers = {}
M:BeginPurchaseCapture("flood", nil)
for i = 1, 500 do frame.OnEvent(frame, "AUCTION_SPAM", i) end
assert(M.diagnostics.count <= 62)

-- A restarted capture ignores the first window's timer.
timers = {}
M:BeginPurchaseCapture("first", nil)
M:BeginPurchaseCapture("second", nil)
timers[1]()
assert(frame.all == true and frame.token ~= nil, "the stale timer must not end the new window")
timers[2](); assert(frame.all == false)

-- Disabled diagnostics or a client without RegisterAllEvents: no capture, no error.
M.diagnostics.enabled = false
M:BeginPurchaseCapture("off", nil); assert(frame.all == false)
M.diagnostics.enabled = true; frame.RegisterAllEvents = nil
M:BeginPurchaseCapture("unsupported", nil)
''')
print("PASS: gold evidence, bounded purchase-window event capture, and unconfirmed-purchase logging")
