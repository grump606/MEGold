local _, M = ...
-- Auction House tab. Custom AH tabs created with the stock PanelTemplates_ helpers taint the UI
-- and break bag actions, so tab creation and switching go through the bundled LibAHTab (MIT).
-- Anything missing (library, AH frame, tab strip) leaves the standalone window as the fallback.
local TAB_ID, TAB_TEXT, TAB_HEADER = "MEGold", "MEGold", "MEGold — Vendor Flips"
local function library()
    return type(LibStub) == "table" and LibStub("LibAHTab-1-0", true) or nil
end
function M:CanAttachTab()
    local lib = library()
    local ah = AuctionHouseFrame
    return lib ~= nil and type(ah) == "table" and type(ah.Tabs) == "table" and #ah.Tabs > 0
        and type(lib.CreateTab) == "function" and type(lib.SetSelected) == "function"
end
-- Creates the tab once per session. Returns true when the tab exists and can be selected.
function M:AttachTab()
    if self.tabPanel then return true end
    if self.tabFailure or not self:CanAttachTab() then return false end
    local lib = library()
    local panel = CreateFrame("Frame", "MEGoldAHPanel", AuctionHouseFrame)
    -- Inset below the AH title and above its footer; the stock display frames use the same area.
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 6, -28)
    panel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, 30)
    self:BuildPanel(panel, 0)
    panel:SetScript("OnShow", function() M:Refresh() end)
    local ok, err = pcall(lib.CreateTab, lib, TAB_ID, panel, TAB_TEXT, TAB_HEADER)
    if not ok then
        -- Do not retry every AH visit: a failed creation may have left partial state behind.
        panel:Hide()
        self.tabFailure = tostring(err)
        self:LogState("tab-error", "Auction House tab unavailable; using the standalone window", {error = self.tabFailure})
        return false
    end
    self.tabPanel = panel
    self:LogState("tab-created", "Auction House tab attached")
    return true
end
function M:SelectTab()
    if not self:AttachTab() then return false end
    local ok, err = pcall(library().SetSelected, library(), TAB_ID)
    if not ok then self:LogState("tab-error", "Selecting the Auction House tab failed", {error = tostring(err)}) end
    return ok
end
-- Called when the AH opens: add the tab, or show the standalone window if that is impossible.
-- The AH frame can finish building just after AUCTION_HOUSE_SHOW, so one delayed retry is made.
function M:OnAuctionHouseShown()
    if self:AttachTab() then
        if self.window then self.window:Hide() end
        return
    end
    self:ShowWindow()
    if not self.tabFailure then
        C_Timer.After(1, function()
            if self.ahOpen and not self.tabPanel and self:AttachTab() and self.window then self.window:Hide() end
        end)
    end
end
