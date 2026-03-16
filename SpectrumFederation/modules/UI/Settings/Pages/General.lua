-- modules/UI/Settings/Pages/General.lua
local _, SF = ...

local Page = {
	id = "general",
	name = "General",
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
	local cursorTracer = SF.CursorTracer

	local def = {
		sections = {
			{
				id = "ui",
				title = "UI Customization",
				items = {
					{
						type = "dropdown",
						label = "Window Style",
						tooltip = "Choose the visual style for addon windows",
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
						tooltip = "Choose the font style for addon text",
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
						tooltip = "Adjust the font size for addon text",
						path = "global.fontSize",
						min = 8,
						max = 20,
						step = 1,
						valueFormat = "%d",
					},
				},
			},
			{
				id = "cursorTracer",
				title = "Rainbow Cursor Trail",
				intro = "Add a smooth rainbow trail behind your mouse cursor.",
				items = {
					{
						type = "slider",
						label = "Trail Length (seconds)",
						tooltip = "Adjust how long the rainbow trail remains visible behind the cursor.",
						path = "global.cursorTracer.trailLength",
						min = cursorTracer.MIN_TRAIL_LENGTH,
						max = cursorTracer.MAX_TRAIL_LENGTH,
						step = 0.01,
						valueFormat = "%.2f",
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
