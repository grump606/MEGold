local _, M = ...
local money = M.Money
local statusLine -- defined below; BuildPanel's ticker needs it
-- Column layout shared by the header and every deal row: the numeric columns are right-aligned and
-- anchored to the row's right edge, and the item name takes the remaining width.
local COLUMNS = { { "roi", "Return", 64 }, { "profit", "Profit", 112 }, { "value", "Vendor", 112 },
    { "cost", "Cost", 112 }, { "quantity", "Qty", 44 } }
local COLUMN_GAP = 10
local function createCells(row, font)
    local cells, offset = {}, 0
    for _, column in ipairs(COLUMNS) do
        local cell = row:CreateFontString(nil, "OVERLAY", font)
        cell:SetPoint("RIGHT", row, "RIGHT", -offset, 0)
        cell:SetWidth(column[3]); cell:SetJustifyH("RIGHT"); cell:SetWordWrap(false)
        cells[column[1]] = cell
        offset = offset + column[3] + COLUMN_GAP
    end
    local name = row:CreateFontString(nil, "OVERLAY", font)
    name:SetPoint("LEFT", row, "LEFT", 4, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -offset, 0)
    name:SetJustifyH("LEFT"); name:SetWordWrap(false)
    cells.name = name
    return cells
end-- Builds the deal list and buying controls into `frame`. The same layout serves the standalone
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
    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(18)
    header:SetPoint("TOPLEFT", 16, -(top + 72)); header:SetPoint("TOPRIGHT", -16, -(top + 72))
    local headings = createCells(header, "GameFontNormal")
    headings.name:SetText("Item")
    for _, column in ipairs(COLUMNS) do headings[column[1]]:SetText(column[2]) end
    frame.rows = {}
    for i = 1, 10 do
        local row = CreateFrame("Button", nil, frame)
        row:SetHeight(21)
        row:SetPoint("TOPLEFT", 16, -(top + 92) - (i - 1) * 22); row:SetPoint("TOPRIGHT", -16, -(top + 92) - (i - 1) * 22)
        row.cells = createCells(row, "GameFontHighlightSmall")
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
        if M.db and M.account and (M.snapshotAt or (M:ScanCooldownRemaining() or 0) > 0) then
            frame.status:SetText(statusLine(M))
        end
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
        .. (self.scan and "" or self:ScanCooldownText())
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
        local cells = widget.cells
        if deal then
            cells.name:SetText(deal.name or "?")
            cells.quantity:SetText(tostring(deal.quantity))
            cells.cost:SetText(money(deal.cost)); cells.value:SetText(money(deal.value))
            cells.profit:SetText("|cff55ff55" .. money(deal.profit) .. "|r")
            cells.roi:SetText(string.format("|cff55ff55%.1f%%|r", deal.roi))
        else
            for _, cell in pairs(cells) do cell:SetText("") end
        end
    end
end
-- Draws every visible main view (standalone window and/or Auction House tab).
function M:Render()
    if not self.db or not self.account then return end
    for _, panel in ipairs({ self.window or false, self.tabPanel or false }) do
        if panel and panel:IsShown() then renderPanel(self, panel) end
    end
end
