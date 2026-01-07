-- Grab the namespace
local addonName, SF = ...

local Page = {
    id = "main",
    name = "Spectrum Federation Settings",
    order = 10,
}

local function AddFakeSettingRow(section, labelText, controlHint)
    section:AddRow(24, function(row)
        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", row, "LEFT", 0, 0)
        label:SetText(labelText)

        local hint = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hint:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        hint:SetText(controlHint or "<control>")
    end)
end

function Page:Build(panel)
    local ui = SF.SettingsUI
    local page = ui:CreatePage(panel)
    panel.__sfPageBuilder = page

    local appearance = page:AddSection("Appearance")
    appearance:AddText("These are placeholders. Next lesson we'll replace them with real controls bound to the DB.")
    AddFakeSettingRow(appearance, "Window Style", "(dropdown)")
    AddFakeSettingRow(appearance, "Font Style", "(dropdown)")
    AddFakeSettingRow(appearance, "Font Size", "(slider)")

    page:Finalize()
end

function Page:Refresh(panel)
    local pb = panel.__sfPageBuilder
    if pb then pb:Reflow() end
end

SF.SettingsUI:RegisterPage(Page)