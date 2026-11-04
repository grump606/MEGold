"""Scan benchmark (not a test; run_all ignores it).

Usage: python tests/bench_scan.py <rows> <vendorPrice> [nosort]
vendor=150 gives ~5.6% deals; vendor=1000 makes every row a deal. Reports CPU time, sort count,
retained memory per row and Refilter time.
"""
import sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".test-deps"))
from lupa.lua51 import LuaRuntime
N, VENDOR, NOSORT = int(sys.argv[1]), int(sys.argv[2]), len(sys.argv) > 3
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'''
M = {{}}
local pending = {{}}
C_Timer = {{ After = function(d, cb) pending[#pending+1] = cb end }}
function drain() local n=0 while #pending>0 do local cb=table.remove(pending,1); cb(); n=n+1 end return n end
function GetMoney() return 10000000000 end
function M:QueueBusy() return false end
function M:SetStatus(m) self.status=m end
function M:Show() end
function M:LogState() end
function M:Supports() return true end
function M:Refresh() end
N = {N}
C_Item = {{ GetItemInfo = function(link) return "Item", link, 1, nil,nil,nil,nil,nil,nil,nil, {VENDOR} end,
  RequestLoadItemDataByID = function() end }}
C_AuctionHouse = {{ ReplicateItems=function() end, GetNumReplicateItems=function() return N end,
  GetReplicateItemLink=function(i) return "|Hitem:"..(i%5000+1)..":0|h[T]|h" end,
  GetReplicateItemInfo=function(i) return "Item",nil,3,1,nil,nil,nil,nil,nil,400 + i % 900,nil,nil,nil,nil,nil,nil,(i%5000+1) end }}
M.db={{settings={{minProfit=1,minReturn=0,maxCost=100000000,budget=1e11,reserve=0,ignored={{}},buyRarities={{}},batchSize=10}}}}
M.account={{spent=0}}; M.ahOpen=true
''')
for f in ("Util.lua","Rules.lua","Scanner.lua","Settings.lua"):
    try: lua.execute((ROOT/"MEGold"/f).read_text(encoding="utf-8"), "MEGold", lua.globals().M)
    except Exception as e: print("skip", f, str(e)[:80])
if NOSORT: lua.execute("sorts=0; M.SortResults=function(self) self.resultsDirty=false end")
else: lua.execute("sorts=0; local o=M.SortResults; M.SortResults=function(self) sorts=sorts+1; return o(self) end")
lua.execute("collectgarbage(); base=collectgarbage('count')")
t=time.time(); lua.execute("M:StartScan(); M:ReadSnapshot(); frames=drain()"); dt=time.time()-t
print(f"N={N} vendor={VENDOR} nosort={NOSORT}: cpu={dt:.2f}s ({dt/N*1e6:.0f} us/row) results={lua.eval('#M.results')} sorts={lua.eval('sorts')}")
lua.execute("collectgarbage(); after=collectgarbage('count')")
print(f"  retained {lua.eval('(after-base)/1024'):.0f} MB ({lua.eval('(after-base)*1024/N'):.0f} B/row)")
if lua.eval("M.Refilter ~= nil"):
    t=time.time(); lua.execute("M:Refilter()"); print(f"  Refilter {time.time()-t:.2f}s")
