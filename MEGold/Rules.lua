local _, M = ...
-- Pure strategy rules: all money is integer copper; cost is for the entire lot.
local MAX_INTEGER = 9007199254740991
local function integer(value, minimum)
    return type(value) == "number" and value == value and value >= (minimum or 0)
        and value <= MAX_INTEGER and value % 1 == 0
end
function M.Evaluate(deal, settings, money, spent)
    if type(deal) ~= "table" or not integer(deal.vendor, 1) then return nil, "unknown vendor value" end
    if not integer(deal.cost, 1) or not integer(deal.quantity, 1) or not integer(deal.itemID, 1) then return nil, "invalid lot" end
    if type(settings) ~= "table" or type(settings.ignored) ~= "table" or type(settings.buyRarities) ~= "table" then return nil, "invalid settings" end
    for _, field in ipairs({ "minProfit", "minReturn", "maxCost", "budget", "reserve" }) do
        if not integer(settings[field]) then return nil, "invalid settings" end
    end
    if not integer(money) or not integer(spent or 0) then return nil, "invalid balance" end
    if settings.ignored[deal.itemID] then return nil, "ignored" end
    if settings.buyRarities[deal.quality] == false then return nil, "rarity excluded" end
    local value = deal.vendor * deal.quantity
    if value > MAX_INTEGER then return nil, "vendor total exceeds supported range" end
    local profit = value - deal.cost
    if profit <= 0 or profit < settings.minProfit then return nil, "profit too low" end
    if profit / deal.cost * 100 < settings.minReturn then return nil, "return too low" end
    if deal.cost > settings.maxCost then return nil, "purchase limit" end
    if deal.cost + (spent or 0) > settings.budget then return nil, "budget" end
    if deal.cost > money - settings.reserve then return nil, "gold reserve" end
    return { value = value, profit = profit, roi = profit / deal.cost * 100 }
end
