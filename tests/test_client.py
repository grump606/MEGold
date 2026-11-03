"""Client feature contracts and lock gates are explicit and independent of UI mocks."""
from support import ROOT, make_queue_runtime

lua, module = make_queue_runtime()
lua.execute('''
C_AddOns = {GetAddOnMetadata = function(_, key) return key == "Version" and "0.6.0" end}
iface = 16001
function GetBuildInfo() return "1.60.1", "test", "today", iface end
C_Container, C_Item = {}, C_Item or {}
for _, name in ipairs({"ReplicateItems", "GetNumReplicateItems", "GetReplicateItemInfo", "GetReplicateItemLink",
    "MakeItemKey", "GetItemKeyInfo", "IsThrottledMessageSystemReady", "SendSearchQuery", "HasFullItemSearchResults",
    "RequestMoreItemSearchResults", "GetNumItemSearchResults", "GetItemSearchResultInfo", "PlaceBid",
    "HasFullCommoditySearchResults", "RequestMoreCommoditySearchResults", "GetNumCommoditySearchResults", "GetCommoditySearchResultInfo",
    "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "CancelCommoditiesPurchase", "GetQuoteDurationRemaining"}) do
    if not C_AuctionHouse[name] then C_AuctionHouse[name] = function() end end
end
C_Item.RequestLoadItemDataByID = function() end
for _, name in ipairs({"GetContainerNumSlots", "GetContainerItemInfo", "GetContainerNumFreeSlots", "GetContainerItemEquipmentSetInfo",
    "SplitContainerItem", "PickupContainerItem", "UseContainerItem"}) do C_Container[name] = function() end end
for _, name in ipairs({"GetNumBuybackItems", "GetBuybackItemInfo", "GetBuybackItemLink", "GetCursorInfo", "InCombatLockdown"}) do _G[name] = function() end end
''')
lua.execute((ROOT / "MEGold" / "Client.lua").read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
M:InitializeClient()
assert(M.VERSION == "0.6.0" and M.Client.flavor == "forever")
assert(M:Supports("scan") and M:Supports("vendor") and M:Supports("inventory"))
assert(not M:CanTransact("itemBuy")) -- stable identity is required
reset(); assert(M:CanTransact("itemBuy") and M:CanTransact("commodityBuy"))
M.account.storageLocked = "bad ledger"
local allowed, reason = M:CanTransact("itemBuy")
assert(not allowed and reason == "bad ledger")
M.account.storageLocked = nil; M.db.storageLocked = "future schema"
assert(not M:CanTransact("vendor"))
M.db.storageLocked = nil
C_AuctionHouse.RequestMoreItemSearchResults = nil
M:InitializeClient()
assert(not M:Supports("itemBuy") and M:Supports("commodityBuy"))
assert(M.Client.reasons.itemBuy:find("RequestMoreItemSearchResults", 1, true))
iface = 120105; M:InitializeClient()
assert(not M:Supports("scan") and not M:Supports("vendor"))
GetBuildInfo = nil; M:InitializeClient()
assert(M.Client.flavor == "unsupported")
''')
print("PASS: explicit client adapter, metadata version, partial API denial, stable identity and saved-data transaction locks")
