local _, M = ...
local AH = M.Client and M.Client.Auction or C_AuctionHouse or {}
local Items = M.Client and M.Client.Items or C_Item or {}
local identity = M.ItemIdentity
function M:InitializeQueue()
    local key = UnitGUID("player")
    if not key then return false end
    self.db.accounts = self.db.accounts or {}
    self.db.accounts[key] = self.db.accounts[key] or { spent = 0, purchases = {}, bought = {} }
    self.account = self:GetStoredAccount(key)
    self:MaintainHistory(self.account)
    if self.account.vendorPending then
        self.vendorRun = nil
        self.account.vendorUncertain = { reason = "reload interrupted a vendor sale; verify inventory and buyback", at = GetServerTime() }
    end
    self.queue = { phase = self.account.pending and "uncertain" or "idle", rows = {}, index = 1 }
    if self.account.pending then
        self.queue.message = "Unresolved purchase from a previous session. Buying locked; inspect mail and saved ledger."
        self:SetStatus(self.queue.message)
    end
    if self.account.storageLocked then self.queue.message = "Transactions locked: " .. self.account.storageLocked end
    return true
end
-- A pre-fetched batch only searches; nothing is quoted, bought or reserved until the player clicks buy,
-- so it never blocks a new scan, demo or manual batch.
function M:QueueBusy()
    local q = self.queue
    return q and q.phase ~= "idle" and not q.prefetch
end
-- Drops a pre-fetched batch that has not been committed to a purchase. In-flight search timers carry
-- the old token, so clearing it makes them no-ops.
function M:DiscardPrefetch()
    local q = self.queue
    if not q or not q.prefetch then return end
    q.prefetch, q.token, q.ready, q.key, q.commodity, q.pagePending, q.pageSent = nil, nil, nil, nil, nil, nil, nil
    q.rows, q.index, q.phase, q.message = {}, 1, "idle", nil
end
-- Right after a scan completes, search the best real deals so the first purchase is ready when the
-- player looks at the list. Controlled by the prefetch setting; failures stay silent.
function M:Prefetch()
    local q = self.queue
    if not q or not self.account or (self.db.settings.prefetch or 0) ~= 1 then return end
    if q.phase ~= "idle" or self.account.pending or not self.ahOpen then return end
    if not (self:CanTransact("itemBuy") or self:CanTransact("commodityBuy")) then return end
    self:BuildBatch(true)
end
function M:QueueMessage(text)
    self.queue.message = text
    self:LogState("queue", text)
    self:Refresh()
end
function M:BuildBatch(prefetch)
    local item, reason = self:CanTransact("itemBuy")
    local commodity = self:CanTransact("commodityBuy")
    if not item and not commodity then
        if not prefetch then self:SetStatus(reason) end
        return
    end
    if self:QueueBusy() then return end
    if not self.ahOpen then
        if not prefetch then self:SetStatus("Open the auction house first.") end
        return
    end
    if not prefetch then
        self:DiscardPrefetch()
        self:StopScan()
    end
    -- Buy the best deals first; the list may still hold unsorted rows from a scan in progress.
    self:SortResults()
    local q = self.queue
    q.rows, q.index, q.phase = {}, 1, "idle"
    local reserved = 0
    for _, row in ipairs(self.results) do
        if not row.demo and self.Evaluate(row, self.db.settings, GetMoney() - reserved, self.account.spent + reserved) then
            q.rows[#q.rows + 1] = row
            reserved = reserved + row.cost
            if #q.rows >= self.db.settings.batchSize then break end
        end
    end
    if #q.rows == 0 then
        if prefetch then return end
        return self:QueueMessage("No real deals meet the remaining budget.")
    end
    q.prefetch = prefetch and true or nil
    q.phase = "next"
    self:PrepareNext()
end
function M:PrepareNext()
    local q = self.queue
    if self.account.pending then return end
    self:CancelQuote()
    q.ready, q.key, q.commodity, q.pagePending = nil, nil, nil, nil
    local row = q.rows[q.index]
    if not row then q.phase, q.prefetch = "idle", nil; return self:QueueMessage("Batch complete. Scan again or prepare another batch.") end
    if not self.ahOpen then q.phase, q.prefetch = "idle", nil; return end
    if type(AH.MakeItemKey) ~= "function" or type(AH.GetItemKeyInfo) ~= "function" then
        q.phase = "blocked"; return self:QueueMessage("Required auction APIs are unavailable.")
    end
    q.key = AH.MakeItemKey(row.itemID, 0, 0, 0)
    local info = AH.GetItemKeyInfo(q.key)
    if not info then
        q.phase = "blocked"
        return self:QueueMessage("Item metadata unavailable. Skip this deal and refresh later.")
    end
    q.commodity = info.isCommodity
    local allowed, reason = self:CanTransact(q.commodity and "commodityBuy" or "itemBuy")
    if not allowed then q.phase = "blocked"; return self:QueueMessage(reason) end
    q.phase = "throttled"
    self:SendQueueSearch()
end
function M:SendQueueSearch()
    local q = self.queue
    if q.phase == "paging" then return self:SendQueuePage() end
    if q.phase ~= "throttled" or not self.ahOpen then return end
    if not AH.IsThrottledMessageSystemReady() then return self:QueueMessage("Waiting for auction search throttle…") end
    q.phase = "searching"
    local token = self:NewQueueRequest()
    self:QueueMessage("Refreshing " .. q.rows[q.index].name .. "…")
    local ok, err = pcall(AH.SendSearchQuery, q.key, {}, true)
    if not ok then self:LogState("api-error", tostring(err), { operation = "SendSearchQuery" }) end
    if not ok then q.phase = "blocked"; return self:QueueMessage("Search rejected. Skip and refresh later.") end
    self:ArmSearchTimeout(token)
end
function M:RequestQueuePage()
    local q = self.queue
    if q.pagePending then return true end
    local checker = q.commodity and AH.HasFullCommoditySearchResults or AH.HasFullItemSearchResults
    local more = q.commodity and AH.RequestMoreCommoditySearchResults or AH.RequestMoreItemSearchResults
    if type(checker) ~= "function" or type(more) ~= "function" then return false end
    local ok, full = pcall(checker, q.commodity and q.key.itemID or q.key)
    if not ok or full then return false end
    if q.pageRequests >= 50 then
        q.phase = "blocked"; self:QueueMessage("Search page limit reached. Skip and refresh later.")
        return true
    end
    q.phase, q.pagePending = "paging", true
    self:ArmSearchTimeout(q.token)
    self:SendQueuePage()
    return true
end
function M:SendQueuePage()
    local q = self.queue
    if q.phase ~= "paging" or not q.pagePending or q.pageSent or not self.ahOpen then return end
    if not AH.IsThrottledMessageSystemReady() then return self:QueueMessage("Waiting for the next search page…") end
    local method = q.commodity and AH.RequestMoreCommoditySearchResults or AH.RequestMoreItemSearchResults
    q.pageRequests, q.pageSent = q.pageRequests + 1, true
    q.pageSeenCount = q.commodity and AH.GetNumCommoditySearchResults(q.key.itemID) or AH.GetNumItemSearchResults(q.key)
    self:ArmSearchTimeout(q.token)
    local ok, err = pcall(method, q.commodity and q.key.itemID or q.key)
    if not ok then
        q.phase, q.pagePending, q.pageSent = "blocked", nil, nil
        return self:QueueMessage("Additional search page failed: " .. tostring(err))
    end
    self:QueueMessage("Loading additional auction results…")
end
function M:PageResponseReady()
    local q = self.queue
    if q.phase ~= "paging" then return true end
    if not q.pageSent then return false end
    local count = q.commodity and AH.GetNumCommoditySearchResults(q.key.itemID) or AH.GetNumItemSearchResults(q.key)
    local checker = q.commodity and AH.HasFullCommoditySearchResults or AH.HasFullItemSearchResults
    local full = checker(q.commodity and q.key.itemID or q.key)
    return count > (q.pageSeenCount or 0) or full == true
end
function M:QueueResults(key)
    local q = self.queue
    if (q.phase ~= "searching" and q.phase ~= "paging") or q.commodity or not key or key.itemID ~= q.key.itemID then return end
    if not self:PageResponseReady() then return end
    q.phase, q.pagePending, q.pageSent = "searching", nil, nil
    local wanted = q.rows[q.index]
    local best
    for i = 1, AH.GetNumItemSearchResults(q.key) do
        local result = AH.GetItemSearchResultInfo(q.key, i)
        if result and not result.containsOwnerItem and not result.containsAccountItem
            and not self.account.bought[result.auctionID]
            and identity(result.itemLink) == identity(wanted.link) and identity(wanted.link)
            and result.quantity == wanted.quantity and result.buyoutAmount and result.buyoutAmount > 0
            and result.buyoutAmount <= wanted.cost then
            local name, _, quality, _, _, _, _, _, _, _, vendor = Items.GetItemInfo(result.itemLink)
            local deal = { itemID = wanted.itemID, name = name, link = result.itemLink, quality = quality,
                quantity = result.quantity, vendor = vendor, cost = result.buyoutAmount, auctionID = result.auctionID }
            if self.Evaluate(deal, self.db.settings, GetMoney(), self.account.spent)
                and (not best or deal.cost < best.cost) then best = deal end
        end
    end
    if not best then
        if self:RequestQueuePage() then return end
        q.phase = "blocked"
        return self:QueueMessage("No matching profitable lot on this results page. Skip this deal.")
    end
    q.ready, q.phase, q.readyAt = best, "ready", GetTime()
    self:QueueMessage(string.format("%d/%d: %s x%d — cost %s. Click Buy Next.%s", q.index, #q.rows,
        best.name, best.quantity, self.Money(best.cost), q.prefetch and " (pre-fetched)" or ""))
end
function M:BuyNext()
    local q = self.queue
    if q.phase ~= "ready" or not q.ready or not self.ahOpen or self.account.pending then return end
    local allowed, reason = self:CanTransact(q.commodity and "commodityBuy" or "itemBuy")
    if not allowed then q.phase = "blocked"; return self:QueueMessage(reason) end
    if q.commodity then return self:BuyCommodity() end
    local deal = q.ready
    if GetTime() - q.readyAt > 10 then return self:PrepareNext() end
    local current
    for i = 1, AH.GetNumItemSearchResults(q.key) do
        local result = AH.GetItemSearchResultInfo(q.key, i)
        if result and result.auctionID == deal.auctionID then current = result; break end
    end
    if not current or current.buyoutAmount ~= deal.cost or current.quantity ~= deal.quantity
        or identity(current.itemLink) ~= identity(deal.link) or current.containsOwnerItem or current.containsAccountItem then
        return self:PrepareNext()
    end
    if not self.Evaluate(deal, self.db.settings, GetMoney(), self.account.spent) then
        q.phase = "blocked"; return self:QueueMessage("Deal no longer meets your filters or budget. Skip it.")
    end
    -- Save intent before sending. A timeout/reload must never silently retry a purchase.
    q.prefetch = nil -- the batch is now committed to a real purchase
    local entry = {}
    for k, v in pairs(deal) do entry[k] = v end
    entry.status, entry.createdAt = "pending", GetServerTime()
    self.account.pending = entry
    q.phase = "purchasing"
    self:QueueMessage("Waiting for purchase confirmation…")
    self:LogState("purchase-intent", "Individual auction buyout", {itemID = deal.itemID, auctionID = deal.auctionID, quantity = deal.quantity, cost = deal.cost, snapshotAge = self:SnapshotAgeSeconds()})
    local ok, err = pcall(AH.PlaceBid, deal.auctionID, deal.cost)
    if not ok then self:LogState("api-error", tostring(err), {operation = "PlaceBid"}) end
    if not ok then q.phase = "uncertain"; return self:QueueMessage("Purchase call failed. Buying locked until reconciled.") end
    C_Timer.After(15, function()
        if self.account.pending == entry then
            q.phase = "uncertain"; self:QueueMessage("Purchase unconfirmed. Buying locked; inspect mail before reconciliation.")
        end
    end)
end
function M:PurchaseConfirmed(auctionID)
    local entry = self.account.pending
    if not entry or entry.commodity or entry.auctionID ~= auctionID then return end
    self:FinishPurchase("server")
end
function M:FinishPurchase(source)
    local entry = self.account.pending
    if not entry then return end
    entry.status, entry.confirmedAt = "purchased", GetServerTime()
    entry.confirmation = source
    self:LogState("purchase-confirmed", source, {itemID = entry.itemID, auctionID = entry.auctionID, quantity = entry.quantity, cost = entry.cost})
    self.account.purchases[#self.account.purchases + 1] = entry
    if entry.auctionID then self.account.bought[entry.auctionID] = GetServerTime() end
    self.account.spent = self.account.spent + entry.cost
    self.account.pending = nil
    self.queue.index = self.queue.index + 1
    self:PrepareNext()
end
function M:SkipDeal()
    local q = self.queue
    if self.account.pending or q.phase == "idle" then return end
    q.token = nil
    q.index = q.index + 1
    self:PrepareNext()
end
function M:CloseQueue()
    local q = self.queue
    self:CancelQuote()
    q.token, q.ready, q.prefetch = nil, nil, nil
    q.phase = self.account.pending and "uncertain" or "idle"
    self:QueueMessage(self.account.pending and "AH closed with an unresolved purchase. Buying locked." or "Buying batch cancelled because the AH closed.")
end
local events = CreateFrame("Frame")
events:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
events:RegisterEvent("ITEM_SEARCH_RESULTS_ADDED")
events:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
events:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED")
events:SetScript("OnEvent", function(_, event, arg)
    if not M.account then return end
    if event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then M:PurchaseConfirmed(arg)
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then M:SendQueueSearch()
    elseif not M.queue.commodity then M:QueueResults(arg) end
end)
