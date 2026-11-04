local _, M = ...
-- Deliberate, audited clearing of a storage lock caused by quarantined (already replaced) records.
-- Unsupported/future schemas and unresolved pending transactions are never unlocked here.
local MAX_AUDIT, MAX_PATHS, POPUP_LINES = 200, 20, 8
local function now() return GetServerTime and GetServerTime() or 0 end
local function clone(value, depth)
    if type(value) ~= "table" then return value end
    if depth > 12 then return nil end
    local result = {}
    for key, child in pairs(value) do result[key] = clone(child, depth + 1) end
    return result
end
local function futureSchema(db)
    return db.storageFormat == "future-preserved" or db.futureData ~= nil
        or (db.schemaVersion ~= nil and (type(db.schemaVersion) ~= "number" or db.schemaVersion > (M.STORAGE_SCHEMA or 1)))
end
local function describe(owner, where, list)
    for _, entry in ipairs(type(owner.quarantine) == "table" and owner.quarantine or {}) do
        if type(entry) == "table" then
            list[#list + 1] = where .. tostring(entry.path) .. ": " .. tostring(entry.reason)
        end
    end
end
-- Returns true, details or false, reason.
function M:EvaluateRecovery()
    local account, db = self.account, self.db
    if not account or not db then return false, "Character data is not initialized yet." end
    if futureSchema(db) then
        return false, "Saved data uses an unsupported or newer schema. It stays locked; use a compatible addon version."
    end
    if not account.storageLocked and not db.storageLocked then return false, "Storage is not locked." end
    if account.pending then
        return false, "A purchase is unresolved. Resolve it in Transactions before unlocking."
    end
    if account.vendorPending then
        return false, "A vendor sale is unresolved. Verify inventory and buyback before unlocking."
    end
    if self.vendorRun then return false, "A vendor sale is in progress." end
    -- Re-run validation on a copy without the lock: data that would simply lock again is not recoverable.
    local probe = clone(account, 0)
    probe.storageLocked, probe.quarantine = nil, nil
    probe = self:ValidateAccount(probe)
    if probe.storageLocked then
        return false, "Saved records are still invalid and would lock again: " .. probe.storageLocked
    end
    local paths = {}
    describe(account, "", paths)
    describe(db, "settings/db: ", paths)
    return true, { paths = paths, accountReason = account.storageLocked, dbReason = db.storageLocked }
end
function M:UnlockStorage()
    local ok, details = self:EvaluateRecovery()
    if not ok then return false, details end
    local account, db = self.account, self.db
    local paths = {}
    for i = 1, math.min(#details.paths, MAX_PATHS) do paths[i] = details.paths[i]:sub(1, 300) end
    local entry = { at = now(), accountReason = details.accountReason and details.accountReason:sub(1, 300) or nil,
        dbReason = details.dbReason and details.dbReason:sub(1, 300) or nil, quarantined = #details.paths, paths = paths }
    account.recoveries = type(account.recoveries) == "table" and account.recoveries or {}
    account.recoveries[#account.recoveries + 1] = entry
    while #account.recoveries > MAX_AUDIT do table.remove(account.recoveries, 1) end
    -- Quarantine samples are kept as evidence. Only the locks are cleared.
    account.storageLocked, db.storageLocked = nil, nil
    if self.queue and type(self.queue.message) == "string" and self.queue.message:find("^Transactions locked") then
        self.queue.message = nil
    end
    if self.LogState then
        self:LogState("recovery", "Storage lock cleared by user", { quarantined = #details.paths,
            accountReason = entry.accountReason or "none", dbReason = entry.dbReason or "none" })
    end
    self:Refresh()
    return true, entry
end
function M:RequestUnlock()
    local ok, details = self:EvaluateRecovery()
    if not ok then
        local message = "Unlock refused: " .. details
        if self.LogState then self:LogState("recovery", message) end
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("MEGold: " .. message) end
        return false, details
    end
    local lines = { "Clear the MEGold storage lock?", "", "Invalid saved records were quarantined and replaced with safe placeholders. Quarantined samples are kept. Spending counters are not restored." }
    for i = 1, math.min(#details.paths, POPUP_LINES) do lines[#lines + 1] = "- " .. details.paths[i]:sub(1, 120) end
    if #details.paths > POPUP_LINES then lines[#lines + 1] = "... and " .. (#details.paths - POPUP_LINES) .. " more" end
    if #details.paths == 0 then lines[#lines + 1] = "Lock reason: " .. tostring(details.accountReason or details.dbReason) end
    StaticPopup_Show("MEGOLD_UNLOCK_STORAGE", table.concat(lines, "\n"))
    return true
end
StaticPopupDialogs.MEGOLD_UNLOCK_STORAGE = {
    text = "%s", button1 = ACCEPT or "Accept", button2 = CANCEL or "Cancel", timeout = 0, whileDead = true, hideOnEscape = true,
    OnAccept = function()
        local ok, reason = M:UnlockStorage()
        if not ok and DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("MEGold: Unlock refused: " .. tostring(reason)) end
    end,
}
