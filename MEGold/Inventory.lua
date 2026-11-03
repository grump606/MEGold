local _, M = ...
function M:ReconcileInventory(totals)
    if self.account.storageLocked or (self.db and self.db.storageLocked) then return end
    local previous = self.account.inventoryTotals
    local outstanding = {}
    for _, purchase in ipairs(self.account.purchases) do
        local id = self.ItemIdentity(purchase.link)
        if id then outstanding[id] = (outstanding[id] or 0) + math.max(0, (purchase.collected or 0) - (purchase.sold or 0)) end
    end
    local changed = false
    for _, purchase in ipairs(self.account.purchases) do
        local id = self.ItemIdentity(purchase.link)
        if id and (purchase.collected or 0) > (purchase.sold or 0)
            and ((previous and (totals[id] or 0) < (previous[id] or 0)) or (outstanding[id] or 0) > (totals[id] or 0)) then
            purchase.collected, purchase.held = purchase.sold or 0, true
            purchase.inventoryReview = GetServerTime()
            changed = true
        end
    end
    self.account.inventoryTotals = totals
    if changed then self:SetStatus("Inventory decreased outside a verified sale. Affected flips are on hold; verify collection in Transactions.") end
end
local events = CreateFrame("Frame")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("MERCHANT_CLOSED")
events:SetScript("OnEvent", function()
    if not M.account then return end
    if M.Supports and not M:Supports("inventory") then return end
    C_Timer.After(0.5, function()
        if not M.merchantOpen and not M.vendorRun and not M.account.vendorUncertain then
            M:ReconcileInventory(M:BagTotals())
            M:Refresh()
        end
    end)
end)
