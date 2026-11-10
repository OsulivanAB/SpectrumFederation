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
local uiHooked = false
local officerHooked = false
local typingFocus = nil

local ICON = 22
local ICON_GAP = 4

local function TrackCreate(frame)
	session.frameCreateCount = session.frameCreateCount + 1
	return frame
end

local function TrackRegionCreate(region)
	session.regionCreateCount = (session.regionCreateCount or 0) + 1
	return region
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
			if Page.panel and Page.panel:IsShown() and Page.Refresh then
				Page:Refresh(Page.panel, { force = true })
			end
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
			if Page.panel and Page.panel:IsShown() and Page.Refresh then
				Page:Refresh(Page.panel, opts)
			end
		end)
	else
		refreshQueued = false
		if Page.panel and Page.Refresh then
			Page:Refresh(Page.panel, opts)
		end
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
	local function place(btn)
		btn:SetParent(host)
		btn:ClearAllPoints()
		btn:SetPoint("LEFT", host, "LEFT", x, 0)
		btn:Show()
		x = x + ICON + ICON_GAP
	end

	local phase = draft.phase or "class"
	if phase == "class" or (not draft.classFile) then
		local order = ClassOrder()
		for i = 1, #order do
			local classFile = order[i]
			local btn = MakeIconButton(host, ICON)
			SetIconVisual(btn, TextureForClass(classFile), true, false)
			btn.tooltipTitle = classFile
			btn:SetScript("OnClick", function()
				if opts.onClass then
					opts.onClass(classFile)
				end
			end)
			place(btn)
		end
	else
		local selected = MakeIconButton(host, ICON)
		if draft.specId then
			SetIconVisual(selected, TextureForSpec(draft.specId), true, false)
			selected.tooltipTitle = SpecName(draft.specId)
		else
			SetIconVisual(selected, TextureForClass(draft.classFile), true, false)
			selected.tooltipTitle = draft.classFile
		end
		place(selected)

		if not draft.specId then
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

local function Definition()
	return {
		id = "raidSignupBoard",
		selectedId = CurrentSelectedId(),
		planOpen = CurrentPlanOpen(),
		caps = Caps(),
		sections = {
			{
				id = "raidSignupStatus",
				title = Loc("RAID_SIGNUP_SECTION_STATUS", "Status"),
				items = {
					{
						type = "display",
						label = Loc("RAID_SIGNUP_STATUS_LABEL", "Access"),
						get = function()
							if session.status then
								return session.status
							end
							local caps = Caps()
							if not caps.canRead then
								return Loc("RAID_SIGNUP_STATUS_NEED_GUILD",
									"Join a guild to view shared Raid Signup plans.")
							end
							if caps.canManagePlans then
								return Loc("RAID_SIGNUP_STATUS_OFFICER",
									"You can manage plans and edit any signup entry.")
							end
							return Loc("RAID_SIGNUP_STATUS_MEMBER",
								"You can add entries and edit ones you created. Officers manage plans.")
						end,
					},
				},
			},
			{
				id = "raidSignupPlans",
				title = Loc("RAID_SIGNUP_SECTION_PLANS", "Roster plans"),
				items = {
					{
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
					},
					{
						type = "editbox_button",
						label = Loc("RAID_SIGNUP_PLAN_CREATE", "Create plan"),
						buttonText = Loc("RAID_SIGNUP_PLAN_CREATE_BTN", "Create"),
						hint = Loc("RAID_SIGNUP_PLAN_NAME_HINT", "Plan name"),
						get = function()
							return session.newPlanName
						end,
						onSubmit = function(text)
							session.newPlanName = text or ""
							local mod = RS()
							if not mod then
								return
							end
							local status, reason, planId = mod:CreatePlan(text)
							Report(status, reason)
							if status == "accepted" and planId then
								session.newPlanName = ""
								mod:SelectPlan(planId)
							end
						end,
						enabled = function()
							return Caps().canManagePlans
						end,
					},
					{
						type = "editbox_button",
						label = Loc("RAID_SIGNUP_PLAN_RENAME", "Rename plan"),
						buttonText = Loc("RAID_SIGNUP_PLAN_RENAME_BTN", "Rename"),
						hint = Loc("RAID_SIGNUP_PLAN_NAME_HINT", "Plan name"),
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
				id = "raidSignupSummary",
				title = Loc("RAID_SIGNUP_SECTION_SUMMARY", "Summary"),
				items = {
					{
						type = "custom",
						build = function(section)
							EnsureSummaryHost(section)
						end,
					},
				},
			},
			{
				id = "raidSignupEntries",
				title = Loc("RAID_SIGNUP_SECTION_ENTRIES", "Signups"),
				items = {
					{
						type = "button",
						label = Loc("RAID_SIGNUP_ADD_ROW", "Add signup"),
						buttonText = Loc("RAID_SIGNUP_ADD_ROW_BTN", "Add Row"),
						enabled = function()
							return Caps().canCreateEntry and CurrentPlanOpen() and session.draft == nil
						end,
						onClick = function()
							local mod = RS()
							local selectedId = CurrentSelectedId()
							if not mod or not selectedId then
								return
							end
							session.editing = nil
							session.altDraft = nil
							session.draft = mod.MakeDraft(selectedId)
							QueueRefresh({ force = true })
						end,
					},
					{
						type = "custom",
						build = function(section)
							EnsureEntriesHost(section)
						end,
					},
				},
			},
		},
	}
end

function PaintSummary(host, planId)
	session.boardPaintCount = session.boardPaintCount + 1
	local rs = RS()
	local summary = rs and rs.GetPlanSummary and rs:GetPlanSummary(planId) or {
		classCounts = {}, major = {}, utility = {},
	}
	local height = math.max(13 * (ICON + 2), (#(rs and rs.MAJOR_CATEGORIES or {}) + 1) * 18)
	host:SetHeight(height + 8)

	-- Build once, then update counts / coverage greys in place so CreateFrame plateaus.
	if not host.__sfSummaryBuilt then
		ReleaseHostChildren(host)
		local classCol = AcquireFrame(host)
		classCol:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -2)
		classCol:SetSize(120, height)
		host.__sfClassCol = classCol
		host.__sfClassCounts = {}
		local order = ClassOrder()
		for i = 1, #order do
			local classFile = order[i]
			local y = -(i - 1) * (ICON + 2)
			local icon = TrackRegionCreate(classCol:CreateTexture(nil, "ARTWORK"))
			icon:SetSize(ICON, ICON)
			icon:SetPoint("TOPLEFT", classCol, "TOPLEFT", 0, y)
			icon:SetTexture(TextureForClass(classFile))
			local count = TrackRegionCreate(classCol:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
			count:SetPoint("LEFT", icon, "RIGHT", 6, 0)
			host.__sfClassCounts[classFile] = count
		end

		local function paintGroup(title, categories, coveredMap, anchor)
			local label = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
			label:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 24, 0)
			label:SetText(title)
			local wrap = AcquireFrame(host)
			wrap:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
			wrap:SetSize(280, height)
			local x, y, colW = 0, 0, ICON + 2
			local perCol = 8
			local buttons = {}
			for i = 1, #categories do
				local cat = categories[i]
				local btn = MakeIconButton(wrap, ICON)
				btn:SetPoint("TOPLEFT", wrap, "TOPLEFT", x, -y)
				SetIconVisual(btn, TextureForCategory(cat), true, not (coveredMap and coveredMap[cat.id]))
				btn.tooltipTitle = Loc(cat.nameKey, cat.nameDefault)
				btn.tooltipText = Loc(cat.tipKey, cat.tipDefault)
				buttons[cat.id] = btn
				if (i % perCol) == 0 then
					x = x + colW + 8
					y = 0
				else
					y = y + ICON + 2
				end
			end
			return label, buttons
		end

		local majorTitle, majorButtons = paintGroup(
			Loc("RAID_SIGNUP_MAJOR_GROUP", "Major Buffs/Debuffs"),
			(rs and rs.MAJOR_CATEGORIES) or {},
			summary.major,
			classCol
		)
		local _, utilityButtons = paintGroup(
			Loc("RAID_SIGNUP_UTILITY_GROUP", "Utility"),
			(rs and rs.UTILITY_CATEGORIES) or {},
			summary.utility,
			majorTitle
		)
		host.__sfMajorButtons = majorButtons
		host.__sfUtilityButtons = utilityButtons
		host.__sfSummaryBuilt = true
	end

	local order = ClassOrder()
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

local function SyncEntriesRowHeight(host, height)
	local panel = Page.panel
	local row = panel and panel.__sfRaidSignupEntriesRow
	if row then
		row.__sfBaseHeight = height
		row:SetHeight(height)
	end
	host:SetHeight(height)
	local section = panel and panel.__sfRaidSignupEntriesSection
	if section and section.ReflowRows then
		section:ReflowRows()
	end
	if section and section._NotifyPageReflow then
		section:_NotifyPageReflow()
	elseif panel and panel.__sfPageBuilder and panel.__sfPageBuilder.Reflow then
		panel.__sfPageBuilder:Reflow()
	end
end

function PaintEntries(host, planId, planOpen, caps)
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
		y = y - height - 4
	end

	if session.draft and planOpen then
		placeRow(56, function(row)
			local nick = AcquireEditBox(row)
			nick.__sfRaidSignupField = "nickname"
			nick:SetSize(140, 22)
			nick:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
			nick:SetMaxLetters(RS().MAX_NICKNAME or 48)
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

			local anchor = nick
			if session.draft.specId then
				local mainBtn = MakeIconButton(row, ICON)
				mainBtn:SetPoint("LEFT", nick, "RIGHT", 8, 0)
				SetIconVisual(mainBtn, TextureForSpec(session.draft.specId), true, false)
				mainBtn.tooltipTitle = SpecName(session.draft.specId)
				anchor = mainBtn
			end

			local notes = AcquireEditBox(row)
			notes.__sfRaidSignupField = "notes"
			notes:SetSize(160, 22)
			notes:SetPoint("LEFT", anchor, "RIGHT", 12, 0)
			notes:SetMaxLetters(RS().MAX_NOTES or 160)
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

			local picker = AcquireFrame(row)
			picker:SetPoint("TOPLEFT", nick, "BOTTOMLEFT", 0, -4)
			picker:SetSize(500, ICON + 2)
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
			})
		end)
	end

	for i = 1, #entries do
		local entry = entries[i]
		local editingThis = session.editing and session.editing.entryId == entry.entryId
		local altThis = session.altDraft and session.altDraft.entryId == entry.entryId
		local rowH = (editingThis or altThis) and 78 or 34
		placeRow(rowH, function(row)
			local canEdit = planOpen and RS().CanEditEntry(caps, caps.actorGuid, entry)
			local nickBox = AcquireEditBox(row)
			nickBox.__sfRaidSignupField = "nickname"
			nickBox:SetSize(120, 20)
			nickBox:SetPoint("LEFT", row, "LEFT", 4, editingThis and 12 or 0)
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

			local mainBtn = MakeIconButton(row, ICON)
			mainBtn:SetPoint("LEFT", nickBox, "RIGHT", 8, 0)
			SetIconVisual(mainBtn, TextureForSpec(entry.mainSpec), planOpen, false)
			mainBtn.tooltipTitle = SpecName(entry.mainSpec)
			mainBtn.tooltipText = (entry.mainClass or "") .. " · " .. SpecName(entry.mainSpec)
			mainBtn:SetScript("OnClick", function()
				if not planOpen then
					return
				end
				if not RS().CanEditEntry(caps, caps.actorGuid, entry) then
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
			if entry.altClass and entry.altSpec and not (editingThis and session.editing.slot == "alt") then
				local altBtn = MakeIconButton(row, ICON)
				altBtn:SetPoint("LEFT", mainBtn, "RIGHT", 6, 0)
				SetIconVisual(altBtn, TextureForSpec(entry.altSpec), planOpen, false)
				altBtn.tooltipTitle = SpecName(entry.altSpec)
				altBtn.tooltipText = Loc("RAID_SIGNUP_ALT_LABEL", "Alternative")
					.. ": " .. (entry.altClass or "") .. " · " .. SpecName(entry.altSpec)
				altBtn:SetScript("OnClick", function()
					if not planOpen then
						return
					end
					if not RS().CanEditEntry(caps, caps.actorGuid, entry) then
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

			local notesBox = AcquireEditBox(row)
			notesBox:SetSize(120, 20)
			notesBox:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
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
			anchor = notesBox

			if planOpen and canEdit then
				local function AcquireTextButton()
					local btn = AcquirePooled(textButtonPool, function()
						local b = TrackCreate(CreateFrame("Button", nil, row, "UIPanelButtonTemplate"))
						b.__sfRaidSignupOwned = true
						b.__sfPoolKind = "text"
						return b
					end)
					btn.__sfRaidSignupOwned = true
					btn.__sfPoolKind = "text"
					btn:SetParent(row)
					SafeClearScript(btn, "OnClick")
					btn:Show()
					return btn
				end
				if not entry.altClass and not altThis and not editingThis then
					local addAlt = AcquireTextButton()
					addAlt:SetSize(90, 20)
					addAlt:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
					addAlt:SetText(Loc("RAID_SIGNUP_ADD_ALT", "Add an Alt?"))
					addAlt:SetScript("OnClick", function()
						session.draft = nil
						session.editing = nil
						session.altDraft = {
							entryId = entry.entryId,
							draft = RS().MakeAltDraft(entry),
						}
						QueueRefresh({ force = true })
					end)
					anchor = addAlt
				elseif entry.altClass then
					local remAlt = AcquireTextButton()
					remAlt:SetSize(90, 20)
					remAlt:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
					remAlt:SetText(Loc("RAID_SIGNUP_REMOVE_ALT", "Remove Alt"))
					remAlt:SetScript("OnClick", function()
						local status, reason = RS():RemoveAlternative(entry.entryId, {
							expectedVer = entry.ver,
						})
						Report(status, reason)
					end)
					anchor = remAlt
				end

				local del = AcquireTextButton()
				del:SetSize(70, 20)
				del:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
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
			end

			if editingThis then
				local picker = AcquireFrame(row)
				picker:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -28)
				picker:SetSize(520, ICON + 2)
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
				})
			elseif altThis then
				local picker = AcquireFrame(row)
				picker:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -28)
				picker:SetSize(520, ICON + 2)
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
				})
			end
		end)
	end

	if #entries == 0 and not session.draft then
		placeRow(24, function(row)
			local fs = AcquireFontString(row, "OVERLAY", "GameFontHighlight")
			fs:ClearAllPoints()
			fs:SetPoint("LEFT", row, "LEFT", 4, 0)
			fs:SetText(Loc("RAID_SIGNUP_EMPTY", "No signups in this plan yet."))
		end)
	end

	-- Restore in-progress typing if the same logical field was focused.
	if focusedText and typingFocus and typingFocus.SetText then
		typingFocus:SetText(focusedText)
		if focusedCursor and typingFocus.SetCursorPosition then
			typingFocus:SetCursorPosition(focusedCursor)
		end
	end

	SyncEntriesRowHeight(host, math.max(24, -y + 4))
end

function EnsureSummaryHost(section)
	local panel = Page.panel
	if not panel then
		return
	end
	if panel.__sfRaidSignupSummaryHost then
		return
	end
	local height = 13 * (ICON + 2) + 8
	section:AddRow(height, function(row)
		local host = TrackCreate(CreateFrame("Frame", nil, row))
		host:SetAllPoints()
		panel.__sfRaidSignupSummaryHost = host
		PaintSummary(host, CurrentSelectedId())
	end)
end

function EnsureEntriesHost(section)
	local panel = Page.panel
	if not panel then
		return
	end
	if panel.__sfRaidSignupEntriesHost then
		return
	end
	panel.__sfRaidSignupEntriesSection = section
	local row = section:AddRow(220, function(rowFrame)
		local host = TrackCreate(CreateFrame("Frame", nil, rowFrame))
		host:SetAllPoints()
		panel.__sfRaidSignupEntriesHost = host
		PaintEntries(host, CurrentSelectedId(), CurrentPlanOpen(), Caps())
	end)
	panel.__sfRaidSignupEntriesRow = row
end

local function PaintOwnedBoards(panel)
	if panel.__sfRaidSignupSummaryHost then
		PaintSummary(panel.__sfRaidSignupSummaryHost, CurrentSelectedId())
	end
	if panel.__sfRaidSignupEntriesHost then
		PaintEntries(panel.__sfRaidSignupEntriesHost, CurrentSelectedId(), CurrentPlanOpen(), Caps())
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
		panel.__sfRaidSignupSummaryHost = nil
		panel.__sfRaidSignupEntriesHost = nil
	end
end

local function BuildWithPageBuilder(panel, opts)
	opts = opts or {}
	if not (SF.SettingsUI and SF.SettingsUI.CreatePage) then
		return false
	end

	-- Soft refresh: keep the page builder and durable board hosts; repaint boards.
	if panel.__sfPageBuilder and not opts.forceRebuild then
		if panel.__sfPageBuilder.Refresh then
			panel.__sfPageBuilder:Refresh()
		end
		PaintOwnedBoards(panel)
		return true
	end

	WipePageBuilder(panel)
	session.fullRebuildCount = session.fullRebuildCount + 1
	local pageBuilder = SF.SettingsUI:CreatePage(panel)
	panel.__sfPageBuilder = pageBuilder
	local controls = SF.SettingsUI.Controls
	local def = Definition()
	for _, secDef in ipairs(def.sections or {}) do
		local section = pageBuilder:AddSection({ title = secDef.title or secDef.id })
		for _, item in ipairs(secDef.items or {}) do
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
		end
	end
	pageBuilder:Finalize()
	return true
end

function Page:Build(panel)
	EnsureUIListener()
	session.openCount = session.openCount + 1
	self.panel = panel
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
	}
end

function Page._GetDraftForTests()
	return session.draft
end

function Page._SetDraftForTests(draft)
	session.draft = draft
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

EnsureUIListener()
SF.SettingsUI:RegisterPage(Page)
Page._Page = Page
SF.RaidSignupUIPage = Page
