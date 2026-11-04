local _, M = ...
local Bags = M.Client and M.Client.Bags or C_Container
local Items = M.Client and M.Client.Items or C_Item
local function lastBag() return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 end
local function same(a, b)
    return a and b and M.ItemIdentity(a.link) == M.ItemIdentity(b.link) and a.quantity == b.quantity and a.price == b.price
end
local function totalsSame(a, b)
    for id, quantity in pairs(a) do if (b[id] or 0) ~= quantity then return false end end
    for id, quantity in pairs(b) do if (a[id] or 0) ~= quantity then return false end end
    return true
end
function M:BagTotals()
    local totals = {}
    for bag = 0, lastBag() do
        for slot = 1, Bags.GetContainerNumSlots(bag) do
            local item = Bags.GetContainerItemInfo(bag, slot)
            local id = item and self.ItemIdentity(item.hyperlink)
            if id then totals[id] = (totals[id] or 0) + item.stackCount end
        end
    end
    return totals
end
function M:ReadBuyback()
    local rows = {}
    for index = 1, GetNumBuybackItems() do
        local _, _, price, quantity = GetBuybackItemInfo(index)
        local link = GetBuybackItemLink(index)
        if not link or not price or not quantity then return nil end
        rows[#rows + 1] = { link = link, price = price, quantity = quantity }
    end
    return rows
end
function M:VendorUncertain(reason)
    self.account.vendorUncertain = { reason = reason, at = GetServerTime() }
    self.vendorRun = nil
    self:SetStatus("Vendor accounting needs review: " .. reason .. ". Sell Flips is locked.")
end
-- Longest count such that the last `count` rows of `old` equal the first `count` rows of `after`
-- (buyback is a ring: new sales append at the end, oldest entries fall off the front).
-- Input: two row arrays. Output: overlap count (0 when nothing lines up).
local function buybackOverlap(old, after)
    for count = math.min(#old, #after), 0, -1 do
        local matches = true
        for i = 1, count do
            if not same(old[#old - count + i], after[i]) then matches = false; break end
        end
        if matches then return count end
    end
    return 0
end

-- A full ring of identical buyback entries can still be confirmed for our own single in-flight
-- sale using its saved intent, exact bag decrease and gold gain.
-- Inputs: snapshot `before`, new rows `after`, current money and bag totals.
-- Output: true when the in-flight "selling" run explains the otherwise unchanged list.
local function confirmsOwnIdenticalSale(self, before, after, money, totals)
    local run = self.vendorRun
    if not run or run.phase ~= "selling" then return false end
    local row = run.rows[run.index]
    local id = self.ItemIdentity(row.link)
    local expected = {link = row.link, price = row.vendor * row.quantity, quantity = row.quantity}
    return money - before.money == row.vendor * row.quantity
        and (before.totals[id] or 0) - (totals[id] or 0) == row.quantity
        and same(after[#after], expected)
end

-- Detects a buyback removal: `after` is `old` minus exactly one row.
-- Output: index into `old` of the removed row; nil when no single-row removal matches;
-- false when several removals match (identical entries may carry different cost allocations,
-- so we must not guess which one was bought back).
local function findRemovedIndex(old, after)
    if #after ~= #old - 1 then return nil end
    local removedIndex
    for skipped = 1, #old do
        local matches = true
        for i = 1, #after do
            if not same(old[i < skipped and i or i + 1], after[i]) then matches = false; break end
        end
        if matches then
            if removedIndex then return false end
            removedIndex = skipped
        end
    end
    return removedIndex
end

-- Reversal of a buyback: verify money spent and bag gain equal the removed row, reverse its
-- receipt, and carry the remaining receipts across onto `after`.
-- Output: true when handled; false when evidence is incomplete (caller returns, retry later).
local function applyReversal(self, before, old, after, removedIndex, money, totals)
    local removed = old[removedIndex]
    local id = self.ItemIdentity(removed.link)
    local moneyOk = money - before.money == -removed.price
    if not moneyOk or (totals[id] or 0) - (before.totals[id] or 0) ~= removed.quantity then return false end
    if removed.receipt then self:ReverseVendorSale(removed.receipt) end
    for i = 1, #after do after[i].receipt = old[i < removedIndex and i or i + 1].receipt end
    return true
end

-- Sums the new rows (after[overlap+1..]) and requires money gain and per-item bag decrease to match.
-- Output: quantities by item identity (the "explained" decreases), or nil when evidence is incomplete.
local function verifyNewSales(self, before, after, overlap, money, totals)
    local revenue, quantities = 0, {}
    for i = overlap + 1, #after do
        local row, id = after[i], self.ItemIdentity(after[i].link)
        if not id then return nil end
        revenue = revenue + row.price
        quantities[id] = (quantities[id] or 0) + row.quantity
    end
    -- Wait for both bag and money events before recognizing a receipt.
    if money - before.money ~= revenue then return nil end
    for id, quantity in pairs(quantities) do
        if (before.totals[id] or 0) - (totals[id] or 0) ~= quantity then return nil end
    end
    return quantities
end

-- Returns the active sale of the current "selling" run, or nil/false when there is none.
local function activeSale(self)
    local run = self.vendorRun
    return run and run.phase == "selling" and run.activeSale
end

-- True when the new rows are exactly our reserved single sale (token, row and allocations).
local function matchesActiveSale(self, sale, after, overlap)
    local expected = sale.row
    local pending = self.account.vendorPending
    local wanted = {link = expected.link, quantity = expected.quantity, price = expected.vendor * expected.quantity}
    return pending and pending.token == sale.token and #after - overlap == 1
        and same(after[#after], wanted)
        and self:ValidateVendorAllocations(expected.link, expected.quantity, expected.allocations, false)
end

-- Records receipts for the new rows (carrying earlier receipts across the overlap).
-- Output: ok (false after VendorUncertain), confirmedSale (the sale when it was recorded).
local function recordNewSales(self, old, after, overlap, sale)
    for i = 1, overlap do after[i].receipt = old[#old - overlap + i].receipt end
    local confirmedSale
    for i = overlap + 1, #after do
        local row = after[i]
        local flipQuantity = sale and sale.row.quantity or math.min(row.quantity, self:AvailableFlips(row.link, true))
        row.receipt = self:RecordVendorSale(row.link, row.quantity, row.price, flipQuantity, sale and sale.row.allocations)
        if not row.receipt then
            self:VendorUncertain("sale could not be allocated to its purchases")
            return false
        end
        if sale then confirmedSale = sale end
    end
    return true, confirmedSale
end

-- New sales branch. Output: ok, explained quantities, confirmedSale. ok=false means the caller returns.
local function applyNewSales(self, before, old, after, overlap, money, totals)
    local quantities = verifyNewSales(self, before, after, overlap, money, totals)
    if not quantities then return false end
    local sale = activeSale(self)
    if sale and not matchesActiveSale(self, sale, after, overlap) then
        self:VendorUncertain("sale response did not match its reserved purchase quantities")
        return false
    end
    local ok, confirmedSale = recordNewSales(self, old, after, overlap, sale)
    if not ok then return false end
    return true, quantities, confirmedSale
end

-- Unchanged buyback list: nothing may have been sold. Gold gained with fewer bag items means a
-- sale we cannot identify (VendorUncertain). Otherwise only an exact money/bag match is accepted.
-- Output: true to commit the (same) snapshot; false when the caller returns.
local function applyUnchanged(self, before, old, after, money, totals)
    if money > before.money then
        for id, quantity in pairs(before.totals) do
            if (totals[id] or 0) < quantity then
                self:VendorUncertain("identical buyback entries prevented sale identification")
                return false
            end
        end
    end
    if money ~= before.money or not totalsSame(totals, before.totals) then return false end
    for i = 1, #after do after[i].receipt = old[i].receipt end
    return true
end

-- Reconcile against the saved baseline before replacing it; only the verified sale quantities
-- (`explained`, may be nil) may explain a lower count (other items/pre-snapshot losses revoke).
local function commitSnapshot(self, after, money, totals, explained)
    if self.ReconcileInventory then self:ReconcileInventory(totals, explained)
    else self.account.inventoryTotals = totals end
    self.vendorSnapshot = { rows = after, money = money, totals = totals }
    self.account.buybackRows = after
end

-- Advance the vendor run after a confirmed sale, only when the sale is still active and the bag
-- count dropped by exactly its quantity.
local function advanceVendorRun(self, confirmedSale, totals)
    if not (confirmedSale and self.vendorRun and self.vendorRun.phase == "selling") then return end
    local run, row = self.vendorRun, confirmedSale.row
    if run.activeSale ~= confirmedSale then return end
    if (totals[self.ItemIdentity(row.link)] or 0) ~= confirmedSale.beforeCount - row.quantity then return end
    self.account.vendorPending = nil
    run.activeSale = nil
    run.index, run.phase = run.index + 1, "next"
    C_Timer.After(0.2, function() if self.vendorRun == run then self:VendorStep() end end)
end

function M:ObserveVendor()
    if not self.merchantOpen or not self.vendorSnapshot then return end
    if self.account.vendorUncertain or self.account.storageLocked then return end
    local before, after = self.vendorSnapshot, self:ReadBuyback()
    if not after then return end
    local money, totals = GetMoney(), self:BagTotals()
    local old = before.rows
    local overlap = buybackOverlap(old, after)
    local unchanged = #old == #after and overlap == #old
    if unchanged and #after > 0 and confirmsOwnIdenticalSale(self, before, after, money, totals) then
        unchanged, overlap = false, #after - 1
    end
    local removedIndex = findRemovedIndex(old, after)
    -- An ambiguous removal (identical entries) must never be reinterpreted as new sales; wait for
    -- clearer evidence. The delayed observation marks the vendor uncertain if it stays unresolved.
    if removedIndex == false then return end
    local confirmedSale, explained
    if removedIndex then
        if not applyReversal(self, before, old, after, removedIndex, money, totals) then return end
    elseif not unchanged and #after > overlap then
        local ok
        ok, explained, confirmedSale = applyNewSales(self, before, old, after, overlap, money, totals)
        if not ok then return end
    elseif unchanged then
        if not applyUnchanged(self, before, old, after, money, totals) then return end
    else
        return
    end
    commitSnapshot(self, after, money, totals, explained)
    advanceVendorRun(self, confirmedSale, totals)
    self:Refresh()
end
function M:ScheduleVendorObservation()
    if not self.merchantOpen then return end
    local token = {}; self.vendorObservation = token
    C_Timer.After(0.2, function()
        if self.vendorObservation ~= token or not self.merchantOpen then return end
        self:ObserveVendor()
        local snapshot = self.vendorSnapshot
        local after = self:ReadBuyback()
        local changed = after and (#after ~= #snapshot.rows)
        if after and not changed then for i = 1, #after do if not same(after[i], snapshot.rows[i]) then changed = true; break end end end
        -- No broad money-delta accounting: repairs, purchases and quest gold are not sales.
        local unsettled = GetMoney() ~= snapshot.money or not totalsSame(self:BagTotals(), snapshot.totals)
        if changed or unsettled then
            C_Timer.After(2, function()
                if self.merchantOpen and self.vendorObservation == token and self.vendorSnapshot == snapshot then
                    self:ObserveVendor()
                    if self.vendorSnapshot == snapshot then
                        if changed then self:VendorUncertain("buyback changes did not match bag and gold changes")
                        elseif not self.vendorRun then
                            -- Non-sale money/inventory activity has settled without changing buyback.
                            local totals = self:BagTotals()
                            if self.ReconcileInventory then self:ReconcileInventory(totals) end
                            self.vendorSnapshot = { rows = after, money = GetMoney(), totals = totals }
                        end
                    end
                end
            end)
        end
    end)
end
function M:VendorEligible(bag, slot)
    local item = Bags.GetContainerItemInfo(bag, slot)
    if not item or item.isLocked or item.isBound or item.hasNoValue or not item.hyperlink then return nil end
    if self.db.settings.neverSell[item.itemID] then return nil end
    local name, _, quality, _, _, _, _, _, _, _, vendor = Items.GetItemInfo(item.hyperlink)
    if not name or not vendor or vendor <= 0 or not self.db.settings.sellRarities[quality] then return nil end
    if not Bags.GetContainerItemEquipmentSetInfo or Bags.GetContainerItemEquipmentSetInfo(bag, slot) then return nil end
    return { bag = bag, slot = slot, link = item.hyperlink, itemID = item.itemID, name = name,
        stackCount = item.stackCount, vendor = vendor, quality = quality }
end
function M:BuildVendorReview()
    if self.account.storageLocked or (self.CanTransact and not self:CanTransact("vendor")) then return end
    if self.vendorRun or self.account.vendorUncertain then return end
    self:ObserveVendor()
    if self.account.vendorUncertain then return end
    local rows, remaining, reserved = {}, {}, {}
    for bag = 0, lastBag() do
        for slot = 1, Bags.GetContainerNumSlots(bag) do
            local row = self:VendorEligible(bag, slot)
            if row then
                local id = self.ItemIdentity(row.link)
                if remaining[id] == nil then remaining[id] = self:AvailableFlips(row.link) end
                row.quantity = math.min(row.stackCount, remaining[id])
                if row.quantity > 0 then
                    row.allocations = self:PlanVendorAllocations(row.link, row.quantity, false, reserved)
                    if not row.allocations then return self:StopVendorSale("Flip allocation changed. Review again.") end
                    for _, allocation in ipairs(row.allocations) do
                        reserved[allocation.purchase] = (reserved[allocation.purchase] or 0) + allocation.quantity
                    end
                    rows[#rows + 1] = row
                    remaining[id] = remaining[id] - row.quantity
                end
            end
        end
    end
    self.vendorReview = rows
    return rows
end
function M:StartVendorSale()
    if self.account.storageLocked or (self.CanTransact and not self:CanTransact("vendor")) then return end
    if not self.merchantOpen or self.vendorRun or self.account.vendorUncertain or not self.vendorReview then return end
    local selected = {}
    for _, row in ipairs(self.vendorReview) do if not row.excluded then selected[#selected + 1] = row end end
    self.vendorRun = { rows = selected, index = 1, phase = "next" }
    self.vendorReview = nil
    self:VendorStep()
end
function M:StopVendorSale(message)
    self.vendorRun = nil
    self:SetStatus(message or "Vendor sale stopped.")
end
function M:VendorStep()
    local run = self.vendorRun
    if not run then return end
    if run.stopRequested and run.phase ~= "selling" then return self:StopVendorSale("Vendor sale stopped after confirmation.") end
    if self.account.storageLocked or (self.CanTransact and not self:CanTransact("vendor")) then return self:StopVendorSale("Vendor selling unavailable until client or saved-data checks pass.") end
    if not self.merchantOpen or not MerchantFrame or not MerchantFrame:IsShown() or InCombatLockdown()
        or (InRepairMode and InRepairMode()) or GetCursorInfo() then return self:StopVendorSale("Vendor sale paused: merchant, combat, repair or cursor state changed.") end
    local row = run.rows[run.index]
    if not row then return self:StopVendorSale("Reviewed flips sold. Profit tally updated.") end
    local current = self:VendorEligible(row.bag, row.slot)
    if not current or self.ItemIdentity(current.link) ~= self.ItemIdentity(row.link) or current.stackCount ~= row.stackCount
        or current.vendor ~= row.vendor or not self:ValidateVendorAllocations(row.link, row.quantity, row.allocations, false) then
        return self:StopVendorSale("Inventory or eligibility changed. Review flips again.")
    end
    if row.stackCount > row.quantity then
        local freeBag, freeSlot
        for bag = 0, lastBag() do
            local _, family = Bags.GetContainerNumFreeSlots(bag)
            if family == 0 then
                for slot = 1, Bags.GetContainerNumSlots(bag) do
                    if not Bags.GetContainerItemInfo(bag, slot) then freeBag, freeSlot = bag, slot; break end
                end
            end
            if freeBag then break end
        end
        if not freeBag then return self:StopVendorSale("A free general-purpose bag slot is needed to split flips.") end
        local ok = pcall(Bags.SplitContainerItem, row.bag, row.slot, row.quantity)
        local cursorType, _, cursorLink = GetCursorInfo()
        if not ok or cursorType ~= "item" or self.ItemIdentity(cursorLink) ~= self.ItemIdentity(row.link)
            or Bags.GetContainerItemInfo(freeBag, freeSlot) then return self:StopVendorSale("Split could not be verified. Check your cursor; nothing was sold.") end
        local placed = pcall(Bags.PickupContainerItem, freeBag, freeSlot)
        if not placed or GetCursorInfo() then return self:StopVendorSale("Could not place the split stack. Check your cursor; nothing was sold.") end
        local originalBag, originalSlot, originalCount = row.bag, row.slot, row.stackCount
        run.phase = "splitting"
        C_Timer.After(0.3, function()
            if self.vendorRun ~= run then return end
            local source = Bags.GetContainerItemInfo(originalBag, originalSlot)
            local target = Bags.GetContainerItemInfo(freeBag, freeSlot)
            if not source or not target or source.stackCount ~= originalCount - row.quantity or target.stackCount ~= row.quantity
                or self.ItemIdentity(source.hyperlink) ~= self.ItemIdentity(row.link) or self.ItemIdentity(target.hyperlink) ~= self.ItemIdentity(row.link) then
                return self:StopVendorSale("Split result changed. Review your bags before selling.")
            end
            row.bag, row.slot, row.stackCount = freeBag, freeSlot, row.quantity
            run.phase = "next"
            self:VendorStep()
        end)
        return
    end
    self:ObserveVendor()
    if self.account.vendorUncertain then return self:StopVendorSale("Vendor accounting needs review.") end
    run.beforeCount = (self:BagTotals()[self.ItemIdentity(row.link)] or 0)
    run.phase = "selling"
    self.account.vendorSequence = (self.account.vendorSequence or 0) + 1
    -- Each attempt owns its immutable correlation token. A previous row's timer
    -- must never time out a later sale that happens to reuse the same batch.
    local sale = { token = self.account.vendorSequence, row = row, beforeCount = run.beforeCount }
    run.activeSale = sale
    self.account.vendorPending = { token = sale.token, link = row.link, quantity = row.quantity,
        allocations = row.allocations, expectedProceeds = row.vendor * row.quantity, at = GetServerTime() }
    if self.LogState then self:LogState("vendor-intent", "Sell reviewed stack", {itemID = row.itemID, quantity = row.quantity, bag = row.bag, slot = row.slot, expected = row.vendor * row.quantity}) end
    local ok, err = pcall(Bags.UseContainerItem, row.bag, row.slot)
    if not ok and self.LogState then self:LogState("api-error", tostring(err), {operation = "UseContainerItem"}) end
    if not ok then return self:VendorUncertain("sale call failed; inspect inventory and vendor buyback") end
    C_Timer.After(4, function()
        if self.vendorRun == run and run.phase == "selling" and run.activeSale == sale then
            self:ObserveVendor()
            if self.vendorRun == run and run.phase == "selling" and run.activeSale == sale then self:VendorUncertain("sale confirmation timed out") end
        end
    end)
end
function M:ExcludeUncertainVendorActivity()
    if not self.account.vendorUncertain or self.vendorRun or not self.merchantOpen then return end
    self.account.vendorReviews = self.account.vendorReviews or {}
    table.insert(self.account.vendorReviews, self.account.vendorUncertain)
    -- Unknown sales must not leave potentially consumed flips eligible for automatic selling.
    for _, purchase in ipairs(self.account.purchases) do
        if (purchase.collected or 0) > (purchase.sold or 0) then
            purchase.collected, purchase.held = purchase.sold or 0, true
        end
    end
    self.account.vendorUncertain = nil
    self.account.vendorPending = nil
    self.vendorSnapshot = { rows = self:ReadBuyback() or {}, money = GetMoney(), totals = self:BagTotals() }
    self.account.inventoryTotals = self.vendorSnapshot.totals
    self.account.buybackRows = self.vendorSnapshot.rows
    self.vendorReview = nil
    self:SetStatus("Uncertain activity excluded from totals. Remaining flips were placed on hold; verify collection before releasing them.")
end
local events = CreateFrame("Frame")
for _, event in ipairs({ "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE", "PLAYER_MONEY", "BAG_UPDATE_DELAYED" }) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event)
    if not M.account then return end
    if M.Supports and not M:Supports("vendor") then
        M.merchantOpen = false
        if event == "MERCHANT_SHOW" then
            local _, reason = M:Supports("vendor")
            M:SetStatus(reason)
        end
        return
    end
    if event == "MERCHANT_SHOW" then
        M.merchantOpen = true
        local rows = M:ReadBuyback() or {}
        local saved = M.account.buybackRows or {}
        if #rows == #saved then
            local matches = true
            for i = 1, #rows do if not same(rows[i], saved[i]) then matches = false; break end end
            if matches then for i = 1, #rows do rows[i].receipt = saved[i].receipt end end
        end
        local totals = M:BagTotals()
        -- A decrease that happened before the delayed inventory callback must be handled
        -- before this snapshot becomes the evidence baseline.
        if M.ReconcileInventory then M:ReconcileInventory(totals) end
        M.vendorSnapshot = { rows = rows, money = GetMoney(), totals = totals }
        M:ShowVendor()
    elseif event == "MERCHANT_CLOSED" then
        M:ObserveVendor()
        if M.vendorRun and M.vendorRun.phase == "selling" then M:VendorUncertain("merchant closed before sale confirmation") end
        M.merchantOpen, M.vendorRun, M.vendorReview = false, nil, nil
        if M.vendorWindow then M.vendorWindow:Hide() end
    else M:ScheduleVendorObservation() end
end)
