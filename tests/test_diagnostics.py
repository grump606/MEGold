"""Persistent bounded logs, pause/clear and error forwarding under Lua 5.1."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
function CreateFrame() return {RegisterEvent = function() end, SetScript = function(self, _, fn) self.callback = fn end} end
function GetServerTime() return 12345 end
function GetBuildInfo() return "1.60.1", "123456", "today", 16001 end
WOW_PROJECT_ID = 1
C_AuctionHouse = {ReplicateItems = function() end}
forwarded = 0
handler = function(message) forwarded = forwarded + 1; return "forwarded" end
function geterrorhandler() return handler end
function seterrorhandler(fn) handler = fn end
stack = "Interface/AddOns/MEGold/Queue.lua:100"
function debugstack() return stack end
M = { db = {}, queue = {phase = "ready"}, account = {spent = 123} }
''')
module = lua.globals().M
lua.execute((ROOT / "MEGold" / "Diagnostics.lua").read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
M:InitializeDiagnostics()
local report = M:ExportDiagnostics()
assert(report:find("Build 123456", 1, true) and report:find("replicate=true", 1, true))
M:ClearDiagnostics()
for i = 1, 700 do M:Log("test", "entry-" .. i, {number = i}) end
assert(M.diagnostics.count == 500 and M.diagnostics.dropped == 201)
report = M:ExportDiagnostics()
assert(not report:find("entry-200 |", 1, true))
assert(report:find("entry-201 |", 1, true) < report:find("entry-700 |", 1, true))
local count = M.diagnostics.sequence
M:SetDiagnosticsEnabled(false); M:Log("test", "not-recorded")
assert(M.diagnostics.sequence == count + 1)
M:SetDiagnosticsEnabled(true)
M:ClearDiagnostics()
assert(M.diagnostics.count == 1 and M.diagnostics.dropped == 0)
M:Log("test", string.rep("x", 10000))
assert(#M.diagnostics.entries[2].message == 2048)
assert(handler("addon failure") == "forwarded")
assert(forwarded == 1 and M:ExportDiagnostics():find("[lua-error]", 1, true))
stack = "Interface/AddOns/MEGold/Diagnostics.lua:52\\nInterface/AddOns/OtherAddon/Other.lua:1"
count = M.diagnostics.sequence
handler("unrelated failure")
assert(forwarded == 2 and M.diagnostics.sequence == count)
M.diagnosticEvents.callback(nil, "COMMODITY_PRICE_UPDATED", 10, 100)
assert(M:ExportDiagnostics():find("totalPrice=100", 1, true))
-- Routine events must not serialize arbitrary text payloads.
M.diagnosticEvents.callback(nil, "MERCHANT_SHOW", "Private character name")
assert(not M:ExportDiagnostics():find("Private character name", 1, true))
local stored, sequence = M.db.diagnostics, M.diagnostics.sequence
M:InitializeDiagnostics()
assert(M.diagnostics == stored and M.diagnostics.sequence == sequence + 2)
M:SetDiagnosticsEnabled(false); M:ClearDiagnostics()
assert(M.diagnostics.count == 0)
M:SetDiagnosticsEnabled(true); M:LogState("state", "pending", {itemID = 42})
assert(M:ExportDiagnostics():find("itemID=42", 1, true))
''')
print("PASS: diagnostic ring retention/order, persistence, pause/clear, bounded messages, build metadata and error forwarding")
