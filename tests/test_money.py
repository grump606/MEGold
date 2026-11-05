"""Money rendering must work on Forever without the removed global API."""
from support import ROOT
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("M = {}")
lua.execute((ROOT / "MEGold" / "Util.lua").read_text(encoding="utf-8"), "MEGold", lua.globals().M)
lua.execute('''
assert(GetCoinTextureString == nil)
C_CurrencyInfo = {GetCoinTextureString = function(value) return "modern:" .. value end}
assert(M.Money(12345) == "modern:12345")
assert(M.Money(-12345) == "-modern:12345")
assert(M.Money(0) == "modern:0")
GetCoinTextureString = function(value) return "legacy:" .. value end
assert(M.Money(5) == "modern:5")
C_CurrencyInfo = nil
assert(M.Money(5) == "legacy:5")
GetCoinTextureString = nil
assert(M.Money(0) == "0c" and M.Money(12345) == "1g 23s 45c")
assert(M.Money(-10000) == "-1g")
assert(M.Money(nil) == "0c")
C_CurrencyInfo = {GetCoinTextureString = function() error("formatter unavailable") end}
assert(M.Money(101) == "1s 1c")
assert(M.Money(0/0) == "?" and M.Money(math.huge) == "?" and M.Money("bad") == "?")
''')
print("PASS: modern-only, legacy, fallback, negative and unavailable money formatting")
