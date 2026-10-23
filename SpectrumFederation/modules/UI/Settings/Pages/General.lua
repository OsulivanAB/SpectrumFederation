-- modules/UI/Settings/Pages/General.lua
local _, SF = ...

local Page = {
	id = "general",
	name = "General",
	navLabel = "General",
	group = "Core",
	description = "Customize the addon's overall look and feel.",
	order = 10,
}

-- ==================================================================
-- Page Definition
-- ==================================================================

function Page:Build(panel)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building General settings page")
	end

	local renderer = SF.SettingsUI.DefinitionRenderer
	local store = SF.SettingsStore

	local def = {
		sections = {
			{
				id = "ui",
				title = "UI Customization",
				items = {
					{
						type = "dropdown",
						label = "Window Style",
						tooltip = "Choose the visual theme used by Spectrum Federation windows.",
						path = "global.windowStyle",
						options = function()
							local opts = {}
							for _, style in ipairs(SF.SettingsSchema.ENUMS.windowStyle) do
								table.insert(opts, { value = style, label = style })
							end
							return opts
						end,
					},

					{
						type = "dropdown",
						label = "Font Style",
						tooltip = "Choose the font family used in Spectrum Federation windows and settings.",
						path = "global.fontStyle",
						options = function()
							local opts = {}
							for _, font in ipairs(SF.SettingsSchema.ENUMS.fontStyle) do
								table.insert(opts, { value = font, label = font })
							end
							return opts
						end,
					},

					{
						type = "slider",
						label = "Font Size",
						tooltip = "Adjust the size of text shown in Spectrum Federation windows and settings.",
						path = "global.fontSize",
						min = 8,
						max = 20,
						step = 1,
						valueFormat = "%d",
					},

					{
						type = "slider",
						label = "Settings Window Opacity",
						tooltip = "Adjust the opacity of the settings window background only. Text and controls stay fully opaque. 100% is fully opaque; lower values show more of the game underneath.",
						path = "global.settingsWindowOpacity",
						min = 70,
						max = 100,
						step = 5,
					},
				},
			},
		},
	}

	renderer:Build(panel, def)
end

function Page:Refresh(panel)
	SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

SF.SettingsUI:RegisterPage(Page)
