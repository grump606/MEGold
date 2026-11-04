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
