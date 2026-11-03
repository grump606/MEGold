local _, M = ...
function M:ShowDiagnostics()
    if not self.diagnosticWindow then
        local f = CreateFrame("Frame", "MEGoldDiagnostics", UIParent, "BasicFrameTemplateWithInset")
        self.diagnosticWindow = f
        f:SetSize(800, 550); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
        f.TitleText:SetText("MEGold — Diagnostics")
        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", 18, -38)
        hint:SetText("Select all, then Ctrl+C to copy. Refresh updates this snapshot. The latest 500 entries persist across reloads.")
        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 18, -68); scroll:SetPoint("BOTTOMRIGHT", -35, 65)
        local box = CreateFrame("EditBox", nil, scroll)
        box:SetMultiLine(true); box:SetAutoFocus(false); box:SetFontObject(ChatFontNormal)
        box:SetWidth(730); box:SetHeight(390); box:SetMaxLetters(0)
        box:SetScript("OnEscapePressed", function(c) c:ClearFocus() end)
        scroll:SetScrollChild(box)
        f.box, f.scroll = box, scroll
        local function button(text, x, action)
            local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            b:SetSize(175, 28); b:SetPoint("BOTTOMLEFT", x, 20); b:SetText(text); b:SetScript("OnClick", action)
            return b
        end
        button("Refresh report", 18, function() M:ShowDiagnostics() end)
        button("Select all / copy", 211, function() box:SetFocus(); box:HighlightText() end)
        f.toggle = button("Pause recording", 404, function()
            M:SetDiagnosticsEnabled(not M.diagnostics.enabled); M:ShowDiagnostics()
        end)
        button("Clear log", 597, function() M:ClearDiagnostics(); M:ShowDiagnostics() end)
    end
    local f = self.diagnosticWindow
    f.box:SetText(self:ExportDiagnostics()); f.box:ClearFocus(); f.scroll:SetVerticalScroll(0)
    f.toggle:SetText(self.diagnostics.enabled and "Pause recording" or "Resume recording")
    f:Show()
end
