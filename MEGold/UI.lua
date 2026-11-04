local _, M = ...
local function money(value) return GetCoinTextureString(value or 0) end
function M:Show()
    if not self.window then
        local frame = CreateFrame("Frame", "MEGoldWindow", UIParent, "BasicFrameTemplateWithInset")
        self.window = frame
        frame:SetSize(780, 565)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame.TitleText:SetText("MEGold — Vendor Flips | " .. (self.VERSION or "development"))
        local function button(label, x, action)
            local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            b:SetSize(110, 26); b:SetPoint("TOPLEFT", x, -35); b:SetText(label)
            b:SetScript("OnClick", action)
            return b
        end
        button("Scan AH", 15, function() M:StartScan() end)
        button("Stop", 135, function() M:StopScan() end)
        button("Demo", 255, function() M:Demo() end)
        button("Filters", 375, function() M:ShowSettings() end)
        self.page = 1
        button("Previous", 495, function() M.page = math.max(1, M.page - 1); M:Refresh() end)
        button("Next batch", 615, function()
            M.page = math.min(math.max(1, math.ceil(#M.results / math.max(1, math.min(10, M.db.settings.batchSize)))), M.page + 1)
            M:Refresh()
        end)
        frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        frame.status:SetPoint("TOPLEFT", 16, -75); frame.status:SetWidth(745)
        frame.status:SetJustifyH("LEFT")
        local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        header:SetPoint("TOPLEFT", 16, -110)
        header:SetText("Item / quantity                         Cost                 Vendor                 Profit / return")
        frame.rows = {}
        for i = 1, 10 do
            local row = CreateFrame("Button", nil, frame)
            row:SetSize(745, 27); row:SetPoint("TOPLEFT", 16, -135 - (i - 1) * 28)
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
        frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        frame.footer:SetPoint("BOTTOMLEFT", 16, 18)
        frame.footer:SetText("Buy Next spends real gold. Open a vendor to review and sell collected flips.")
        frame.queueStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        frame.queueStatus:SetPoint("TOPLEFT", 16, -424)
        frame.queueStatus:SetWidth(745); frame.queueStatus:SetJustifyH("LEFT")
        local function queueButton(label, x, action)
            local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            b:SetSize(150, 28); b:SetPoint("BOTTOMLEFT", x, 52); b:SetText(label)
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
    end
    self.window:Show()
    self:Refresh()
end
function M:Render()
    if not self.window or not self.db or not self.account then return end
    local size = math.max(1, math.min(10, self.db.settings.batchSize))
    local pages = math.max(1, math.ceil(#self.results / size))
    self.page = math.min(self.page or 1, pages)
    self.window.status:SetText(self.status .. " | Batch " .. self.page .. "/" .. pages)
    local q = self.queue
    local tally = self:GetProfitTally()
    self.window.footer:SetText("Realized flip profit: " .. self.Money(tally.profit) .. " | Other vendor proceeds: " .. self.Money(tally.otherProceeds))
    if q then
        self.window.queueStatus:SetText((q.message or "Prepare a batch to refresh real item deals.") ..
            " | Budget spent: " .. money(self.account.spent))
        local itemAllowed = self:CanTransact("itemBuy")
        local commodityAllowed = self:CanTransact("commodityBuy")
        self.window.prepare:SetEnabled((itemAllowed or commodityAllowed) and q.phase == "idle" and self.ahOpen and not self.account.pending)
        self.window.buy:SetText(q.phase == "quoted" and "Confirm Buy" or (q.commodity and "Get Quote" or "Buy Next"))
        self.window.buy:SetEnabled((q.commodity and commodityAllowed or (not q.commodity and itemAllowed)) and (q.phase == "ready" or q.phase == "quoted") and self.ahOpen and not self.account.pending)
        self.window.skip:SetEnabled(q.phase ~= "idle" and not self.account.pending)
    end
    for i, widget in ipairs(self.window.rows) do
        local deal = i <= size and self.results[(self.page - 1) * size + i] or nil
        widget.deal = deal
        widget.text:SetText(deal and string.format("%s x%d    %s    %s    |cff55ff55%s (%.1f%%)|r",
            deal.name, deal.quantity, money(deal.cost), money(deal.value), money(deal.profit), deal.roi) or "")
    end
end
