-- Raid Tools → Raid Signup (#404). Season/tier roster planning; no Loot Helper profile.
-- luacheck: globals CreateFrame GameTooltip UIPanelButtonTemplate InputBoxTemplate

local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

local function DebugInfo(fmt, ...)
	if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
		SF.Debug:Info("RAID_SIGNUP", fmt, ...)
	end
end

SF.SettingsUI:RegisterCategory({
	id = "raidSignup",
	name = Loc("RAID_SIGNUP_CATEGORY_NAME", "Raid Signup"),
	navLabel = Loc("RAID_SIGNUP_CATEGORY_NAV", "Raid Signup"),
	group = "Raid Tools",
	description = Loc("RAID_SIGNUP_CATEGORY_DESC",
		"Plan season and tier roster signups. Independent of Loot Helper profiles."),
	order = 30,
})

local Page = {
	id = "raidSignupBoard",
	categoryId = "raidSignup",
	name = Loc("RAID_SIGNUP_PAGE_NAME", "Raid Signup"),
	navLabel = Loc("RAID_SIGNUP_PAGE_NAV", "Raid Signup"),
	contentHeading = Loc("RAID_SIGNUP_PAGE_HEADING", "Raid Signup"),
	group = "Raid Tools",
	description = Loc("RAID_SIGNUP_PAGE_DESC",
		"Create named roster plans, sign up with nicknames and class/spec choices, and review planned coverage."),
	order = 19,
}

local function RS()
	return SF.RaidSignup
end

-- Session UI state (never SavedVariables).
local session = {
	draft = nil,
	altDraft = nil, -- { entryId = ..., draft = ... }
	editing = nil, -- { entryId, slot = "main"|"alt", draft = ... }
	status = nil,
	statusKind = nil,
	view = "signup", -- "signup" | "manage" (manage is officer-only)
	newPlanName = "",
	renamePlanName = "",
	openCount = 0,
	refreshCount = 0,
	fullRebuildCount = 0,
	listenerCount = 0,
	frameCreateCount = 0,
	frameReuseCount = 0,
	regionCreateCount = 0,
	regionReuseCount = 0,
	boardPaintCount = 0,
}

local refreshQueued = false
local deferredRefresh = false
local buildPanel = nil
local uiHooked = false
local officerHooked = false
local typingFocus = nil

local ICON = 22
local ICON_GAP = 4

local VIEW_SIGNUP = "signup"
local VIEW_MANAGE = "manage"
local TAB_BAR_TOP_OFFSET = -2
local TAB_BAR_RIGHT_INSET = -24
local TAB_BAR_SCROLL_DROP = 34 -- 2px top pad + 28px bar + 4px gap

local BOARD_COL_GAP = 16
local BOARD_LEFT_RATIO = 0.62
local BOARD_MIN_WIDTH = 480
local BOARD_TOP_H = 62
local BOARD_STATUS_H = 18
local CLASS_COUNT_WIDTH = 24

local function TrackCreate(frame)
	session.frameCreateCount = session.frameCreateCount + 1
	return frame
end

local function TrackRegionCreate(region)
	session.regionCreateCount = (session.regionCreateCount or 0) + 1
	return region
end

-- Refresh every shown host that built this page (Blizzard Settings panel and
-- the standalone window can each hold one); Page.panel alone would leave the
-- visible host stale when another host was built last.
local function EachShownBuiltPanel(fn)
	for builtPanel in pairs(Page._builtPanels or {}) do
		if builtPanel and builtPanel.IsShown and builtPanel:IsShown() then
			fn(builtPanel)
		end
	end
end

local function HasTypingFocus()
	return typingFocus ~= nil
		and typingFocus.HasFocus
		and typingFocus:HasFocus()
end

local function BindTypingFocus(edit, onLost)
	edit:SetScript("OnEditFocusGained", function(self)
		typingFocus = self
	end)
	edit:SetScript("OnEditFocusLost", function(self)
		if typingFocus == self then
			typingFocus = nil
		end
		if onLost then
			onLost(self)
		end
		if deferredRefresh then
			deferredRefresh = false
			EachShownBuiltPanel(function(builtPanel)
				Page:Refresh(builtPanel, { force = true })
			end)
		end
	end)
end

local function QueueRefresh(opts)
	opts = opts or {}
	if not opts.force and HasTypingFocus() then
		deferredRefresh = true
		return
	end
	if refreshQueued then
		return
	end
	refreshQueued = true
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function()
			refreshQueued = false
			EachShownBuiltPanel(function(builtPanel)
				Page:Refresh(builtPanel, opts)
			end)
		end)
	else
		refreshQueued = false
		EachShownBuiltPanel(function(builtPanel)
			Page:Refresh(builtPanel, opts)
		end)
	end
end

local function SetStatus(msg, kind)
	session.status = msg
	session.statusKind = kind
end

local function Report(status, reason)
	local rs = RS()
	if rs and rs.FormatMutationFeedback then
		local msg, kind = rs.FormatMutationFeedback(status, reason)
		SetStatus(msg, kind)
	else
		SetStatus(tostring(status) .. ":" .. tostring(reason), "error")
	end
	QueueRefresh({ force = true })
end

local function Caps()
	local rs = RS()
	if not rs or not rs.GetCapabilities then
		return { canRead = false, canCreateEntry = false, canManagePlans = false }
	end
	return rs:GetCapabilities()
end

local function DiscardEphemeral()
	session.draft = nil
	session.altDraft = nil
	session.editing = nil
	-- Scope rename drafts to the selected plan; never carry dirty text across
	-- plan selection (getter-only editbox_button + getSelectionKey).
	session.renamePlanName = ""
end

local function EnsureUIListener()
	if uiHooked then
		return
	end
	local rs = RS()
	if not rs or not rs.RegisterUIListener then
		return
	end
	uiHooked = true
	session.listenerCount = session.listenerCount + 1
	rs.RegisterUIListener(function()
		-- Remote/local durable changes: drop incomplete pickers so saved values win.
		if session.editing then
			session.editing = nil
		end
		if session.altDraft then
			session.altDraft = nil
		end
		QueueRefresh({ force = not HasTypingFocus() })
	end)
	local GO = SF.GuildOfficer
	if GO and GO.RegisterUIListener and not officerHooked then
		officerHooked = true
		session.listenerCount = session.listenerCount + 1
		GO.RegisterUIListener(function()
			QueueRefresh()
		end)
	end
end

local function ClassOrder()
	local rs = RS()
	return (rs and rs.CLASS_ORDER) or {}
end

local function SpecsFor(classFile)
	local rs = RS()
	if not rs or not rs.CLASS_SPECS then
		return {}
	end
	return rs.CLASS_SPECS[string.upper(tostring(classFile or ""))] or {}
end

local function TextureForClass(classFile)
	local rs = RS()
	if rs and rs.ClassIconTexture then
		return rs.ClassIconTexture(classFile)
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function TextureForSpec(specId)
	local rs = RS()
	if rs and rs.SpecIconTexture then
		return rs.SpecIconTexture(specId)
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function TextureForCategory(cat)
	local rs = RS()
	if rs and rs.CategoryIconTexture then
		return rs.CategoryIconTexture(cat)
	end
	return (cat and cat.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function SpecName(specId)
	local rs = RS()
	if rs and rs.SpecDisplayName then
		return rs.SpecDisplayName(specId) or tostring(specId)
	end
	return tostring(specId)
end

local function ClassName(classFile)
	local rs = RS()
	if rs and rs.ClassDisplayName then
		return rs.ClassDisplayName(classFile) or tostring(classFile or "")
	end
	return tostring(classFile or "")
end

local function TryPersistDraft()
	local rs = RS()
	local draft = session.draft
	if not rs or not draft or not rs.DraftReadyToPersist or not rs.DraftReadyToPersist(draft) then
		return false
	end
	local status, reason, entryId = rs:UpsertEntry({
		planId = draft.planId,
		nickname = draft.nickname,
		mainClass = draft.classFile,
		mainSpec = draft.specId,
		notes = draft.notes or "",
	})
	Report(status, reason)
	if status == "accepted" then
		session.draft = nil
		DebugInfo("draft persisted entryId=%s", tostring(entryId))
		return true
	end
	return false
end

local function TryPersistAltDraft()
	local rs = RS()
	local wrap = session.altDraft
	if not rs or not wrap or not wrap.draft then
		return false
	end
	local draft = wrap.draft
	if not rs.AltDraftIsComplete or not rs.AltDraftIsComplete(draft) then
		return false
	end
	local entries = rs:GetSortedEntries(draft.planId)
	local entry = nil
	for i = 1, #entries do
		if entries[i].entryId == wrap.entryId then
			entry = entries[i]
			break
		end
	end
	if not entry then
		session.altDraft = nil
		return false
	end
	local status, reason = rs:UpsertEntry({
		entryId = entry.entryId,
		planId = entry.planId,
		nickname = entry.nickname,
		mainClass = entry.mainClass,
		mainSpec = entry.mainSpec,
		notes = entry.notes,
		altClass = draft.classFile,
		altSpec = draft.specId,
	}, { expectedVer = entry.ver })
	Report(status, reason)
	if status == "accepted" then
		session.altDraft = nil
		return true
	end
	return false
end

local function TryPersistEdit()
	local rs = RS()
	local editing = session.editing
	if not rs or not editing or not editing.draft then
		return false
	end
	local entries = rs:GetSortedEntries()
	local entry = nil
	for i = 1, #entries do
		if entries[i].entryId == editing.entryId then
			entry = entries[i]
			break
		end
	end
	if not entry then
		session.editing = nil
		return false
	end
	local draft = editing.draft
	if editing.slot == "main" then
		if not rs.DraftReadyToPersist or not rs.DraftReadyToPersist(draft) then
			return false
		end
		local fields = {
			entryId = entry.entryId,
			planId = entry.planId,
			nickname = draft.nickname ~= "" and draft.nickname or entry.nickname,
			mainClass = draft.classFile,
			mainSpec = draft.specId,
			notes = entry.notes,
		}
		if entry.altClass then
			fields.altClass = entry.altClass
			fields.altSpec = entry.altSpec
		end
		local status, reason = rs:UpsertEntry(fields, { expectedVer = entry.ver })
		Report(status, reason)
		if status == "accepted" then
			session.editing = nil
			return true
		end
		return false
	end

	draft.mainClass = entry.mainClass
	draft.mainSpec = entry.mainSpec
	if not rs.AltDraftIsComplete(draft) then
		return false
	end
	local status, reason = rs:UpsertEntry({
		entryId = entry.entryId,
		planId = entry.planId,
		nickname = entry.nickname,
		mainClass = entry.mainClass,
		mainSpec = entry.mainSpec,
		notes = entry.notes,
		altClass = draft.classFile,
		altSpec = draft.specId,
	}, { expectedVer = entry.ver })
	Report(status, reason)
	if status == "accepted" then
		session.editing = nil
		return true
	end
	return false
end

local iconButtonPool = {}
local textButtonPool = {}
local framePool = {}
local editPool = {}
local fontStringPool = {}

-- Peak simultaneous demand is finite (MAX_ENTRIES_PER_PLAN rows with main+alt
-- icons, nick+notes, action buttons, plus an active class/spec picker). Pools
-- therefore retain every released owned widget instead of discarding at a low
-- hard cap that would force recurring CreateFrame work.

local function SafeClearScript(widget, script)
	if not widget or type(script) ~= "string" then
		return
	end
	if type(widget.HasScript) == "function" then
		if widget:HasScript(script) and widget.SetScript then
			widget:SetScript(script, nil)
		end
		return
	end
	-- HasScript unavailable: clear only by object type.
	local ot = widget.GetObjectType and widget:GetObjectType() or nil
	if ot == "Button" and script == "OnClick" and widget.SetScript then
		widget:SetScript(script, nil)
	elseif ot == "EditBox" and widget.SetScript then
		if script == "OnEnterPressed" or script == "OnEscapePressed"
			or script == "OnTextChanged" or script == "OnEditFocusGained"
			or script == "OnEditFocusLost" then
			widget:SetScript(script, nil)
		end
	end
end

local function ClearTeardownScripts(widget)
	if not widget then
		return
	end
	local ot = widget.GetObjectType and widget:GetObjectType() or nil
	if ot == "EditBox" then
		-- Clear focus handlers before Hide/reparent can invoke them.
		SafeClearScript(widget, "OnEditFocusLost")
		SafeClearScript(widget, "OnEditFocusGained")
		SafeClearScript(widget, "OnTextChanged")
		SafeClearScript(widget, "OnEnterPressed")
		SafeClearScript(widget, "OnEscapePressed")
	elseif ot == "Button" then
		-- Keep stable OnEnter/OnLeave tooltip handlers installed at acquire time.
		SafeClearScript(widget, "OnClick")
	end
end

local function ReleasePooled(widget, pool, kind)
	if not widget then
		return
	end
	if typingFocus == widget then
		typingFocus = nil
	end
	-- Clear teardown-sensitive callbacks before Hide/reparent can fire them.
	ClearTeardownScripts(widget)
	local ot = widget.GetObjectType and widget:GetObjectType() or nil
	if ot == "EditBox" and widget.HasFocus and widget:HasFocus() and widget.ClearFocus then
		widget:ClearFocus()
	end
	widget:Hide()
	if widget.ClearAllPoints then
		widget:ClearAllPoints()
	end
	if widget.SetParent then
		widget:SetParent(nil)
	end
	widget.__sfRaidSignupField = nil
	-- Always retain for reuse across supported demand; never discard at a low cap.
	pool[#pool + 1] = widget
end

local function AcquirePooled(pool, factory, reuseCounter)
	local frame = table.remove(pool)
	if frame then
		if reuseCounter == "region" then
			session.regionReuseCount = (session.regionReuseCount or 0) + 1
		else
			session.frameReuseCount = (session.frameReuseCount or 0) + 1
		end
		if frame.Show then
			frame:Show()
		end
		return frame, true
	end
	return factory(), false
end

local function MakeIconButton(parent, size)
	local btn = AcquirePooled(iconButtonPool, function()
		local b = TrackCreate(CreateFrame("Button", nil, parent))
		b.__sfRaidSignupOwned = true
		b.__sfPoolKind = "icon"
		b:SetSize(size or ICON, size or ICON)
		local tex = TrackRegionCreate(b:CreateTexture(nil, "ARTWORK"))
		tex:SetAllPoints()
		b.icon = tex
		b:SetScript("OnEnter", function(self)
			if self.tooltipTitle or self.tooltipText then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				if self.tooltipTitle then
					GameTooltip:SetText(self.tooltipTitle, 1, 1, 1)
				end
				if self.tooltipText then
					GameTooltip:AddLine(self.tooltipText, 0.9, 0.9, 0.9, true)
				end
				GameTooltip:Show()
			end
		end)
		b:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		return b
	end)
	btn.__sfRaidSignupOwned = true
	btn.__sfPoolKind = "icon"
	btn:SetParent(parent)
	btn:SetSize(size or ICON, size or ICON)
	btn.tooltipTitle = nil
	btn.tooltipText = nil
	btn.__sfRaidSignupSpecSlot = nil
	SafeClearScript(btn, "OnClick")
	btn:Show()
	return btn
end

local function SetIconVisual(btn, texture, enabled, grey)
	if not btn.icon then
		local tex = TrackRegionCreate(btn:CreateTexture(nil, "ARTWORK"))
		tex:SetAllPoints()
		btn.icon = tex
	end
	btn.icon:SetTexture(texture)
	if grey or not enabled then
		btn.icon:SetDesaturated(true)
		btn.icon:SetVertexColor(0.45, 0.45, 0.45)
	else
		btn.icon:SetDesaturated(false)
		btn.icon:SetVertexColor(1, 1, 1)
	end
	if enabled then
		btn:Enable()
	else
		btn:Disable()
	end
end

local function ReleaseOwnedRegions(host)
	if not host or not host.GetRegions then
		return
	end
	local regions = { host:GetRegions() }
	for i = 1, #regions do
		local region = regions[i]
		if region and region.__sfRaidSignupOwned and region.__sfPoolKind == "font" then
			ReleasePooled(region, fontStringPool, "font")
		end
	end
end

local function ReleaseHostChildren(host)
	if not host then
		return
	end
	local kids = { host:GetChildren() }
	for i = 1, #kids do
		local child = kids[i]
		-- Only pool feature-owned widgets. Template/framework descendants stay
		-- with their owning control and are never absorbed into generic pools.
		if child and child.__sfRaidSignupOwned then
			ReleaseHostChildren(child)
			ReleaseOwnedRegions(child)
			local kind = child.__sfPoolKind
			if kind == "icon" then
				ReleasePooled(child, iconButtonPool, "icon")
			elseif kind == "text" then
				ReleasePooled(child, textButtonPool, "text")
			elseif kind == "edit" then
				ReleasePooled(child, editPool, "edit")
			elseif kind == "frame" then
				ReleasePooled(child, framePool, "frame")
			end
		end
	end
	ReleaseOwnedRegions(host)
end

local function AcquireFrame(parent)
	local frame = AcquirePooled(framePool, function()
		local f = TrackCreate(CreateFrame("Frame", nil, parent))
		f.__sfRaidSignupOwned = true
		f.__sfPoolKind = "frame"
		return f
	end)
	frame.__sfRaidSignupOwned = true
	frame.__sfPoolKind = "frame"
	frame:SetParent(parent)
	frame:Show()
	return frame
end

local function AcquireEditBox(parent)
	local edit = AcquirePooled(editPool, function()
		local e = TrackCreate(CreateFrame("EditBox", nil, parent, "InputBoxTemplate"))
		e.__sfRaidSignupOwned = true
		e.__sfPoolKind = "edit"
		e:SetAutoFocus(false)
		return e
	end)
	edit.__sfRaidSignupOwned = true
	edit.__sfPoolKind = "edit"
	edit:SetParent(parent)
	-- Pool reset: prior saved rows may have Disable()'d this widget (archived /
	-- non-owned). Restore enabled so draft/Add Row and editable rows can type;
	-- callers that need read-only then Disable() again after acquire.
	if edit.Enable then
		edit:Enable()
	end
	edit:Show()
	return edit
end

local function AcquireFontString(parent, layer, template)
	local fs = AcquirePooled(fontStringPool, function()
		local created = TrackRegionCreate(parent:CreateFontString(nil, layer or "OVERLAY", template or "GameFontHighlight"))
		created.__sfRaidSignupOwned = true
		created.__sfPoolKind = "font"
		return created
	end, "region")
	fs.__sfRaidSignupOwned = true
	fs.__sfPoolKind = "font"
	if fs.SetParent then
		fs:SetParent(parent)
	end
	if fs.Show then
		fs:Show()
	end
	return fs
end

local function ClassColor(classFile)
	local key = type(classFile) == "string" and string.upper(classFile) or nil
	local data = key and SF.WOW_CLASSES and SF.WOW_CLASSES[key]
	local c = data and data.colorCode
	if c then
		return c.r or 1, c.g or 1, c.b or 1
	end
	return 1, 1, 1
end

-- Display-only clip for collapsed rows: nicknames/notes are byte-capped but can
-- still overflow the fixed row width; cut at a UTF-8 character boundary.
local function ClipDisplay(text, maxChars)
	if type(text) ~= "string" or text == "" then
		return ""
	end
	local chars = {}
	-- Lua 5.1 patterns reject a literal NUL byte in a set, so the ASCII range
	-- starts at byte 1 (NUL cannot appear in nicknames/notes anyway).
	for ch in text:gmatch("[\1-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = ch
		if #chars > maxChars then
			break
		end
	end
	if #chars > maxChars then
		return table.concat(chars, "", 1, maxChars) .. "…"
	end
	return text
end

local function AcquireFieldLabel(parent, text)
	local fs = AcquireFontString(parent, "OVERLAY", "GameFontHighlight")
	fs:ClearAllPoints()
	fs:SetText(text or "")
	fs:SetTextColor(0.75, 0.75, 0.75)
	return fs
end

local function AcquireTextButton(parent)
	local btn = AcquirePooled(textButtonPool, function()
		local b = TrackCreate(CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"))
		b.__sfRaidSignupOwned = true
		b.__sfPoolKind = "text"
		return b
	end)
	btn.__sfRaidSignupOwned = true
	btn.__sfPoolKind = "text"
	btn.tooltipTitle = nil
	btn.tooltipText = nil
	btn:SetParent(parent)
	SafeClearScript(btn, "OnClick")
	btn:Show()
	return btn
end

local function SafeSetEditText(edit, text)
	if not edit then
		return
	end
	if typingFocus == edit and edit.HasFocus and edit:HasFocus() then
		return
	end
	edit:SetText(text or "")
end

local function LayoutPicker(host, draft, opts)
	opts = opts or {}
	ReleaseHostChildren(host)

	local x = 0
	local function place(btn, width)
		btn:SetParent(host)
		btn:ClearAllPoints()
		btn:SetPoint("LEFT", host, "LEFT", x, 0)
		btn:Show()
		x = x + (width or ICON) + ICON_GAP
	end

	local phase = draft.phase or "class"
	if phase == "class" or (not draft.classFile) then
		local order = ClassOrder()
		for i = 1, #order do
			local classFile = order[i]
			local btn = MakeIconButton(host, ICON)
			SetIconVisual(btn, TextureForClass(classFile), true, false)
			btn.tooltipTitle = ClassName(classFile)
			btn:SetScript("OnClick", function()
				if opts.onClass then
					opts.onClass(classFile)
				end
			end)
			place(btn)
		end
	else
		local function WireChangeClassControl(control)
			control.tooltipText = Loc("RAID_SIGNUP_TIP_CHANGE_CLASS",
				"Click to choose a different class.")
			control:SetScript("OnClick", function()
				if opts.onResetClass then
					opts.onResetClass()
				end
			end)
		end

		if draft.specId then
			-- Collapsed selection: only the chosen spec icon.
			local selected = MakeIconButton(host, ICON)
			selected:Enable()
			SetIconVisual(selected, TextureForSpec(draft.specId), true, false)
			selected.tooltipTitle = SpecName(draft.specId)
			WireChangeClassControl(selected)
			place(selected)
		else
			-- Spec phase: only spec icons; a back button returns to class picking
			-- so the chosen class icon does not linger among them.
			local back = AcquirePooled(textButtonPool, function()
				local b = TrackCreate(CreateFrame("Button", nil, host, "UIPanelButtonTemplate"))
				b.__sfRaidSignupOwned = true
				b.__sfPoolKind = "text"
				return b
			end)
			back.__sfRaidSignupOwned = true
			back.__sfPoolKind = "text"
			back:SetParent(host)
			SafeClearScript(back, "OnClick")
			back:SetSize(56, 20)
			back:SetText(Loc("RAID_SIGNUP_PICKER_BACK", "Back"))
			back.tooltipTitle = ClassName(draft.classFile)
			back:SetScript("OnEnter", function(self)
				if self.tooltipTitle or self.tooltipText then
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					if self.tooltipTitle then
						GameTooltip:SetText(self.tooltipTitle, 1, 1, 1)
					end
					if self.tooltipText then
						GameTooltip:AddLine(self.tooltipText, 0.9, 0.9, 0.9, true)
					end
					GameTooltip:Show()
				end
			end)
			back:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			WireChangeClassControl(back)
			back:Show()
			place(back, 56)

			local specs = SpecsFor(draft.classFile)
			for i = 1, #specs do
				local specId = specs[i]
				local disabled = opts.disableSpec and opts.disableSpec(specId)
				local btn = MakeIconButton(host, ICON)
				SetIconVisual(btn, TextureForSpec(specId), not disabled, disabled)
				btn.tooltipTitle = SpecName(specId)
				if disabled then
					btn.tooltipText = Loc("RAID_SIGNUP_TIP_SPEC_DISABLED",
						"This specialization matches the main selection and cannot be chosen as the alternative.")
				end
				btn:SetScript("OnClick", function()
					if disabled then
						return
					end
					if opts.onSpec then
						opts.onSpec(specId)
					end
				end)
				place(btn)
			end
		end
	end
	host:SetHeight(ICON + 2)
	return x
end

local function CurrentPlans()
	local rs = RS()
	return rs and rs.GetSortedPlans and rs:GetSortedPlans(true) or {}
end

local function CurrentSelectedId()
	local rs = RS()
	return rs and rs.GetSelectedPlanId and rs:GetSelectedPlanId() or nil
end

local function CurrentSelectedPlan()
	local selectedId = CurrentSelectedId()
	local plans = CurrentPlans()
	for i = 1, #plans do
		if plans[i].planId == selectedId then
			return plans[i]
		end
	end
	return nil
end

local function CurrentPlanOpen()
	local plan = CurrentSelectedPlan()
	return plan ~= nil and not plan.archived
end

local function CurrentPlanOptions()
	local planOptions = {}
	local plans = CurrentPlans()
	for i = 1, #plans do
		local p = plans[i]
		local label = p.name
		if p.archived then
			label = label .. Loc("RAID_SIGNUP_ARCHIVED_SUFFIX", " (archived)")
		end
		planOptions[#planOptions + 1] = { value = p.planId, label = label }
	end
	return planOptions
end

local function MakePlanDropdownItem()
	return {
		type = "dropdown",
		label = Loc("RAID_SIGNUP_PLAN_SELECT", "Active plan"),
		get = function()
			return CurrentSelectedId()
		end,
		set = function(value)
			local mod = RS()
			if not mod then
				return
			end
			DiscardEphemeral()
			mod:SelectPlan(value)
			QueueRefresh({ force = true })
		end,
		options = function()
			return CurrentPlanOptions()
		end,
		enabled = function()
			return Caps().canRead and #CurrentPlanOptions() > 0
		end,
	}
end

-- One tab bar per panel; reused across rebuilds so tab switching never
-- accumulates widgets or callbacks.
local function EnsureTabBar(panel)
	local existing = panel.__sfRaidSignupTabBar
	if existing then
		return existing
	end
	local ui = SF.SettingsUI
	if not (ui and ui.TabBar and ui.TabBar.Create) then
		return nil
	end
	local bar = ui.TabBar:Create(panel)
	bar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, TAB_BAR_TOP_OFFSET)
	bar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", TAB_BAR_RIGHT_INSET, TAB_BAR_TOP_OFFSET)
	local preferred = bar.GetPreferredHeight and bar:GetPreferredHeight() or 28
	bar:SetHeight(preferred)
	panel.__sfRaidSignupTabDrop = 2 + preferred + 4
	bar:SetOnSelect(function(tabId)
		if tabId ~= VIEW_SIGNUP and tabId ~= VIEW_MANAGE then
			return
		end
		if tabId == VIEW_MANAGE then
			local caps = Caps()
			if not caps.canManagePlans then
				return
			end
		end
		if session.view == tabId then
			return
		end
		session.view = tabId
		if Page.Refresh then
			Page:Refresh(panel, { force = true })
		end
	end)
	bar:Hide()
	panel.__sfRaidSignupTabBar = bar
	return bar
end

-- Inline action/error feedback via the active view's section message row
-- (same pattern as other settings pages); never chat output.
local function SyncFeedback(panel, view)
	local sections = panel.__sfRaidSignupSections
	if not sections then
		return
	end
	local targetId = (view == VIEW_MANAGE) and "raidSignupPlans" or nil
	local applied = panel.__sfRaidSignupMessages
	if not applied then
		applied = {}
		panel.__sfRaidSignupMessages = applied
	end
	for id, section in pairs(sections) do
		if section.SetMessage and section.ClearMessage then
			local wantText, wantKind = nil, nil
			if id == targetId and session.status and session.status ~= "" then
				wantText, wantKind = session.status, session.statusKind
			end
			local cur = applied[id]
			local unchanged = (cur and cur.text or nil) == wantText
				and (wantText == nil or (cur ~= nil and cur.kind == wantKind))
			if not unchanged then
				if wantText then
					section:SetMessage(wantText, wantKind)
				else
					section:ClearMessage()
				end
				applied[id] = wantText and { text = wantText, kind = wantKind } or nil
			end
		end
	end
	-- Signup view feedback renders beneath the signup list, not in a section header.
	local fs = panel.__sfRaidSignupStatusFs
	if fs and fs.SetText then
		if view == VIEW_SIGNUP and session.status and session.status ~= "" then
			fs:SetText(session.status)
			local r, g, b = 1, 1, 1
			if session.statusKind == "error" then
				r, g, b = 1, 0.25, 0.25
			elseif session.statusKind == "success" then
				r, g, b = 0.25, 1, 0.25
			elseif session.statusKind == "warn" then
				r, g, b = 1, 0.82, 0
			end
			if fs.SetTextColor then fs:SetTextColor(r, g, b) end
			if fs.Show then fs:Show() end
		else
			fs:SetText("")
			if fs.Hide then fs:Hide() end
		end
	end
end

-- Apply the active view: officer-only Manage tab, section visibility, scroll
-- offset for the tab bar, and inline feedback. Safe fallback to the normal
-- signup view when management eligibility is lost.
local function SyncChrome(panel)
	if not panel then
		return
	end
	local caps = Caps()
	local canManage = caps.canManagePlans and true or false
	if session.view == VIEW_MANAGE and not canManage then
		session.view = VIEW_SIGNUP
	end
	local view = (session.view == VIEW_MANAGE) and VIEW_MANAGE or VIEW_SIGNUP

	local sections = panel.__sfRaidSignupSections
	if sections then
		for _, section in pairs(sections) do
			local want = (section.__sfRaidSignupView or VIEW_SIGNUP) == view
			if section.SetShown then
				section:SetShown(want)
			end
		end
	end

	local pb = panel.__sfPageBuilder
	local bar = panel.__sfRaidSignupTabBar
	if canManage then
		bar = EnsureTabBar(panel)
		if bar then
			local tabs = {
				{ id = VIEW_SIGNUP, label = Loc("RAID_SIGNUP_TAB_SIGNUP", "Signup") },
				{ id = VIEW_MANAGE, label = Loc("RAID_SIGNUP_TAB_MANAGE", "Manage") },
			}
			if not bar.HasSameTabs or not bar:HasSameTabs(tabs) then
				bar:SetTabs(tabs)
			end
			if bar.SetSelected then
				bar:SetSelected(view)
			end
			bar:Show()
		end
	else
		if bar then
			bar:Hide()
		end
	end

	local scroll = pb and pb.scrollFrame
	if scroll and scroll.SetPoint then
		if canManage then
			-- Negative Y: content starts below the tab strip, never under it.
			scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -(panel.__sfRaidSignupTabDrop or TAB_BAR_SCROLL_DROP))
		else
			scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
		end
	end

	SyncFeedback(panel, view)

	if pb and pb.Reflow then
		pb:Reflow()
	end
end

-- Forward-declare page-local paint/host helpers used by Definition closures
-- before their bodies (avoids accidental globals).
local PaintSummary, PaintEntries, EnsureBoardHost, LayoutBoard, PaintRoleTotals

local function SubmitCreatePlan(text)
	session.newPlanName = text or ""
	local mod = RS()
	if not mod then
		return
	end
	local status, reason, planId = mod:CreatePlan(text)
	Report(status, reason)
	if status == "accepted" and planId then
		session.newPlanName = ""
		-- Creating a plan switches selection; never carry an in-progress
		-- signup/edit draft into the new roster.
		DiscardEphemeral()
		mod:SelectPlan(planId)
	end
end

local function Definition()
	return {
		id = "raidSignupBoard",
		selectedId = CurrentSelectedId(),
		planOpen = CurrentPlanOpen(),
		caps = Caps(),
		sections = {
			{
				id = "raidSignupPlanSelect",
				view = VIEW_SIGNUP,
				headerless = true,
				title = Loc("RAID_SIGNUP_SECTION_PLAN", "Roster plan"),
				items = {
					MakePlanDropdownItem(),
				},
			},
			{
				id = "raidSignupPlans",
				view = VIEW_MANAGE,
				title = Loc("RAID_SIGNUP_SECTION_PLANS", "Roster plans"),
				items = {
					MakePlanDropdownItem(),
					{
						type = "editbox_button",
						label = Loc("RAID_SIGNUP_PLAN_CREATE", "Create plan"),
						buttonText = Loc("RAID_SIGNUP_PLAN_CREATE_BTN", "Create"),
						hint = Loc("RAID_SIGNUP_PLAN_NAME_HINT", "Plan name"),
						get = function()
							return session.newPlanName
						end,
						onSubmit = SubmitCreatePlan,
						enabled = function()
							return Caps().canManagePlans
						end,
					},
					{
						type = "editbox_button",
						label = Loc("RAID_SIGNUP_PLAN_RENAME", "Rename plan"),
						buttonText = Loc("RAID_SIGNUP_PLAN_RENAME_BTN", "Rename"),
						hint = Loc("RAID_SIGNUP_PLAN_NAME_HINT", "Plan name"),
						-- Bind dirty draft text to selected plan identity so a
						-- deferred refresh cannot submit plan A's text against B.
						getSelectionKey = function()
							return CurrentSelectedId()
						end,
						get = function()
							local selectedPlan = CurrentSelectedPlan()
							return session.renamePlanName ~= "" and session.renamePlanName
								or (selectedPlan and selectedPlan.name) or ""
						end,
						onSubmit = function(text)
							session.renamePlanName = text or ""
							local mod = RS()
							local selectedId = CurrentSelectedId()
							local selectedPlan = CurrentSelectedPlan()
							if not mod or not selectedId then
								return
							end
							local status, reason = mod:RenamePlan(selectedId, text, {
								expectedVer = selectedPlan and selectedPlan.ver,
							})
							Report(status, reason)
							if status == "accepted" then
								session.renamePlanName = ""
							end
						end,
						enabled = function()
							local selectedPlan = CurrentSelectedPlan()
							return Caps().canManagePlans and selectedPlan ~= nil and not selectedPlan.archived
						end,
						getDisabledTooltip = function()
							local selectedPlan = CurrentSelectedPlan()
							if selectedPlan and selectedPlan.archived then
								return Loc("RAID_SIGNUP_TIP_RENAME_ARCHIVED",
									"Archived plans are read-only. Reopen the plan before renaming.")
							end
							return nil
						end,
					},
					{
						type = "button",
						label = Loc("RAID_SIGNUP_PLAN_ARCHIVE", "Archive / reopen"),
						buttonText = function()
							local selectedPlan = CurrentSelectedPlan()
							if selectedPlan and selectedPlan.archived then
								return Loc("RAID_SIGNUP_PLAN_REOPEN_BTN", "Reopen")
							end
							return Loc("RAID_SIGNUP_PLAN_ARCHIVE_BTN", "Archive")
						end,
						enabled = function()
							return Caps().canManagePlans and CurrentSelectedPlan() ~= nil
						end,
						onClick = function()
							local mod = RS()
							local selectedId = CurrentSelectedId()
							local selectedPlan = CurrentSelectedPlan()
							if not mod or not selectedId or not selectedPlan then
								return
							end
							local status, reason = mod:SetPlanArchived(selectedId, not selectedPlan.archived, {
								expectedVer = selectedPlan.ver,
							})
							Report(status, reason)
							DiscardEphemeral()
						end,
					},
				},
			},
			{
				id = "raidSignupBoard",
				view = VIEW_SIGNUP,
				headerless = true,
				title = Loc("RAID_SIGNUP_SECTION_ENTRIES", "Signups"),
				items = {
					{
						type = "custom",
						build = function(section)
							EnsureBoardHost(section)
						end,
					},
				},
			},
		},
	}
end

local function SidebarWidth(host)
	local w = host and host.GetWidth and host:GetWidth() or 0
	if not w or w < 120 then
		w = 300
	end
	return w
end

-- Sidebar column count for the compact class/coverage grids.
local function SidebarCols(width, pitch)
	return math.max(1, math.min(5, math.floor((width + 8) / pitch)))
end

PaintSummary = function(host, planId)
	session.boardPaintCount = session.boardPaintCount + 1
	local rs = RS()
	local summary = rs and rs.GetPlanSummary and rs:GetPlanSummary(planId) or {
		classCounts = {}, major = {}, utility = {},
	}
	local order = ClassOrder()
	local majorCats = (rs and rs.MAJOR_CATEGORIES) or {}
	local utilityCats = (rs and rs.UTILITY_CATEGORIES) or {}
	local w = SidebarWidth(host)

	local classPitch = ICON + 6 + CLASS_COUNT_WIDTH + 8
	local iconPitch = ICON + 8
	local cols = SidebarCols(w, classPitch)
	local iconCols = SidebarCols(w, iconPitch)
	local rowH = ICON + 4
	local classRows = math.max(1, math.ceil(#order / cols))
	local majorRows = math.max(1, math.ceil(#majorCats / iconCols))
	local utilityRows = math.max(1, math.ceil(#utilityCats / iconCols))
	local height = 4 + 16 + classRows * rowH + 10 + 16 + majorRows * rowH + 10 + 16 + utilityRows * rowH + 4
	host.__sfSummaryContentH = height
	host:SetHeight(height)
	LayoutBoard(host.__sfRaidSignupPanel)

	-- Build once per width bucket, then update counts / coverage greys in place.
	local builtW = host.__sfSummaryBuiltW or 0
	if not host.__sfSummaryBuilt or math.abs(builtW - w) > 24 then
		ReleaseHostChildren(host)
		host.__sfClassCounts = nil
		host.__sfClassIcons = nil
		host.__sfMajorButtons = nil
		host.__sfUtilityButtons = nil

		local function addTitle(text, y)
			local t = AcquireFontString(host, "OVERLAY", "GameFontNormal")
			t:SetPoint("TOPLEFT", host, "TOPLEFT", 0, y)
			t:SetText(text)
			return t
		end

		addTitle(Loc("RAID_SIGNUP_SECTION_CLASSES", "Classes"), -4)
		local classY = -24

		-- Row-major compact grid: icon + count, CLASS_ORDER preserved.
		for i = 1, #order do
			local classFile = order[i]
			local idx = i - 1
			local col = idx % cols
			local rowIndex = math.floor(idx / cols)
			local x = col * classPitch
			local y = classY - rowIndex * rowH
			local icon = MakeIconButton(host, ICON)
			icon:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
			SetIconVisual(icon, TextureForClass(classFile), true, false)
			host.__sfClassIcons = host.__sfClassIcons or {}
			host.__sfClassIcons[classFile] = icon
			local count = AcquireFontString(host, "OVERLAY", "GameFontHighlight")
			count:SetPoint("LEFT", icon, "RIGHT", 6, 0)
			host.__sfClassCounts = host.__sfClassCounts or {}
			host.__sfClassCounts[classFile] = count
		end

		local function paintGroup(title, categories, coveredMap, y)
			addTitle(title, y)
			local buttons = {}
			local gridY = y - 20
			for i = 1, #categories do
				local cat = categories[i]
				local idx = i - 1
				local col = idx % iconCols
				local rowIndex = math.floor(idx / iconCols)
				local btn = MakeIconButton(host, ICON)
				btn:SetPoint("TOPLEFT", host, "TOPLEFT",
					col * iconPitch, gridY - rowIndex * rowH)
				SetIconVisual(btn, TextureForCategory(cat), true, not (coveredMap and coveredMap[cat.id]))
				btn.tooltipTitle = Loc(cat.nameKey, cat.nameDefault)
				btn.tooltipText = Loc(cat.tipKey, cat.tipDefault)
				buttons[cat.id] = btn
			end
			return buttons
		end

		local majorY = classY - classRows * rowH - 10
		host.__sfMajorButtons = paintGroup(
			Loc("RAID_SIGNUP_MAJOR_GROUP", "Major Buffs/Debuffs"),
			majorCats, summary.major, majorY)
		local utilityY = majorY - majorRows * rowH - 10
		host.__sfUtilityButtons = paintGroup(
			Loc("RAID_SIGNUP_UTILITY_GROUP", "Utility"),
			utilityCats, summary.utility, utilityY)

		host.__sfSummaryBuilt = true
		host.__sfSummaryBuiltW = w
	end

	for i = 1, #order do
		local classFile = order[i]
		local fs = host.__sfClassCounts and host.__sfClassCounts[classFile]
		if fs then
			fs:SetText(tostring((summary.classCounts and summary.classCounts[classFile]) or 0))
		end
	end
	local function refreshButtons(buttons, coveredMap, categories)
		if not buttons then
			return
		end
		for i = 1, #(categories or {}) do
			local cat = categories[i]
			local btn = buttons[cat.id]
			if btn then
				SetIconVisual(btn, TextureForCategory(cat), true, not (coveredMap and coveredMap[cat.id]))
			end
		end
	end
	refreshButtons(host.__sfMajorButtons, summary.major, rs and rs.MAJOR_CATEGORIES)
	refreshButtons(host.__sfUtilityButtons, summary.utility, rs and rs.UTILITY_CATEGORIES)
end

PaintEntries = function(host, planId, planOpen, caps)
	-- Preserve focused edit text across pooled rebuilds.
	local focusedText, focusedCursor = nil, nil
	if typingFocus and typingFocus.HasFocus and typingFocus:HasFocus() and typingFocus.GetText then
		focusedText = typingFocus:GetText()
		focusedCursor = typingFocus.GetCursorPosition and typingFocus:GetCursorPosition() or nil
	end
	ReleaseHostChildren(host)
	session.boardPaintCount = session.boardPaintCount + 1
	local rs = RS()
	local entries = rs and rs.GetSortedEntries and rs:GetSortedEntries(planId) or {}
	local y = -2

	local function placeRow(height, builder)
		local row = AcquireFrame(host)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", host, "TOPLEFT", 0, y)
		row:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, y)
		row:SetHeight(height)
		builder(row)
		-- Subtle divider beneath each signup row; created once per pooled row.
		if not row.__sfRowLine then
			local line = TrackRegionCreate(row:CreateTexture(nil, "ARTWORK"))
			line:SetHeight(1)
			line:SetColorTexture(1, 1, 1, 0.18)
			row.__sfRowLine = line
		end
		row.__sfRowLine:ClearAllPoints()
		row.__sfRowLine:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
		row.__sfRowLine:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
		row.__sfRowLine:Show()
		y = y - height - 4
	end

	if session.draft and planOpen and session.draft.planId == planId then
		placeRow(86, function(row)
			local nameLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_NAME", "Name"))
			nameLabel:SetPoint("LEFT", row, "LEFT", 4, -13)
			local nick = AcquireEditBox(row)
			nick.__sfRaidSignupField = "nickname"
			nick:SetSize(170, 22)
			nick:SetPoint("LEFT", nameLabel, "RIGHT", 6, 0)
			nick:SetMaxLetters(RS().MAX_NICKNAME or 48)
			nick:Enable()
			SafeSetEditText(nick, session.draft.nickname or "")
			if nick.Instructions then
				nick.Instructions:SetText(Loc("RAID_SIGNUP_NICK_HINT", "Nickname"))
			end
			local function commitNick(self)
				local mod = RS()
				if not mod or not session.draft then
					return
				end
				mod.UpdateDraftField(session.draft, "nickname", self:GetText() or "")
				mod.CommitDraftNickname(session.draft)
				TryPersistDraft()
			end
			BindTypingFocus(nick, commitNick)
			nick:SetScript("OnTextChanged", function(self, userInput)
				if userInput == false then
					return
				end
				local mod = RS()
				if not mod or not session.draft then
					return
				end
				local text = self:GetText() or ""
				mod.UpdateDraftField(session.draft, "nickname", text)
				-- Do not refresh or persist while typing; commit boundary below.
			end)
			nick:SetScript("OnEnterPressed", function(self)
				commitNick(self)
				self:ClearFocus()
			end)

			local classLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_CLASS_SPEC", "Class / Spec"))
			classLabel:SetPoint("LEFT", row, "LEFT", 4, -42)
			local picker = AcquireFrame(row)
			picker:SetPoint("LEFT", classLabel, "RIGHT", 6, 0)
			picker:SetSize(380, ICON + 2)
			LayoutPicker(picker, session.draft, {
				onClass = function(classFile)
					RS().UpdateDraftField(session.draft, "classFile", classFile)
					TryPersistDraft()
					QueueRefresh({ force = true })
				end,
				onSpec = function(specId)
					RS().UpdateDraftField(session.draft, "specId", specId)
					TryPersistDraft()
					QueueRefresh({ force = true })
				end,
				onResetClass = function()
					RS().UpdateDraftField(session.draft, "classFile", nil)
					QueueRefresh({ force = true })
				end,
			})

			local notesLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_NOTES", "Notes"))
			notesLabel:SetPoint("LEFT", row, "LEFT", 4, -69)
			local notes = AcquireEditBox(row)
			notes.__sfRaidSignupField = "notes"
			notes:SetSize(240, 22)
			notes:SetPoint("LEFT", notesLabel, "RIGHT", 6, 0)
			notes:SetMaxLetters(RS().MAX_NOTES or 160)
			notes:Enable()
			SafeSetEditText(notes, session.draft.notes or "")
			if notes.Instructions then
				notes.Instructions:SetText(Loc("RAID_SIGNUP_NOTES_HINT", "Notes (optional)"))
			end
			BindTypingFocus(notes, function(self)
				local mod = RS()
				if mod and session.draft then
					mod.UpdateDraftField(session.draft, "notes", self:GetText() or "")
					TryPersistDraft()
				end
			end)
			notes:SetScript("OnTextChanged", function(self, userInput)
				if userInput == false then
					return
				end
				local mod = RS()
				if not mod or not session.draft then
					return
				end
				mod.UpdateDraftField(session.draft, "notes", self:GetText() or "")
			end)
			notes:SetScript("OnEnterPressed", function(self)
				local mod = RS()
				if mod and session.draft then
					mod.UpdateDraftField(session.draft, "notes", self:GetText() or "")
					TryPersistDraft()
				end
				self:ClearFocus()
			end)
		end)
	end

	for i = 1, #entries do
		local entry = entries[i]
		local editingThis = session.editing and session.editing.entryId == entry.entryId
		local altThis = session.altDraft and session.altDraft.entryId == entry.entryId
		local expanded = editingThis or altThis
		placeRow(expanded and 86 or 26, function(row)
			local canEdit = planOpen and RS().CanEditEntry(caps, caps.actorGuid, entry)
			if expanded then
				-- Editing: labeled fields stacked Name / Class + Spec / Notes, with a
				-- Done button that leaves edit mode without changing class/spec.
				local nameLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_NAME", "Name"))
				nameLabel:SetPoint("LEFT", row, "LEFT", 4, -13)
				local nickBox = AcquireEditBox(row)
				nickBox.__sfRaidSignupField = "nickname"
				nickBox:SetSize(170, 20)
				nickBox:SetPoint("LEFT", nameLabel, "RIGHT", 6, 0)
				nickBox:SetMaxLetters(RS().MAX_NICKNAME or 48)
				SafeSetEditText(nickBox, entry.nickname or "")
				if nickBox.Instructions then
					nickBox.Instructions:SetText(Loc("RAID_SIGNUP_NICK_HINT", "Nickname"))
				end
				if canEdit then
					nickBox:Enable()
				else
					nickBox:Disable()
				end
				local function commitSavedNick(self)
					if not canEdit then
						return
					end
					local text = self:GetText() or ""
					local status, reason = RS():UpsertEntry({
						entryId = entry.entryId,
						planId = entry.planId,
						nickname = text,
						mainClass = entry.mainClass,
						mainSpec = entry.mainSpec,
						notes = entry.notes,
						altClass = entry.altClass,
						altSpec = entry.altSpec,
					}, { expectedVer = entry.ver })
					Report(status, reason)
				end
				BindTypingFocus(nickBox, function()
					-- Only commit nickname edits explicitly via Enter; Escape reverts.
				end)
				nickBox:SetScript("OnEnterPressed", function(self)
					commitSavedNick(self)
					self:ClearFocus()
				end)
				nickBox:SetScript("OnEscapePressed", function(self)
					self:SetText(entry.nickname or "")
					self:ClearFocus()
				end)

				local classLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_CLASS_SPEC", "Class / Spec"))
				classLabel:SetPoint("LEFT", row, "LEFT", 4, -42)
				local picker = AcquireFrame(row)
				picker:SetPoint("LEFT", classLabel, "RIGHT", 6, 0)
				picker:SetSize(380, ICON + 2)
				if editingThis then
					local draft = session.editing.draft
					LayoutPicker(picker, draft, {
						disableSpec = function(specId)
							return session.editing.slot == "alt"
								and RS().IsAltSpecDisabled(draft, specId)
						end,
						onClass = function(classFile)
							if session.editing.slot == "main" then
								RS().UpdateDraftField(draft, "classFile", classFile)
							else
								RS().UpdateAltDraftField(draft, "classFile", classFile)
							end
							TryPersistEdit()
							QueueRefresh({ force = true })
						end,
						onSpec = function(specId)
							if session.editing.slot == "main" then
								RS().UpdateDraftField(draft, "specId", specId)
							else
								RS().UpdateAltDraftField(draft, "specId", specId)
							end
							TryPersistEdit()
							QueueRefresh({ force = true })
						end,
						onResetClass = function()
							if session.editing.slot == "main" then
								RS().UpdateDraftField(draft, "classFile", nil)
							else
								RS().UpdateAltDraftField(draft, "classFile", nil)
							end
							QueueRefresh({ force = true })
						end,
					})
				else
					local draft = session.altDraft.draft
					LayoutPicker(picker, draft, {
						disableSpec = function(specId)
							return RS().IsAltSpecDisabled(draft, specId)
						end,
						onClass = function(classFile)
							RS().UpdateAltDraftField(draft, "classFile", classFile)
							TryPersistAltDraft()
							QueueRefresh({ force = true })
						end,
						onSpec = function(specId)
							RS().UpdateAltDraftField(draft, "specId", specId)
							TryPersistAltDraft()
							QueueRefresh({ force = true })
						end,
						onResetClass = function()
							RS().UpdateAltDraftField(draft, "classFile", nil)
							QueueRefresh({ force = true })
						end,
					})
				end

				local notesLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_NOTES", "Notes"))
				notesLabel:SetPoint("LEFT", row, "LEFT", 4, -69)
				local notesBox = AcquireEditBox(row)
				notesBox.__sfRaidSignupField = "notes"
				notesBox:SetSize(240, 20)
				notesBox:SetPoint("LEFT", notesLabel, "RIGHT", 6, 0)
				notesBox:SetMaxLetters(RS().MAX_NOTES or 160)
				SafeSetEditText(notesBox, entry.notes or "")
				if notesBox.Instructions then
					notesBox.Instructions:SetText(Loc("RAID_SIGNUP_NOTES_HINT", "Notes (optional)"))
				end
				if canEdit then
					notesBox:Enable()
				else
					notesBox:Disable()
				end
				BindTypingFocus(notesBox)
				notesBox:SetScript("OnEnterPressed", function(self)
					if not canEdit then
						return
					end
					local status, reason = RS():UpsertEntry({
						entryId = entry.entryId,
						planId = entry.planId,
						nickname = entry.nickname,
						mainClass = entry.mainClass,
						mainSpec = entry.mainSpec,
						notes = self:GetText() or "",
						altClass = entry.altClass,
						altSpec = entry.altSpec,
					}, { expectedVer = entry.ver })
					Report(status, reason)
					self:ClearFocus()
				end)
				notesBox:SetScript("OnEscapePressed", function(self)
					self:SetText(entry.notes or "")
					self:ClearFocus()
				end)

				local done = AcquireTextButton(row)
				done:SetSize(60, 20)
				done:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -4)
				done:SetText(Loc("RAID_SIGNUP_DONE", "Done"))
				done:SetScript("OnClick", function()
					-- Done saves pending Name/Notes edits (Enter commits individually);
					-- both fields go in one write so the version check stays valid.
					if canEdit then
						local newNick = nickBox:GetText() or ""
						local newNotes = notesBox:GetText() or ""
						if newNick ~= (entry.nickname or "") or newNotes ~= (entry.notes or "") then
							local status, reason = RS():UpsertEntry({
								entryId = entry.entryId,
								planId = entry.planId,
								nickname = newNick,
								mainClass = entry.mainClass,
								mainSpec = entry.mainSpec,
								notes = newNotes,
								altClass = entry.altClass,
								altSpec = entry.altSpec,
							}, { expectedVer = entry.ver })
							Report(status, reason)
						end
					end
					if editingThis then
						session.editing = nil
					else
						session.altDraft = nil
					end
					QueueRefresh({ force = true })
				end)
				return
			end

			-- Collapsed: one line — class-colored name, spec icon(s), alt spec
			-- name + icon, then notes. Clicking an icon opens the editor.
			local nameFs = AcquireFieldLabel(row, ClipDisplay(entry.nickname or "", 20))
			nameFs:SetPoint("LEFT", row, "LEFT", 4, 0)
			nameFs:SetTextColor(ClassColor(entry.mainClass))
			local mainBtn = MakeIconButton(row, ICON)
			mainBtn.__sfRaidSignupSpecSlot = "main"
			mainBtn:SetPoint("LEFT", nameFs, "RIGHT", 6, 0)
			-- Enabled presentation follows canEdit (plan open + edit eligibility).
			-- Informative hover tooltips stay assigned even when the button is disabled.
			SetIconVisual(mainBtn, TextureForSpec(entry.mainSpec), canEdit, false)
			mainBtn.tooltipTitle = SpecName(entry.mainSpec)
			mainBtn.tooltipText = ClassName(entry.mainClass) .. " · " .. SpecName(entry.mainSpec)
			mainBtn:SetScript("OnClick", function()
				if not canEdit then
					return
				end
				session.draft = nil
				session.altDraft = nil
				session.editing = {
					entryId = entry.entryId,
					slot = "main",
					draft = {
						nickname = entry.nickname,
						nicknameCommitted = true,
						classFile = nil,
						specId = nil,
						phase = "class",
					},
				}
				QueueRefresh({ force = true })
			end)
			local anchor = mainBtn
			if entry.altClass and entry.altSpec then
				local altNameFs = AcquireFieldLabel(row, SpecName(entry.altSpec))
				altNameFs:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
				altNameFs:SetTextColor(0.85, 0.85, 0.85)
				local altBtn = MakeIconButton(row, ICON)
				altBtn.__sfRaidSignupSpecSlot = "alt"
				altBtn:SetPoint("LEFT", altNameFs, "RIGHT", 4, 0)
				SetIconVisual(altBtn, TextureForSpec(entry.altSpec), canEdit, false)
				altBtn.tooltipTitle = SpecName(entry.altSpec)
				altBtn.tooltipText = Loc("RAID_SIGNUP_ALT_LABEL", "Alternative")
					.. ": " .. ClassName(entry.altClass) .. " · " .. SpecName(entry.altSpec)
				altBtn:SetScript("OnClick", function()
					if not canEdit then
						return
					end
					session.draft = nil
					session.altDraft = nil
					session.editing = {
						entryId = entry.entryId,
						slot = "alt",
						draft = {
							classFile = nil,
							specId = nil,
							mainClass = entry.mainClass,
							mainSpec = entry.mainSpec,
							phase = "class",
						},
					}
					QueueRefresh({ force = true })
				end)
				anchor = altBtn
			end
			local notesText = entry.notes or ""
			if notesText ~= "" then
				local notesFs = AcquireFieldLabel(row, ClipDisplay(notesText, 28))
				notesFs:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
				notesFs:SetTextColor(0.6, 0.6, 0.6)
				anchor = notesFs
			end
			if planOpen and canEdit then
				local del = AcquireTextButton(row)
				del:SetSize(70, 20)
				del:SetPoint("RIGHT", row, "RIGHT", -4, 0)
				del:SetText(Loc("RAID_SIGNUP_DELETE", "Delete"))
				del:SetScript("OnClick", function()
					local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
					local msg = Loc("RAID_SIGNUP_DELETE_CONFIRM",
						"Delete this signup entry?")
					local function commit()
						local status, reason = RS():DeleteEntry(entry.entryId, {
							expectedVer = entry.ver,
						})
						Report(status, reason)
					end
					if dialogs and dialogs.Confirm then
						dialogs:Confirm(msg, Loc("RAID_SIGNUP_DELETE", "Delete"), commit)
					else
						commit()
					end
				end)
				local altAction = AcquireTextButton(row)
				altAction:SetSize(90, 20)
				altAction:SetPoint("RIGHT", del, "LEFT", -8, 0)
				if not entry.altClass then
					altAction:SetText(Loc("RAID_SIGNUP_ADD_ALT", "Add an Alt?"))
					altAction:SetScript("OnClick", function()
						session.draft = nil
						session.editing = nil
						session.altDraft = {
							entryId = entry.entryId,
							draft = RS().MakeAltDraft(entry),
						}
						QueueRefresh({ force = true })
					end)
				else
					altAction:SetText(Loc("RAID_SIGNUP_REMOVE_ALT", "Remove Alt"))
					altAction:SetScript("OnClick", function()
						local status, reason = RS():RemoveAlternative(entry.entryId, {
							expectedVer = entry.ver,
						})
						Report(status, reason)
					end)
				end
			end
		end)
	end

	if #entries == 0 and not session.draft then
		placeRow(24, function(row)
			local fs = AcquireFontString(row, "OVERLAY", "GameFontHighlight")
			fs:ClearAllPoints()
			fs:SetPoint("LEFT", row, "LEFT", 4, 0)
			fs:SetText(Loc("RAID_SIGNUP_EMPTY", "No signups in this plan yet."))
			fs:SetTextColor(1, 1, 1)
		end)
	end

	-- Restore in-progress typing if the same logical field was focused.
	if focusedText and typingFocus and typingFocus.SetText then
		typingFocus:SetText(focusedText)
		if focusedCursor and typingFocus.SetCursorPosition then
			typingFocus:SetCursorPosition(focusedCursor)
		end
	end

	host.__sfEntriesContentH = math.max(24, -y + 4)
	host:SetHeight(host.__sfEntriesContentH)
	if LayoutBoard then
		LayoutBoard(host.__sfRaidSignupPanel)
	end
end

local BOARD_ROLE_ORDER = { "tank", "healer", "ranged", "melee" }

local function BoardWidth(host)
	local w = host and host.GetWidth and host:GetWidth() or 0
	if not w or w < BOARD_MIN_WIDTH then
		w = 720
	end
	return w
end

local function ColumnWidths(host)
	local w = BoardWidth(host)
	local leftW = math.floor(w * BOARD_LEFT_RATIO)
	local rightW = w - leftW - BOARD_COL_GAP
	return leftW, rightW
end

-- Position chrome and both columns for the current width, then size the row
-- so the page scroll includes the taller column.
LayoutBoard = function(panel)
	local host = panel and panel.__sfRaidSignupBoardHost
	if not host then
		return
	end
	local leftW, rightW = ColumnWidths(host)
	local entriesHost = panel.__sfRaidSignupEntriesHost
	local summaryHost = panel.__sfRaidSignupSummaryHost
	local entriesH = math.max(24, (entriesHost and entriesHost.__sfEntriesContentH) or 24)
	local summaryH = math.max(24, (summaryHost and summaryHost.__sfSummaryContentH) or 24)
	local bodyH = math.max(entriesH, summaryH)

	if panel.__sfRaidSignupSummaryTitle and panel.__sfRaidSignupSummaryTitle.SetPoint then
		panel.__sfRaidSignupSummaryTitle:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -2)
	end
	if panel.__sfRaidSignupLeftLine then
		panel.__sfRaidSignupLeftLine:ClearAllPoints()
		panel.__sfRaidSignupLeftLine:SetPoint("BOTTOMLEFT", host, "TOPLEFT", 0, -20)
		panel.__sfRaidSignupLeftLine:SetPoint("BOTTOMRIGHT", host, "TOPLEFT", leftW, -20)
	end
	if panel.__sfRaidSignupRightLine then
		panel.__sfRaidSignupRightLine:ClearAllPoints()
		panel.__sfRaidSignupRightLine:SetPoint("BOTTOMLEFT", host, "TOPLEFT", leftW + BOARD_COL_GAP, -20)
		panel.__sfRaidSignupRightLine:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", 0, -20)
	end
	local plus = panel.__sfRaidSignupAddBtn
	if plus and plus.SetPoint then
		plus:ClearAllPoints()
		plus:SetPoint("TOPRIGHT", host, "TOPLEFT", leftW - 2, -4)
	end
	if panel.__sfRaidSignupNickHeader then
		panel.__sfRaidSignupNickHeader:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -42)
	end
	if panel.__sfRaidSignupSpecHeader then
		panel.__sfRaidSignupSpecHeader:SetPoint("TOPLEFT", host, "TOPLEFT", 176, -42)
	end
	if entriesHost then
		entriesHost:ClearAllPoints()
		entriesHost:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -BOARD_TOP_H)
		entriesHost:SetSize(leftW, entriesH)
	end
	if summaryHost then
		summaryHost:ClearAllPoints()
		summaryHost:SetPoint("TOPLEFT", host, "TOPLEFT", leftW + BOARD_COL_GAP, -BOARD_TOP_H)
		summaryHost:SetSize(rightW, summaryH)
	end
	local vdiv = panel.__sfRaidSignupVDivider
	if vdiv then
		vdiv:ClearAllPoints()
		vdiv:SetPoint("TOPLEFT", host, "TOPLEFT", leftW + math.floor(BOARD_COL_GAP / 2), -20)
		vdiv:SetPoint("BOTTOMLEFT", host, "TOPLEFT", leftW + math.floor(BOARD_COL_GAP / 2), -(BOARD_TOP_H + bodyH))
	end
	local status = panel.__sfRaidSignupStatusFs
	if status then
		status:ClearAllPoints()
		status:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -(BOARD_TOP_H + entriesH + 4))
		if status.SetWidth then
			status:SetWidth(leftW)
		end
	end

	local total = BOARD_TOP_H + bodyH + BOARD_STATUS_H + 6
	host:SetHeight(total)
	local row = panel.__sfRaidSignupBoardRow
	if row then
		row.__sfBaseHeight = total
		row:SetHeight(total)
	end
	local section = panel.__sfRaidSignupBoardSection
	if section and section.ReflowRows then
		section:ReflowRows()
	end
	if section and section._NotifyPageReflow then
		section:_NotifyPageReflow()
	elseif panel.__sfPageBuilder and panel.__sfPageBuilder.Reflow then
		panel.__sfPageBuilder:Reflow()
	end
end

PaintRoleTotals = function(panel)
	local role = panel and panel.__sfRaidSignupRole
	if not role then
		return
	end
	local rs = RS()
	local entries = rs and rs.GetSortedEntries and rs:GetSortedEntries(CurrentSelectedId()) or {}
	local totals = nil
	if rs and rs.BuildRoleTotals then
		totals = rs.BuildRoleTotals(entries)
	end
	totals = totals or { tank = 0, healer = 0, ranged = 0, melee = 0 }
	for _, key in ipairs(BOARD_ROLE_ORDER) do
		local slot = role[key]
		if slot and slot.count and slot.count.SetText then
			slot.count:SetText(tostring(totals[key] or 0))
		end
	end
end

local function BoardTooltipEnter(self)
	if self.tooltipTitle or self.tooltipText then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self.tooltipTitle then
			GameTooltip:SetText(self.tooltipTitle, 1, 1, 1)
		end
		if self.tooltipText then
			GameTooltip:AddLine(self.tooltipText, 0.9, 0.9, 0.9, true)
		end
		GameTooltip:Show()
	end
end

local function BuildBoardChrome(panel, host)
	local signupsTitle = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	signupsTitle:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -2)
	signupsTitle:SetText(Loc("RAID_SIGNUP_SECTION_ENTRIES", "Signups"))
	panel.__sfRaidSignupSignupsTitle = signupsTitle

	local summaryTitle = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	summaryTitle:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -2)
	summaryTitle:SetText(Loc("RAID_SIGNUP_SECTION_SUMMARY", "Summary"))
	panel.__sfRaidSignupSummaryTitle = summaryTitle

	local function headingLine()
		local line = TrackRegionCreate(host:CreateTexture(nil, "ARTWORK"))
		line:SetHeight(1)
		line:SetColorTexture(1, 1, 1, 0.28)
		if line.SetWidth then
			line:SetWidth(1)
		end
		return line
	end
	panel.__sfRaidSignupLeftLine = headingLine()
	panel.__sfRaidSignupRightLine = headingLine()
	local vdiv = TrackRegionCreate(host:CreateTexture(nil, "ARTWORK"))
	vdiv:SetColorTexture(1, 1, 1, 0.14)
	if vdiv.SetWidth then
		vdiv:SetWidth(1)
	end
	panel.__sfRaidSignupVDivider = vdiv

	-- Role totals: white labels, yellow counts, one line.
	local roleDefs = {
		{ key = "tank", label = Loc("RAID_SIGNUP_ROLE_TANKS", "Tanks") },
		{ key = "healer", label = Loc("RAID_SIGNUP_ROLE_HEALERS", "Healers") },
		{ key = "ranged", label = Loc("RAID_SIGNUP_ROLE_RANGED", "Ranged DPS") },
		{ key = "melee", label = Loc("RAID_SIGNUP_ROLE_MELEE", "Melee DPS") },
	}
	panel.__sfRaidSignupRole = {}
	local anchor = nil
	for i, def in ipairs(roleDefs) do
		if i > 1 then
			local sep = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
			if anchor then
				sep:SetPoint("LEFT", anchor, "RIGHT", 12, 0)
			end
			sep:SetText("·")
			sep:SetTextColor(0.6, 0.6, 0.6)
			anchor = sep
		end
		local label = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
		if anchor then
			label:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
		else
			label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -26)
		end
		label:SetText(def.label .. ":")
		label:SetTextColor(1, 1, 1)
		local count = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
		count:SetPoint("LEFT", label, "RIGHT", 4, 0)
		count:SetText("0")
		count:SetTextColor(1, 0.82, 0.18)
		panel.__sfRaidSignupRole[def.key] = { label = label, count = count }
		anchor = count
	end

	-- Column headers above the signup rows.
	local nickHeader = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	nickHeader:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -42)
	nickHeader:SetText(Loc("RAID_SIGNUP_COL_NICKNAME", "Nickname"))
	nickHeader:SetTextColor(0.8, 0.8, 0.8)
	panel.__sfRaidSignupNickHeader = nickHeader
	local specHeader = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	specHeader:SetPoint("TOPLEFT", host, "TOPLEFT", 176, -42)
	specHeader:SetText(Loc("RAID_SIGNUP_LABEL_CLASS_SPEC", "Class / Spec"))
	specHeader:SetTextColor(0.8, 0.8, 0.8)
	panel.__sfRaidSignupSpecHeader = specHeader

	-- Dynamic columns and status line.
	local entriesHost = TrackCreate(CreateFrame("Frame", nil, host))
	entriesHost.__sfRaidSignupPanel = panel
	entriesHost.__sfEntriesContentH = 24
	panel.__sfRaidSignupEntriesHost = entriesHost
	local summaryHost = TrackCreate(CreateFrame("Frame", nil, host))
	summaryHost.__sfRaidSignupPanel = panel
	summaryHost.__sfSummaryContentH = 24
	panel.__sfRaidSignupSummaryHost = summaryHost

	local statusFs = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	statusFs:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -BOARD_TOP_H)
	statusFs:SetText("")
	statusFs:SetTextColor(1, 1, 1)
	panel.__sfRaidSignupStatusFs = statusFs

	-- Small square "+" button at the right end of the Signups heading.
	local plus = TrackCreate(CreateFrame("Button", nil, host, "UIPanelButtonTemplate"))
	plus:SetSize(24, 24)
	local plusText = TrackRegionCreate(plus:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	plusText:SetPoint("CENTER", plus, "CENTER", 0, -1)
	plusText:SetText("+")
	plusText:SetTextColor(1, 0.82, 0.18)
	plus.tooltipTitle = Loc("RAID_SIGNUP_ADD_ROW", "Add signup")
	plus:SetScript("OnEnter", BoardTooltipEnter)
	plus:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	plus:SetScript("OnClick", function()
		local mod = RS()
		local selectedId = CurrentSelectedId()
		if not mod or not selectedId then
			return
		end
		if not (Caps().canCreateEntry and CurrentPlanOpen() and session.draft == nil) then
			return
		end
		session.editing = nil
		session.altDraft = nil
		session.draft = mod.MakeDraft(selectedId)
		QueueRefresh({ force = true })
	end)
	panel.__sfRaidSignupAddBtn = plus

	host:SetScript("OnSizeChanged", function(self)
		local w = self.GetWidth and self:GetWidth() or 0
		local last = panel.__sfRaidSignupBoardLastW or 0
		if math.abs(w - last) > 4 then
			panel.__sfRaidSignupBoardLastW = w
			QueueRefresh({ force = true })
		end
	end)
end

local function PaintBoardChrome(panel)
	local plus = panel and panel.__sfRaidSignupAddBtn
	if plus then
		local ok = Caps().canCreateEntry and CurrentPlanOpen() and session.draft == nil
		if ok then
			if plus.Enable then plus:Enable() end
		else
			if plus.Disable then plus:Disable() end
		end
	end
	PaintRoleTotals(panel)
end

EnsureBoardHost = function(section)
	local panel = buildPanel or Page.panel
	if not panel then
		return
	end
	if panel.__sfRaidSignupBoardHost then
		return
	end
	panel.__sfRaidSignupBoardSection = section
	local row = section:AddRow(BOARD_TOP_H + BOARD_STATUS_H + 48, function(rowFrame)
		local host = TrackCreate(CreateFrame("Frame", nil, rowFrame))
		host:SetAllPoints()
		host.__sfRaidSignupPanel = panel
		panel.__sfRaidSignupBoardHost = host
		BuildBoardChrome(panel, host)
		PaintBoardChrome(panel)
		PaintEntries(panel.__sfRaidSignupEntriesHost, CurrentSelectedId(), CurrentPlanOpen(), Caps())
		PaintSummary(panel.__sfRaidSignupSummaryHost, CurrentSelectedId())
		PaintRoleTotals(panel)
		LayoutBoard(panel)
	end)
	panel.__sfRaidSignupBoardRow = row
	LayoutBoard(panel)
end

local function PaintOwnedBoards(panel)
	-- A paint failure must not take down the whole refresh; log and continue.
	local ok, err = pcall(function()
		PaintBoardChrome(panel)
		if panel.__sfRaidSignupEntriesHost then
			PaintEntries(panel.__sfRaidSignupEntriesHost, CurrentSelectedId(), CurrentPlanOpen(), Caps())
		end
		if panel.__sfRaidSignupSummaryHost then
			PaintSummary(panel.__sfRaidSignupSummaryHost, CurrentSelectedId())
		end
		PaintRoleTotals(panel)
		LayoutBoard(panel)
	end)
	if not ok then
		local detail = tostring(err)
		if SF.Debug and SF.Debug.Warn then
			SF.Debug:Warn("RAID_SIGNUP_UI", "board paint failed: %s", detail)
		end
		SetStatus(Loc("RAID_SIGNUP_UI_ERROR", "Raid Signup UI error") .. ": " .. detail, "error")
	end
end

local function WipePageBuilder(panel)
	local pb = panel and panel.__sfPageBuilder
	if pb and pb.scrollFrame then
		pb.scrollFrame:Hide()
		pb.scrollFrame:SetParent(nil)
	end
	if panel then
		panel.__sfPageBuilder = nil
		panel.__sfRaidSignupBoardHost = nil
		panel.__sfRaidSignupBoardRow = nil
		panel.__sfRaidSignupBoardSection = nil
		panel.__sfRaidSignupEntriesHost = nil
		panel.__sfRaidSignupSummaryHost = nil
		panel.__sfRaidSignupStatusFs = nil
		panel.__sfRaidSignupRole = nil
		panel.__sfRaidSignupAddBtn = nil
		panel.__sfRaidSignupSignupsTitle = nil
		panel.__sfRaidSignupSummaryTitle = nil
		panel.__sfRaidSignupLeftLine = nil
		panel.__sfRaidSignupRightLine = nil
		panel.__sfRaidSignupVDivider = nil
		panel.__sfRaidSignupNickHeader = nil
		panel.__sfRaidSignupSpecHeader = nil
		panel.__sfRaidSignupSections = nil
		panel.__sfRaidSignupMessages = nil
	end
end

local function BuildWithPageBuilder(panel, opts)
	opts = opts or {}
	if not (SF.SettingsUI and SF.SettingsUI.CreatePage) then
		return false
	end
	buildPanel = panel

	-- Soft refresh: keep the page builder and durable board hosts; repaint boards.
	if panel.__sfPageBuilder and not opts.forceRebuild then
		if panel.__sfPageBuilder.Refresh then
			panel.__sfPageBuilder:Refresh()
		end
		PaintOwnedBoards(panel)
		SyncChrome(panel)
		buildPanel = nil
		return true
	end

	WipePageBuilder(panel)
	session.fullRebuildCount = session.fullRebuildCount + 1
	local pageBuilder = SF.SettingsUI:CreatePage(panel)
	panel.__sfPageBuilder = pageBuilder
	local controls = SF.SettingsUI.Controls
	local def = Definition()
	panel.__sfRaidSignupSections = {}
	for _, secDef in ipairs(def.sections or {}) do
		local section = pageBuilder:AddSection({
			title = secDef.title or secDef.id,
			headerless = secDef.headerless == true,
		})
		section.__sfRaidSignupView = secDef.view or VIEW_SIGNUP
		panel.__sfRaidSignupSections[secDef.id] = section
		for itemIndex, item in ipairs(secDef.items or {}) do
			-- One failing item must not blank the rest of the page; log and continue.
			local ok, err = pcall(function()
				if item.type == "custom" and item.build then
					item.build(section)
				elseif controls and item.type == "display" then
					controls:AddDisplay(section, item)
				elseif controls and item.type == "button" then
					controls:AddButton(section, item)
				elseif controls and item.type == "dropdown" then
					controls:AddDropdown(section, item)
				elseif controls and item.type == "editbox_button" then
					controls:AddEditBoxWithButton(section, item)
				end
			end)
			if not ok then
				local detail = tostring(err)
				if SF.Debug and SF.Debug.Warn then
					SF.Debug:Warn("RAID_SIGNUP_UI", "section %s item %d (%s) failed: %s",
						tostring(secDef.id), itemIndex, tostring(item.type), detail)
				end
				-- Surface build failures in the section message row so they are
				-- diagnosable without enabling debug logging.
				SetStatus(Loc("RAID_SIGNUP_UI_ERROR", "Raid Signup UI error") .. ": " .. detail, "error")
			end
		end
	end
	pageBuilder:Finalize()
	SyncChrome(panel)
	buildPanel = nil
	return true
end

function Page:Build(panel)
	EnsureUIListener()
	session.openCount = session.openCount + 1
	self.panel = panel
	Page._builtPanels = Page._builtPanels or {}
	Page._builtPanels[panel] = true
	BuildWithPageBuilder(panel, { forceRebuild = true })
	if panel.HookScript and not panel.__sfRaidSignupHook then
		panel.__sfRaidSignupHook = true
		panel:HookScript("OnShow", function()
			QueueRefresh({ force = true })
		end)
		panel:HookScript("OnHide", function()
			Page:OnHide()
		end)
	end
end

function Page:Refresh(panel, opts)
	opts = opts or {}
	panel = panel or self.panel
	if not panel or not panel.IsShown or not panel:IsShown() then
		return
	end
	if not opts.force and not opts.forceRebuild and HasTypingFocus() then
		deferredRefresh = true
		return
	end
	session.refreshCount = session.refreshCount + 1
	BuildWithPageBuilder(panel, opts)
end

function Page:OnHide()
	refreshQueued = false
	deferredRefresh = false
	typingFocus = nil
	DiscardEphemeral()
end

-- Test/perf counters
function Page._GetLifecycleCounters()
	return {
		openCount = session.openCount,
		refreshCount = session.refreshCount,
		fullRebuildCount = session.fullRebuildCount,
		listenerCount = session.listenerCount,
		frameCreateCount = session.frameCreateCount,
		frameReuseCount = session.frameReuseCount or 0,
		regionCreateCount = session.regionCreateCount or 0,
		regionReuseCount = session.regionReuseCount or 0,
		boardPaintCount = session.boardPaintCount,
		iconButtonPool = #iconButtonPool,
		textButtonPool = #textButtonPool,
		framePool = #framePool,
		editPool = #editPool,
		fontStringPool = #fontStringPool,
		hasDraft = session.draft ~= nil,
		draftNicknameCommitted = session.draft and session.draft.nicknameCommitted or false,
	}
end

function Page._ResetSessionForTests()
	DiscardEphemeral()
	session.status = nil
	session.statusKind = nil
	session.view = VIEW_SIGNUP
	session.newPlanName = ""
	session.renamePlanName = ""
	session.frameCreateCount = 0
	session.frameReuseCount = 0
	session.regionCreateCount = 0
	session.regionReuseCount = 0
	session.boardPaintCount = 0
	session.refreshCount = 0
	session.fullRebuildCount = 0
end

function Page._GetDefinitionSnapshotForTests()
	return {
		selectedId = CurrentSelectedId(),
		planOpen = CurrentPlanOpen(),
		canCreateEntry = Caps().canCreateEntry,
		canManagePlans = Caps().canManagePlans,
		planOptions = CurrentPlanOptions(),
		renameEnabled = Caps().canManagePlans
			and CurrentSelectedPlan() ~= nil
			and not (CurrentSelectedPlan() and CurrentSelectedPlan().archived),
		view = session.view,
	}
end

function Page._GetViewForTests()
	return session.view
end

function Page._SetViewForTests(view)
	session.view = view
end

function Page._GetSectionVisibilityForTests(panel)
	panel = panel or Page.panel
	local out = {}
	local sections = panel and panel.__sfRaidSignupSections
	if sections then
		for id, section in pairs(sections) do
			if section.IsShown then
				out[id] = section:IsShown() and true or false
			elseif section._shown ~= nil then
				out[id] = section._shown and true or false
			end
		end
	end
	return out
end

function Page._GetTabBarForTests(panel)
	panel = panel or Page.panel
	return panel and panel.__sfRaidSignupTabBar or nil
end

function Page._GetDraftForTests()
	return session.draft
end

function Page._SetDraftForTests(draft)
	session.draft = draft
end

function Page._SubmitCreatePlanForTests(text)
	SubmitCreatePlan(text)
end

function Page._GetEditingForTests()
	return session.editing
end

function Page._SetEditingForTests(editing)
	session.editing = editing
end

function Page._GetAltDraftForTests()
	return session.altDraft
end

function Page._SetAltDraftForTests(altDraft)
	session.altDraft = altDraft
end

function Page._RefreshShownPanelsForTests(opts)
	local n = 0
	EachShownBuiltPanel(function(builtPanel)
		n = n + 1
		Page:Refresh(builtPanel, opts or {})
	end)
	return n
end

function Page._GetRenamePlanNameForTests()
	return session.renamePlanName
end

function Page._SetRenamePlanNameForTests(name)
	session.renamePlanName = name
end

function Page._FindEditBoxesForTests(root, field)
	local found = {}
	local function walk(frame)
		if not frame then
			return
		end
		if frame.GetObjectType and frame:GetObjectType() == "EditBox" then
			if not field or frame.__sfRaidSignupField == field then
				found[#found + 1] = frame
			end
		end
		local kids = { frame:GetChildren() }
		for i = 1, #kids do
			walk(kids[i])
		end
	end
	walk(root)
	return found
end

function Page._FindSpecButtonsForTests(root, slot)
	local found = {}
	local function walk(frame)
		if not frame then
			return
		end
		if frame.GetObjectType and frame:GetObjectType() == "Button"
			and frame.__sfRaidSignupSpecSlot then
			if not slot or frame.__sfRaidSignupSpecSlot == slot then
				found[#found + 1] = frame
			end
		end
		local kids = { frame:GetChildren() }
		for i = 1, #kids do
			walk(kids[i])
		end
	end
	walk(root)
	return found
end

EnsureUIListener()
SF.SettingsUI:RegisterPage(Page)
Page._Page = Page
SF.RaidSignupUIPage = Page
