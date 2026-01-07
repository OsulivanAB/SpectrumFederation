-- Grab the namespace
local addonName, SF = ...

local Page = {
    id = "lootHelper",
    parentId = "main",
    name = "Loot Helper Settings",
    order = 20,
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

	local general = page:AddSection("General")
	general:AddText("Next lesson: real checkbox, dropdown, editbox + buttons wired to SavedVariables.")
	AddFakeSettingRow(general, "Enable Loot Helper", "(checkbox)")
	AddFakeSettingRow(general, "Profile Selection", "(dropdown)")
	AddFakeSettingRow(general, "Delete Selected Profile", "(button)")
	AddFakeSettingRow(general, "Create Profile Name", "(editbox)")
	AddFakeSettingRow(general, "Create Profile", "(button)")

	local admin = page:AddSection("Admin Tools")
	admin:AddText("Later we’ll conditionally show this section based on rank/permission.")
	AddFakeSettingRow(admin, "Safe Mode", "(toggle)")

	page:Finalize()
end

function Page:Refresh(panel)
	local pb = panel.__sfPageBuilder
	if pb then pb:Reflow() end
end

SF.SettingsUI:RegisterPage(Page)
