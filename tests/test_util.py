"""Shared helpers (Integer, ItemIdentity) and the single settings schema."""
from pathlib import Path
import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
function GetServerTime() return 100 * 86400 end
M = {}
M.defaults = { batchSize = 10, minProfit = 1, minReturn = 0, maxCost = 100000, budget = 1000000, reserve = 0, prefetch = 1 }
''')
module = lua.globals().M
for filename in ("Util.lua", "Storage.lua", "Settings.lua"):
    lua.execute((ROOT / "MEGold" / filename).read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
local I, MAX = M.Integer, 9007199254740991
local nan, inf = 0/0, 1/0
assert(I(0) and I(5) and I(MAX))
assert(not I(MAX + 2) and not I(nil) and not I("5") and not I({}) and not I(true))
assert(not I(nan) and not I(inf) and not I(-inf))
assert(not I(-1) and not I(1.5) and not I(0.1))
assert(not I(0, 1) and I(1, 1) and I(-3, -5) and not I(-6, -5))        -- default minimum is 0
assert(I(7, 0, 7) and not I(8, 0, 7) and I(7, 1, 7) and not I(0, 1, 7))
assert(I(MAX, 0, nil) and not I(inf, 0, inf))

local id = M.ItemIdentity
assert(id("|Hitem:12:0:1|h[X]|h") == "item:12:0:1")
assert(id(nil) == nil and id(5) == nil and id(false) == nil and id({}) == nil)
assert(id("no link here") == nil and id("") == nil)

-- Compact age text.
assert(M.AgeText(0) == "0s" and M.AgeText(45.9) == "45s" and M.AgeText(60) == "1m 00s")
assert(M.AgeText(185) == "3m 05s" and M.AgeText(3599) == "59m 59s" and M.AgeText(3720) == "1h 02m")
assert(M.AgeText(-5) == "0s" and M.AgeText(nil) == "0s")

-- One schema: Settings validation and Storage validation use identical bounds.
assert(type(M.SettingsSchema) == "table" and #M.SettingsSchema == 7)
for _, field in ipairs(M.SettingsSchema) do
    local key, label, lo, hi = field[1], field[2], field[3], field[4]
    assert(M.defaults[key] ~= nil and I(M.defaults[key], lo, hi), "default in bounds: " .. key)
    local function values(v)
        local t = {}
        for _, f in ipairs(M.SettingsSchema) do t[f[1]] = tostring(M.defaults[f[1]]) end
        t[key] = tostring(v); return t
    end
    local function stored(v)
        local settings = {}
        settings[key] = v
        return M:InitializeStorage({ settings = settings })
    end
    for _, ok in ipairs({ lo, hi }) do
        assert(M.ValidateSettings(values(ok)), "settings accepts " .. key)
        local db = stored(ok)
        assert(not db.storageLocked and db.settings[key] == ok, "storage accepts " .. key)
    end
    for _, bad in ipairs({ lo - 1, hi + 1 }) do
        local validated, err = M.ValidateSettings(values(bad))
        assert(validated == nil and err == label .. " must be a whole number between " .. lo .. " and " .. hi .. ".")
        local db = stored(bad)
        assert(db.storageLocked and db.settings[key] == M.defaults[key], "storage rejects " .. key)
    end
end
''')
print("PASS: shared Integer/ItemIdentity helpers and single settings schema")
