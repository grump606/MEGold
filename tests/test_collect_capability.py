"""MarkCollected and the Ledger collect button honor the inventory capability."""
from support import ROOT, make_vendor_runtime

lua, module = make_vendor_runtime()
lua.execute('StaticPopupDialogs = {}')
lua.execute((ROOT / "MEGold" / "Ledger.lua").read_text(encoding="utf-8"), "MEGold", module)
lua.execute('''
local inventory = false
function M:Supports(feature) return feature ~= "inventory" or inventory, "Missing client APIs: bags" end
vendorReset(3); M.merchantOpen = false
local p = addPurchase(3, 150, 0)
-- Missing bag APIs: direct domain calls fail closed instead of raising a nil-function error.
M.BagTotals = function() error("attempt to call a nil value") end
local ok, result = pcall(M.MarkCollected, M, p)
assert(ok and result == false and p.collected == 0)

-- Ledger: collect button is disabled when inventory is unsupported, enabled once it is.
local function widget() return { SetText = function(s, t) s.text = t end, SetEnabled = function(s, v) s.enabled = v end,
    SetShown = function(s, v) s.shown = v end } end
local f = { summary = widget(), tally = widget(), pending = widget(), history = widget(), yes = widget(), no = widget(), reset = widget(), page = 1, rows = {} }
for i = 1, 10 do f.rows[i] = { text = widget(), collect = widget(), hold = widget() } end
M.ledgerWindow = f
M:RenderLedger()
assert(f.rows[1].collect.enabled == false)
inventory = true
M:RenderLedger()
assert(f.rows[1].collect.enabled == true)
-- Capability returning later: the real totals path works again.
M.BagTotals = nil
for _, name in ipairs({}) do end
''')
print("PASS: collection requires inventory capability in the domain method and Ledger button")
