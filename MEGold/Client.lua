local _, M = ...
-- Modern auction contract. Future client adapters must implement these same operations;
-- business rules and accounting do not decide which WoW API flavor to use.
local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
M.VERSION = metadata and metadata("MEGold", "Version") or "development"
M.Client = { Auction = C_AuctionHouse or {}, Bags = C_Container or {}, Items = C_Item or {} }
local requirements = {
    inventory = { Bags = { "GetContainerNumSlots", "GetContainerItemInfo" } },
    scan = { Auction = { "ReplicateItems", "GetNumReplicateItems", "GetReplicateItemInfo", "GetReplicateItemLink" },
        Items = { "GetItemInfo", "RequestLoadItemDataByID" } },
    itemBuy = { Auction = { "MakeItemKey", "GetItemKeyInfo", "IsThrottledMessageSystemReady", "SendSearchQuery",
        "HasFullItemSearchResults", "RequestMoreItemSearchResults", "GetNumItemSearchResults", "GetItemSearchResultInfo", "PlaceBid" },
        Items = { "GetItemInfo" } },
    commodityBuy = { Auction = { "MakeItemKey", "GetItemKeyInfo", "IsThrottledMessageSystemReady", "SendSearchQuery",
        "HasFullCommoditySearchResults", "RequestMoreCommoditySearchResults", "GetNumCommoditySearchResults", "GetCommoditySearchResultInfo",
        "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "CancelCommoditiesPurchase", "GetQuoteDurationRemaining" },
        Items = { "GetItemInfo" } },
    vendor = { Bags = { "GetContainerNumSlots", "GetContainerItemInfo", "GetContainerNumFreeSlots", "GetContainerItemEquipmentSetInfo",
        "SplitContainerItem", "PickupContainerItem", "UseContainerItem" }, Items = { "GetItemInfo" } },
}
function M:InitializeClient()
    local client = self.Client
    local interface
    if type(GetBuildInfo) == "function" then interface = select(4, GetBuildInfo()) end
    client.interface = interface
    client.flavor = type(interface) == "number" and interface >= 16000 and interface < 17000 and "forever" or "unsupported"
    client.features, client.reasons = {}, {}
    for feature, namespaces in pairs(requirements) do
        local missing = {}
        for namespace, names in pairs(namespaces) do
            for _, name in ipairs(names) do
                if type(client[namespace][name]) ~= "function" then missing[#missing + 1] = namespace .. "." .. name end
            end
        end
        if feature == "vendor" then
            for _, name in ipairs({ "GetNumBuybackItems", "GetBuybackItemInfo", "GetBuybackItemLink", "GetCursorInfo", "InCombatLockdown" }) do
                if type(_G[name]) ~= "function" then missing[#missing + 1] = name end
            end
        end
        table.sort(missing)
        client.features[feature] = client.flavor == "forever" and #missing == 0
        client.reasons[feature] = client.flavor ~= "forever" and "This client build has no supported MEGold adapter."
            or (#missing > 0 and "Missing client APIs: " .. table.concat(missing, ", ") or nil)
    end
end
function M:Supports(feature)
    local client = self.Client
    return client.features and client.features[feature] == true,
        client.reasons and client.reasons[feature] or "Client capabilities are not initialized."
end
function M:CanTransact(feature)
    if self.db and self.db.storageLocked then return false, self.db.storageLocked end
    if not self.account then return false, "Waiting for a stable character identity." end
    if self.account.storageLocked then return false, self.account.storageLocked end
    return self:Supports(feature)
end
