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
	local store = SF.SettingsStore
	local function CursorTracerEnabled()
		return store:Get("global.cursorTracer.enabled") and true or false
	end

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
				title = "Cursor Tracer",
				intro = "Add a cosmetic trail behind your mouse cursor using built-in game textures.",
				items = {
					{
						type = "checkbox",
						label = "Enable Cursor Tracer",
						tooltip = "Show a cosmetic trail that follows your cursor.",
						path = "global.cursorTracer.enabled",
					},
					{
						type = "dropdown",
						label = "Tracer Texture",
						tooltip = "Choose which built-in texture is used for the cursor trail.",
						path = "global.cursorTracer.texture",
						options = function()
							if SF.CursorTracer and SF.CursorTracer.GetTextureOptions then
								return SF.CursorTracer:GetTextureOptions()
							end

							return {}
						end,
						visible = CursorTracerEnabled,
						enabled = CursorTracerEnabled,
					},
					{
						type = "slider",
						label = "Trail Length",
						tooltip = "Adjust how many trail segments follow the cursor.",
						path = "global.cursorTracer.length",
						min = SF.CursorTracer and SF.CursorTracer.MIN_LENGTH or 6,
						max = SF.CursorTracer and SF.CursorTracer.MAX_LENGTH or 24,
						step = 1,
						visible = CursorTracerEnabled,
						enabled = CursorTracerEnabled,
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
