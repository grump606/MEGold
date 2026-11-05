local _, M = ...
local money = M.Money
local statusLine -- defined below; BuildPanel's ticker needs it
-- Builds the deal list and buying controls into `frame`. The same layout serves the standalone
-- window and the Auction House tab, so it anchors to the frame edges instead of fixed widths.
-- `top` reserves room for a title bar when the parent draws one.
function M:BuildPanel(frame, top)
    local function button(label, x, action)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(110, 26); b:SetPoint("TOPLEFT", x, -(top + 7)); b:SetText(label)
        b:SetScript("OnClick", action)
        return b
    end
    button("Scan AH", 15, function() M:StartScan() end)
    button("Stop", 135, function() M:StopScan() end)
    button("Demo", 255, function() M:Demo() end)
    button("Filters", 375, function() M:ShowSettings() end)
    self.page = self.page or 1
    button("Previous", 495, function() M.page = math.max(1, M.page - 1); M:Refresh() end)
    button("Next batch", 615, function()
        M.page = math.min(math.max(1, math.ceil(#M.results / math.max(1, math.min(10, M.db.settings.batchSize)))), M.page + 1)
        M:Refresh()
    end)
    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.status:SetPoint("TOPLEFT", 16, -(top + 42)); frame.status:SetPoint("TOPRIGHT", -16, -(top + 42))
    frame.status:SetJustifyH("LEFT")
    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 16, -(top + 72))
    header:SetText("Item / quantity                         Cost                 Vendor                 Profit / return")
    frame.rows = {}
    for i = 1, 10 do
        local row = CreateFrame("Button", nil, frame)
        row:SetHeight(21)
        row:SetPoint("TOPLEFT", 16, -(top + 92) - (i - 1) * 22); row:SetPoint("TOPRIGHT", -16, -(top + 92) - (i - 1) * 22)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetAllPoints(); row.text:SetJustifyH("LEFT")
        row:SetScript("OnEnter", function(r)
            if r.deal and r.deal.link then
                GameTooltip:SetOwner(r, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(r.deal.link); GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        frame.rows[i] = row
    end
    -- The snapshot age ticks once a second; only the status line is redrawn (hidden frames get no OnUpdate).
    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, seconds)
        elapsed = elapsed + (seconds or 0)
        if elapsed < 1 then return end
        elapsed = 0
        if M.snapshotAt and M.db and M.account then frame.status:SetText(statusLine(M)) end
    end)
    frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", 16, 12)
    frame.footer:SetText("Buy Next spends real gold. Open a vendor to review and sell collected flips.")
    frame.queueStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.queueStatus:SetPoint("TOPLEFT", 16, -(top + 322)); frame.queueStatus:SetPoint("TOPRIGHT", -16, -(top + 322))
    frame.queueStatus:SetJustifyH("LEFT")
    local function queueButton(label, x, action)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(150, 28); b:SetPoint("BOTTOMLEFT", x, 38); b:SetText(label)
        b:SetScript("OnClick", action)
        return b
    end
    frame.prepare = queueButton("Prepare buying batch", 16, function() M:BuildBatch() end)
    frame.buy = queueButton("Buy Next", 176, function()
        if M.queue.phase == "quoted" then M:ConfirmCommodity() else M:BuyNext() end
    end)
    frame.skip = queueButton("Skip deal", 336, function() M:SkipDeal() end)
    queueButton("Transactions", 496, function() M:ShowLedger() end)
    local logs = queueButton("Diagnostics", 656, function() M:ShowDiagnostics() end)
    logs:SetSize(110, 28)
    return frame
end
-- Standalone window, used when the Auction House tab is unavailable or the AH is closed.
function M:ShowWindow()
    if not self.window then
        local frame = CreateFrame("Frame", "MEGoldWindow", UIParent, "BasicFrameTemplateWithInset")
        self.window = frame
        frame:SetSize(780, 450)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame.TitleText:SetText("MEGold — Vendor Flips | " .. (self.VERSION or "development"))
        self:BuildPanel(frame, 28)
    end
    self.window:Show()
    self:Refresh()
end
-- Opens the main view: the Auction House tab while the AH is open, otherwise the standalone window.
function M:Show()
    if self.ahOpen and self:SelectTab() then return self:Refresh() end
    self:ShowWindow()
end
statusLine = function(self)
    local size = math.max(1, math.min(10, self.db.settings.batchSize))
    local pages = math.max(1, math.ceil(#self.results / size))
    self.page = math.min(self.page or 1, pages)
    return self.status .. " | Batch " .. self.page .. "/" .. pages .. self:SnapshotAgeText()
end
local function renderPanel(self, panel)
    local size = math.max(1, math.min(10, self.db.settings.batchSize))
    panel.status:SetText(statusLine(self))
    local q = self.queue
    local tally = self:GetProfitTally()
    panel.footer:SetText("Realized flip profit: " .. self.Money(tally.profit) .. " | Other vendor proceeds: " .. self.Money(tally.otherProceeds))
    if q then
        panel.queueStatus:SetText((q.message or "Prepare a batch to refresh real item deals.") ..
            " | Budget spent: " .. money(self.account.spent))
        local itemAllowed = self:CanTransact("itemBuy")
        local commodityAllowed = self:CanTransact("commodityBuy")
        panel.prepare:SetEnabled((itemAllowed or commodityAllowed) and q.phase == "idle" and self.ahOpen and not self.account.pending)
        panel.buy:SetText(q.phase == "quoted" and "Confirm Buy" or (q.commodity and "Get Quote" or "Buy Next"))
        panel.buy:SetEnabled((q.commodity and commodityAllowed or (not q.commodity and itemAllowed)) and (q.phase == "ready" or q.phase == "quoted") and self.ahOpen and not self.account.pending)
        panel.skip:SetEnabled(q.phase ~= "idle" and not self.account.pending)
    end
    for i, widget in ipairs(panel.rows) do
        local deal = i <= size and self.results[(self.page - 1) * size + i] or nil
        widget.deal = deal
        widget.text:SetText(deal and string.format("%s x%d    %s    %s    |cff55ff55%s (%.1f%%)|r",
            deal.name, deal.quantity, money(deal.cost), money(deal.value), money(deal.profit), deal.roi) or "")
    end
end
-- Draws every visible main view (standalone window and/or Auction House tab).
function M:Render()
    if not self.db or not self.account then return end
    for _, panel in ipairs({ self.window or false, self.tabPanel or false }) do
        if panel and panel:IsShown() then renderPanel(self, panel) end
    end
end
