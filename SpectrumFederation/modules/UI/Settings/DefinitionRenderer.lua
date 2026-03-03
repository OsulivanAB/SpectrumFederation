-- modules/UI/Settings/DefinitionRenderer.lua
local _, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI.DefinitionRenderer = UI.DefinitionRenderer or {}
local R = UI.DefinitionRenderer

-- Get unique key for a section definition
-- @param secDef table Section definition table
-- @return string Section key (id or title)
local function SectionKey(secDef)
	return secDef.id or secDef.title
end

-- Create context object for control builders with UI references
-- @param panel Frame The panel frame being built
-- @param section Section The section being built into
-- @return table Context table with panel, section, store, schema, ui, pageBuilder
local function MakeCtx(panel, section)
	return {
		panel = panel,
		section = section,
		store = SF.SettingsStore,
		schema = SF.SettingsSchema,
		ui = UI,
		pageBuilder = panel.__sfPageBuilder,
	}
end

-- Build a settings page from definition and populate with controls
-- @param panel Frame The panel frame to build into
-- @param pageDef table Page definition with sections and items
-- @return nil
function R:Build(panel, pageDef)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building page definition with %d section(s)", #(pageDef.sections or {}))
	end

	local controls = UI.Controls
	local dialogs = UI.Dialogs

	local pb = UI:CreatePage(panel)
	panel.__sfPageBuilder = pb
	panel.__sfPageDef = pageDef
	panel.__sfSections = {}
	panel.__sfWatchedPaths = {}

	for _, secDef in ipairs(pageDef.sections or {}) do
		local sec = pb:AddSection(secDef.title or "")
		sec.__sfPageBuilder = pb

		local key = SectionKey(secDef)
		panel.__sfSections[key] = sec

		-- Initial visibility (admin gating, etc.)
		if secDef.condition then
			sec:SetShown(secDef.condition(MakeCtx(panel, sec)))
		end

		-- Optional intro text
		if secDef.intro then
			sec:AddText(secDef.intro)
		end

		-- Items
		for _, item in ipairs(secDef.items or {}) do
			local t = item.type
			local ctx = MakeCtx(panel, sec)

			-- Track paths for auto-refresh on external changes
			if item.path and type(item.path) == "string" then
				panel.__sfWatchedPaths[item.path] = true
			end

			if t == "text" then
				sec:AddText(item.text)

			elseif t == "spacer" then
				sec:AddSpacer(item.height or 8)

			elseif t == "help" then
				controls:AddHelpText(sec, item)

			elseif t == "checkbox" then
				controls:AddCheckbox(sec, item)

			elseif t == "slider" then
				controls:AddSlider(sec, item)

			elseif t == "dropdown" then
				local opts = item
				if type(opts.onValueChanged) == "function" then
					local fn = opts.onValueChanged
					opts = CopyTable(opts)
					opts.onValueChanged = function(value)
						return fn(MakeCtx(panel, sec), value)
					end
				end
				controls:AddDropdown(sec, opts)

			elseif t == "display" then
				controls:AddDisplay(sec, item)

			elseif t == "editbox" then
				local opts = item
				if type(opts.onCommit) == "function" then
					local fn = opts.onCommit
					opts = CopyTable(opts)
					opts.onCommit = function(text, editBox)
						return fn(MakeCtx(panel, sec), text, editBox)
					end
				end
				controls:AddEditBox(sec, opts)

			elseif t == "dropdownIconButton" then
				local opts = item
				if type(opts.onIconClick) == "function" then
					local fn = opts.onIconClick
					opts = CopyTable(opts)
					opts.onIconClick = function(btn)
						return fn(MakeCtx(panel, sec), btn)
					end
				end
				if type(opts.onValueChanged) =="function" then
					local fn = opts.onValueChanged
					opts = CopyTable(opts)
					opts.onValueChanged = function(value)
						return fn(MakeCtx(panel, sec), value)
					end
				end
				controls:AddDropdownWithIconButton(sec, opts)

			elseif t == "scrollList" then
				local opts = item
				if type(opts.onRemove) == "function" then
					local fn = opts.onRemove
					opts = CopyTable(opts)
					opts.onRemove = function(item)
						return fn(MakeCtx(panel, sec), item)
					end
				end
				controls:AddScrollList(sec, opts)

			elseif t == "button" then
				local opts = item
				if type(opts.onClick) == "function" then
					local fn = opts.onClick
					opts = CopyTable(opts)
					opts.onClick = function(btn)
						return fn(ctx, btn)
					end
				end
				controls:AddButton(sec, opts)

			elseif t == "editboxButton" then
				local opts = item
				if type(opts.onSubmit) == "function" then
					local fn = opts.onSubmit
					opts = CopyTable(opts)
					opts.onSubmit = function(text, editBox, btn)
						return fn(ctx, text, editBox, btn)
					end
				end
				controls:AddEditBoxWithButton(sec, opts)

			elseif t == "scrollableText" then
				controls:AddScrollableText(sec, item)
			end
		end

        local function Confirm(message, acceptText, onAccept)
            if UI.Dialogs and UI.Dialogs.Confirm then
                UI.Dialogs:Confirm(message, acceptText, onAccept)
            else
                if onAccept then onAccept() end
            end
        end

		-- Per-section reset (optional)
		if secDef.reset then
			local reset = secDef.reset
			controls:AddButton(sec, {
				label = reset.label or "Reset to Defaults",
				buttonText = reset.buttonText or "Reset",
				width = reset.width or 120,
				tooltip = reset.tooltip,

				onClick = function()
					sec:ClearMessage()

					local confirmText = reset.confirmText or ("Reset '%s' to defaults?"):format(secDef.title or "settings")
					Confirm(
                        confirmText,
                        reset.buttonText or "Reset",
                        function()
                            local store = SF.SettingsStore

                            if reset.paths then
                                store:ResetPaths(reset.paths)
                            end
                            if reset.profileKeys then
                                store:ResetActiveProfileKeys(reset.profileKeys)
                            end
                            if reset.all then
                                store:ResetAll()
                            end

                            if panel.__sfPageBuilder then
                                panel.__sfPageBuilder:Refresh()
                                panel.__sfPageBuilder:Reflow()
                            end

                            sec:SetMessage(reset.successMessage or "Reset to defaults","success")
                        end
                    )
				end,
			})
		end
	end

	pb:Finalize()

	-- Register Store callbacks for auto-refresh when settings change externally
	-- Note: Callbacks are not unregistered to match existing pattern (see Apply.lua).
	-- Each panel registers its own callbacks; multiple panels watching the same path
	-- will each receive notifications and refresh independently.
	if SF.SettingsStore and SF.SettingsStore.RegisterCallback then
		for path, _ in pairs(panel.__sfWatchedPaths or {}) do
			SF.SettingsStore:RegisterCallback(path, function(_newValue, _oldValue, changedPath)
				-- Refresh the page builder when any watched setting changes
				if pb and pb.Refresh then
					if SF.Debug then
						SF.Debug:Verbose("UI", "Auto-refreshing page due to setting change: %s", tostring(changedPath))
					end
					pb:Refresh()
				end
			end)
		end
	end

	return pb
end

-- Refresh the page definition display (called when panel is reopened)
-- @param panel Frame The panel frame to refresh
-- @return nil
function R:Refresh(panel)
	local pb = panel.__sfPageBuilder
	local pageDef = panel.__sfPageDef
	local sections = panel.__sfSections

	if not pb or not pageDef or not sections then return end

	for _, secDef in ipairs(pageDef.sections or {}) do
		if secDef.condition then
			local key = SectionKey(secDef)
			local sec = sections[key]
			if sec then
				sec:SetShown(secDef.condition(MakeCtx(panel, sec)))
			end
		end
	end

	pb:Refresh()
	pb:Reflow()
end