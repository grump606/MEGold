"""Shared deterministic Lua 5.1 auction fixture. Importing this module runs no tests."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime


def make_queue_runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('''
    M = {}
    timers, bids, searches, results = {}, {}, {}, {}
    now, funds, commodity, throttle = 100, 10000, false, true
    function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end
    function UnitGUID() return "Player-test" end
    function GetMoney() return funds end
    function GetTime() return now end
    function GetServerTime() return now end
    function GetCoinTextureString(n) return tostring(n) end
    C_Timer = { After = function(seconds, callback) table.insert(timers, callback) end }
    C_Item = { GetItemInfo = function(link)
        return "Test", link, 1, nil, nil, nil, nil, nil, nil, nil, 100
    end }
    C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id } end,
        GetItemKeyInfo = function() return { isCommodity = commodity } end,
        IsThrottledMessageSystemReady = function() return throttle end,
        SendSearchQuery = function(key) table.insert(searches, key) end,
        GetNumItemSearchResults = function() return #results end,
        GetItemSearchResultInfo = function(key, index) return results[index] end,
        PlaceBid = function(id, cost) table.insert(bids, { id = id, cost = cost }) end,
    }
    function M:Refresh() end
    function M:SetStatus(message) self.status = message end
    function M:StopScan() end
    function reset()
        timers, bids, searches, results = {}, {}, {}, {}
        now, funds, commodity, throttle = 100, 10000, false, true
        M.db = { settings = { minProfit = 1, minReturn = 0, maxCost = 10000,
            budget = 10000, reserve = 0, ignored = {}, buyRarities = {}, batchSize = 10 } }
        M.ahOpen = true
        M.results = { { name = "Test", itemID = 1, link = "|Hitem:1:0|h[Test]|h",
            vendor = 100, quality = 1, quantity = 5, cost = 300 } }
        M:InitializeQueue()
        results = { { auctionID = 42, itemLink = "|Hitem:1:0|h[Test]|h",
            quantity = 5, buyoutAmount = 300 } }
    end
    function ready()
        M:BuildBatch()
        assert(M.queue.phase == "searching")
        M:QueueResults({itemID = 1})
        assert(M.queue.phase == "ready")
    end
    ''')
    module = lua.globals().M
    for filename in ("Rules.lua", "State.lua", "Queue.lua"):
        lua.execute((ROOT / "MEGold" / filename).read_text(encoding="utf-8"), "MEGold", module)
    return lua, module


def make_vendor_runtime():
    lua, module = make_queue_runtime()
    lua.execute('''
    bags, buyback, cursor = {}, {}, nil
    NUM_TOTAL_EQUIPPED_BAG_SLOTS = 0
    MerchantFrame = { IsShown = function() return true end }
    function InCombatLockdown() return false end
    function GetCursorInfo() if cursor then return "item", 1, cursor.hyperlink end end
    function GetNumBuybackItems() return #buyback end
    function GetBuybackItemInfo(i) return "Test", nil, buyback[i].price, buyback[i].quantity end
    function GetBuybackItemLink(i) return buyback[i].link end
    C_Container = {
        GetContainerNumSlots = function() return 4 end,
        GetContainerItemInfo = function(bag, slot) return bags[slot] end,
        GetContainerNumFreeSlots = function() return 1, 0 end,
        GetContainerItemEquipmentSetInfo = function() return false end,
        SplitContainerItem = function(bag, slot, quantity)
            assert(not cursor)
            local item = bags[slot]
            cursor = { hyperlink = item.hyperlink, itemID = 1, stackCount = quantity }
            item.stackCount = item.stackCount - quantity
        end,
        PickupContainerItem = function(bag, slot)
            assert(not bags[slot]); bags[slot], cursor = cursor, nil
        end,
        UseContainerItem = function(bag, slot)
            local item = bags[slot]
            table.insert(buyback, {link = item.hyperlink, quantity = item.stackCount, price = item.stackCount * 100})
            if #buyback > 12 then table.remove(buyback, 1) end
            funds = funds + item.stackCount * 100
            bags[slot] = nil
        end,
    }
    function item(quantity) return { hyperlink = "|Hitem:1:0|h[Test]|h", itemID = 1, stackCount = quantity } end
    function vendorReset(quantity)
        reset(); bags, buyback, cursor = {item(quantity)}, {}, nil
        M.db.settings.neverSell, M.db.settings.sellRarities = {}, {[1] = true}
        M.vendorRun, M.vendorReview, M.vendorObservation = nil, nil, nil
        M.merchantOpen = true
        M.vendorSnapshot = {rows = {}, money = funds, totals = M:BagTotals()}
    end
    function addPurchase(quantity, cost, collected)
        local purchase = {name = "Test", itemID = 1, link = "|Hitem:1:0|h[Test]|h",
            quantity = quantity, cost = cost, collected = collected}
        table.insert(M.account.purchases, purchase)
        return purchase
    end
    ''')
    for filename in ("Profit.lua", "Vendor.lua", "Inventory.lua"):
        lua.execute((ROOT / "MEGold" / filename).read_text(encoding="utf-8"), "MEGold", module)
    return lua, module
