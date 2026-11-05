"""Lua 5.1 TOC/UI wiring checks with an explicit API whitelist, not visual validation."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
frames = {}
local methods = {}
-- Missing fields stay nil; calling any unknown API consequently fails instead of silently passing.
local meta = { __index = methods }
local function widget() return setmetatable({scripts = {}, events = {}, text = "", shown = true}, meta) end
for _, name in ipairs({"SetSize", "SetPoint", "SetMovable", "EnableMouse", "RegisterForDrag",
    "StartMoving", "StopMovingOrSizing", "SetWidth", "SetHeight", "SetJustifyH", "SetAllPoints",
    "SetFrameStrata", "SetAutoFocus", "SetMaxLetters", "ClearFocus", "SetMultiLine", "SetFontObject",
    "SetFocus", "HighlightText", "SetVerticalScroll", "RegisterEvent", "SetWordWrap"}) do
    methods[name] = function() end
end
function methods:SetScript(event, fn) self.scripts[event] = fn end
function methods:RegisterEvent(event) self.events[event] = true end
function methods:CreateFontString() return widget() end
function methods:SetScrollChild(child) self.scrollChild = child end
function methods:SetText(text) self.text = text end
function methods:GetText() return self.text end
function methods:SetChecked(value) self.checked = value end
function methods:GetChecked() return self.checked end
function methods:SetEnabled(value) self.enabled = value end
function methods:SetShown(value) self.shown = value and true or false end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:IsShown() return self.shown end
function CreateFrame(kind, name, parent, template)
    assert(({Frame = true, Button = true, CheckButton = true, EditBox = true, ScrollFrame = true})[kind], "Unknown frame kind: " .. tostring(kind))
    assert(template == nil or ({BasicFrameTemplateWithInset = true, UIPanelButtonTemplate = true,
        InputBoxTemplate = true, UICheckButtonTemplate = true, UIPanelScrollFrameTemplate = true})[template], "Unknown template: " .. tostring(template))
    local frame = widget()
    frame.TitleText = widget()
    table.insert(frames, frame)
    return frame
end
StaticPopupDialogs, SlashCmdList = {}, {}
UIParent = widget()
C_AuctionHouse = {}
C_Container = {
    GetContainerNumSlots = function() return 0 end,
    GetContainerItemInfo = function() end,
}
guidReady = false
function UnitGUID() return guidReady and "Player-smoke" or nil end
function fireEvent(event, ...)
    for _, frame in ipairs(frames) do
        if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
    end
end
function GetBuildInfo() return "1.60.1", "123456", "today", 16001 end
function GetMoney() return 100000 end
function GetTime() return 100 end
function GetServerTime() return 100 end
C_CurrencyInfo = {GetCoinTextureString = function(value) return tostring(value) end}
strmatch = string.match -- WoW alias used by the vendored LibStub
timers = {}
C_Timer = { After = function(seconds, fn) timers[#timers + 1] = fn end }
M = {}
''')
module = lua.globals().M
toc = (ROOT / "MEGold" / "MEGold.toc").read_text(encoding="utf-8")
for filename in toc.splitlines():
    if filename.endswith(".lua"):
        lua.execute((ROOT / "MEGold" / filename.replace("\\", "/")).read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
M.events.scripts.OnEvent(M.events, "ADDON_LOADED", "MEGold")
assert(not M.account and not M.queue)
fireEvent("AUCTION_HOUSE_CLOSED")
fireEvent("PLAYER_ENTERING_WORLD")
assert(not M.account)
guidReady = true; fireEvent("PLAYER_ENTERING_WORLD")
assert(M.account and M.queue)
assert(M.Client.flavor == "forever")
for _, feature in ipairs({"scan", "itemBuy", "commodityBuy", "vendor"}) do
    local allowed, reason = M:CanTransact(feature)
    assert(not allowed and reason:find("Missing client APIs:", 1, true))
end
M:Show()
M:ShowSettings()
M:ShowLedger()
M:ShowVendor()
M:ShowDiagnostics()
M:Demo()
M:Refresh()
assert(M.window.shown and M.ledgerWindow.shown and M.settingsWindow.shown and M.vendorWindow.shown)
assert(M.diagnosticWindow.shown and M.diagnosticWindow.box.text:find("MEGold diagnostic report", 1, true))
assert(M.diagnosticWindow.scroll.scrollChild == M.diagnosticWindow.box)
assert(M.diagnosticWindow.NonexistentField == nil)
local acceptedUnknown = pcall(function() M.diagnosticWindow:UnsupportedNativeMethod() end)
assert(not acceptedUnknown)
assert(#M.results == 23 and M.db.settings.batchSize == 10)
-- The actual save handler validates and persists form values.
M.settingsWindow.inputs.minProfit:SetText("100")
local saved = false
for _, frame in ipairs(frames) do
    if frame.text == "Save filters" then frame.scripts.OnClick(frame); saved = true end
end
assert(saved and M.db.settings.minProfit == 100)
-- Exercise a populated ledger, not just the empty state.
table.insert(M.account.purchases, {name = "Test", itemID = 1, link = "|Hitem:1:0|h[Test]|h", quantity = 3, cost = 100})
M:Refresh()
assert(M.ledgerWindow.rows[1].purchase == M.account.purchases[1])
-- Real registered background handlers must also respect missing API contracts.
C_Container.GetContainerNumSlots = nil; C_Container.GetContainerItemInfo = nil
M:InitializeClient()
assert(not M:Supports("inventory"))
local timerCount = #timers
fireEvent("PLAYER_ENTERING_WORLD"); fireEvent("BAG_UPDATE_DELAYED")
fireEvent("MERCHANT_SHOW"); fireEvent("MERCHANT_UPDATE"); fireEvent("MERCHANT_CLOSED")
assert(#timers == timerCount and not M.merchantOpen)
-- Refresh must not repaint hidden windows. Visible windows still render.
local main, ledger, vendor = M.Render, M.RenderLedger, M.RenderVendor
local calls = {main = 0, ledger = 0, vendor = 0}
M.Render = function() calls.main = calls.main + 1 end
M.RenderLedger = function() calls.ledger = calls.ledger + 1 end
M.RenderVendor = function() calls.vendor = calls.vendor + 1 end
M.window:Hide(); M.ledgerWindow:Hide(); M.vendorWindow:Hide()
M:Refresh()
assert(calls.main == 0 and calls.ledger == 0 and calls.vendor == 0)
M.window:Show(); M:Refresh()
assert(calls.main == 1 and calls.ledger == 0 and calls.vendor == 0)
M.Render, M.RenderLedger, M.RenderVendor = main, ledger, vendor
-- Reproduce the live failure: a visible window must not abort StartScan before
-- ReplicateItems and its timeout are reached when only the modern formatter exists.
assert(GetCoinTextureString == nil)
local requested = 0
M.Client.Auction.ReplicateItems = function() requested = requested + 1 end
M.Client.Auction.GetNumReplicateItems = function() return 0 end
M.Client.Auction.GetReplicateItemInfo = function() end
M.Client.Auction.GetReplicateItemLink = function() end
M.Client.Items.GetItemInfo = function() end
M.Client.Items.RequestLoadItemDataByID = function() end
M.Client.features.scan = true
M.ahOpen = true
M:StartScan()
assert(requested == 1 and M.scan.phase == "waiting")
assert(#timers > timerCount)
''')
print("PASS: Lua 5.1 TOC/UI wiring with strict method whitelist, partial-API denial, diagnostics, and hidden-window refresh checks (not visual validation)")
