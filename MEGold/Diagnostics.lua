local _, M = ...
local LIMIT, MESSAGE_LIMIT = 500, 2048
local function clean(value, limit)
    return tostring(value):gsub("\r", ""):sub(1, limit or MESSAGE_LIMIT)
end
function M:Log(category, message, fields)
    local log = self.diagnostics
    if not log or not log.enabled then return end
    local parts = {}
    for key, value in pairs(fields or {}) do
        if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
            parts[#parts + 1] = clean(key, 48) .. "=" .. clean(value, 256):gsub("[\r\n]", " ")
        end
    end
    table.sort(parts)
    log.sequence = log.sequence + 1
    log.entries[log.next] = {
        sequence = log.sequence, at = GetServerTime and GetServerTime() or 0,
        category = clean(category, 32), message = clean(message),
        context = clean(table.concat(parts, " "), 1024),
    }
    log.next = log.next % LIMIT + 1
    if log.count < LIMIT then log.count = log.count + 1 else log.dropped = log.dropped + 1 end
end
function M:LogState(category, message, fields)
    fields = fields or {}
    fields.queue = self.queue and self.queue.phase or "uninitialized"
    fields.scan = self.scan and self.scan.phase or "idle"
    fields.vendor = self.vendorRun and self.vendorRun.phase or "idle"
    fields.purchasePending = self.account and self.account.pending ~= nil or false
    fields.vendorPending = self.account and self.account.vendorPending ~= nil or false
    self:Log(category, message, fields)
end
function M:InitializeDiagnostics()
    self.db.diagnostics = self.db.diagnostics or { enabled = true, entries = {}, next = 1, count = 0, sequence = 0, dropped = 0 }
    self.diagnostics = self.db.diagnostics
    local log = self.diagnostics
    local version, build, _, interface
    if GetBuildInfo then version, build, _, interface = GetBuildInfo() end
    log.client = { version = version or "unknown", build = build or "unknown", interface = interface or "unknown",
        project = WOW_PROJECT_ID or "unknown", addon = self.VERSION or "unknown" }
    self:Log("startup", "MEGold loaded", log.client)
    local api = C_AuctionHouse or {}
    self:Log("capabilities", "Auction API availability", {
        replicate = type(api.ReplicateItems) == "function", search = type(api.SendSearchQuery) == "function",
        itemBuy = type(api.PlaceBid) == "function", commodityQuote = type(api.StartCommoditiesPurchase) == "function",
        commodityConfirm = type(api.ConfirmCommoditiesPurchase) == "function",
    })
    -- Chain the previous error handler; record only errors whose message/stack references this addon.
    if geterrorhandler and seterrorhandler and not self.errorHandlerInstalled then
        local previous = geterrorhandler()
        if type(previous) == "function" then
            local handling = false
            seterrorhandler(function(message)
                if not handling then
                    handling = true
                    pcall(function()
                        local stack = debugstack and debugstack(2, 12, 12) or ""
                        local combined = tostring(message) .. "\n" .. stack
                        local relevant = tostring(message):match("[\\/]MEGold[\\/]")
                        for line in stack:gmatch("[^\n]+") do
                            -- The diagnostic wrapper itself appears on every error's stack.
                            if line:match("[\\/]MEGold[\\/]") and not line:match("[\\/]MEGold[\\/]Diagnostics%.lua") then relevant = true end
                        end
                        if relevant then M:LogState("lua-error", combined) end
                    end)
                    handling = false
                end
                return previous(message)
            end)
            self.errorHandlerInstalled = true
        end
    end
end
function M:ClearDiagnostics()
    local log = self.diagnostics
    log.entries, log.next, log.count, log.dropped = {}, 1, 0, 0
    self:Log("diagnostics", "Log cleared")
end
function M:SetDiagnosticsEnabled(enabled)
    local log = self.diagnostics
    if not enabled then self:Log("diagnostics", "Recording disabled") end
    log.enabled = enabled and true or false
    if enabled then self:Log("diagnostics", "Recording enabled") end
end
function M:ExportDiagnostics()
    local log, lines = self.diagnostics, { "MEGold diagnostic report" }
    local client = log.client or {}
    lines[#lines + 1] = string.format("Addon %s | Client %s | Build %s | Interface %s | Project %s",
        tostring(client.addon), tostring(client.version), tostring(client.build), tostring(client.interface), tostring(client.project))
    lines[#lines + 1] = string.format("Recording: %s | Entries: %d/%d | Older entries discarded: %d", tostring(log.enabled), log.count, LIMIT, log.dropped)
    lines[#lines + 1] = string.format("Current queue: %s | Scan: %s | Vendor: %s | Budget spent: %s copper",
        self.queue and self.queue.phase or "uninitialized", self.scan and self.scan.phase or "idle",
        self.vendorRun and self.vendorRun.phase or "idle", tostring(self.account and self.account.spent or 0))
    if self.db then
        lines[#lines + 1] = "Storage schema: " .. tostring(self.db.schemaVersion or "unversioned") ..
            " | Lock: " .. tostring(self.db.storageLocked or (self.account and self.account.storageLocked) or "none")
    end
    for i = 1, log.count do
        local index = (log.next - log.count + i - 2) % LIMIT + 1
        local entry = log.entries[index]
        if entry then
            local stamp = date and date("%Y-%m-%d %H:%M:%S", entry.at) or tostring(entry.at)
            lines[#lines + 1] = string.format("#%d %s [%s] %s%s", entry.sequence, stamp, entry.category,
                entry.message, entry.context ~= "" and " | " .. entry.context or "")
        end
    end
    return table.concat(lines, "\n")
end
local events = CreateFrame("Frame")
local watched = {
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE",
    "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED", "COMMODITY_SEARCH_RESULTS_RECEIVED",
    "COMMODITY_SEARCH_RESULTS_ADDED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
    "COMMODITY_PURCHASED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
    "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_SHOW_ERROR", "MERCHANT_SHOW", "MERCHANT_CLOSED",
    "PLAYER_LOGOUT",
}
for _, event in ipairs(watched) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, a, b)
    local fields = {}
    -- Avoid names, chat, tooltips or arbitrary event payloads in routine entries.
    if event == "COMMODITY_PRICE_UPDATED" then fields.unitPrice, fields.totalPrice = a, b
    elseif event == "COMMODITY_PURCHASED" then fields.itemID, fields.quantity = a, b
    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then fields.auctionID = a
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then fields.itemID = a and a.itemID
    elseif event == "AUCTION_HOUSE_SHOW_ERROR" then fields.errorCode = a end
    M:LogState("event", event, fields)
end)
-- Purchase window: for a short time after a purchase request, record the relevant client events (name and
-- simple arguments) so this client's real confirmation events can be identified. Bounded in time and count.
local CAPTURE_SECONDS, CAPTURE_LIMIT = 20, 60
local CAPTURE_PREFIXES = { "AUCTION", "COMMODITY", "ITEM_", "BID", "PURCHASE", "MAIL", "PLAYER_MONEY",
    "CHAT_MSG_SYSTEM", "UI_ERROR", "UI_INFO", "BAG_UPDATE_DELAYED", "OWNED", "ERR_" }
local capture = CreateFrame("Frame")
M.captureFrame = capture
capture:SetScript("OnEvent", function(frame, event, ...)
    if not frame.token or frame.count >= CAPTURE_LIMIT then return end
    local relevant = false
    for _, prefix in ipairs(CAPTURE_PREFIXES) do
        if event:sub(1, #prefix) == prefix then relevant = true; break end
    end
    if not relevant then return end
    frame.count = frame.count + 1
    local fields = { elapsed = tonumber(string.format("%.1f", GetTime() - frame.started)) }
    for i = 1, math.min(select("#", ...), 4) do
        local value = select(i, ...)
        fields["arg" .. i] = type(value) == "table" and "table" or value
    end
    M:LogState("capture-event", event, fields)
end)
function M:BeginPurchaseCapture(label, moneyBefore)
    local log = self.diagnostics
    if not log or not log.enabled or type(capture.RegisterAllEvents) ~= "function" then return end
    local token = {}
    capture.token, capture.count, capture.started = token, 0, GetTime()
    capture:RegisterAllEvents()
    self:LogState("capture", "Purchase event capture started", { label = label, money = GetMoney() })
    C_Timer.After(CAPTURE_SECONDS, function()
        if capture.token ~= token then return end
        capture:UnregisterAllEvents()
        capture.token = nil
        local fields = { label = label, events = capture.count, money = GetMoney() }
        if M.Integer(moneyBefore) then fields.moneyChange = GetMoney() - moneyBefore end
        M:LogState("capture", "Purchase event capture ended", fields)
    end)
end
M.diagnosticEvents = events
