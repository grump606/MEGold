"""Auction House tab wiring: attach once, fall back to the standalone window, render into the tab."""
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
    "SetFocus", "HighlightText", "SetVerticalScroll", "RegisterEvent"}) do
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
guidReady = true; fireEvent("PLAYER_ENTERING_WORLD")
assert(M.account and M.queue)

-- Replace the vendored library's tab operations with recorders (the real ones need Blizzard templates).
local lib = LibStub("LibAHTab-1-0")
assert(lib, "LibAHTab must load from the TOC")
created, selected, failCreate = {}, {}, false
function lib:CreateTab(id, frame, text, header)
    if failCreate then error("boom") end
    created[#created + 1] = {id = id, frame = frame, text = text, header = header}
    frame:Hide()
end
function lib:SetSelected(id)
    selected[#selected + 1] = id
    for _, tab in ipairs(created) do if tab.id == id then tab.frame:Show() end end
end

-- 1. No Auction House frame yet: standalone fallback, one delayed retry queued, nothing attached.
M.ahOpen = true
fireEvent("AUCTION_HOUSE_SHOW")
assert(M.window and M.window:IsShown() and not M.tabPanel and #created == 0)
assert(#timers >= 1)

-- 2. The frame appears before the retry fires: the tab attaches and the standalone window hides.
AuctionHouseFrame = CreateFrame("Frame")
AuctionHouseFrame.Tabs = {CreateFrame("Button")}
timers[#timers](); timers = {}
assert(M.tabPanel and #created == 1 and not M.window:IsShown())
assert(created[1].id == "MEGold" and created[1].frame == M.tabPanel and created[1].header:find("MEGold", 1, true))
assert(#selected == 0, "opening the AH must not steal the default tab")

-- 3. Re-opening the AH never creates a second tab.
fireEvent("AUCTION_HOUSE_SHOW")
assert(#created == 1 and not M.window:IsShown())

-- 4. Show() selects the tab while the AH is open and renders into it, not the standalone window.
M.status = "tab status"
M:Show()
assert(selected[#selected] == "MEGold" and M.tabPanel:IsShown() and not M.window:IsShown())
assert(M.tabPanel.status.text:find("tab status", 1, true))
assert(#M.tabPanel.rows == 10)
-- The snapshot age ticks in place on the visible panel, without a full re-render.
M.snapshotAt = GetTime() - 45
M.tabPanel.scripts.OnUpdate(M.tabPanel, 1.5)
assert(M.tabPanel.status.text:find("Snapshot 45s old", 1, true) and M.tabPanel.status.text:find("tab status", 1, true))
M.snapshotAt = nil

-- 5. With the AH closed Show() uses the standalone window again.
fireEvent("AUCTION_HOUSE_CLOSED")
M:Show()
assert(M.window:IsShown())
M.window:Hide()

-- 6. A failing library on a fresh session falls back once and is not retried every visit.
M.tabPanel, M.window = nil, nil
failCreate = true
M.ahOpen = true
fireEvent("AUCTION_HOUSE_SHOW")
assert(M.tabFailure and M.window:IsShown() and not M.tabPanel)
failCreate = false
local before = #timers
fireEvent("AUCTION_HOUSE_SHOW")
assert(#created == 1 and #timers == before and not M.tabPanel)
''')
print("PASS: Auction House tab attaches once, never steals the default tab, renders into the tab and falls back safely")
