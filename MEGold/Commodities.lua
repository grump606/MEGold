local _, M = ...
local AH = M.Client and M.Client.Auction or C_AuctionHouse or {}
local Items = M.Client and M.Client.Items or C_Item or {}
function M:CancelQuote()
    local q = self.queue
    if q and q.ownsQuote and not self.account.pending then
        q.ownsQuote = nil
        q.ownCall = true
        pcall(AH.CancelCommoditiesPurchase)
        q.ownCall = nil
    end
end
function M:CommodityResults(itemID)
    local q = self.queue
    if (q.phase ~= "searching" and q.phase ~= "paging") or not q.commodity or (itemID and itemID ~= q.key.itemID) then return end
    if not self:PageResponseReady() then return end
    q.phase, q.pagePending, q.pageSent = "searching", nil, nil
    local wanted = q.rows[q.index]
    local tiers = {}
    for i = 1, AH.GetNumCommoditySearchResults(wanted.itemID) do
        local result = AH.GetCommoditySearchResultInfo(wanted.itemID, i)
        if result and result.unitPrice and result.quantity and not result.containsOwnerItem and not result.containsAccountItem then
            tiers[#tiers + 1] = result
        end
    end
    table.sort(tiers, function(a, b) return a.unitPrice < b.unitPrice end)
    local remaining, cost = wanted.quantity, 0
    for _, tier in ipairs(tiers) do
        local quantity = math.min(remaining, tier.quantity)
        cost, remaining = cost + quantity * tier.unitPrice, remaining - quantity
        if remaining == 0 then break end
    end
    local name, link, quality, _, _, _, _, _, _, _, vendor = Items.GetItemInfo(wanted.itemID)
    local deal = { name = name, link = link, quality = quality, vendor = vendor, itemID = wanted.itemID,
        quantity = wanted.quantity, cost = cost, commodity = true, maxCost = wanted.cost }
    if remaining > 0 and self:RequestQueuePage() then return end
    if remaining > 0 or cost > wanted.cost or not self.Evaluate(deal, self.db.settings, GetMoney(), self.account.spent) then
        q.phase = "blocked"; return self:QueueMessage("Commodity quantity or price no longer meets your limits. Skip this deal.")
    end
    q.ready, q.phase, q.readyAt = deal, "ready", GetTime()
    self:QueueMessage(string.format("%s x%d — estimated %s. Click Get Quote, then confirm its price.%s", name, deal.quantity, self.Money(cost), q.prefetch and " (pre-fetched)" or ""))
end
function M:BuyCommodity()
    local q, deal = self.queue, self.queue.ready
    if not self.Evaluate(deal, self.db.settings, GetMoney(), self.account.spent) then
        q.phase = "blocked"; return self:QueueMessage("Commodity no longer meets your budget or filters.")
    end
    q.phase, q.ownsQuote, q.ownCall = "quoting", true, true
    q.prefetch = nil -- the batch is now committed to a real purchase
    self:LogState("quote-request", "Commodity quote", {itemID = deal.itemID, quantity = deal.quantity, cap = deal.maxCost, snapshotAge = self:SnapshotAgeSeconds()})
    local ok, err = pcall(AH.StartCommoditiesPurchase, deal.itemID, deal.quantity)
    if not ok then self:LogState("api-error", tostring(err), {operation = "StartCommoditiesPurchase"}) end
    q.ownCall = nil
    if not ok then self:CancelQuote(); q.phase = "blocked"; return self:QueueMessage("Commodity quote request failed.") end
    local token = {}; q.quoteToken = token
    self:QueueMessage("Waiting for a firm commodity quote…")
    C_Timer.After(10, function()
        if q.quoteToken == token and q.phase == "quoting" then
            self:CancelQuote(); q.phase = "blocked"; self:QueueMessage("Commodity quote timed out. Skip and refresh later.")
        end
    end)
end
function M:CommodityQuote(unitPrice, totalPrice)
    local q = self.queue
    if not q or not q.commodity or not q.ownsQuote or (q.phase ~= "quoting" and q.phase ~= "quoted") then return end
    local deal = q.ready
    deal.cost = totalPrice
    if not totalPrice or totalPrice <= 0 or not unitPrice or unitPrice <= 0 or totalPrice > deal.maxCost
        or not self.Evaluate(deal, self.db.settings, GetMoney(), self.account.spent) then
        self:CancelQuote(); q.phase = "blocked"
        return self:QueueMessage("Firm commodity quote exceeds your price/profit limits. Nothing purchased.")
    end
    q.phase, q.readyAt = "quoted", GetTime()
    self:LogState("quote-accepted", "Firm quote meets limits", {itemID = deal.itemID, quantity = deal.quantity, cost = totalPrice})
    self:QueueMessage(string.format("Firm quote: %s x%d for %s. Click Confirm Buy before it expires.", deal.name, deal.quantity, self.Money(totalPrice)))
end
function M:ConfirmCommodity()
    local q = self.queue
    if q.phase ~= "quoted" or not q.ownsQuote or not self.ahOpen or self.account.pending then return end
    local allowed, reason = self:CanTransact("commodityBuy")
    if not allowed then self:CancelQuote(); q.phase = "blocked"; return self:QueueMessage(reason) end
    if AH.GetQuoteDurationRemaining() <= 0 then
        self:CancelQuote(); q.phase = "ready"
        return self:QueueMessage("Quote expired. Click Get Quote again.")
    end
    local deal = q.ready
    if deal.cost > deal.maxCost or not self.Evaluate(deal, self.db.settings, GetMoney(), self.account.spent) then
        self:CancelQuote(); q.phase = "blocked"; return self:QueueMessage("Quote no longer meets your filters or budget.")
    end
    local entry = {}
    for k, v in pairs(deal) do entry[k] = v end
    entry.status, entry.createdAt = "pending", GetServerTime()
    self.account.pending = entry
    q.phase, q.ownCall = "purchasing", true
    self:LogState("purchase-intent", "Commodity confirmation", {itemID = deal.itemID, quantity = deal.quantity, cost = deal.cost})
    local ok, err = pcall(AH.ConfirmCommoditiesPurchase, deal.itemID, deal.quantity)
    if not ok then self:LogState("api-error", tostring(err), {operation = "ConfirmCommoditiesPurchase"}) end
    q.ownCall = nil
    if not ok then q.phase = "uncertain"; return self:QueueMessage("Commodity confirmation failed. Buying locked for review.") end
    self:QueueMessage("Waiting for commodity purchase confirmation…")
    C_Timer.After(15, function()
        if self.account.pending == entry then
            q.phase = "uncertain"; self:QueueMessage("Commodity purchase unconfirmed. Review Transactions before continuing.")
        end
    end)
end
function M:CommodityPurchased(itemID, quantity)
    local entry = self.account.pending
    if entry and entry.commodity and not entry.conflicted and entry.itemID == itemID and entry.quantity == quantity then
        self.queue.ownsQuote = nil
        self:FinishPurchase("server")
    end
end
-- Quotes are shared client state. A different buying UI invalidates our ownership.
if hooksecurefunc and AH.StartCommoditiesPurchase then
    local function foreignCall()
        local q = M.queue
        if not q or q.ownCall then return end
        q.ownsQuote = nil
        if M.account.pending and M.account.pending.commodity then
            M.account.pending.conflicted = true
            q.phase = "uncertain"
            M:QueueMessage("Another buying UI changed the commodity transaction. Review Transactions.")
        elseif q.commodity and (q.phase == "quoting" or q.phase == "quoted") then
            q.phase = "blocked"
            M:QueueMessage("Another buying UI replaced the quote. Skip and refresh this deal.")
        end
    end
    hooksecurefunc(AH, "StartCommoditiesPurchase", foreignCall)
    if AH.ConfirmCommoditiesPurchase then hooksecurefunc(AH, "ConfirmCommoditiesPurchase", foreignCall) end
    if AH.CancelCommoditiesPurchase then hooksecurefunc(AH, "CancelCommoditiesPurchase", foreignCall) end
end
local events = CreateFrame("Frame")
for _, event in ipairs({ "COMMODITY_SEARCH_RESULTS_RECEIVED", "COMMODITY_SEARCH_RESULTS_ADDED",
    "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASED", "COMMODITY_PURCHASE_FAILED" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, a, b)
    if not M.account then return end
    if event == "COMMODITY_PRICE_UPDATED" then M:CommodityQuote(a, b)
    elseif event == "COMMODITY_PURCHASED" then M:CommodityPurchased(a, b)
    elseif event == "COMMODITY_SEARCH_RESULTS_RECEIVED" or event == "COMMODITY_SEARCH_RESULTS_ADDED" then M:CommodityResults(a)
    elseif M.queue.commodity and (M.queue.phase == "quoting" or M.queue.phase == "quoted") then
        M:CancelQuote(); M.queue.phase = "blocked"; M:QueueMessage("Commodity quote unavailable. Skip this deal.")
    elseif M.account.pending and M.account.pending.commodity then
        M.queue.phase = "uncertain"; M:QueueMessage("Commodity purchase reported a failure. Review Transactions before retrying.")
    end
end)
