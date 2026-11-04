local _, M = ...
local CHUNK_SIZE, MAX_ATTEMPTS, REQUEST_TIMEOUT, RETRY_DELAY = 100, 3, 5, 1
-- Time-budgeted snapshot reads: ~8ms of work per frame, never fewer than MIN_ROWS rows so a
-- slow client still progresses. Without debugprofilestop the loop uses fixed CHUNK_SIZE chunks.
local FRAME_BUDGET_MS, MIN_ROWS, STATUS_EVERY = 8, 25, 20
local MAX_INTEGER = 9007199254740991
local function auction() return M.Client and M.Client.Auction or C_AuctionHouse end
local function items() return M.Client and M.Client.Items or C_Item end
local integer = M.Integer
local function current(self, scan, generation)
    return self.scan == scan and self.generation == generation
end
-- Ranking: profit, then return, then cheaper lots, then stable snapshot order.
function M.CompareDeals(a, b)
    local ap, bp = a.profit or 0, b.profit or 0
    if ap ~= bp then return ap > bp end
    local ar, br = a.roi or 0, b.roi or 0
    if ar ~= br then return ar > br end
    local ac, bc = a.cost or 0, b.cost or 0
    if ac ~= bc then return ac < bc end
    local ai, bi = a.snapshotIndex or a.itemID or 0, b.snapshotIndex or b.itemID or 0
    return ai < bi
end
-- One O(n log n) sort per checkpoint; rows are appended unsorted by ValueRow.
function M:SortResults()
    if self.results and #self.results > 1 then table.sort(self.results, M.CompareDeals) end
    self.resultsDirty = false
end
function M:StopScan()
    self.generation = (self.generation or 0) + 1
    if self.scan and self.resultsDirty then self:SortResults() end
    self.scan = nil
    self:SetStatus("Scan stopped. Results are snapshots; refresh before purchasing.")
end
function M:StartScan()
    if self.Supports then
        local supported, reason = self:Supports("scan")
        if not supported then return self:SetStatus(reason) end
    end
    if self:QueueBusy() then return self:SetStatus("Finish or skip the current buying batch first.") end
    if not self.ahOpen then return self:SetStatus("Open the auction house first.") end
    if self.scan then return end
    local api, itemAPI = auction(), items()
    if not api or type(api.ReplicateItems) ~= "function" or type(api.GetNumReplicateItems) ~= "function"
        or type(api.GetReplicateItemInfo) ~= "function" or type(api.GetReplicateItemLink) ~= "function"
        or not itemAPI or type(itemAPI.GetItemInfo) ~= "function" or type(itemAPI.RequestLoadItemDataByID) ~= "function" then
        return self:SetStatus("This client does not expose the required scan and item-data APIs.")
    end
    self.generation = (self.generation or 0) + 1
    self.results, self.candidates, self.resultsDirty = {}, {}, false
    local scan = { phase = "waiting", pendingByItem = {}, failedItems = {}, pendingCount = 0,
        failedRows = 0, invalidRows = 0, checked = 0, total = 0 }
    self.scan = scan
    self:SetStatus("Requesting auction snapshot. Server cooldowns may delay this request.")
    local generation = self.generation
    local ok, err = pcall(api.ReplicateItems)
    if not ok then self:StopScan(); return self:SetStatus(tostring(err)) end
    C_Timer.After(30, function()
        if current(self, scan, generation) and scan.phase == "waiting" then
            self:StopScan()
            self:SetStatus("No snapshot received. The server may be on scan cooldown; try later.")
        end
    end)
end
function M:ValueRow(row)
    if row.valued then return true end
    -- Item links preserve suffix/variant information; never substitute ID-only pricing.
    if not row.link and row.snapshotIndex ~= nil then
        local ok, link = pcall(auction().GetReplicateItemLink, row.snapshotIndex)
        if ok then row.link = link end
    end
    if type(row.link) ~= "string" then return false end
    local linkID = tonumber(row.link:match("item:(%d+)"))
    if linkID ~= row.itemID then
        row.valued = true
        if self.scan then self.scan.invalidRows = self.scan.invalidRows + 1 end
        return true
    end
    local ok, name, _, quality, _, _, _, _, _, _, _, vendor = pcall(items().GetItemInfo, row.link)
    if not ok or not name or vendor == nil then return false end
    row.valued = true
    if type(name) ~= "string" or name == "" or not integer(vendor, 0) or not integer(quality, 0, 7) or vendor > math.floor(MAX_INTEGER / row.quantity) then
        if self.scan then self.scan.invalidRows = self.scan.invalidRows + 1 end
        return true
    end
    row.name, row.quality, row.vendor = name, quality, vendor
    self.candidates = self.candidates or {}
    self.candidates[#self.candidates + 1] = row
    local metrics = self.Evaluate(row, self.db.settings, GetMoney(), self.account and self.account.spent or 0)
    if metrics then
        row.value, row.profit, row.roi = metrics.value, metrics.profit, metrics.roi
        self.results[#self.results + 1] = row
        self.resultsDirty = true
    end
    return true
end
function M:ExpirePendingItem(scan, itemID)
    local group = scan.pendingByItem[itemID]
    if not group then return end
    scan.pendingByItem[itemID], scan.failedItems[itemID] = nil, true
    scan.pendingCount, scan.failedRows = scan.pendingCount - group.count, scan.failedRows + group.count
    if self.LogState then self:LogState("scan-item-expired", "Item data unavailable after bounded retries", {itemID = itemID, rows = group.count, attempts = group.attempts}) end
    self:ScanProgress()
end
function M:RequestPendingItem(scan, itemID)
    if self.scan ~= scan then return end
    local group = scan.pendingByItem[itemID]
    if not group then return end
    if group.attempts >= MAX_ATTEMPTS then return self:ExpirePendingItem(scan, itemID) end
    group.attempts = group.attempts + 1
    local token, generation = {}, self.generation
    group.token = token
    local function timedRetry()
        if current(self, scan, generation) and scan.pendingByItem[itemID] == group and group.token == token then
            self:RetryPending(itemID, nil, true)
        end
    end
    -- Install the timeout first: item events can be raised synchronously by test or client adapters.
    C_Timer.After(REQUEST_TIMEOUT, timedRetry)
    local ok = pcall(items().RequestLoadItemDataByID, itemID)
    if not ok then self:RetryPending(itemID, false) end
end
function M:AddPendingRow(scan, row)
    if scan.failedItems[row.itemID] then scan.failedRows = scan.failedRows + 1; return end
    local group = scan.pendingByItem[row.itemID]
    local first = not group
    if first then
        group = { rows = {}, count = 0, attempts = 0 }
        scan.pendingByItem[row.itemID] = group
    end
    group.rows[row.snapshotIndex] = row
    group.count, scan.pendingCount = group.count + 1, scan.pendingCount + 1
    if first then self:RequestPendingItem(scan, row.itemID) end
end
function M:RetryPending(itemID, success, timeout)
    local scan = self.scan
    local group = scan and scan.pendingByItem[itemID]
    if not group then return end
    -- Resolve only this item's rows; unrelated item events are constant-time lookups.
    if success ~= false then
        for index, row in pairs(group.rows) do
            if self:ValueRow(row) then
                group.rows[index] = nil
                group.count, scan.pendingCount = group.count - 1, scan.pendingCount - 1
            end
        end
    end
    if group.count == 0 then
        scan.pendingByItem[itemID] = nil
    elseif success == false or timeout then
        if group.attempts >= MAX_ATTEMPTS then return self:ExpirePendingItem(scan, itemID) end
        local token, generation = {}, self.generation
        group.token = token -- invalidate the request's old timeout and duplicate failure events
        if not group.retryScheduled then
            group.retryScheduled = true
            C_Timer.After(RETRY_DELAY, function()
                if current(self, scan, generation) and scan.pendingByItem[itemID] == group then
                    group.retryScheduled = nil
                    self:RequestPendingItem(scan, itemID)
                end
            end)
        end
    end
    self:ScanProgress()
end
function M:ScanProgress()
    local scan = self.scan
    if not scan then return end
    local pending = scan.pendingCount
    local complete = scan.checked == scan.total and scan.phase ~= "waiting"
    local bucket = math.floor(scan.checked / 1000)
    -- Sort at 1000-row checkpoints and when processing completes, never per inserted row.
    if self.resultsDirty and (complete or scan.sortBucket ~= bucket) then
        scan.sortBucket = bucket
        self:SortResults()
    end
    if self.LogState and (scan.logBucket ~= bucket or (complete and not scan.logComplete)) then
        scan.logBucket, scan.logComplete = bucket, complete
        self:LogState("scan-progress", "Snapshot processing", {checked = scan.checked, total = scan.total,
            deals = #self.results, pending = pending, unavailable = scan.failedRows, invalid = scan.invalidRows})
    end
    -- Status/Refresh re-render the whole window: only at 1000-row checkpoints, on reaching
    -- completion, when the last pending row resolves, or every STATUS_EVERY calls otherwise.
    scan.statusCalls = (scan.statusCalls or 0) + 1
    local final = complete and pending == 0
    if scan.statusBucket ~= bucket or (complete and not scan.statusComplete) or final or scan.statusCalls >= STATUS_EVERY then
        scan.statusBucket, scan.statusComplete, scan.statusCalls = bucket, complete, 0
        local suffix = string.format(" | %d unavailable | %d invalid", scan.failedRows, scan.invalidRows)
        self:SetStatus(string.format("%d/%d listings checked | %d deals | %d awaiting item data", scan.checked, scan.total, #self.results, pending) .. suffix, true)
    end
    if complete then
        scan.phase = "complete"
        if pending == 0 then
            self.lastScan = { total = scan.total, deals = #self.results, unavailable = scan.failedRows, invalid = scan.invalidRows }
            self.scan = nil
        end
    end
end
function M:ReadSnapshot()
    if not self.scan or self.scan.phase ~= "waiting" then return end
    local scan, generation = self.scan, self.generation
    local ok, total = pcall(auction().GetNumReplicateItems)
    if not ok or not integer(total, 0, 10000000) then
        self:StopScan(); return self:SetStatus("Auction snapshot returned an invalid listing count.")
    end
    scan.phase, scan.total = "processing", total
    local index = 0
    local function chunk()
        if not current(self, scan, generation) then return end
        local clock = debugprofilestop
        local started = type(clock) == "function" and clock() or nil
        local limit, processed = scan.total, 0
        if not started then limit = math.min(index + CHUNK_SIZE, scan.total) end
        while index < limit do
            -- pcall shifts the documented return positions by one; avoid a per-row result table.
            local infoOK, name, _, quantity, quality, _, _, _, _, _, cost, _, _, _, _, _, _, itemID =
                pcall(auction().GetReplicateItemInfo, index)
            local linkOK, link = pcall(auction().GetReplicateItemLink, index)
            if infoOK and integer(itemID, 1, 2147483647) and integer(cost, 1) and integer(quantity, 1) then
                local row = { name = name, quantity = quantity, quality = quality,
                    cost = cost, itemID = itemID, link = linkOK and link or nil, snapshotIndex = index }
                if not self:ValueRow(row) then self:AddPendingRow(scan, row) end
            elseif not (infoOK and cost == 0) then scan.invalidRows = scan.invalidRows + 1 end
            index = index + 1
            processed = processed + 1
            if started and processed >= MIN_ROWS and clock() - started >= FRAME_BUDGET_MS then break end
        end
        scan.checked = index
        self:ScanProgress()
        if index < scan.total then C_Timer.After(0, chunk) end
    end
    chunk()
end
function M:Demo()
    if self:QueueBusy() then return self:SetStatus("Finish the buying batch before opening demo data.") end
    self:StopScan()
    self.results = {}
    self.candidates = {}
    for i = 1, 23 do
        local row = { name = "Demo item " .. i, itemID = i, quality = 1,
            quantity = 5, vendor = 100, cost = 200 + i * 5, demo = true }
        self.candidates[#self.candidates + 1] = row
        local metrics = self.Evaluate(row, self.db.settings, 10000000, 0)
        if metrics then
            row.value, row.profit, row.roi = metrics.value, metrics.profit, metrics.roi
            self.results[#self.results + 1] = row
        end
    end
    self:SortResults()
    self:SetStatus("DEMO DATA — no auctions or purchases. Use Scan for real results.")
    self:Show()
end
