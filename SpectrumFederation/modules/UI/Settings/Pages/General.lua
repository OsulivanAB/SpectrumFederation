-- modules/UI/Settings/Pages/General.lua
local _, SF = ...

local Page = {
	id = "general",
	name = "General",
	order = 10,
}

local function PingActionsAvailable()
	return SF.SpellBookPingButtons and SF.SpellBookPingButtons.RunPingMacroActionById ~= nil
end

local function CreatePingButton(id, text)
	return {
		text = text,
		width = 170,
		onClick = function(ctx)
			ctx.section:ClearMessage()

			if not PingActionsAvailable() then
				ctx.section:SetMessage("Ping macro actions are not available.", "error")
				return
			end

			local _, message, kind = SF.SpellBookPingButtons:RunPingMacroActionById(id)
			ctx.section:SetMessage(message or "Ping macro action completed.", kind or "info")
		end,
	}
end

local function CreatePingButtonRow(leftId, leftText, rightId, rightText)
	local row = {
		type = "buttonRow",
		enabled = function()
			return PingActionsAvailable()
		end,
		CreatePingButton(leftId, leftText),
	}

	if rightId and rightText then
		row[2] = CreatePingButton(rightId, rightText)
	end

	return row
end

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
				id = "pingMacros",
				title = "Ping Macros",
				items = {
					{
						type = "help",
						text = "Create or refresh Blizzard ping macros from settings. If your cursor is free, the macro is picked up immediately so you can drag it onto an action bar.",
					},
					CreatePingButtonRow("attack", "Attack", "assist", "Assist"),
					CreatePingButtonRow("onmyway", "On My Way", "warning", "Warning"),
					CreatePingButtonRow("nonthreat", "Non-Threat"),
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
