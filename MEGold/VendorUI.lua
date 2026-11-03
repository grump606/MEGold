local _, M = ...
StaticPopupDialogs.MEGOLD_VENDOR_REVIEW = {
    text = "Exclude unresolved vendor activity from the tally and resume tracking?\n\nIts profit will remain unknown. Remaining collected flips will be unmarked and placed on hold so they cannot be sold twice. Verify collection and release holds in Transactions before selling them.",
    button1 = "Exclude and resume", button2 = "Cancel", timeout = 0, hideOnEscape = true,
    OnAccept = function() M:ExcludeUncertainVendorActivity() end,
}
function M:ShowVendor()
    if not self.vendorWindow then
        local f = CreateFrame("Frame", "MEGoldVendor", UIParent, "BasicFrameTemplateWithInset")
        self.vendorWindow = f
        f:SetSize(760, 565); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
        f.TitleText:SetText("MEGold — Review vendor flips")
        f.tally = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.tally:SetPoint("TOPLEFT", 18, -42); f.tally:SetWidth(720); f.tally:SetJustifyH("LEFT")
        f.rarities = {}
        local names = { "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }
        for quality = 0, 7 do
            local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
            check:SetPoint("TOPLEFT", 16 + (quality % 4) * 178, -95 - math.floor(quality / 4) * 30)
            local label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", check, "RIGHT", 0, 0); label:SetText(names[quality + 1])
            local rarity = quality
            check:SetScript("OnClick", function(c)
                M.db.settings.sellRarities[rarity] = c:GetChecked() and true or false
                M.vendorReview = nil; M:Refresh()
            end)
            f.rarities[quality] = check
        end
        local function button(label, x, y, action)
            local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            b:SetSize(170, 27); b:SetPoint("TOPLEFT", x, y); b:SetText(label); b:SetScript("OnClick", action)
            return b
        end
        f.review = button("Review flips", 18, -168, function() M:BuildVendorReview(); f.page = 1; M:Refresh() end)
        f.sell = button("Sell reviewed flips", 198, -168, function() M:StartVendorSale() end)
        f.stop = button("Stop selling", 378, -168, function()
            M:RequestVendorStop()
        end)
        button("Transactions", 558, -168, function() M:ShowLedger() end)
        f.rows, f.page = {}, 1
        for i = 1, 10 do
            local row = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
            row:SetPoint("TOPLEFT", 18, -205 - (i - 1) * 25)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", row, "RIGHT", 3, 0); row.label:SetWidth(655); row.label:SetJustifyH("LEFT")
            row:SetScript("OnClick", function(c) if c.deal then c.deal.excluded = not c:GetChecked() end end)
            row:SetScript("OnEnter", function(c)
                if c.deal then GameTooltip:SetOwner(c, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(c.deal.link); GameTooltip:Show() end
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            f.rows[i] = row
        end
        button("Previous", 18, -477, function() f.page = math.max(1, f.page - 1); M:Refresh() end)
        button("Next", 198, -477, function() f.page = f.page + 1; M:Refresh() end)
        f.resolve = button("Review accounting…", 378, -477, function() StaticPopup_Show("MEGOLD_VENDOR_REVIEW") end)
        f.note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        f.note:SetPoint("BOTTOMLEFT", 18, 18); f.note:SetWidth(720); f.note:SetJustifyH("LEFT")
    end
    self:RenderVendor()
    self.vendorWindow:Show()
end
function M:RenderVendor()
    local f = self.vendorWindow
    if not f or not self.account then return end
    local tally = self:GetProfitTally()
    f.tally:SetText(string.format("Flip sales: %s | Cost: %s | Realized profit: %s\nOther vendor proceeds: %s (purchase cost unknown)",
        self.Money(tally.flipProceeds), self.Money(tally.cost), self.Money(tally.profit), self.Money(tally.otherProceeds)))
    local rows = self.vendorReview or {}
    local allowed, reason = self:CanTransact("vendor")
    f.page = math.min(f.page or 1, math.max(1, math.ceil(#rows / 10)))
    for i, widget in ipairs(f.rows) do
        local row = rows[(f.page - 1) * 10 + i]
        widget.deal = row
        widget:SetShown(row ~= nil)
        widget:SetEnabled(not self.vendorRun)
        widget:SetChecked(row and not row.excluded)
        widget.label:SetText(row and string.format("%s x%d | %s | Bag %d:%d%s", row.name, row.quantity,
            self.Money(row.vendor * row.quantity), row.bag, row.slot, row.quantity < row.stackCount and " | will split" or "") or "")
    end
    for quality, check in pairs(f.rarities) do check:SetChecked(self.db.settings.sellRarities[quality]); check:SetEnabled(not self.vendorRun) end
    f.review:SetEnabled(allowed and not self.vendorRun and not self.account.vendorUncertain and self.merchantOpen)
    f.sell:SetEnabled(allowed and not self.vendorRun and #rows > 0 and not self.account.vendorUncertain and self.merchantOpen)
    f.stop:SetEnabled(self.vendorRun ~= nil)
    f.resolve:SetEnabled(self.account.vendorUncertain ~= nil and self.merchantOpen)
    f.note:SetText(not allowed and reason or self.account.vendorUncertain and "Accounting locked: " .. self.account.vendorUncertain.reason or
        (self.vendorRun and "Selling reviewed flips; waiting for verified bag, gold and buyback updates." or
        "Mark purchases collected in Transactions first. Never Sell IDs and held purchases are excluded. Page " .. f.page))
end
