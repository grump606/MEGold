local _, M = ...
M.defaults = { batchSize = 10, minProfit = 1, minReturn = 0, maxCost = 100000,
    budget = 1000000, reserve = 0, ignored = {}, neverSell = {}, buyRarities = {}, sellRarities = { [0] = true, [1] = true } }
M.results = {}
M.status = "Open the auction house to scan."
M.events = CreateFrame("Frame")
function M:Refresh()
    if self.Render and self.window and self.window:IsShown() then self:Render() end
    if self.RenderLedger and self.ledgerWindow and self.ledgerWindow:IsShown() then self:RenderLedger() end
    if self.RenderVendor and self.vendorWindow and self.vendorWindow:IsShown() then self:RenderVendor() end
end
function M:SetStatus(message, quiet)
    if not quiet and self.LogState then self:LogState("status", message) end
    self.status = message
    self:Refresh()
end
M.events:RegisterEvent("ADDON_LOADED")
M.events:RegisterEvent("AUCTION_HOUSE_SHOW")
M.events:RegisterEvent("AUCTION_HOUSE_CLOSED")
M.events:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
M.events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
M.events:RegisterEvent("PLAYER_ENTERING_WORLD")
M.events:RegisterEvent("PLAYER_LOGOUT")
function M:TryInitializeCharacter()
    if self.account then return true end
    if not self.db or not UnitGUID("player") then return false end
    if self:InitializeQueue() then
        self:LogState("startup", "Saved character state initialized", {schema = self.db.schemaVersion,
            storageLocked = self.account.storageLocked ~= nil, lockReason = self.account.storageLocked or "none"})
        return true
    end
    return false
end
M.events:SetScript("OnEvent", function(_, event, arg, success)
    if event == "ADDON_LOADED" and arg == "MEGold" then
        MEGoldDB = M:InitializeStorage(MEGoldDB)
        M:InitializeClient()
        M:InitializeDiagnostics()
        M:TryInitializeCharacter()
    elseif event == "PLAYER_ENTERING_WORLD" then
        M:TryInitializeCharacter()
    elseif event == "PLAYER_LOGOUT" and M.account then
        M:MaintainHistory(M.account)
    elseif event == "AUCTION_HOUSE_SHOW" then
        M.ahOpen = true
        if M:TryInitializeCharacter() then M:Show() end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        M.ahOpen = false
        M:StopScan()
        if M.queue then M:CloseQueue() end
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        M:ReadSnapshot()
    elseif event == "GET_ITEM_INFO_RECEIVED" and M.scan then
        M:RetryPending(arg, success)
    end
end)
SLASH_MEGOLD1 = "/megold"
SLASH_MEGOLD2 = "/meg"
SlashCmdList.MEGOLD = function(message)
    if not M.db then return end
    if message == "logs" or message == "diagnostics" then return M:ShowDiagnostics() end
    if not M:TryInitializeCharacter() then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("MEGold: waiting for character identity. Try again after entering the world.") end
        return
    end
    if message == "demo" then M:Demo()
    elseif message == "unlock" then M:RequestUnlock()
    elseif message == "ledger" then M:ShowLedger()
    elseif message == "vendor" then
        if M.merchantOpen then M:ShowVendor() else M:SetStatus("Open a vendor first."); M:Show() end
    else M:Show() end
end
