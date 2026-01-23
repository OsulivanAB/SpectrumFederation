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

function Controls:_ApplyRowState(row, section, opts, widgets)
	opts = opts or {}
	local visible = EvalBool(opts.visible, true)
	local enabled = EvalBool(opts.enabled, true)

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

local function ResolveGetOnly(opts)
	local get = opts.get
	if not get and opts.path then
		get = function() return Store:Get(opts.path) end
	end
	assert(type(get) == "function", "Control requires opts.get or opts.path")
	return get
end

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

local function AttachTooltip(region, title, text)
	if not text or text == "" then return end
	region:EnableMouse(true)

	region:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title or "", 1, 1, 1)
		GameTooltip:AddLine(text, nil, nil, nil, true)
		GameTooltip:Show()
	end)

	region:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function RegisterRefresh(section, fn)
	local pb = section.__sfPageBuilder
	if pb and pb.RegisterRefresh then
		pb:RegisterRefresh(fn)
	end
end

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

	AttachTooltip(row, opts.label, opts.tooltip)
	return label, control
end

-- ---------------------------------------
-- Checkbox
-- ---------------------------------------
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
-- Button (action)
-- ---------------------------------------
function Controls:AddButton(section, opts)
	return section:AddRow(26, function(row)
		local _, control = self:InitRow(row, opts)

		local btn = CreateFrame("Button", nil, control, "UIPanelButtonTemplate")
		btn:SetPoint("LEFT", control, "LEFT", 0, 0)
		btn:SetSize(opts.width or 140, 22)
		btn:SetText(opts.buttonText or "Button")

		btn:SetScript("OnClick", function()
			if not btn:IsEnabled() then return end
			if opts.onClick then
				opts.onClick(btn)
			end
		end)

		local function Refresh()
			self:_ApplyRowState(row, section, opts, {btn})
		end
		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

-- ---------------------------------------
-- EditBox + Button
-- ---------------------------------------
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

function Controls:AddEditBox(section, opts)
	local get, set = ResolveGetSet(opts)

	return section:AddRow(26, function(row)
		local _, control = self:InitRow(row, opts)

		local edit = CreateFrame("EditBox", nil, control, "InputBoxTemplate")
		edit:SetAutoFocus(false)
		edit:SetSize(opts.width or 180, 22)
		edit:SetPoint("LEFT", control, "LEFT", 0, 0)

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
			ignore = false

			self:_ApplyRowState(row, section, opts, {edit})
		end

		Refresh()
		RegisterRefresh(section, Refresh)
	end)
end

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

		if opts.iconTooltip then
			AttachTooltip(iconBtn, opts.label or "", opts.iconTooltip)
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

		dropdown:SetupMenu(Generator)

		iconBtn:SetScript("OnClick", function()
			if iconBtn.IsEnabled and not iconBtn:IsEnabled() then return end
			if opts.onIconClick then
				opts.onIconClick(iconBtn)
			end
		end)

		local function Refresh()
			self:_ApplyRowState(row, section, opts, {dropdown})

			local iconEnabled = EvalBool(opts.iconEnabled, EvalBool(opts.enabled, true))
			if iconBtn.SetEnabled then
				iconBtn:SetEnabled(iconEnabled)
			else
				iconBtn:EnableMouse(iconEnabled)
			end
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
function Controls:AddScrollList(section, opts)
	opts = opts or {}

	local getItems = opts.getItems
	if type(getItems) ~= "function" then
		getItems = function() return {} end
	end

	local height = opts.height or 160
	local rowHeight = opts.rowHeight or 20
	local removeAtlas = opts.removeAtlas or "common-icon-redx"

	return section:AddRow(height, function(row)
		local _, control = self:InitRow(row, opts)

		local scroll = CreateFrame("ScrollFrame", nil, control, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", control, "TOPLEFT", 0, 0)
		scroll:SetPoint("BOTTOMRIGHT", control, "BOTTOMRIGHT", 0, 0)

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

			local remove = CreateIconButton(r, removeAtlas, 18)
			remove:SetPoint("RIGHT", r, "RIGHT", 0, 0)
			r.Remove = remove

			rows[i] = r
			return r
		end

		local function Refresh()
			self:_ApplyRowState(row, section, opts, nil)

			local items = getItems() or {}
			local y = 0

			local w = (control:GetWidth() or 0)
			local sb = scroll.ScrollBar
			local sbw = (sb and sb:GetWidth()) or 20
			content:SetWidth(math.max(1, w - sbw - 4))

			for i = 1, #items do
				local item = items[i]
				local r = EnsureRow(i)

				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
				r:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)

				r.Text:SetText(item.text or "")

				local canRemove = item.canRemove and true or false
				r.Remove:SetShown(canRemove)

				if canRemove then
					r.Remove:SetScript("OnClick", function()
						if opts.onRemove then
							opts.onRemove(item)
						end
					end)
				end

				r:Show()
				y = y + rowHeight + 2
			end

			for i = #items + 1, #rows do
				rows[i]:Hide()
			end

			content:SetHeight(math.max(1, y))
		end

		Refresh()
		RegisterRefresh(section, Refresh)

		scroll:HookScript("OnSizeChanged", function()
			Refresh()
		end)
	end)
end

-- =======================================
-- Help Text
-- =======================================
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


