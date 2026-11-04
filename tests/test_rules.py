"""Execute real Lua rules via lupa; no WoW installation needed."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parents[1] / ".test-deps"))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
module = lua.table()
for source in (Path(__file__).parents[1] / "MEGold").glob("*.lua"):
    lua.execute("assert(loadstring(...))", source.read_text(encoding="utf-8"))
for name in ("Util.lua", "Rules.lua"):
    lua.execute((Path(__file__).parents[1] / "MEGold" / name).read_text(), "MEGold", module)
settings = lua.table_from(dict(minProfit=1, minReturn=0, maxCost=10000,
                              budget=10000, reserve=0,
                              ignored=lua.table(), buyRarities=lua.table()))

def evaluate(cost=300, vendor=100, quantity=5, money=10000, spent=0):
    deal = lua.table_from(dict(itemID=1, quality=1, cost=cost, vendor=vendor, quantity=quantity))
    return module.Evaluate(deal, settings, money, spent)

assert evaluate().profit == 200
assert evaluate(cost=500)[0] is None  # break-even
assert evaluate(cost=501)[0] is None
assert evaluate(vendor=0)[0] is None
assert evaluate(quantity=0)[0] is None
assert evaluate(quantity=float("inf"))[0] is None
assert evaluate(cost=float("nan"))[0] is None
assert evaluate(money=-1)[0] is None
settings.minProfit = 201
assert evaluate()[0] is None
settings.minProfit = 200
assert evaluate().profit == 200
settings.minReturn = 67
assert evaluate()[0] is None
settings.minReturn = 0
settings.reserve = 9701
assert evaluate()[0] is None
settings.reserve = 9700
assert evaluate().profit == 200
settings.reserve = 0
assert evaluate(spent=9701)[0] is None
settings.ignored[1] = True
assert evaluate()[0] is None
settings.ignored[1] = None
settings.buyRarities[1] = False
assert evaluate()[0] is None
print("PASS: Lua vendor-profit, threshold, budget, reserve, and exclusion checks")
module.SortResults = lua.eval("function() end")  # Scanner.lua is not loaded in this fixture
lua.execute((Path(__file__).parents[1] / "MEGold" / "Settings.lua").read_text(), "MEGold", module)
values = lua.table_from(dict(minProfit="1", minReturn="5", maxCost="10000",
                             budget="50000", reserve="0", batchSize="10"))
assert module.ValidateSettings(values).batchSize == 10
for invalid in ("0", "11", "1.5", "abc", "nan", "inf", ""):
    values.batchSize = invalid
    assert module.ValidateSettings(values)[0] is None
values.batchSize = "5"
assert module.ValidateSettings(values).batchSize == 5
lua.globals().GetMoney = lambda: 10000
module.db = lua.table_from(dict(settings=settings))
module.candidates = lua.table_from([lua.table_from(dict(itemID=1, quality=1,
    cost=300, vendor=100, quantity=5))])
module.Refresh = lambda *_: None
module.Refilter(module)
assert len(module.results) == 0  # rarity currently excluded
settings.buyRarities[1] = True
module.Refilter(module)
assert len(module.results) == 1  # restored without rescanning
settings.minProfit = 201
module.Refilter(module)
assert len(module.results) == 0
print("PASS: settings validation and bidirectional refiltering")
ids = module.ParseItemIDs("123, 456 123")
assert ids[123] and ids[456]
for invalid in ("-1", "1.2", "abc", "0", "2147483648", "1;2"):
    assert module.ParseItemIDs(invalid)[0] is None
assert len(list(module.ParseItemIDs("").items())) == 0
print("PASS: item exclusion list validation")
