-- modules/UI/Settings/Controls/Controls.lua
local _, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI
UI.Controls = UI.Controls or {}
local Controls = UI.Controls

local Store = SF.SettingsStore
local Style = UI.Style or {}
local R = Style.Row or {}

local LABEL_WIDTH   = R.labelWidth or 220
local GUTTER        = R.gutter or 16
local CONTROL_WIDTH = R.controlWidth or 240
local ADMIN_ONLY_SUFFIX = "|cffff4040(Admin Only)|r"

-- Evaluate a value or thunk to a boolean with default
-- @param v any Boolean, function returning boolean, or nil
-- @param defaultValue boolean Default to use if v is nil or errors
-- @return boolean Resolved boolean
local function EvalBool(v, defaultValue)
	if v == nil then return defaultValue end
	if type(v) == "function" then
		local ok, res = pcall(v)
		if ok then
			return res and true or false
		end
		return defaultValue
	end
	return v and true or false
end

-- Request a layout reflow for a section or its page builder
-- @param section table Section frame/table containing reflow methods
-- @return nil
local function RequestSectionReflow(section)
	if not section then return end
	if section.RequestReflow then
		section:RequestReflow()
		return
	end
	if section.ReflowRows then
		section:ReflowRows()
		return
	end
	local pb = section.__sfPageBuilder
	if pb and pb.Reflow then
		pb:Reflow()
	end
end

local function IsAdminForSection(section)
	local predicate = section and section.__sfAdminPredicate
	if type(predicate) ~= "function" then
		return true
	end

	local ok, result = pcall(predicate)
	if not ok then
		return true
	end

	return result and true or false
end

local function EvalEnabled(section, opts)
	opts = opts or {}
	local enabled = EvalBool(opts.enabled, true)
	if opts.adminOnly then
		enabled = enabled and IsAdminForSection(section)
	end
	return enabled
end

local function FormatTooltipTitle(title, adminOnly)
	title = title or ""
	if not adminOnly then
		return title
	end
	if title ~= "" then
		return string.format("%s %s", title, ADMIN_ONLY_SUFFIX)
	end
	return ADMIN_ONLY_SUFFIX
end

local function HasAdminOnlyItems(items)
	for _, item in ipairs(items or {}) do
		if type(item) == "table" and item.adminOnly then
			return true
		end
	end
	return false
end

-- Apply visibility/enabled state to a row and its widgets
-- @param row Frame Row frame to update
-- @param section table Section containing the row
-- @param opts table Options with visible/enabled toggles
-- @param widgets table|nil Array of widgets to enable/disable
-- @return boolean visible, boolean enabled
function Controls:_ApplyRowState(row, section, opts, widgets)
	opts = opts or {}
	local visible = EvalBool(opts.visible, true)
	local enabled = EvalEnabled(section, opts)

	local wasShown = row:IsShown()
	if visible ~= wasShown then
		row:SetShown(visible)
		RequestSectionReflow(section)
	end

	-- Disabled "greyed-out" UX
	row:SetAlpha(enabled and 1 or 0.45)

	-- Disable any widgets we were given
	if widgets then
		for _, w in ipairs(widgets) do
			if w then
				if w.SetEnabled then
					w:SetEnabled(enabled)
				elseif w.Disable and not enabled then
					w:Disable()
				elseif w.Enable and enabled then
					w:Enable()
				elseif w.EnableMouse then
					w:EnableMouse(enabled)
				end
			end
		end
	end

	return visible, enabled
end

-- Resolve get/set functions from opts or path binding
-- @param opts table Options containing get/set or path
-- @return function get, function set
local function ResolveGetSet(opts)
	-- Either opts.get/opts.set OR opts.path
	local get = opts.get
	local set = opts.set

	if not get and opts.path then
		get = function() return Store:Get(opts.path) end
	end
	if not set and opts.path then
		set = function(v) Store:Set(opts.path, v) end
	end

	assert(type(get) == "function", "Control requires opts.get or opts.path")
	assert(type(set) == "function", "Control requires opts.set or opts.path")

	return get, set
end

-- Resolve get function from opts or path binding
-- @param opts table Options containing get or path
-- @return function get
local function ResolveGetOnly(opts)
	local get = opts.get
	if not get and opts.path then
		get = function() return Store:Get(opts.path) end
	end
	assert(type(get) == "function", "Control requires opts.get or opts.path")
	return get
end

-- Create a simple icon button with highlight
-- @param parent Frame Parent frame
-- @param atlas string|nil Atlas name for texture
-- @param size number|nil Size of button (width/height)
-- @return Button The created button
local function CreateIconButton(parent, atlas, size)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(size or 20, size or 20)

	local icon = btn:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints(btn)
	btn.Icon = icon

	if atlas then
		icon:SetAtlas(atlas, true)
	end

	local hl = btn:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(btn)
	hl:SetColorTexture(1, 1, 1, 0.18)
	btn.Highlight = hl

	return btn
end

-- Attach tooltip handlers to a region
-- @param region Region UI region to attach tooltip to
-- @param title string|nil Tooltip title
-- @param text string|nil Tooltip body text
-- @return nil
local function AttachTooltip(region, title, text, adminOnly)
	if not text or text == "" then return end
	region:EnableMouse(true)

	region:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(FormatTooltipTitle(title, adminOnly), 1, 1, 1)
		GameTooltip:AddLine(text, nil, nil, nil, true)
		GameTooltip:Show()
	end)

	region:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

-- Register a refresh callback on the page builder for a section
-- @param section table Section containing __sfPageBuilder
-- @param fn function Callback to run on refresh
-- @return nil
local function RegisterRefresh(section, fn)
	local pb = section.__sfPageBuilder
	if pb and pb.RegisterRefresh then
		pb:RegisterRefresh(fn)
	end
end

local function EnsureCheckboxRowHeight(section, row, checkbox)
	if not row or not checkbox then return end

	local checkboxHeight = checkbox:GetHeight() or 0
	local minHeight = math.max(row:GetHeight() or 0, checkboxHeight + 2)
	if minHeight > (row:GetHeight() or 0) then
		row:SetHeight(minHeight)
		RequestSectionReflow(section)
	end
end

-- ---------------------------------------
-- Button Row (two buttons)
-- ---------------------------------------
function Controls:AddButtonRow(section, opts)
	return section:AddRow(26, function(row)
		local btns = {}
		local defs = {}
		local rowOpts = opts
		if not opts.adminOnly and HasAdminOnlyItems(opts) then
			rowOpts = CopyTable(opts)
			rowOpts.adminOnly = true
		end
		for i = 1, 2 do
			local def = opts[i]
			if def then
				defs[#defs + 1] = def
				local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
				btn:SetSize(def.width or 140, def.height or 22)
				if i == 1 then
					btn:SetPoint("LEFT", row, "LEFT", 0, 0)
				else
					btn:SetPoint("LEFT", row, "LEFT", (def.offsetX or 200), 0)
				end
				local function ApplyText()
					if type(def.text) == "function" then
						btn:SetText(def.text() or "")
					else
						btn:SetText(def.text or "")
					end
				end
				ApplyText()
				if def.onClick then
					btn:SetScript("OnClick", function()
						if btn:IsEnabled() then
							def.onClick(btn)
						end
					end)
				end
				btns[#btns + 1] = btn
				btn.ApplyText = ApplyText
			end
		end

		local function Refresh()
			local _, enabled = self:_ApplyRowState(row, section, rowOpts, nil)
			for idx, b in ipairs(btns) do
				if b.SetEnabled then b:SetEnabled(enabled) end
				b:SetAlpha(enabled and 1 or 0.45)
				local def = defs[idx]
				if def and b.ApplyText then
					b:ApplyText()
				end
			end
		end

		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

-- ---------------------------------------
-- Checkbox Row (multi-column)
-- ---------------------------------------
-- Add a single row with multiple checkboxes laid out horizontally
-- @param section table Section to add row into
-- @param opts table Options including items (array of entries with label/get/set), spacing, visible/enabled
-- @return Frame The created row
function Controls:AddCheckboxRow(section, opts)
	local items = opts.items or {}
	local spacing = opts.spacing or 140
	local rowOpts = opts
	if not opts.adminOnly and HasAdminOnlyItems(items) then
		rowOpts = CopyTable(opts)
		rowOpts.adminOnly = true
	end

	return section:AddRow(opts.height or 26, function(row)
		local checkboxes = {}

		local function BuildCheckbox(idx, def)
			if not def then return nil end
			local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
			if idx == 1 then
				cb:SetPoint("LEFT", row, "LEFT", 0, 0)
			else
				cb:SetPoint("LEFT", checkboxes[idx - 1] or row, "LEFT", spacing, 0)
			end

			if cb.Text then
				cb.Text:SetText("")
				cb.Text:Hide()
			end

			local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
			label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
			label:SetText(def.label or "")

			if def.tooltip then
				AttachTooltip(label, def.label, def.tooltip, def.adminOnly or rowOpts.adminOnly)
			end

			cb:SetScript("OnClick", function(selfBtn)
				if not selfBtn:IsEnabled() then return end
				if def.set then
					def.set(selfBtn:GetChecked() and true or false)
				end
			end)

			EnsureCheckboxRowHeight(section, row, cb)

			checkboxes[idx] = cb
			return cb
		end

		for idx, def in ipairs(items) do
			BuildCheckbox(idx, def)
		end

		local function Refresh()
			for idx, def in ipairs(items) do
				local cb = checkboxes[idx]
				if cb and def.get then
					cb:SetChecked(def.get() and true or false)
				end
			end
			Controls:_ApplyRowState(row, section, rowOpts, checkboxes)
		end

		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

-- Resolve get/set binding helpers (alias of ResolveGetSet)
-- @param opts table Options containing get/set or path
-- @return function get, function set
local function ResolveBinding(opts)
	local get = opts.get
	local set = opts.set

	if not get and opts.path then
		get = function() return Store:Get(opts.path) end
	end
	if not set and opts.path then
		set = function(v) Store:Set(opts.path, v) end
	end

	assert(type(get) == "function", "Control requires opts.get or opts.path")
	assert(type(set) == "function", "Control requires opts.set or opts.path")

	return get, set
end

-- Initialize a row with label and control container
-- @param row Frame Row to initialize
-- @param opts table Options containing label and tooltip
-- @return FontString label, Frame control
function Controls:InitRow(row, opts)
	-- Label (fixed column)
	local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.Label = label
	label:SetPoint("LEFT", row, "LEFT", 0, 0)
	label:SetWidth(LABEL_WIDTH)
	label:SetJustifyH("LEFT")
	label:SetText(opts.label or "")

	-- Control container (right column)
	local control = CreateFrame("Frame", nil, row)
	row.Control = control
	control:SetPoint("LEFT", row, "LEFT", LABEL_WIDTH + GUTTER, 0)
	control:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	control:SetPoint("TOP", row, "TOP", 0, 0)
	control:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)

	AttachTooltip(row, opts.label, opts.tooltip, opts.adminOnly)
	return label, control
end

-- ---------------------------------------
-- Checkbox
-- ---------------------------------------
-- Add a checkbox control row bound to settings
-- @param section table Section to add row into
-- @param opts table Options including label, path/get/set, tooltip, visible/enabled
-- @return Frame The created row
function Controls:AddCheckbox(section, opts)
	local get, set = ResolveGetSet(opts)

	return section:AddRow(26, function(row)
		local _, control = self:InitRow(row, opts)

		local cb = CreateFrame("CheckButton", nil, control, "UICheckButtonTemplate")
		cb:SetPoint("LEFT", control, "LEFT", 0, 0)

		if cb.Text then
			cb.Text:SetText("")
			cb.Text:Hide()
		end

		cb:SetScript("OnClick", function(selfBtn)
			if not selfBtn:IsEnabled() then return end
			set(selfBtn:GetChecked() and true or false)
		end)

		EnsureCheckboxRowHeight(section, row, cb)

		local function Refresh()
			cb:SetChecked(get() and true or false)
			self:_ApplyRowState(row, section, opts, {cb})
		end

		Refresh()
		RegisterRefresh(section, Refresh)

		row:EnableMouse(true)
		row:SetScript("OnMouseDown", function()
			if cb:IsEnabled() then
				cb:Click()
			end
		end)
	end)
end

-- ---------------------------------------
-- Checkbox Grid (2 columns per row)
-- ---------------------------------------
-- Add a two-cell checkbox row for compact layouts
-- @param section table Section to add row into
-- @param opts table Options including items (array of up to 2 entries with label/get/set), visible/enabled
-- @return Frame The created row
function Controls:AddCheckboxGrid(section, opts)
	local items = opts.items or {}
	local rowOpts = opts
	if not opts.adminOnly and HasAdminOnlyItems(items) then
		rowOpts = CopyTable(opts)
		rowOpts.adminOnly = true
	end

	return section:AddRow(opts.height or 26, function(row)
		local cells = {}
		for i = 1, 2 do
			local cell = CreateFrame("Frame", nil, row)
			cells[i] = cell
			if i == 1 then
				cell:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
				cell:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
				cell:SetPoint("RIGHT", row, "CENTER", -6, 0)
			else
				cell:SetPoint("TOPLEFT", row, "CENTER", 6, 0)
				cell:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
			end
		end

		local checkboxes = {}

		local function BuildCell(idx, def)
			if not def then return end
			local cell = cells[idx]
			local cb = CreateFrame("CheckButton", nil, cell, "UICheckButtonTemplate")
			cb:SetPoint("LEFT", cell, "LEFT", 0, 0)

			if cb.Text then
				cb.Text:SetText("")
				cb.Text:Hide()
			end

			local label = cell:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
			label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
			label:SetText(def.label or "")

			if def.tooltip then
				AttachTooltip(cell, def.label, def.tooltip, def.adminOnly or rowOpts.adminOnly)
			end

			cb:SetScript("OnClick", function(selfBtn)
				if not selfBtn:IsEnabled() then return end
				if def.set then
					def.set(selfBtn:GetChecked() and true or false)
				end
			end)

			EnsureCheckboxRowHeight(section, row, cb)

			checkboxes[#checkboxes + 1] = cb
			return cb
		end

		local cb1 = BuildCell(1, items[1])
		local cb2 = BuildCell(2, items[2])

		local function Refresh()
			if cb1 and items[1] and items[1].get then
				cb1:SetChecked(items[1].get() and true or false)
			end
			if cb2 and items[2] and items[2].get then
				cb2:SetChecked(items[2].get() and true or false)
			end
			self:_ApplyRowState(row, section, rowOpts, checkboxes)
		end

		Refresh()
		RegisterRefresh(section, Refresh)

		row:EnableMouse(true)
		row:SetScript("OnMouseDown", function()
			if cb1 and cb1:IsMouseOver() and cb1:IsEnabled() then
				cb1:Click()
			elseif cb2 and cb2:IsMouseOver() and cb2:IsEnabled() then
				cb2:Click()
			end
		end)
	end)
end

-- ---------------------------------------
-- Button (action)
-- ---------------------------------------
-- Add a button control row
-- @param section table Section to add row into
-- @param opts table Options including label, buttonText, width, onClick, visible/enabled
-- @return Frame The created row
function Controls:AddButton(section, opts)
	return section:AddRow(26, function(row)
		local _, control = self:InitRow(row, opts)

		local btn = CreateFrame("Button", nil, control, "UIPanelButtonTemplate")
		btn:SetPoint("LEFT", control, "LEFT", 0, 0)
		btn:SetSize(opts.width or 140, 22)
		
		-- Support dynamic button text (function or string)
		local function GetButtonText()
			local text = (type(opts.buttonText) == "function") and opts.buttonText() or opts.buttonText
			return text or "Button"
		end
		btn:SetText(GetButtonText())

		btn:SetScript("OnClick", function()
			if not btn:IsEnabled() then return end
			if opts.onClick then
				opts.onClick(btn)
			end
		end)

		local function Refresh()
			-- Update button text on refresh
			btn:SetText(GetButtonText())
			self:_ApplyRowState(row, section, opts, {btn})
		end
		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

-- ---------------------------------------
-- EditBox + Button
-- ---------------------------------------
-- Add an edit box with adjacent button
-- @param section table Section to add row into
-- @param opts table Options including label, onSubmit, buttonText, widths, visible/enabled
-- @return Frame The created row
function Controls:AddEditBoxWithButton(section, opts)
	return section:AddRow(26, function(row)
		local _, control = self:InitRow(row, opts)

		local edit = CreateFrame("EditBox", nil, control, "InputBoxTemplate")
		edit:SetAutoFocus(false)
		edit:SetSize(opts.editWidth or 150, 22)
		edit:SetPoint("LEFT", control, "LEFT", 0, 0)
		edit:SetText("")

		if opts.hint and edit.Instructions then
			edit.Instructions:SetText(opts.hint)
		end

		local btn = CreateFrame("Button", nil, control, "UIPanelButtonTemplate")
		btn:SetSize(opts.buttonWidth or 90, 22)
		btn:SetText(opts.buttonText or "OK")
		btn:SetPoint("LEFT", edit, "RIGHT", 8, 0)

		local function DoSubmit()
			if (btn.IsEnabled and not btn:IsEnabled()) then return end	
			local text = edit:GetText()
			if opts.onSubmit then
				opts.onSubmit(text, edit, btn)
			end
		end

		btn:SetScript("OnClick", DoSubmit)
		edit:SetScript("OnEnterPressed", function(selfEdit)
			DoSubmit()
			selfEdit:ClearFocus()
		end)

		local function Refresh()
			self:_ApplyRowState(row, section, opts, {edit, btn})
		end
		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

-- ---------------------------------------
-- Slider
-- ---------------------------------------
-- Add a slider control row bound to settings
-- @param section table Section to add row into
-- @param opts table Options including label, min, max, step, path/get/set, visible/enabled
-- @return Frame The created row
function Controls:AddSlider(section, opts)
	local get, set = ResolveGetSet(opts)

	return section:AddRow(46, function(row)
		local _, control = self:InitRow(row, opts)

		local minValue = opts.min or 0
		local maxValue = opts.max or 100
		local step = opts.step or 1

		local slider = CreateFrame("Slider", nil, control, "UISliderTemplate")
		slider:SetSize(opts.width or CONTROL_WIDTH, 16)
		slider:SetPoint("LEFT", control, "LEFT", 0, 0)
		slider:SetMinMaxValues(minValue, maxValue)
		slider:SetValueStep(step)
		if slider.SetObeyStepOnDrag then
			slider:SetObeyStepOnDrag(true)
		end

		local valueText = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		valueText:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 2)

		local low = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
		low:SetText(tostring(minValue))

		local high = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)
		high:SetText(tostring(maxValue))

		slider.__sfIgnore = false
		slider:SetScript("OnValueChanged", function(selfSlider, val)
			if selfSlider.__sfIgnore then return end
			if selfSlider.IsEnabled and not selfSlider:IsEnabled() then return end
			val = tonumber(val) or minValue
			set(val)
			valueText:SetText(tostring(val))
		end)

		local function Refresh()
			slider.__sfIgnore = true
			local val = tonumber(get()) or minValue
			slider:SetValue(val)
			valueText:SetText(tostring(val))
			slider.__sfIgnore = false

			self:_ApplyRowState(row, section, opts, {slider})
		end

		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

-- ---------------------------------------
-- Dropdown using Blizzard_Menu DropdownButton
-- ---------------------------------------
-- Add a dropdown control row using Blizzard dropdown template
-- @param section table Section to add row into
-- @param opts table Options including label, options, path/get/set, defaultText, onValueChanged
-- @return Frame The created row
function Controls:AddDropdown(section, opts)
	local get, set = ResolveGetSet(opts)

	return section:AddRow(30, function(row)
		local _, control = self:InitRow(row, opts)

		local dropdown = CreateFrame("DropdownButton", nil, control, "WowStyle1DropdownTemplate")
		dropdown:SetPoint("LEFT", control, "LEFT", 0, 0)
		dropdown:SetWidth(opts.width or CONTROL_WIDTH)
		dropdown:SetDefaultText(opts.defaultText or "Select...")

		local function GetOptions()
			local o = opts.options
			if type(o) == "function" then
				return o()
			end
			return o or {}
		end

		local function IsSelected(value)
			return get() == value
		end

		local function SetSelected(value)
			set(value)
			if opts.onValueChanged then
				opts.onValueChanged(value)
			end
		end

		local function Generator(owner, rootDescription)
			for _, opt in ipairs(GetOptions()) do
				local value, label

				if type(opt) == "table" then
					value = opt.value
					label = opt.label
				else
					value = opt
					label = tostring(opt)
				end

				if value ~= nil then
					rootDescription:CreateRadio(tostring(label or value), IsSelected, SetSelected, value)
				end
			end
		end

		-- SetupMenu is the intended pattern for dropdown buttons. 
		dropdown:SetupMenu(Generator)

		local function Refresh()
			self:_ApplyRowState(row, section, opts, {dropdown})
			if dropdown.GenerateMenu then
				dropdown:GenerateMenu()
			end
		end

		Refresh()
		RegisterRefresh(section, Refresh)

		row.__sfDropdown = dropdown
	end)
end

-- Add a read-only display row
-- @param section table Section to add row into
-- @param opts table Options including label, get/path, tooltip, visible/enabled
-- @return Frame The created row
function Controls:AddDisplay(section, opts)
	local get = ResolveGetOnly(opts)

	return section:AddRow(26, function(row)
		local _, control = self:InitRow(row, opts)

		local fs = control:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		fs:SetPoint("LEFT", control, "LEFT", 0, 0)
		fs:SetPoint("RIGHT", control, "RIGHT", 0, 0)
		fs:SetJustifyH("LEFT")
		fs:SetText("")

		local function Refresh()
			local v = get()
			fs:SetText(v == nil and "" or tostring(v))
			self:_ApplyRowState(row, section, opts, {fs})
		end

		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

-- Add an edit box control row bound to settings
-- @param section table Section to add row into
-- @param opts table Options including label, path/get/set, maxLetters, onCommit
-- @return Frame The created row
function Controls:AddEditBox(section, opts)
	local get, set = ResolveGetSet(opts)

	return section:AddRow(26, function(row)
		local _, control = self:InitRow(row, opts)

		local edit = CreateFrame("EditBox", nil, control, "InputBoxTemplate")
		edit:SetAutoFocus(false)
		edit:SetSize(opts.width or 180, 22)
		edit:SetPoint("LEFT", control, "LEFT", 0, 0)
		edit:SetTextColor(1, 1, 1)
		if edit.SetHighlightColor then
			edit:SetHighlightColor(0.25, 0.5, 1, 0.35)
		end

		if opts.maxLetters then
			edit:SetMaxLetters(opts.maxLetters)
		end

		local ignore = false

		local function Commit()
			if ignore then return end
			if edit.IsEnabled and  not edit:IsEnabled() then return end

			local text = edit:GetText() or ""
			set(text)

			if opts.onCommit then
				opts.onCommit(text, edit)
			end
		end

		edit:SetScript("OnEnterPressed", function(selfEdit)
			Commit()
			selfEdit:ClearFocus()
		end)

		edit:SetScript("OnEditFocusLost", function(selfEdit)
			Commit()
		end)

		local function Refresh()
			ignore = true
			edit:SetText(tostring(get() or ""))
			if edit.SetCursorPosition then
				edit:SetCursorPosition(0)
			end
			ignore = false

			local _, enabled = self:_ApplyRowState(row, section, opts, {edit})
			local c = enabled and 1 or 0.6
			edit:SetTextColor(c, c, c)
		end

		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

-- Add a dropdown with an adjacent icon button
-- @param section table Section to add row into
-- @param opts table Options including label, options, iconAtlas, iconTooltip, onIconClick
-- @return Frame The created row
function Controls:AddDropdownWithIconButton(section, opts)
	local get, set = ResolveGetSet(opts)
	return section:AddRow(30, function(row)
		local _, control = self:InitRow(row, opts)

		local iconSize = opts.iconSize or 20
		local gap = opts.iconGap or 6

		local dropdown = CreateFrame("DropdownButton", nil, control, "WowStyle1DropdownTemplate")
		dropdown:SetPoint("LEFT", control, "LEFT", 0, 0)
		dropdown:SetWidth((opts.width or CONTROL_WIDTH) - iconSize - gap)
		dropdown:SetDefaultText(opts.defaultText or "Select...")

		local iconBtn = CreateIconButton(control, opts.iconAtlas or "common-icon-trash", iconSize)
		iconBtn:SetPoint("LEFT", dropdown, "RIGHT", gap, 0)

		local iconTooltip = opts.iconTooltip or opts.iconToolTip
		if iconTooltip then
			AttachTooltip(iconBtn, opts.label or "", iconTooltip, opts.adminOnly)
		end

		local function GetOptions()
			local o = opts.options
			if type(o) == "function" then
				return o()
			end
			return o or {}
		end

		local function IsSelected(value)
			return get() == value
		end

		local Refresh  -- Forward declaration

		local function SetSelected(value)
			set(value)
			if opts.onValueChanged then
				opts.onValueChanged(value)
			end
			-- Trigger refresh to update icon button enabled state
			if Refresh then
				Refresh()
			end
		end

		local function Generator(owner, rootDescription)
			for _, opt in ipairs(GetOptions()) do
				local value, label
				if type(opt) == "table" then
					value = opt.value
					label = opt.label
				else
					value = opt
					label = tostring(opt)
				end
				if value ~= nil then
					rootDescription:CreateRadio(tostring(label or value), IsSelected, SetSelected, value)
				end
			end
		end

		dropdown:SetupMenu(Generator)

		-- Add custom IsEnabled method to track enabled state
		iconBtn._enabled = true
		iconBtn.IsEnabled = function(self)
			return self._enabled
		end

		iconBtn:SetScript("OnClick", function()
			if iconBtn.IsEnabled and not iconBtn:IsEnabled() then return end
			if opts.onIconClick then
				opts.onIconClick(iconBtn)
			end
		end)

		Refresh = function()  -- Define Refresh function
			local options = GetOptions()
			local hasOptions = type(options) == "table" and #options > 0

			local _, enabled = self:_ApplyRowState(row, section, opts, {dropdown})
			local effectiveEnabled = enabled and hasOptions
			if dropdown.SetEnabled then
				dropdown:SetEnabled(effectiveEnabled)
			elseif dropdown.EnableMouse then
				dropdown:EnableMouse(effectiveEnabled)
			end
			dropdown:SetAlpha(effectiveEnabled and 1 or 0.45)
			row:SetAlpha(effectiveEnabled and 1 or 0.45)

			local iconEnabled = EvalBool(opts.iconEnabled, effectiveEnabled)
			-- Store enabled state in custom property
			iconBtn._enabled = iconEnabled
			-- Always keep mouse enabled so clicks can be detected
			iconBtn:EnableMouse(true)
			iconBtn:SetAlpha(iconEnabled and 1 or 0.45)

			if dropdown.GenerateMenu then
				dropdown:GenerateMenu()
			end
		end

		Refresh()
		RegisterRefresh(section, Refresh)

		row.__sfDropdown = dropdown
		row.__sfIconButton = iconBtn
	end)
end

-- Function to add a scrollable list of items with optional remove buttons
-- @Param section: The settings section to add the scroll list to
-- @Param opts: Table of options
--   - getItems: Function that returns a list of items to display. Each item is a table with:
--       - text: The text to display for the item. (e.g. "|cFF00FF00Osully|r")
--       - canRemove: Boolean indicating if the remove button should be shown
--   - onRemove: Function(item) called when an item's remove button is clicked
--   - height: Height of the scroll list control (default: 160)
--   - rowHeight: Height of each row in the list (default: 20)
--   - removeAtlas: Atlas name for the remove button icon (default: "common-icon-redx")
-- @Return The created scroll list control
-- Add a scrollable list control with optional remove buttons
-- @param section table Section to add row into
-- @param opts table Options with getItems, onRemove, sizing, and display settings
-- @return Frame The created row
function Controls:AddScrollList(section, opts)
	opts = opts or {}

	local getItems = opts.getItems
	if type(getItems) ~= "function" then
		getItems = function() return {} end
	end

	local rowHeight = opts.rowHeight or 20
	local rowSpacing = opts.rowSpacing or 2

	local resize = (opts.resize ~= false)	-- Default to true
	local border = (opts.border == true)	-- Default to false
	local borderInset = border and (opts.borderInset or 4) or 0

	local fixedHeight = opts.height or 160
	local maxHeight = opts.maxHeight or fixedHeight

	local minRowHeight = rowHeight + (borderInset * 2)
	if fixedHeight < minRowHeight then fixedHeight = minRowHeight end
	if maxHeight < minRowHeight then maxHeight = minRowHeight end

	local initialHeight = resize and minRowHeight or fixedHeight

	return section:AddRow(initialHeight, function(row)
		local _, control = self:InitRow(row, opts)

		local parent = control
		if border then
			local box = CreateFrame("Frame", nil, control, "BackdropTemplate")
			box:SetPoint("TOPLEFT", control, "TOPLEFT", 0, 0)
			box:SetPoint("BOTTOMRIGHT", control, "BOTTOMRIGHT", 0, 0)

			if box.SetBackdrop then
				box:SetBackdrop({
					bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
					edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
					tile = true,
					tileSize = 8,
					edgeSize = 12,
					insets = { 
						left = borderInset, 
						right = borderInset, 
						top = borderInset, 
						bottom = borderInset
					 }
				})
				
				box:SetBackdropColor(0, 0, 0, 0.12)	-- semi-transparent bg
				box:SetBackdropBorderColor(0.5, 0.5, 0.5, 1) -- light grey border
			end

			parent = box
		end

		local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
		scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

		local content = CreateFrame("Frame", nil, scroll)
		content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		content:SetHeight(1)
		scroll:SetScrollChild(content)

		local rows = {}

		local function EnsureRow(i)
			if rows[i] then return rows[i] end

			local r = CreateFrame("Frame", nil, content)
			r:SetHeight(rowHeight)

			local fs = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
			fs:SetPoint("LEFT", r, "LEFT", 0, 0	)
			fs:SetPoint("RIGHT", r, "RIGHT", -24, 0)
			fs:SetJustifyH("LEFT")
			r.Text = fs

			local remove = CreateIconButton(r, opts.removeAtlas or "common-icon-redx", 18)
			remove:SetPoint("RIGHT", r, "RIGHT", 0, 0)
			r.Remove = remove

			rows[i] = r
			return r
		end

		local function SetScrollBarShown(show)
			local sb = scroll.ScrollBar
			if not sb then return 0 end

			sb:SetShown(show)

			if not show then
				scroll:SetVerticalScroll(0)
				if sb.SetValue then sb:SetValue(0) end
				if sb.Disable then sb:Disable() end
				return 0
			end

			if sb.Enable then sb:Enable() end
			return sb:GetWidth() or 20
		end

		local function Refresh()
			if row.__sfScrollListRefreshing then return end
			row.__sfScrollListRefreshing = true

			local _, enabled = self:_ApplyRowState(row, section, opts, {scroll})

			local items = getItems() or {}

			local y = 0

			for i = 1, #items do
				local item = items[i]
				local r = EnsureRow(i)

				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
				r:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)

				r.Text:SetText(item.text or "")

				local canRemove = item.canRemove and true or false
				r.Remove:SetShown(canRemove)
				r:SetAlpha(enabled and 1 or 0.45)

				if canRemove then
					local removeEnabled = enabled
					r.Remove:EnableMouse(true)
					r.Remove:SetAlpha(removeEnabled and 1 or 0.45)
					r.Remove:SetScript("OnClick", function()
						if not removeEnabled then return end
						if opts.onRemove then
							opts.onRemove(item)
						end
					end)
				else
					r.Remove:SetAlpha(0.45)
					r.Remove:SetScript("OnClick", nil)
				end

				r:Show()
				y = y + rowHeight + rowSpacing
			end

			for i = #items + 1, #rows do
				rows[i]:Hide()
			end

			local contentH = (y > 0) and (y - rowSpacing) or 0
			content:SetHeight(math.max(1, contentH))

			-- Resize behavior
			local sbw = 0
			if resize then
				local maxVisible = math.max(rowHeight, maxHeight - (borderInset * 2))
				local needVisible = math.max(rowHeight, contentH)

				local showScroll = needVisible > maxVisible
				sbw = SetScrollBarShown(showScroll)

				local targetVisible = math.min(needVisible, maxVisible)
				local targetRowH = targetVisible + (borderInset * 2)

				-- Only apply if changed, then request reflow so stacking updates
				if math.abs((row:GetHeight() or 0) - targetRowH) > 0.5 then
					row:SetHeight(targetRowH)
					if section.RequestReflow then
						section:RequestReflow()
					end
				end
			else
				SetScrollBarShown(true)

				if math.abs((row:GetHeight() or 0) - fixedHeight) > 0.5 then
					row:SetHeight(fixedHeight)
					if section.RequestReflow then
						section:RequestReflow()
					end
				end

				local sb = scroll.ScrollBar
				sbw = (sb and sb:GetWidth()) or 20
			end

			-- Width management
			local w = scroll:GetWidth() or 0
			if w > 0 then
				content:SetWidth(math.max(1, w - sbw - 4))
			end

			row.__sfScrollListRefreshing = false
		end

		Refresh()
		RegisterRefresh(section, Refresh)

		scroll:HookScript("OnSizeChanged", Refresh)
	end)
end

-- =======================================
-- Help Text
-- =======================================
-- Add a help text row with optional indentation and dynamic height
-- @param section table Section to add row into
-- @param opts table Options including text, indent, padding, minHeight
-- @return Frame The created row
function Controls:AddHelpText(section, opts)
	opts = opts or {}

	-- indent can be:
	--  "label"   -> starts at far left
	--  "control" -> starts where controls begin (after label column)
	--  number    -> explicit px indent
	local indent = opts.indent or "label"
	local indentX = 0
	if indent == "control" then
		indentX = LABEL_WIDTH + GUTTER
	elseif type(indent) == "number" then
		indentX = indent
	end

	local padTop = opts.padTop or 2
	local padBottom = opts.padBottom or 2
	local minHeight = opts.minHeight or 14

	return section:AddRow(minHeight + padTop + padBottom, function(row)
		local fs = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		fs:SetPoint("TOPLEFT", row, "TOPLEFT", indentX, -padTop)
		fs:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -padTop)
		fs:SetJustifyH("LEFT")
		fs:SetJustifyV("TOP")
		fs:SetWordWrap(true)
		fs:SetText(opts.text or "")

		local function Refresh()
			self:_ApplyRowState(row, section, opts, {editBox, scrollFrame})
		end

		Refresh()
		RegisterRefresh(section, Refresh)

		local function UpdateHeight()
			-- Width is sometimes 0 during the first layout pass; try again later.
			local w = row:GetWidth() or 0
			if w < 60 then return end

			-- With left+right anchors set, the fontstring already has width.
			local textH = fs:GetStringHeight() or 0
			local wanted = math.max(minHeight, textH) + padTop + padBottom

			if math.abs((row:GetHeight() or 0) - wanted) > 0.5 then
				row:SetHeight(wanted)

				-- IMPORTANT: request a deferred reflow, never synchronous reflow here
				if section.RequestReflow then
					section:RequestReflow()
				end
			end
		end

		local function ScheduleUpdate()
			-- Coalesce multiple size changes into one next-frame calc
			if row.__sfHelpScheduled then return end
			row.__sfHelpScheduled = true

			if C_Timer and C_Timer.After then
				C_Timer.After(0, function()
					row.__sfHelpScheduled = false
					UpdateHeight()
				end)
			else
				row.__sfHelpScheduled = false
				UpdateHeight()
			end
		end

		-- Resize after the row gets a real width (and on future resizes)
		row:HookScript("OnSizeChanged", ScheduleUpdate)

		-- Run at least once after build; next-frame ensures the row has a width
		ScheduleUpdate()
	end)
end

-- Add a scrollable text box (read-only, multiline, copyable)
-- @param section table Section to add row into
-- @param opts table Options including label, height, get
-- @return Frame The created row
function Controls:AddScrollableText(section, opts)
	opts = opts or {}
	local get = opts.get or function() return "" end
	local height = opts.height or 200
	local hasLabel = opts.label and opts.label ~= ""
	
	return section:AddRow(height + 4, function(row)
		local scrollFrame, editBox
		
		if hasLabel then
			-- Normal layout with label
			local label, control = self:InitRow(row, opts)
			
			scrollFrame = CreateFrame("ScrollFrame", nil, control, "UIPanelScrollFrameTemplate")
			scrollFrame:SetPoint("TOPLEFT", control, "TOPLEFT", 0, 0)
			scrollFrame:SetPoint("BOTTOMRIGHT", control, "BOTTOMRIGHT", -4, 0)
			
			editBox = CreateFrame("EditBox", nil, scrollFrame)
			editBox:SetWidth(CONTROL_WIDTH - 24)
		else
			-- Full-width layout without label
			scrollFrame = CreateFrame("ScrollFrame", nil, row, "UIPanelScrollFrameTemplate")
			scrollFrame:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
			scrollFrame:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
			
			editBox = CreateFrame("EditBox", nil, scrollFrame)
			-- Set initial width (fallback before OnSizeChanged fires)
			local INITIAL_WIDTH = 400
			editBox:SetWidth(INITIAL_WIDTH)
			
			-- Update width when scrollFrame gets its actual size
			-- Subtract 24px for scrollbar width
			local SCROLLBAR_WIDTH = 24
			scrollFrame:SetScript("OnSizeChanged", function(self, width)
				if width and width > SCROLLBAR_WIDTH then
					editBox:SetWidth(width - SCROLLBAR_WIDTH)
				end
			end)
		end
		
		-- Common edit box setup
		editBox:SetMultiLine(true)
		editBox:SetFontObject(ChatFontNormal)
		editBox:SetAutoFocus(false)
		editBox:SetTextColor(1, 1, 1)
		
		-- Make it read-only by preventing text changes
		-- Keep EditBox enabled so users can select and copy text
		editBox:EnableMouse(true)
		editBox:EnableKeyboard(true)
		
		-- Store the current text to prevent modifications
		local currentText = ""
		local isUpdating = false  -- Prevent recursion
		
		-- Helper to revert text changes
		local function RevertText()
			if not isUpdating then
				isUpdating = true
				editBox:SetText(currentText)
				editBox:HighlightText(0, 0)
				isUpdating = false
			end
		end
		
		-- Block all text input to make it read-only
		editBox:SetScript("OnChar", function() RevertText() end)
		editBox:SetScript("OnTextChanged", function(self, userInput)
			if userInput and not isUpdating then
				-- User tried to type - revert to stored text
				RevertText()
			end
		end)
		editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		
		scrollFrame:SetScrollChild(editBox)
		
		local function Refresh()
			isUpdating = true
			local text = get()
			currentText = tostring(text or "")
			editBox:SetText(currentText)
			editBox:HighlightText(0, 0)
			editBox:SetCursorPosition(0)
			isUpdating = false
			
			self:_ApplyRowState(row, section, opts)
		end
		
		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end
