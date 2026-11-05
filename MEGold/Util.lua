local _, M = ...
-- Shared helpers and the single numeric-settings schema. Loaded right after Core.lua.
local MAX_INTEGER = 9007199254740991
M.MAX_INTEGER = MAX_INTEGER

-- True for finite whole numbers in [minimum or 0, maximum or MAX_INTEGER]; false for everything else
-- (nil, non-numbers, NaN, +/-inf, fractions).
function M.Integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value >= (minimum or 0)
        and value <= (maximum or MAX_INTEGER) and value % 1 == 0
end

-- "item:ID:..." portion of an item link, or nil for non-strings and strings without one.
function M.ItemIdentity(link) return type(link) == "string" and link:match("(item:[^|]+)") or nil end

-- Forever exposes coin formatting under C_CurrencyInfo. Keep display failures
-- from aborting scans/transactions on clients without the old global helper.
function M.Money(amount)
    amount = amount or 0
    if type(amount) ~= "number" or not M.Integer(math.abs(amount)) then return "?" end
    local absolute, sign = math.abs(amount), amount < 0 and "-" or ""
    local modern = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString
    for _, formatter in ipairs({ modern or false, GetCoinTextureString or false }) do
        if type(formatter) == "function" then
            local ok, result = pcall(formatter, absolute)
            if ok and type(result) == "string" and result ~= "" then return sign .. result end
        end
    end
    local gold = math.floor(absolute / 10000)
    local silver = math.floor(absolute / 100) % 100
    local copper = absolute % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = string.format("%.0fg", gold) end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if copper > 0 or #parts == 0 then parts[#parts + 1] = copper .. "c" end
    return sign .. table.concat(parts, " ")
end

-- Numeric settings schema: { key, label, minimum, maximum }. Defaults live in M.defaults (Core.lua).
-- Settings.lua (UI and ValidateSettings) and Storage.lua (load-time validation) both read this.
M.SettingsSchema = {
    { "minProfit", "Minimum profit (copper)", 0, 100000000000 },
    { "minReturn", "Minimum return (%)", 0, 1000000 },
    { "maxCost", "Maximum purchase (copper)", 1, 100000000000 },
    { "budget", "Session budget (copper)", 0, 100000000000 },
    { "reserve", "Gold reserve (copper)", 0, 100000000000 },
    { "batchSize", "Deals per batch (1–10)", 1, 10 },
}
