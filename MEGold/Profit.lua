local _, M = ...
local integer = M.Integer
function M:MarkCollected(purchase)
    if self.vendorRun or self.account.vendorUncertain or self.account.storageLocked or (self.db and self.db.storageLocked) then return false end
    if not self:Supports("inventory") then return false end
    local totals = self:BagTotals()
    -- Confirming one purchase must not adopt a baseline that hides another pending decrease.
    self:ReconcileInventory(totals)
    local found, allocated = false, 0
    for _, entry in ipairs(self.account.purchases) do
        if entry == purchase then found = true end
        if self.ItemIdentity(entry.link) == self.ItemIdentity(purchase.link) then
            allocated = allocated + math.max(0, (entry.collected or 0) - (entry.sold or 0))
        end
    end
    local remaining = purchase.quantity - (purchase.collected or 0)
    if not found or remaining <= 0 then return false end
    if (totals[self.ItemIdentity(purchase.link)] or 0) < allocated + remaining then return false end
    purchase.collected, purchase.collectedAt = purchase.quantity, GetServerTime()
    self:LogState("collection", "Purchase marked collected", {itemID = purchase.itemID, quantity = purchase.quantity})
    self.account.inventoryTotals = totals
    self:Refresh()
    return true
end
function M:AvailableFlips(link, includeHeld)
    local id, total = self.ItemIdentity(link), 0
    if not id then return 0 end
    for _, purchase in ipairs(self.account.purchases) do
        if self.ItemIdentity(purchase.link) == id and (includeHeld or not purchase.held) then
            total = total + math.max(0, (purchase.collected or 0) - (purchase.sold or 0))
        end
    end
    return total
end
-- Plans are plain saved-data records. Automatic sales reserve exact unheld purchase
-- quantities; manual receipts may explicitly opt into held-inclusive FIFO allocation.
function M:PlanVendorAllocations(link, quantity, includeHeld, reserved)
    local id, remaining, plan = self.ItemIdentity(link), quantity, {}
    if not id or not integer(quantity) then return nil end
    for index, purchase in ipairs(self.account.purchases) do
        if remaining == 0 then break end
        if self.ItemIdentity(purchase.link) == id and (includeHeld or not purchase.held) then
            local available = math.max(0, (purchase.collected or 0) - (purchase.sold or 0) - (reserved and reserved[index] or 0))
            local count = math.min(remaining, available)
            if count > 0 then
                plan[#plan + 1] = { purchase = index, quantity = count }
                remaining = remaining - count
            end
        end
    end
    if remaining ~= 0 then return nil end
    return plan
end
function M:ValidateVendorAllocations(link, quantity, plan, includeHeld)
    if type(plan) ~= "table" or not integer(quantity) then return false end
    local id, total, seen = self.ItemIdentity(link), 0, {}
    if not id then return false end
    for _, allocation in ipairs(plan) do
        if type(allocation) ~= "table" then return false end
        local index, count = allocation.purchase, allocation.quantity
        if not integer(index, 1) or not integer(count, 1) then return false end
        local purchase = self.account.purchases[index]
        if not purchase or seen[index] or type(count) ~= "number" or count <= 0 or count % 1 ~= 0
            or self.ItemIdentity(purchase.link) ~= id or (purchase.held and not includeHeld)
            or count > (purchase.collected or 0) - (purchase.sold or 0) then return false end
        total, seen[index] = total + count, true
    end
    return total == quantity
end
function M:InvalidateProfitTally()
    self.profitRevision = (self.profitRevision or 0) + 1
    self.profitCache = nil
end
function M:RecordVendorSale(link, quantity, proceeds, flipQuantity, allocations)
    if self.account.storageLocked then return nil, "Saved financial records require recovery" end
    local id = self.ItemIdentity(link)
    if not id or not integer(quantity, 1) or not integer(proceeds) or not integer(flipQuantity)
        or flipQuantity > quantity then return nil, "Invalid receipt" end
    local automatic = allocations ~= nil
    local plan = allocations or self:PlanVendorAllocations(link, flipQuantity, true)
    if not self:ValidateVendorAllocations(link, flipQuantity, plan, not automatic) then
        return nil, "Sale purchase allocation changed"
    end
    local receipt = { link = link, quantity = quantity, proceeds = proceeds, flipQuantity = flipQuantity,
        flipProceeds = math.floor(proceeds * flipQuantity / quantity), cost = 0, allocations = {}, at = GetServerTime() }
    for _, allocation in ipairs(plan) do
        local purchase = self.account.purchases[allocation.purchase]
        local sold, count = purchase.sold or 0, allocation.quantity
        -- Allocate remaining cost so partial sales and out-of-order buybacks conserve copper.
        local remainingCost, remainingQuantity = purchase.cost - (purchase.costSold or 0), purchase.quantity - sold
        local cost = count == remainingQuantity and remainingCost
            or math.min(remainingCost, math.floor(remainingCost * count / remainingQuantity))
        receipt.allocations[#receipt.allocations + 1] = { purchase = allocation.purchase, quantity = count, cost = cost }
        receipt.cost = receipt.cost + cost
    end
    for _, allocation in ipairs(receipt.allocations) do
        local purchase = self.account.purchases[allocation.purchase]
        purchase.sold = (purchase.sold or 0) + allocation.quantity
        purchase.costSold = (purchase.costSold or 0) + allocation.cost
    end
    self.account.sales = self.account.sales or {}
    self.account.sales[#self.account.sales + 1] = receipt
    self:InvalidateProfitTally()
    self:LogState("vendor-receipt", "Verified vendor sale", {receipt = #self.account.sales, quantity = quantity, proceeds = proceeds, flipQuantity = flipQuantity, cost = receipt.cost})
    return #self.account.sales
end
function M:ReverseVendorSale(index)
    local receipt = self.account.sales and self.account.sales[index]
    if not receipt or receipt.reversed or receipt.archived then return false end
    for _, allocation in ipairs(receipt.allocations) do
        local purchase = self.account.purchases[allocation.purchase]
        purchase.sold = purchase.sold - allocation.quantity
        purchase.costSold = purchase.costSold - allocation.cost
    end
    receipt.reversed, receipt.reversedAt = true, GetServerTime()
    self:InvalidateProfitTally()
    self:LogState("vendor-buyback", "Sale receipt reversed", {receipt = index, quantity = receipt.quantity, proceeds = receipt.proceeds})
    return true
end
function M:GetProfitTally()
    local cache = self.profitCache
    if cache and cache.account == self.account and cache.sales == self.account.sales
        and cache.revision == (self.profitRevision or 0) then return cache.tally end
    local tally = { flipProceeds = 0, cost = 0, profit = 0, otherProceeds = 0, flipQuantity = 0, otherQuantity = 0 }
    for key in pairs(tally) do
        if key ~= "profit" then tally[key] = (self.account.saleArchive and self.account.saleArchive[key]) or 0 end
    end
    for _, sale in ipairs(self.account.sales or {}) do
        if not sale.reversed then
            tally.flipProceeds = tally.flipProceeds + sale.flipProceeds
            tally.cost = tally.cost + sale.cost
            tally.otherProceeds = tally.otherProceeds + sale.proceeds - sale.flipProceeds
            tally.flipQuantity = tally.flipQuantity + sale.flipQuantity
            tally.otherQuantity = tally.otherQuantity + sale.quantity - sale.flipQuantity
        end
    end
    tally.profit = tally.flipProceeds - tally.cost
    self.profitCache = { account = self.account, sales = self.account.sales, revision = self.profitRevision or 0, tally = tally }
    return tally
end
