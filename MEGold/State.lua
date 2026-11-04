local _, M = ...
-- Queue phases describe a single request lifecycle. A unique request token separates
-- old timers from the currently active search, including repeated searches of one item.
M.QueuePhase = {
    idle = "idle", next = "next", throttled = "throttled", searching = "searching",
    paging = "paging", blocked = "blocked", ready = "ready", quoting = "quoting",
    quoted = "quoted", purchasing = "purchasing", uncertain = "uncertain",
}
function M:NewQueueRequest()
    local queue = self.queue
    queue.token, queue.pageRequests, queue.pagePending, queue.pageSent = {}, 0, nil, nil
    return queue.token
end
function M:ArmSearchTimeout(token)
    local queue = self.queue
    local deadline = {}
    queue.timeoutToken = deadline
    C_Timer.After(15, function()
        if self.queue == queue and queue.token == token and queue.timeoutToken == deadline
            and (queue.phase == "searching" or queue.phase == "paging") then
            queue.phase = "blocked"
            self:QueueMessage("Search timed out. Skip and refresh later.")
        end
    end)
end
function M:RequestVendorStop()
    local run = self.vendorRun
    if not run then return end
    if run.phase == "selling" then
        run.stopRequested = true
        self:SetStatus("Stopping after the current sale is confirmed.")
    else
        self:StopVendorSale()
    end
end
function M:SetPurchaseHold(purchase, held)
    if not self.account or self.account.storageLocked or self.vendorRun then return false end
    for _, entry in ipairs(self.account.purchases) do
        if entry == purchase and not entry.archived then
            entry.held = held and true or false
            self:LogState("hold", "Purchase hold changed", {itemID = entry.itemID, held = entry.held})
            self:Refresh()
            return true
        end
    end
    return false
end
