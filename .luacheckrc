std = "lua51"
max_line_length = false
self = false -- colon methods on the shared addon table need not use self

globals = {
    "MEGoldDB",
    "SLASH_MEGOLD1",
    "SLASH_MEGOLD2",
    "SlashCmdList",
    "StaticPopupDialogs",
}

read_globals = {
    -- frames and UI
    "CreateFrame", "UIParent", "DEFAULT_CHAT_FRAME", "GameTooltip", "MerchantFrame",
    -- namespaced APIs
    "C_AddOns", "C_AuctionHouse", "C_Container", "C_Item", "C_Timer",
    -- legacy / misc APIs
    "GetAddOnMetadata", "GetBuildInfo", "GetBuybackItemInfo", "GetBuybackItemLink",
    "GetCoinTextureString", "GetContainerItemEquipmentSetInfo", "GetContainerItemInfo",
    "GetContainerNumFreeSlots", "GetContainerNumSlots", "GetCursorInfo", "GetItemInfo",
    "GetMoney", "GetNumBuybackItems", "GetServerTime", "GetTime", "InCombatLockdown",
    "PickupContainerItem", "SplitContainerItem", "UnitGUID", "UseContainerItem",
    -- constants
    "NUM_BAG_SLOTS", "NUM_TOTAL_EQUIPPED_BAG_SLOTS", "WOW_PROJECT_ID", "ACCEPT", "CANCEL", "ChatFontNormal",
    -- more client functions
    "hooksecurefunc", "geterrorhandler", "seterrorhandler", "debugstack", "date", "debugprofilestop",
    "StaticPopup_Show", "InRepairMode",
}
