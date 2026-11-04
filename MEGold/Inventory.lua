local _, M = ...
-- `explained` maps item identity to quantities removed by verified sale evidence. Only that
-- evidence may justify a lower bag count; everything else revokes flip eligibility first.
function M:ReconcileInventory(totals, explained)
    if self.account.storageLocked or (self.db and self.db.storageLocked) then return end
    local previous = self.account.inventoryTotals
    local outstanding, identities = {}, {}
    local purchases = self.account.purchases
    for index, purchase in ipairs(purchases) do
        local id = self.ItemIdentity(purchase.link) -- pattern-match once per purchase per pass
        identities[index] = id or false
        if id then outstanding[id] = (outstanding[id] or 0) + math.max(0, (purchase.collected or 0) - (purchase.sold or 0)) end
    end
    local changed = false
    for index, purchase in ipairs(purchases) do
        local id = identities[index]
        if id and (purchase.collected or 0) > (purchase.sold or 0)
            and ((previous and (totals[id] or 0) < (previous[id] or 0) - (explained and explained[id] or 0)) or (outstanding[id] or 0) > (totals[id] or 0)) then
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
-- A burst of bag events schedules one reconcile; each event supersedes the previous token.
local reconcileToken
events:SetScript("OnEvent", function()
    if not M.account then return end
    if M.Supports and not M:Supports("inventory") then return end
    if M.inventoryReconcilePending then return end -- already scheduled; the timer reads state when it fires
    local token = {}
    reconcileToken, M.inventoryReconcilePending = token, true
    C_Timer.After(0.5, function()
        if reconcileToken ~= token then return end
        reconcileToken, M.inventoryReconcilePending = nil, nil
        if not M.account then return end
        if not M.merchantOpen and not M.vendorRun and not M.account.vendorUncertain then
            M:ReconcileInventory(M:BagTotals())
            M:Refresh()
        end
    end)
end)
