local _, M = ...
-- Schema changes are additive. Financial array indexes are durable identifiers.
local SCHEMA, MAX_INTEGER = 1, 9007199254740991
local RETENTION = 30 * 86400
local integer = M.Integer
local function now() return GetServerTime and GetServerTime() or 0 end
local function copy(value, depth, seen, budget)
    depth, seen, budget = depth or 0, seen or {}, budget or { 10000 }
    local kind = type(value)
    if kind == "string" then return value:sub(1, 8192) end
    if kind == "number" then return value == value and math.abs(value) <= MAX_INTEGER and value or nil end
    if kind == "boolean" then return value end
    if kind ~= "table" or depth > 10 or seen[value] or budget[1] <= 0 then return nil end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do
        if budget[1] <= 0 then break end
        if type(key) == "string" or integer(key, 1) then
            budget[1] = budget[1] - 1
            result[key] = copy(child, depth + 1, seen, budget)
        end
    end
    seen[value] = nil
    return result
end
local function quarantine(owner, path, value, reason)
    owner.quarantine = type(owner.quarantine) == "table" and owner.quarantine or {}
    owner.quarantine[#owner.quarantine + 1] = { path = path, reason = reason, at = now(), value = copy(value) }
    -- Keep an audit sample bounded. A lock remains until a deliberate recovery is provided.
    if #owner.quarantine > 50 then table.remove(owner.quarantine, 1) end
end
local function lock(owner, path, value, reason)
    owner.storageLocked = owner.storageLocked or (path .. ": " .. reason)
    quarantine(owner, path, value, reason)
end
local function listLength(value)
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if not integer(key, 1) then return nil end
        count = count + 1
    end
    if count ~= #value then return nil end
    return count
end
local function numericMap(value, booleans)
    if type(value) ~= "table" then return nil end
    local result = {}
    for key, enabled in pairs(value) do
        if not integer(key, 1, booleans and 2147483647 or MAX_INTEGER) or (booleans and type(enabled) ~= "boolean") then return nil end
        if booleans then result[key] = enabled
        elseif enabled == true or integer(enabled) then result[key] = enabled
        else return nil end
    end
    return result
end
local function validLink(value) return type(value) == "string" and #value <= 4096 and value:match("item:%d+") ~= nil end
local identity = M.ItemIdentity
local function validPurchase(p, pending)
    if type(p) ~= "table" or not integer(p.itemID, 1, 2147483647) or not integer(p.quantity, 1)
        or not integer(p.cost, pending and 1 or 0) then return false end
    if not p.archived and not validLink(p.link) then return false end
    if p.link ~= nil and (not validLink(p.link) or tonumber(p.link:match("item:(%d+)")) ~= p.itemID) then return false end
    if p.auctionID ~= nil and not integer(p.auctionID, 1) then return false end
    for _, field in ipairs({ "name", "status", "confirmation" }) do
        if p[field] ~= nil and type(p[field]) ~= "string" then return false end
    end
    for _, field in ipairs({ "archived", "held", "commodity", "conflicted" }) do
        if p[field] ~= nil and type(p[field]) ~= "boolean" then return false end
    end
    if p.quality ~= nil and not integer(p.quality, 0, 7) then return false end
    if p.vendor ~= nil and not integer(p.vendor) then return false end
    if p.maxCost ~= nil and not integer(p.maxCost, 1) then return false end
    for _, field in ipairs({ "createdAt", "confirmedAt", "collectedAt", "reviewedAt", "inventoryReview" }) do
        if p[field] ~= nil and not integer(p[field]) then return false end
    end
    local sold = p.sold == nil and 0 or p.sold
    local collected = p.collected == nil and 0 or p.collected
    local costSold = p.costSold == nil and 0 or p.costSold
    if not integer(sold, 0, p.quantity) or not integer(collected, sold, p.quantity)
        or not integer(costSold, 0, p.cost) then return false end
    if (sold == 0 and costSold ~= 0) or (sold == p.quantity and costSold ~= p.cost) then return false end
    if pending and not p.commodity and not p.auctionID then return false end
    return true
end
local function emptyAccount()
    return { spent = 0, purchases = {}, bought = {}, sales = {}, reviews = {}, budgetHistory = {}, vendorReviews = {} }
end
function M:ValidateAccount(raw)
    local account = type(raw) == "table" and raw or emptyAccount()
    if raw ~= nil and type(raw) ~= "table" then lock(account, "account", raw, "expected a table") end
    if account.storageLocked ~= nil and type(account.storageLocked) ~= "string" then account.storageLocked = "Invalid saved storage lock" end
    if not integer(account.spent) then
        lock(account, "spent", account.spent, "invalid spent counter; spending remains disabled")
        account.spent = MAX_INTEGER
    end
    local purchases = account.purchases
    if not listLength(purchases) then lock(account, "purchases", purchases, "invalid purchase array"); purchases = {} end
    account.purchases = purchases
    for index, purchase in ipairs(purchases) do
        if not validPurchase(purchase, false) then
            lock(account, "purchases[" .. index .. "]", purchase, "invalid financial record")
            purchases[index] = { archived = true, quarantined = true, itemID = 1, quantity = 1,
                cost = 0, sold = 1, collected = 1, costSold = 0, held = true, name = "Quarantined purchase" }
        else
            purchase.sold, purchase.collected, purchase.costSold = purchase.sold or 0, purchase.collected or 0, purchase.costSold or 0
            purchase.held = purchase.held == true
            if purchase.name ~= nil and type(purchase.name) ~= "string" then purchase.name = tostring(purchase.itemID) end
        end
    end
    local bought = numericMap(account.bought, false)
    if not bought then lock(account, "bought", account.bought, "invalid duplicate-purchase guards"); bought = {} end
    account.bought = bought
    local sales = account.sales
    if sales == nil then sales = {} end
    if not listLength(sales) then lock(account, "sales", sales, "invalid sale array"); sales = {} end
    account.sales = sales
    local activeAllocations = {}
    for index, sale in ipairs(sales) do
        local valid = type(sale) == "table"
        if valid and sale.archived ~= nil and type(sale.archived) ~= "boolean" then valid = false end
        if valid and sale.reversed ~= nil and type(sale.reversed) ~= "boolean" then valid = false end
        if valid and sale.archived then
            valid = sale.reversed == true
        elseif valid then
            valid = validLink(sale.link) and integer(sale.quantity, 1) and integer(sale.proceeds)
                and integer(sale.flipQuantity, 0, sale.quantity) and integer(sale.flipProceeds, 0, sale.proceeds)
                and integer(sale.cost) and integer(sale.at) and listLength(sale.allocations) ~= nil
            local allocatedQuantity, allocatedCost = 0, 0
            if valid then
                for _, allocation in ipairs(sale.allocations) do
                    local purchase = type(allocation) == "table" and integer(allocation.purchase, 1) and purchases[allocation.purchase]
                    if not purchase or purchase.quarantined or purchase.archived or identity(purchase.link) ~= identity(sale.link)
                        or not integer(allocation.quantity, 1, purchase.quantity)
                        or not integer(allocation.cost, 0, purchase.cost) then valid = false; break end
                    allocatedQuantity, allocatedCost = allocatedQuantity + allocation.quantity, allocatedCost + allocation.cost
                end
                valid = valid and allocatedQuantity == sale.flipQuantity and allocatedCost == sale.cost
            end
        end
        if not valid then
            lock(account, "sales[" .. index .. "]", sale, "invalid sale/allocation record")
            sales[index] = { archived = true, reversed = true, quarantined = true }
        elseif not sale.archived and not sale.reversed then
            for _, allocation in ipairs(sale.allocations) do
                local totals = activeAllocations[allocation.purchase] or { quantity = 0, cost = 0 }
                activeAllocations[allocation.purchase] = totals
                totals.quantity, totals.cost = totals.quantity + allocation.quantity, totals.cost + allocation.cost
            end
        end
    end
    -- Archived receipts may account for part of a purchase's sold balance. Active
    -- receipts can be less than that balance, but can never exceed it.
    for index, totals in pairs(activeAllocations) do
        local purchase = purchases[index]
        if totals.quantity > purchase.sold or totals.cost > purchase.costSold then
            lock(account, "purchase allocations[" .. index .. "]", totals, "active sale allocations exceed recorded sold quantity or purchase cost")
        end
    end
    if account.pending ~= nil and not validPurchase(account.pending, true) then
        lock(account, "pending", account.pending, "invalid pending intent; manual recovery required")
        account.pending = nil
    end
    if account.vendorPending ~= nil then
        local pending = account.vendorPending
        if type(pending) ~= "table" or not validLink(pending.link) or not integer(pending.quantity, 1) then
            lock(account, "vendorPending", pending, "invalid pending vendor intent")
            account.vendorPending = nil
        elseif (pending.token ~= nil and not integer(pending.token, 1))
            or (pending.expectedProceeds ~= nil and not integer(pending.expectedProceeds, 1))
            or (pending.at ~= nil and not integer(pending.at)) then
            lock(account, "vendorPending", pending, "invalid vendor transaction token or expected proceeds")
        elseif pending.allocations ~= nil then
            local valid = listLength(pending.allocations) ~= nil
            local allocated = 0
            if valid then
                for _, allocation in ipairs(pending.allocations) do
                    local purchase = type(allocation) == "table" and purchases[allocation.purchase]
                    if not purchase or purchase.archived or not integer(allocation.quantity, 1, purchase.quantity) then valid = false; break end
                    allocated = allocated + allocation.quantity
                end
            end
            valid = valid and allocated == pending.quantity
            if not valid then lock(account, "vendorPending.allocations", pending.allocations, "invalid reserved purchase references") end
        end
    end
    for _, field in ipairs({ "reviews", "budgetHistory", "vendorReviews", "recoveries" }) do
        if account[field] == nil then account[field] = {}
        elseif not listLength(account[field]) then lock(account, field, account[field], "invalid audit history"); account[field] = {} end
    end
    for _, field in ipairs({ "buybackRows", "inventoryTotals" }) do
        if account[field] ~= nil and type(account[field]) ~= "table" then lock(account, field, account[field], "invalid inventory metadata"); account[field] = nil end
    end
    if account.buybackRows then
        local valid = listLength(account.buybackRows) ~= nil and #account.buybackRows <= 12
        if valid then
            for _, row in ipairs(account.buybackRows) do
                if type(row) ~= "table" or not validLink(row.link) or not integer(row.price) or not integer(row.quantity, 1)
                    or (row.receipt ~= nil and (not integer(row.receipt, 1) or not sales[row.receipt] or sales[row.receipt].archived)) then valid = false; break end
            end
        end
        if not valid then lock(account, "buybackRows", account.buybackRows, "invalid buyback references"); account.buybackRows = nil end
    end
    if account.inventoryTotals then
        for id, quantity in pairs(account.inventoryTotals) do
            if type(id) ~= "string" or not integer(quantity) then lock(account, "inventoryTotals", account.inventoryTotals, "invalid inventory counts"); account.inventoryTotals = nil; break end
        end
    end
    if account.vendorUncertain ~= nil and type(account.vendorUncertain) ~= "table" then
        lock(account, "vendorUncertain", account.vendorUncertain, "invalid recovery state")
        account.vendorUncertain = { reason = "Saved vendor recovery state was malformed", at = now() }
    elseif account.vendorUncertain and type(account.vendorUncertain.reason) ~= "string" then
        lock(account, "vendorUncertain.reason", account.vendorUncertain.reason, "invalid recovery reason")
        account.vendorUncertain.reason = "Saved vendor recovery state was malformed"
    end
    if account.saleArchive ~= nil then
        local valid = type(account.saleArchive) == "table"
        if valid then for _, field in ipairs({ "flipProceeds", "cost", "otherProceeds", "flipQuantity", "otherQuantity" }) do if not integer(account.saleArchive[field]) then valid = false end end end
        if not valid then lock(account, "saleArchive", account.saleArchive, "invalid archived totals"); account.saleArchive = nil end
    end
    if account.vendorSequence ~= nil and not integer(account.vendorSequence) then
        lock(account, "vendorSequence", account.vendorSequence, "invalid vendor transaction sequence")
        account.vendorSequence = 0
    end
    if account.archivedAuditCounts ~= nil then
        local valid = type(account.archivedAuditCounts) == "table"
        if valid then for _, value in pairs(account.archivedAuditCounts) do if not integer(value) then valid = false; break end end end
        if not valid then lock(account, "archivedAuditCounts", account.archivedAuditCounts, "invalid audit summary"); account.archivedAuditCounts = {} end
    end
    return account
end
function M:GetStoredAccount(key)
    local account = self:ValidateAccount(self.db.accounts[key])
    if self.db.storageLocked then account.storageLocked = account.storageLocked or self.db.storageLocked end
    self.db.accounts[key] = account
    return account
end
local function diagnostics(raw)
    local result = { enabled = type(raw) ~= "table" or raw.enabled ~= false, entries = {}, next = 1, count = 0, sequence = 0, dropped = 0 }
    if type(raw) ~= "table" then return result end
    local entries, examined = {}, 0
    for _, entry in pairs(type(raw.entries) == "table" and raw.entries or {}) do
        examined = examined + 1
        if examined > 1000 then break end
        if type(entry) == "table" and integer(entry.sequence, 1) and integer(entry.at)
            and type(entry.category) == "string" and type(entry.message) == "string" then entries[#entries + 1] = entry end
    end
    table.sort(entries, function(a, b) return a.sequence < b.sequence end)
    for i = math.max(1, #entries - 499), #entries do
        local entry = entries[i]
        result.count = result.count + 1
        result.entries[result.count] = { sequence = entry.sequence, at = entry.at, category = entry.category:sub(1, 32),
            message = entry.message:sub(1, 2048), context = type(entry.context) == "string" and entry.context:sub(1, 1024) or "" }
        result.sequence = math.max(result.sequence, entry.sequence)
    end
    result.next = result.count % 500 + 1
    result.sequence = math.max(result.sequence, integer(raw.sequence) and raw.sequence or 0)
    result.dropped = integer(raw.dropped) and raw.dropped or 0
    return result
end
function M:InitializeStorage(raw)
    if type(raw) == "table" and raw.schemaVersion ~= nil
        and (not integer(raw.schemaVersion) or raw.schemaVersion > SCHEMA) then
        -- Never interpret or rewrite unknown financial structures. Keep the exact source
        -- under futureData and expose a safe, locked current-format view to the UI.
        local original = raw.storageFormat == "future-preserved" and type(raw.futureData) == "table" and raw.futureData or raw
        local shell = self:InitializeStorage(nil)
        shell.schemaVersion = original.schemaVersion
        shell.storageFormat, shell.futureData = "future-preserved", original
        shell.storageLocked = "Unsupported saved-data schema; financial data preserved in futureData. Use a compatible addon before transacting."
        shell.diagnostics = diagnostics(raw.diagnostics)
        quarantine(shell, "schemaVersion", original.schemaVersion, "unsupported schema preserved without financial transformation")
        self.db = shell
        return shell
    end
    local db = type(raw) == "table" and raw or {}
    if raw ~= nil and type(raw) ~= "table" then lock(db, "database", raw, "invalid database") end
    local settings = type(db.settings) == "table" and db.settings or {}
    if db.settings ~= nil and type(db.settings) ~= "table" then lock(db, "settings", db.settings, "invalid settings") end
    db.settings = settings
    local defaults = self.defaults -- Core.lua precedes Storage.lua in the TOC
    for _, field in ipairs(self.SettingsSchema) do
        local key = field[1]
        if settings[key] == nil then settings[key] = defaults[key]
        elseif not integer(settings[key], field[3], field[4]) then lock(db, "settings." .. key, settings[key], "invalid limit"); settings[key] = defaults[key] end
    end
    for _, key in ipairs({ "ignored", "neverSell" }) do
        local value = settings[key] == nil and {} or numericMap(settings[key], true)
        if not value then lock(db, "settings." .. key, settings[key], "invalid item protection list"); value = {} end
        settings[key] = value
    end
    for _, key in ipairs({ "buyRarities", "sellRarities" }) do
        if settings[key] == nil then settings[key] = key == "sellRarities" and {[0] = true, [1] = true} or {} end
        local result, valid = {}, type(settings[key]) == "table"
        if valid then for quality, enabled in pairs(settings[key]) do if not integer(quality, 0, 7) or type(enabled) ~= "boolean" then valid = false; break end; result[quality] = enabled end end
        if not valid then lock(db, "settings." .. key, settings[key], "invalid rarity protection list") end
        settings[key] = valid and result or {}
    end
    if db.accounts == nil then db.accounts = {}
    elseif type(db.accounts) ~= "table" then lock(db, "accounts", db.accounts, "invalid account map"); db.accounts = {} end
    for key, account in pairs(db.accounts) do
        if type(key) ~= "string" then lock(db, "accounts key", key, "invalid character key"); db.accounts[key] = nil
        else db.accounts[key] = self:ValidateAccount(account) end
    end
    db.diagnostics = diagnostics(db.diagnostics)
    -- Never relabel a future schema as current; preserving the version preserves the lock.
    if db.schemaVersion == nil or (integer(db.schemaVersion) and db.schemaVersion <= SCHEMA) then db.schemaVersion = SCHEMA end
    self.db = db
    return db
end
function M:MaintainHistory(account)
    if not account or account.storageLocked or account.pending or account.vendorPending then return end
    local protected = {}
    for _, row in ipairs(account.buybackRows or {}) do if row.receipt then protected[row.receipt] = true end end
    local archive = account.saleArchive or { flipProceeds = 0, cost = 0, otherProceeds = 0, flipQuantity = 0, otherQuantity = 0 }
    local changed, cutoff = false, now() - RETENTION
    for index, sale in ipairs(account.sales or {}) do
        if not sale.archived and not protected[index] and integer(sale.at) and sale.at < cutoff then
            if not sale.reversed then
                archive.flipProceeds, archive.cost = archive.flipProceeds + sale.flipProceeds, archive.cost + sale.cost
                archive.otherProceeds = archive.otherProceeds + sale.proceeds - sale.flipProceeds
                archive.flipQuantity, archive.otherQuantity = archive.flipQuantity + sale.flipQuantity, archive.otherQuantity + sale.quantity - sale.flipQuantity
            end
            account.sales[index] = { archived = true, reversed = true, at = sale.at }
            changed = true
        end
    end
    account.saleArchive = archive
    local referenced = {}
    for _, sale in ipairs(account.sales or {}) do for _, allocation in ipairs(sale.allocations or {}) do referenced[allocation.purchase] = true end end
    for index, purchase in ipairs(account.purchases) do
        if not purchase.archived and not referenced[index] and purchase.sold == purchase.quantity
            and integer(purchase.confirmedAt) and purchase.confirmedAt < cutoff then
            account.purchases[index] = { archived = true, held = true, itemID = purchase.itemID, quantity = purchase.quantity,
                cost = purchase.cost, sold = purchase.sold, collected = purchase.collected, costSold = purchase.costSold,
                name = "Archived purchase", confirmedAt = purchase.confirmedAt }
            changed = true
        end
    end
    for auctionID, seenAt in pairs(account.bought) do
        if seenAt == true then account.bought[auctionID] = now()
        elseif integer(seenAt) and seenAt < cutoff then account.bought[auctionID] = nil end
    end
    for _, field in ipairs({ "reviews", "budgetHistory", "vendorReviews" }) do
        local rows = account[field]
        if rows and #rows > 200 then
            account.archivedAuditCounts = account.archivedAuditCounts or {}
            account.archivedAuditCounts[field] = (account.archivedAuditCounts[field] or 0) + #rows - 200
            local retained = {}
            for i = #rows - 199, #rows do retained[#retained + 1] = rows[i] end
            account[field] = retained
        end
    end
    if changed then self:InvalidateProfitTally(account) end
    account.lastMaintenanceAt = now()
end
M.STORAGE_SCHEMA = SCHEMA
