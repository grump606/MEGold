local _, M = ...
function M:ResolvePending(entry, purchased)
    if self.account.storageLocked or self.db.storageLocked then return end
    if self.account.pending ~= entry or self.queue.phase ~= "uncertain" then return end
    self:LogState("manual-review", "Pending purchase resolved", {purchased = purchased, itemID = entry.itemID, quantity = entry.quantity, cost = entry.cost})
    if purchased then
        self:FinishPurchase("manual review")
    else
        entry.status, entry.reviewedAt = "not purchased", GetServerTime()
        self.account.reviews = self.account.reviews or {}
        self.account.reviews[#self.account.reviews + 1] = entry
        self.account.pending = nil
        if entry.auctionID then self.account.bought[entry.auctionID] = GetServerTime() end
        self.queue.index = self.queue.index + 1
        self:PrepareNext()
    end
    self:ShowLedger()
end
StaticPopupDialogs.MEGOLD_RECONCILE = {
    text = "%s", button1 = "Confirm review", button2 = "Cancel", timeout = 0,
    whileDead = true, hideOnEscape = true, preferredIndex = 3,
    OnAccept = function(_, data) M:ResolvePending(data.entry, data.purchased) end,
}
StaticPopupDialogs.MEGOLD_RESET_BUDGET = {
    text = "Start a new MEGold spending budget? Purchase history stays recorded. This resets only the budget counter.",
    button1 = "Start new budget", button2 = "Cancel", timeout = 0, whileDead = true, hideOnEscape = true,
    OnAccept = function()
        if M:QueueBusy() or M.account.pending or M.account.storageLocked or M.db.storageLocked then return end
        M.account.budgetHistory = M.account.budgetHistory or {}
        table.insert(M.account.budgetHistory, { spent = M.account.spent, closedAt = GetServerTime() })
        M.account.spent = 0
        M:LogState("budget", "Spending budget reset")
        M:Refilter(); M:ShowLedger()
    end,
}
StaticPopupDialogs.MEGOLD_COLLECTED = {
    text = "%s", button1 = "Mark collected", button2 = "Cancel", timeout = 0,
    whileDead = true, hideOnEscape = true,
    OnAccept = function(_, purchase)
        if not M:MarkCollected(purchase) then
            M:SetStatus("Could not mark collected: the full unallocated quantity must be in your bags.")
        end
    end,
}
function M:ReviewPending(purchased)
    local entry = self.account.pending
    if not entry or self.queue.phase ~= "uncertain" then return end
    local text = string.format("%s x%d — %s\n\n%s\nCheck your mailbox, inventory and gold before confirming.",
        entry.name or tostring(entry.itemID), entry.quantity, self.Money(entry.cost),
        purchased and "I verified this purchase completed. Record its cost and unlock buying." or
        "I verified this purchase did NOT complete. Unlock buying without recording a purchase.")
    StaticPopup_Show("MEGOLD_RECONCILE", text, nil, { entry = entry, purchased = purchased })
end
function M:ShowLedger()
    if not self.ledgerWindow then
        local f = CreateFrame("Frame", "MEGoldLedger", UIParent, "BasicFrameTemplateWithInset")
        self.ledgerWindow = f
        f:SetSize(760, 610); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
        f.TitleText:SetText("MEGold — Transactions")
        f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.summary:SetPoint("TOPLEFT", 18, -40); f.summary:SetWidth(720); f.summary:SetJustifyH("LEFT")
        f.pending = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.pending:SetPoint("TOPLEFT", 18, -135); f.pending:SetWidth(720); f.pending:SetJustifyH("LEFT")
        f.tally = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.tally:SetPoint("TOPLEFT", 18, -70); f.tally:SetWidth(720); f.tally:SetJustifyH("LEFT")
        local function button(label, x, y, action)
            local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            b:SetSize(215, 28); b:SetPoint("TOPLEFT", x, y); b:SetText(label); b:SetScript("OnClick", action)
            return b
        end
        f.yes = button("Verified purchased…", 18, -188, function() M:ReviewPending(true) end)
        f.no = button("Verified not purchased…", 250, -188, function() M:ReviewPending(false) end)
        f.reset = button("Start new budget…", 482, -188, function() StaticPopup_Show("MEGOLD_RESET_BUDGET") end)
        f.history = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.history:SetPoint("TOPLEFT", 18, -232); f.history:SetWidth(720); f.history:SetJustifyH("LEFT")
        f.rows = {}
        for i = 1, 10 do
            local row = {}
            row.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("TOPLEFT", 18, -258 - (i - 1) * 26); row.text:SetWidth(450); row.text:SetJustifyH("LEFT")
            row.collect = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            row.collect:SetSize(120, 23); row.collect:SetPoint("TOPLEFT", 480, -252 - (i - 1) * 26)
            row.collect:SetText("Collected…")
            row.collect:SetScript("OnClick", function()
                local p = row.purchase
                if p then StaticPopup_Show("MEGOLD_COLLECTED", string.format("I collected %s x%d from this purchase.\n\nMarking collection makes the remaining quantity eligible for Sell Flips. Verify the purchase mail was collected.", p.name or tostring(p.itemID), p.quantity), nil, p) end
            end)
            row.hold = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            row.hold:SetSize(110, 23); row.hold:SetPoint("TOPLEFT", 610, -252 - (i - 1) * 26)
            row.hold:SetScript("OnClick", function()
                if row.purchase then M:SetPurchaseHold(row.purchase, not row.purchase.held) end
            end)
            f.rows[i] = row
        end
        f.page = 1
        button("Newer", 18, -550, function() f.page = math.max(1, f.page - 1); M:ShowLedger() end)
        button("Older", 250, -550, function() f.page = f.page + 1; M:ShowLedger() end)
    end
    self:RenderLedger()
    self.ledgerWindow:Show()
end
function M:RenderLedger()
    local f, account = self.ledgerWindow, self.account
    if not f or not account then return end
    f.summary:SetText(string.format("Confirmed purchases: %d | Current budget spent: %s", #account.purchases, self.Money(account.spent)))
    local tally = self:GetProfitTally()
    f.tally:SetText(string.format("Flips sold: %d | Proceeds: %s | Purchase cost: %s | Realized profit: %s\nOther items sold: %d | Proceeds: %s%s",
        tally.flipQuantity, self.Money(tally.flipProceeds), self.Money(tally.cost), self.Money(tally.profit),
        tally.otherQuantity, self.Money(tally.otherProceeds), account.vendorUncertain and "\nUnreconciled vendor activity: totals exclude it; Sell Flips is locked." or ""))
    local entry = account.pending
    f.pending:SetText(entry and string.format("UNRESOLVED: %s x%d | %s | %s", entry.name or tostring(entry.itemID),
        entry.quantity, self.Money(entry.cost), self.queue.phase) or "No unresolved purchase.")
    local canReview = entry and self.queue.phase == "uncertain" and not account.storageLocked and not self.db.storageLocked
    f.yes:SetEnabled(canReview and true or false); f.no:SetEnabled(canReview and true or false)
    f.reset:SetEnabled(not self:QueueBusy() and not entry and not account.storageLocked and not self.db.storageLocked)
    f.page = math.min(f.page, math.max(1, math.ceil(#account.purchases / 10)))
    f.history:SetText("Purchase history — page " .. f.page .. " | Confirm collection before selling; Hold protects an entire purchase.")
    for i = 1, 10 do
        local purchase = account.purchases[#account.purchases - (f.page - 1) * 10 - i + 1]
        local row = f.rows[i]
        row.purchase = purchase
        row.text:SetText(purchase and string.format("%s x%d | Collected %d | Sold %d | %s", purchase.name or tostring(purchase.itemID),
            purchase.quantity, purchase.collected or 0, purchase.sold or 0, self.Money(purchase.cost)) or "")
        row.collect:SetShown(purchase ~= nil); row.hold:SetShown(purchase ~= nil)
        local inventoryOk = self:Supports("inventory")
        row.collect:SetEnabled(purchase and (purchase.collected or 0) < purchase.quantity and not self.vendorRun and not account.vendorUncertain
            and not account.storageLocked and not self.db.storageLocked and inventoryOk and true or false)
        row.hold:SetEnabled(purchase and not purchase.archived and not self.vendorRun and not account.storageLocked)
        row.hold:SetText(purchase and purchase.held and "Release hold" or "Hold for AH")
    end
end
