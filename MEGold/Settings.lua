local _, M = ...
local fields = M.SettingsSchema
function M.ParseItemIDs(text)
    local ids = {}
    for token in text:gmatch("[^,%s]+") do
        local value = tonumber(token)
        if not token:match("^%d+$") or not value or value < 1 or value > 2147483647 then
            return nil, "Item lists accept positive item IDs separated by commas or spaces."
        end
        ids[value] = true
    end
    return ids
end
local function formatIDs(ids)
    local values = {}
    for id, enabled in pairs(ids or {}) do if enabled then values[#values + 1] = id end end
    table.sort(values)
    for i, value in ipairs(values) do values[i] = tostring(value) end
    return table.concat(values, ", ")
end
function M.ValidateSettings(values)
    local validated = {}
    for _, field in ipairs(fields) do
        local value = tonumber(values[field[1]])
        if not value or value ~= value or value < field[3] or value > field[4] or value % 1 ~= 0 then
            return nil, field[2] .. " must be a whole number between " .. field[3] .. " and " .. field[4] .. "."
        end
        validated[field[1]] = value
    end
    return validated
end
function M:Refilter()
    local settings, evaluate = self.db.settings, self.Evaluate
    local money, spent = GetMoney(), self.account and self.account.spent or 0
    local itemAPI = M.Client and M.Client.Items or C_Item
    local getInfo = itemAPI and itemAPI.GetItemInfo
    local candidates, results, n = self.candidates or {}, {}, 0
    for i = 1, #candidates do
        local row = candidates[i]
        local metrics = evaluate(row, settings, row.demo and 10000000 or money, spent)
        if metrics then
            if row.name == nil then
                -- Non-deal candidates carry no name; resolve it now, tolerating missing item data.
                local ok, name
                if row.link and getInfo then ok, name = pcall(getInfo, row.link) end
                row.name = ok and type(name) == "string" and name ~= "" and name or ("Item " .. row.itemID)
            end
            row.value, row.profit, row.roi = metrics.value, metrics.profit, metrics.roi
            n = n + 1
            results[n] = row
        elseif row.profit ~= nil then
            -- No longer a deal: drop result-only fields so retained rows stay slim.
            row.value, row.profit, row.roi = nil, nil, nil
            if row.link then row.name = nil end
        end
    end
    self.results = results
    self:SortResults()
    self.page = 1
    self:Refresh()
end
function M:ShowSettings()
    if not self.settingsWindow then
        local f = CreateFrame("Frame", "MEGoldSettings", UIParent, "BasicFrameTemplateWithInset")
        self.settingsWindow = f
        f:SetSize(460, 607); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
        f.TitleText:SetText("MEGold — Buying filters")
        f.inputs, f.rarities, f.itemLists = {}, {}, {}
        for i, field in ipairs(fields) do
            local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            label:SetPoint("TOPLEFT", 18, -42 - (i - 1) * 37); label:SetText(field[2])
            local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
            input:SetSize(140, 25); input:SetPoint("TOPRIGHT", -25, -36 - (i - 1) * 37)
            input:SetAutoFocus(false); input:SetMaxLetters(14)
            input:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
            f.inputs[field[1]] = input
        end
        local names = { "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }
        for quality = 0, 7 do
            local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
            check:SetPoint("TOPLEFT", 15 + (quality % 4) * 108, -304 - math.floor(quality / 4) * 35)
            local label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", check, "RIGHT", 0, 0); label:SetText(names[quality + 1])
            f.rarities[quality] = check
        end
        for i, field in ipairs({ { "ignored", "Ignore buying (item IDs)" }, { "neverSell", "Never sell (item IDs)" } }) do
            local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            label:SetPoint("TOPLEFT", 18, -382 - (i - 1) * 57); label:SetText(field[2])
            local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
            input:SetSize(410, 25); input:SetPoint("TOPLEFT", 23, -402 - (i - 1) * 57)
            input:SetAutoFocus(false); input:SetMaxLetters(4096)
            input:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
            f.itemLists[field[1]] = input
        end
        f.error = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.error:SetPoint("TOPLEFT", 18, -497); f.error:SetWidth(420); f.error:SetJustifyH("LEFT")
        local save = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        save:SetSize(140, 28); save:SetPoint("BOTTOM", 0, 20); save:SetText("Save filters")
        save:SetScript("OnClick", function()
            local values = {}
            for key, input in pairs(f.inputs) do values[key] = input:GetText() end
            local validated, err = M.ValidateSettings(values)
            if not validated then f.error:SetText(err); return end
            local lists = {}
            for key, input in pairs(f.itemLists) do
                local ids, listError = M.ParseItemIDs(input:GetText())
                if not ids then f.error:SetText(listError); return end
                lists[key] = ids
            end
            for key, value in pairs(validated) do M.db.settings[key] = value end
            for key, ids in pairs(lists) do M.db.settings[key] = ids end
            for quality, check in pairs(f.rarities) do M.db.settings.buyRarities[quality] = check:GetChecked() and true or false end
            M:LogState("settings", "Buying filters saved", validated)
            M:Refilter(); f:Hide()
        end)
    end
    local f = self.settingsWindow
    for key, input in pairs(f.inputs) do input:SetText(tostring(self.db.settings[key])) end
    for key, input in pairs(f.itemLists) do input:SetText(formatIDs(self.db.settings[key])) end
    for quality, check in pairs(f.rarities) do check:SetChecked(self.db.settings.buyRarities[quality] ~= false) end
    f.error:SetText("100 copper = 1 silver; 10,000 copper = 1 gold. Budget spending persists through reloads for this character.")
    f:Show()
end
