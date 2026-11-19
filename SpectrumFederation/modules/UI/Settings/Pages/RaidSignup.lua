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
local BOARD_TOP_H = 69
local BOARD_STATUS_H = 18
-- Summary content starts just beneath its own heading divider, independent of
-- the left column's role totals and table headings.
local SUMMARY_CONTENT_TOP = 30
-- Compact, bounded nickname column for collapsed signup rows. Ordinary
-- nicknames fit; the column does not keep expanding as the row widens, and
-- longer nicknames ellipsize (full value on hover).
local ENTRY_NICK_W = 76
-- Fixed columns for collapsed signup rows (Nickname | Main | Alt | Notes).
local COL_MAIN_X = 140
local COL_ALT_X = COL_MAIN_X + 36
local CLASS_COUNT_WIDTH = 24

-- Roster-planning guidance palette shared by the role totals and the tier
-- token groups. Advisory heuristics only, not Blizzard requirements.
local GUIDANCE_COLORS = {
	yellow = { 1, 0.82, 0.18 },
	orange = { 1, 0.6, 0.1 },
	red = { 1, 0.2, 0.2 },
}

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
local rowButtonPool = {}
local hoverPool = {}
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
			if self.tooltipTitle or self.tooltipText or self.tooltipLines then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				if self.tooltipTitle then
					GameTooltip:SetText(self.tooltipTitle, 1, 1, 1)
				end
				if self.tooltipText then
					GameTooltip:AddLine(self.tooltipText, 0.9, 0.9, 0.9, true)
				end
				if self.tooltipLines then
					for i = 1, #self.tooltipLines do
						GameTooltip:AddLine(self.tooltipLines[i], 0.9, 0.9, 0.9, true)
					end
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
	btn.tooltipLines = nil
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
			elseif kind == "rowbtn" then
				ReleasePooled(child, rowButtonPool, "rowbtn")
			elseif kind == "hover" then
				-- Never leave a pooled note tooltip orphaned on reuse.
				if child.__sfHoverText ~= nil then
					GameTooltip:Hide()
				end
				child.__sfHoverText = nil
				child.__sfRaidSignupHover = nil
				ReleasePooled(child, hoverPool, "hover")
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

local ENTRY_ACTION_W = 4 + 24 -- right margin + compact delete X
local ENTRY_BTN = 24 -- hit target for the Alt dash and delete row buttons
local ENTRY_CHAR_W = 7 -- fallback estimate for GameFontHighlight text

-- Rendered width of a fontstring's text (GetStringWidth when available).
local function MeasureFontWidth(fs, text)
	if fs and fs.SetText and text ~= nil then
		fs:SetText(text)
	end
	if fs and fs.GetStringWidth then
		local ok, w = pcall(function()
			return fs:GetStringWidth()
		end)
		if ok and type(w) == "number" then
			return w
		end
	end
	return #(tostring(text or "")) * ENTRY_CHAR_W
end

-- Bound displayed text by rendered width rather than a fixed character count,
-- clipping at UTF-8 boundaries like ClipDisplay.
local function ClipToWidth(fs, text, maxPx)
	text = text or ""
	if maxPx <= 0 then
		fs:SetText("")
		return ""
	end
	if MeasureFontWidth(fs, text) <= maxPx then
		return text
	end
	local chars = {}
	for ch in tostring(text):gmatch("[\1-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = ch
	end
	local n = #chars
	while n > 0 do
		local candidate = table.concat(chars, "", 1, n) .. "…"
		if MeasureFontWidth(fs, candidate) <= maxPx then
			fs:SetText(candidate)
			return candidate
		end
		n = n - 1
	end
	fs:SetText("…")
	return "…"
end

-- Shared column geometry for collapsed rows and their headings: reserve the
-- action-button group first, then allocate bounded Nickname / Main / Alt /
-- Notes space from the real row width.
local function EntryColGeom(leftW, reserveActions)
	local rightReserve = reserveActions and ENTRY_ACTION_W or 8
	local contentW = math.max(96, (tonumber(leftW) or 0) - rightReserve)
	-- Reserve room for Main + Alt + a note sliver even at narrow widths; above
	-- that the nickname column stays a fixed compact width.
	local nickW = math.min(ENTRY_NICK_W, math.max(48, contentW - 110))
	local mainX = 4 + nickW + 10
	local altX = mainX + ICON + 12
	local notesX = altX + ICON + 12
	return {
		nickW = nickW,
		mainX = mainX,
		altX = altX,
		notesX = notesX,
		rightReserve = rightReserve,
		leftW = leftW,
	}
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

-- Small glyph row button (Alt dash / delete X): pooled, tooltip-capable,
-- with the same stable OnEnter/OnLeave pattern as the spec icons.
local function AcquireRowButton(parent)
	local btn = AcquirePooled(rowButtonPool, function()
		local b = TrackCreate(CreateFrame("Button", nil, parent))
		b.__sfRaidSignupOwned = true
		b.__sfPoolKind = "rowbtn"
		local label = TrackRegionCreate(b:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
		label:SetPoint("CENTER", b, "CENTER", 0, -1)
		b.rowLabel = label
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
	btn.__sfPoolKind = "rowbtn"
	btn.tooltipTitle = nil
	btn.tooltipText = nil
	btn:SetParent(parent)
	SafeClearScript(btn, "OnClick")
	btn:Show()
	return btn
end

-- Mouse-enabled hover target over a collapsed row's note preview. FontStrings
-- cannot take frame scripts, so the full saved note is shown from this region.
local function AcquireNotesHover(parent)
	local hover = AcquirePooled(hoverPool, function()
		local f = TrackCreate(CreateFrame("Frame", nil, parent))
		f.__sfRaidSignupOwned = true
		f.__sfPoolKind = "hover"
		f:EnableMouse(true)
		f:SetScript("OnEnter", function(self)
			local text = self.__sfHoverText
			if text and text ~= "" then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(text, 0.9, 0.9, 0.9)
				GameTooltip:Show()
			end
		end)
		f:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		return f
	end)
	hover.__sfRaidSignupOwned = true
	hover.__sfPoolKind = "hover"
	hover.__sfHoverText = nil
	hover.__sfRaidSignupHover = nil
	hover:SetParent(parent)
	hover:Show()
	return hover
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

local function LayoutPicker(host, draft, opts, width)
	opts = opts or {}
	ReleaseHostChildren(host)

	-- Wrap icons within the available width instead of one fixed strip; the
	-- returned height lets callers place following fields below the real bottom.
	width = tonumber(width) or (host.GetWidth and host:GetWidth()) or 0
	if width <= 0 then
		width = 380
	end
	local pitch = ICON + ICON_GAP
	local perRow = math.max(1, math.floor((width + ICON_GAP) / pitch))
	local x = 0
	local y = 0
	local col = 0
	local function place(btn, w)
		btn:SetParent(host)
		btn:ClearAllPoints()
		local itemW = w or ICON
		if col > 0 and (col >= perRow or x + itemW > width) then
			col = 0
			x = 0
			y = y + ICON + ICON_GAP
		end
		btn:SetPoint("TOPLEFT", host, "TOPLEFT", x, -y)
		btn:Show()
		x = x + itemW + ICON_GAP
		col = col + 1
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
	local height = y + ICON + 2
	host:SetHeight(height)
	return height
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


-- Sidebar column count for the compact class/coverage grids.
local function SidebarCols(width, pitch)
	return math.max(1, math.min(5, math.floor((width + 8) / pitch)))
end

-- Tier token groups: Midnight armor-based class-set families. Presentation
-- only; counts reuse the main-only class summary. This mapping describes
-- Midnight, not past or future expansions, and measures roster competition,
-- not actual gear need or drop probability.
local TOKEN_GROUP_TEXTURES = {
	cloth = "Interface\\Icons\\INV_Chest_Cloth_21",
	leather = "Interface\\Icons\\INV_Chest_Leather_03",
	mail = "Interface\\Icons\\INV_Chest_Chain",
	plate = "Interface\\Icons\\INV_Chest_Plate01",
}
local TOKEN_GROUP_DEFAULT_NAMES = {
	cloth = "Cloth — Woven",
	leather = "Leather — Cured",
	mail = "Mail — Cast",
	plate = "Plate — Forged",
}

local function TokenGroups()
	local rs = RS()
	return (rs and rs.ARMOR_TOKEN_GROUPS) or {}
end

-- Crowding assessment for one token group. Deliberately asymmetric: low
-- representation is never penalized; only counts above the rounded even
-- share can reach orange or red. fairMax = ceil(N/4) keeps an exactly
-- balanced 14-signup roster (4/4/3/3) yellow.
local function AssessTokenCrowding(count, total)
	if total <= 0 then
		return { level = "yellow", fairMax = 0, empty = true }
	end
	local fairMax = math.ceil(total / 4)
	local wiggle = math.max(1, math.floor(total * 0.05 + 0.5))
	local level
	if count <= fairMax then
		level = "yellow"
	elseif count <= fairMax + wiggle then
		level = "orange"
	else
		level = "red"
	end
	return { level = level, fairMax = fairMax, empty = false }
end
Page._AssessTokenCrowdingForTests = AssessTokenCrowding

local function TokenTooltipLines(group, count, total)
	local lines = {}
	local names = {}
	for i = 1, #(group.classes or {}) do
		names[#names + 1] = ClassName(group.classes[i])
	end
	lines[#lines + 1] = table.concat(names, ", ")
	if total <= 0 then
		lines[#lines + 1] = Loc("RAID_SIGNUP_TOKEN_EMPTY", "No completed signups yet.")
		return lines
	end
	-- Percentage is display-only; colors come from the integer rules.
	local pct = math.floor(count * 100 / total + 0.5)
	lines[#lines + 1] = string.format(Loc("RAID_SIGNUP_TOKEN_LINE_COUNT", "%d of %d signups: %d%%"),
		count, total, pct)
	local assess = AssessTokenCrowding(count, total)
	lines[#lines + 1] = string.format(Loc("RAID_SIGNUP_TOKEN_LINE_TARGET", "Even-share target: %d"),
		assess.fairMax)
	if assess.level == "orange" then
		lines[#lines + 1] = Loc("RAID_SIGNUP_TOKEN_ASSESS_CROWDED", "Slightly crowded.")
	elseif assess.level == "red" then
		lines[#lines + 1] = Loc("RAID_SIGNUP_TOKEN_ASSESS_OVER", "Outside the usual range.")
	else
		lines[#lines + 1] = Loc("RAID_SIGNUP_TOKEN_ASSESS_OK", "Within the even-share range.")
	end
	return lines
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
	local tokenGroups = TokenGroups()

	local classPitch = ICON + 6 + CLASS_COUNT_WIDTH + 8
	local iconPitch = ICON + 8
	local cols = SidebarCols(w, classPitch)
	local iconCols = SidebarCols(w, iconPitch)
	local rowH = ICON + 4
	local classRows = math.max(1, math.ceil(#order / cols))
	local tokenRows = math.max(1, math.ceil(#tokenGroups / cols))
	local majorRows = math.max(1, math.ceil(#majorCats / iconCols))
	local utilityRows = math.max(1, math.ceil(#utilityCats / iconCols))

	-- Group geometry: heading, fixed heading-to-grid gap, then icon rows.
	-- The next heading starts a small gap below the actual bottom of the
	-- preceding grid, so wrapped rows never collide with the next heading.
	local TITLE_TO_GRID = 20
	local GROUP_GAP = 8
	local function gridBottom(titleY, rows)
		return titleY - TITLE_TO_GRID - (rows - 1) * rowH - ICON
	end
	local classTitleY = -4
	local classGridY = classTitleY - TITLE_TO_GRID
	local tokenTitleY = gridBottom(classTitleY, classRows) - GROUP_GAP
	local tokenGridY = tokenTitleY - TITLE_TO_GRID
	local majorTitleY = gridBottom(tokenTitleY, tokenRows) - GROUP_GAP
	local majorGridY = majorTitleY - TITLE_TO_GRID
	local utilityTitleY = gridBottom(majorTitleY, majorRows) - GROUP_GAP
	local utilityGridY = utilityTitleY - TITLE_TO_GRID
	local height = -gridBottom(utilityTitleY, utilityRows) + 4
	host.__sfSummaryContentH = height
	host:SetHeight(height)
	LayoutBoard(host.__sfRaidSignupPanel)

	-- Rebuild when the effective grid geometry changes (column counts drive
	-- every position and the container height), not just on large width deltas:
	-- a 2px resize can cross a grid-column threshold.
	local geomKey = cols .. ":" .. iconCols
	local builtW = host.__sfSummaryBuiltW or 0
	if not host.__sfSummaryBuilt or host.__sfSummaryBuiltKey ~= geomKey
		or math.abs(builtW - w) > 24 then
		ReleaseHostChildren(host)
		host.__sfClassCounts = nil
		host.__sfClassIcons = nil
		host.__sfTokenIcons = nil
		host.__sfTokenCounts = nil
		host.__sfMajorButtons = nil
		host.__sfUtilityButtons = nil

		local function addTitle(text, y)
			local t = AcquireFontString(host, "OVERLAY", "GameFontNormal")
			t:SetPoint("TOPLEFT", host, "TOPLEFT", 0, y)
			t:SetText(text)
			return t
		end

		addTitle(Loc("RAID_SIGNUP_SECTION_CLASSES", "Classes"), classTitleY)

		-- Row-major compact grid: icon + count, CLASS_ORDER preserved.
		for i = 1, #order do
			local classFile = order[i]
			local idx = i - 1
			local col = idx % cols
			local rowIndex = math.floor(idx / cols)
			local x = col * classPitch
			local y = classGridY - rowIndex * rowH
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

		addTitle(Loc("RAID_SIGNUP_SECTION_TIER_TOKENS", "Tier Tokens"), tokenTitleY)
		host.__sfTokenIcons = {}
		host.__sfTokenCounts = {}
		for i = 1, #tokenGroups do
			local group = tokenGroups[i]
			local idx = i - 1
			local col = idx % cols
			local rowIndex = math.floor(idx / cols)
			local icon = MakeIconButton(host, ICON)
			icon:SetPoint("TOPLEFT", host, "TOPLEFT", col * classPitch, tokenGridY - rowIndex * rowH)
			SetIconVisual(icon, TOKEN_GROUP_TEXTURES[group.id]
				or "Interface\\Icons\\INV_Misc_QuestionMark", true, false)
			host.__sfTokenIcons[group.id] = icon
			local count = AcquireFontString(host, "OVERLAY", "GameFontHighlight")
			count:SetPoint("LEFT", icon, "RIGHT", 6, 0)
			host.__sfTokenCounts[group.id] = count
		end

		local function paintGroup(title, categories, coveredMap, titleY, gridY)
			addTitle(title, titleY)
			local buttons = {}
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

		host.__sfMajorButtons = paintGroup(
			Loc("RAID_SIGNUP_MAJOR_GROUP", "Major Buffs/Debuffs"),
			majorCats, summary.major, majorTitleY, majorGridY)
		host.__sfUtilityButtons = paintGroup(
			Loc("RAID_SIGNUP_UTILITY_GROUP", "Utility"),
			utilityCats, summary.utility, utilityTitleY, utilityGridY)

		host.__sfSummaryBuilt = true
		host.__sfSummaryBuiltW = w
		host.__sfSummaryBuiltKey = geomKey
	end

	for i = 1, #order do
		local classFile = order[i]
		local count = (summary.classCounts and summary.classCounts[classFile]) or 0
		local fs = host.__sfClassCounts and host.__sfClassCounts[classFile]
		if fs then
			fs:SetText(tostring(count))
		end
		local icon = host.__sfClassIcons and host.__sfClassIcons[classFile]
		if icon then
			-- Zero-count classes take the missing-coverage grey treatment but
			-- stay enabled. Applied on every paint so zero/nonzero transitions
			-- work without rebuilding the grid.
			SetIconVisual(icon, TextureForClass(classFile), true, count <= 0)
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
	-- Tier tokens: same main-only class counts, grouped by armor family.
	-- Colors and greying repaint on every pass so transitions reset without
	-- rebuilding the grid.
	local tokenCounts = {}
	local tokenTotal = 0
	for i = 1, #tokenGroups do
		local group = tokenGroups[i]
		local c = 0
		for j = 1, #(group.classes or {}) do
			c = c + ((summary.classCounts and summary.classCounts[group.classes[j]]) or 0)
		end
		tokenCounts[group.id] = c
		tokenTotal = tokenTotal + c
	end
	for i = 1, #tokenGroups do
		local group = tokenGroups[i]
		local c = tokenCounts[group.id] or 0
		local fs = host.__sfTokenCounts and host.__sfTokenCounts[group.id]
		if fs then
			fs:SetText(tostring(c))
		end
		local icon = host.__sfTokenIcons and host.__sfTokenIcons[group.id]
		if icon then
			SetIconVisual(icon, TOKEN_GROUP_TEXTURES[group.id]
				or "Interface\\Icons\\INV_Misc_QuestionMark", true, c <= 0)
		end
		local assess = AssessTokenCrowding(c, tokenTotal)
		local color = GUIDANCE_COLORS[assess.level] or GUIDANCE_COLORS.yellow
		if fs then
			fs:SetTextColor(color[1], color[2], color[3])
		end
		if icon then
			icon.tooltipTitle = Loc("RAID_SIGNUP_TOKEN_" .. string.upper(group.id) .. "_NAME",
				TOKEN_GROUP_DEFAULT_NAMES[group.id] or group.id)
			icon.tooltipLines = TokenTooltipLines(group, c, tokenTotal)
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
	-- Column geometry shared by rows and headings, from the real board width.
	local panel = host.__sfRaidSignupPanel
	local boardHost = panel and panel.__sfRaidSignupBoardHost
	local leftW = boardHost and ColumnWidths(boardHost) or 446
	local geom = EntryColGeom(leftW, planOpen)
	if panel then
		panel.__sfEntryGeom = geom
		panel.__sfRaidSignupPlanOpen = planOpen
	end

	local function placeRow(height, builder)
		local row = AcquireFrame(host)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", host, "TOPLEFT", 0, y)
		row:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, y)
		row:SetHeight(height or 26)
		local contentH = builder(row)
		local finalH = height or 26
		if type(contentH) == "number" and contentH > 0 then
			finalH = contentH
		end
		row:SetHeight(finalH)
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
		y = y - finalH - 4
	end

	if session.draft and planOpen and session.draft.planId == planId then
		placeRow(26, function(row)
			local PAD, bandH, gap = 6, 22, 6
			local yOff = PAD
			local nameLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_NAME", "Name"))
			nameLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -yOff)
			local nick = AcquireEditBox(row)
			nick.__sfRaidSignupField = "nickname"
			nick:SetSize(170, 22)
			nick:SetPoint("TOPLEFT", nameLabel, "TOPRIGHT", 6, 0)
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

			yOff = yOff + bandH + gap
			local classLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_CLASS_SPEC", "Class / Spec"))
			classLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -yOff)
			local pickerX = 4 + MeasureFontWidth(classLabel, classLabel:GetText()) + 6
			local pickerW = math.max(120, geom.leftW - pickerX - 8)
			local picker = AcquireFrame(row)
			picker:SetPoint("TOPLEFT", classLabel, "TOPRIGHT", 6, 0)
			picker:SetSize(pickerW, ICON + 2)
			local pickerH = LayoutPicker(picker, session.draft, {
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
			}, pickerW)
			picker:SetHeight(pickerH)

			yOff = yOff + pickerH + gap
			local notesLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_NOTES", "Notes"))
			notesLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -yOff)
			local notes = AcquireEditBox(row)
			notes.__sfRaidSignupField = "notes"
			notes:SetSize(240, 22)
			notes:SetPoint("TOPLEFT", notesLabel, "TOPRIGHT", 6, 0)
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
			yOff = yOff + bandH + 4
			return yOff
		end)
	end

	for i = 1, #entries do
		local entry = entries[i]
		local editingThis = session.editing and session.editing.entryId == entry.entryId
		local altThis = session.altDraft and session.altDraft.entryId == entry.entryId
		local expanded = editingThis or altThis
		placeRow(26, function(row)
			local canEdit = planOpen and RS().CanEditEntry(caps, caps.actorGuid, entry)
			if expanded then
				-- Editing: labeled fields stacked Name / Class + Spec / Notes, anchored
				-- from the row top; the row is sized from the resulting content,
				-- including the picker's wrapped height.
				local PAD, bandH, gap = 6, 22, 6
				local yOff = PAD
				local nameLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_NAME", "Name"))
				nameLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -yOff)
				local nickBox = AcquireEditBox(row)
				nickBox.__sfRaidSignupField = "nickname"
				nickBox:SetSize(170, 20)
				nickBox:SetPoint("TOPLEFT", nameLabel, "TOPRIGHT", 6, 0)
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

				yOff = yOff + bandH + gap
				local classLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_CLASS_SPEC", "Class / Spec"))
				classLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -yOff)
				local pickerX = 4 + MeasureFontWidth(classLabel, classLabel:GetText()) + 6
				local pickerW = math.max(120, geom.leftW - pickerX - 8)
				local picker = AcquireFrame(row)
				picker:SetPoint("TOPLEFT", classLabel, "TOPRIGHT", 6, 0)
				picker:SetSize(pickerW, ICON + 2)
				local pickerH = ICON + 2
				if editingThis then
					local draft = session.editing.draft
					pickerH = LayoutPicker(picker, draft, {
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
					}, pickerW)
				else
					local draft = session.altDraft.draft
					pickerH = LayoutPicker(picker, draft, {
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
					}, pickerW)
				end
				picker:SetHeight(pickerH)

				yOff = yOff + pickerH + gap
				local notesLabel = AcquireFieldLabel(row, Loc("RAID_SIGNUP_LABEL_NOTES", "Notes"))
				notesLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -yOff)
				local notesBox = AcquireEditBox(row)
				notesBox.__sfRaidSignupField = "notes"
				notesBox:SetSize(240, 20)
				notesBox:SetPoint("TOPLEFT", notesLabel, "TOPRIGHT", 6, 0)
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
				-- Alt editor only: removing the alternative preserves the main
				-- signup and reuses the same version-checked removal operation.
				local isAltEditor = altThis
					or (editingThis and session.editing and session.editing.slot == "alt")
				if isAltEditor and entry.altClass and canEdit then
					local rmAlt = AcquireTextButton(row)
					rmAlt:SetSize(84, 20)
					rmAlt:SetPoint("RIGHT", done, "LEFT", -6, 0)
					rmAlt:SetText(Loc("RAID_SIGNUP_REMOVE_ALT", "Remove Alt"))
					rmAlt:SetScript("OnClick", function()
						local status, reason = RS():RemoveAlternative(entry.entryId, {
							expectedVer = entry.ver,
						})
						Report(status, reason)
						session.altDraft = nil
						session.editing = nil
						QueueRefresh({ force = true })
					end)
				end
				yOff = yOff + bandH + 4
				return yOff
			end

			-- Collapsed: fixed columns — Nickname, Main icon, Alt icon (or a clickable
			-- muted dash), note preview, compact delete X. Clicking an icon or the
			-- dash opens the editor for that slot. Columns come from the shared
			-- geometry so rows and headings always agree.
			local nameFs = AcquireFieldLabel(row, entry.nickname or "")
			local nickFull = entry.nickname or ""
			local nickShown = ClipToWidth(nameFs, nickFull, geom.nickW)
			nameFs:SetPoint("LEFT", row, "LEFT", 4, 0)
			nameFs:SetTextColor(ClassColor(entry.mainClass))
			if nickShown ~= nickFull and nickFull ~= "" then
				-- Truncated nickname: the full stored value is available on hover.
				local nickHover = AcquireNotesHover(row)
				nickHover.__sfRaidSignupHover = true
				nickHover.__sfHoverText = nickFull
				nickHover:ClearAllPoints()
				nickHover:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -3)
				nickHover:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 4 + geom.nickW + 2, 3)
			end
			local mainBtn = MakeIconButton(row, ICON)
			mainBtn.__sfRaidSignupSpecSlot = "main"
			mainBtn:SetPoint("LEFT", row, "LEFT", geom.mainX, 0)
			-- Enabled presentation follows canEdit (plan open + edit eligibility).
			-- Informative hover tooltips stay assigned even when the button is disabled.
			SetIconVisual(mainBtn, TextureForSpec(entry.mainSpec), canEdit, false)
			mainBtn.tooltipTitle = Loc("RAID_SIGNUP_COL_MAIN", "Main")
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
			if entry.altClass and entry.altSpec then
				local altBtn = MakeIconButton(row, ICON)
				altBtn.__sfRaidSignupSpecSlot = "alt"
				altBtn:SetPoint("LEFT", row, "LEFT", geom.altX, 0)
				SetIconVisual(altBtn, TextureForSpec(entry.altSpec), canEdit, false)
				altBtn.tooltipTitle = Loc("RAID_SIGNUP_COL_ALT", "Alt")
				altBtn.tooltipText = ClassName(entry.altClass) .. " · " .. SpecName(entry.altSpec)
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
			else
				-- No alternate: a muted, clickable dash keeps the Alt column aligned
				-- and starts the add-alt workflow; read-only users get it disabled.
				local dash = AcquireRowButton(row)
				dash:SetSize(ENTRY_BTN, ENTRY_BTN)
				dash:SetPoint("LEFT", row, "LEFT", geom.altX, 0)
				if dash.rowLabel then
					dash.rowLabel:SetText("—")
					dash.rowLabel:SetTextColor(0.5, 0.5, 0.5)
				end
				dash.tooltipTitle = Loc("RAID_SIGNUP_TIP_ADD_ALT", "Add alternative")
				if canEdit then
					dash:Enable()
				else
					dash:Disable()
				end
				dash:SetScript("OnClick", function()
					if not canEdit then
						return
					end
					session.draft = nil
					session.editing = nil
					session.altDraft = {
						entryId = entry.entryId,
						draft = RS().MakeAltDraft(entry),
					}
					QueueRefresh({ force = true })
				end)
			end
			-- The compact X is the only reserved action, so notes get the space
			-- between the Alt slot and the delete button.
			local showActions = planOpen and canEdit
			local notesReserve = showActions and ENTRY_ACTION_W or 8
			local notesText = entry.notes or ""
			if notesText ~= "" then
				-- Clip notes to the rendered space left of the delete X so long
				-- text never runs under it; the full note stays on hover.
				local notesBudget = geom.leftW - geom.notesX - notesReserve - 6
				local notesFs = AcquireFieldLabel(row, notesText)
				ClipToWidth(notesFs, notesText, math.max(24, notesBudget))
				notesFs:SetPoint("LEFT", row, "LEFT", geom.notesX, 0)
				notesFs:SetTextColor(0.6, 0.6, 0.6)
				local hover = AcquireNotesHover(row)
				hover.__sfRaidSignupHover = true
				hover.__sfHoverText = notesText
				hover:ClearAllPoints()
				hover:SetPoint("TOPLEFT", row, "TOPLEFT", geom.notesX, -3)
				hover:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -(notesReserve + 4), 3)
			end
			if showActions then
				local del = AcquireRowButton(row)
				del:SetSize(ENTRY_BTN, ENTRY_BTN)
				del:SetPoint("RIGHT", row, "RIGHT", -4, 0)
				if del.rowLabel then
					del.rowLabel:SetText("×")
					del.rowLabel:SetTextColor(1, 0.2, 0.2)
				end
				del.tooltipTitle = Loc("RAID_SIGNUP_TIP_DELETE", "Delete signup")
				del:Enable()
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

-- Position chrome and both columns for the current width, then size the row
-- so the page scroll includes the taller column.
local ROLE_TOTALS_TOP = -26
local ROLE_LINE_H = 15
local ROLE_HEADER_GAP = 8
local ROLE_HEADER_H = 20 -- header band between column headings and rows
local ROLE_ICON_SIZE = 14 -- role icons stay close to the text-line height
local ROLE_GROUP_GAP = 14 -- consistent separation between role groups

-- Position the role totals from their measured contents (icon, count, gaps),
-- wrapping whole groups onto extra lines rather than crossing the column
-- divider. Groups are compact enough to stay on one line at supported widths.
-- Returns the number of lines used.
local function LayoutRoleTotals(panel, availW)
	local role = panel and panel.__sfRaidSignupRole
	local host = panel and panel.__sfRaidSignupBoardHost
	if not role or not host then
		return 1
	end
	availW = math.max(120, (tonumber(availW) or 0) - 4)
	local items = {}
	for _, key in ipairs(BOARD_ROLE_ORDER) do
		local slot = role[key]
		if slot and slot.icon and slot.count then
			local countText = slot.count.GetText and slot.count:GetText() or "0"
			items[#items + 1] = {
				icon = slot.icon,
				count = slot.count,
				hover = slot.hover,
				w = ROLE_ICON_SIZE + 4 + MeasureFontWidth(slot.count, countText),
			}
		end
	end
	if #items == 0 then
		return 1
	end
	-- Greedy wrap: keep every icon+count group intact on one line.
	local lines = {}
	local cur, curW = nil, 0
	for _, it in ipairs(items) do
		local need = it.w + (cur and ROLE_GROUP_GAP or 0)
		if cur and curW + need > availW then
			lines[#lines + 1] = cur
			cur, curW, need = nil, 0, it.w
		end
		if not cur then
			cur = {}
		end
		cur[#cur + 1] = it
		curW = curW + need
	end
	if cur then
		lines[#lines + 1] = cur
	end
	local y = ROLE_TOTALS_TOP
	for _, line in ipairs(lines) do
		local x = 0
		for _, it in ipairs(line) do
			it.icon:ClearAllPoints()
			it.icon:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
			it.count:ClearAllPoints()
			it.count:SetPoint("TOPLEFT", host, "TOPLEFT", x + ROLE_ICON_SIZE + 4, y - 1)
			if it.hover and it.hover.SetPoint then
				it.hover:ClearAllPoints()
				it.hover:SetPoint("TOPLEFT", host, "TOPLEFT", x - 3, y + 3)
				it.hover:SetPoint("BOTTOMRIGHT", it.count, "BOTTOMRIGHT", 4, -3)
				it.hover:Show()
			end
			x = x + it.w + ROLE_GROUP_GAP
		end
		y = y - ROLE_LINE_H
	end
	return #lines
end

Page._LayoutRoleTotalsForTests = LayoutRoleTotals

LayoutBoard = function(panel)
	local host = panel and panel.__sfRaidSignupBoardHost
	if not host then
		return
	end
	local leftW, rightW = ColumnWidths(host)
	local totalsLines = LayoutRoleTotals(panel, leftW)
	local geom = panel.__sfEntryGeom
	if not geom then
		geom = EntryColGeom(leftW, panel.__sfRaidSignupPlanOpen ~= false)
	end
	local headersY = ROLE_TOTALS_TOP - totalsLines * ROLE_LINE_H - ROLE_HEADER_GAP
	local topH = -headersY + ROLE_HEADER_H
	panel.__sfRaidSignupTopH = topH
	-- The sidebar starts beneath its own divider, so its position never
	-- depends on how many lines the left column's role totals wrap to.
	panel.__sfRaidSignupSummaryTopH = SUMMARY_CONTENT_TOP
	local entriesHost = panel.__sfRaidSignupEntriesHost
	local summaryHost = panel.__sfRaidSignupSummaryHost
	local entriesH = math.max(24, (entriesHost and entriesHost.__sfEntriesContentH) or 24)
	local summaryH = math.max(24, (summaryHost and summaryHost.__sfSummaryContentH) or 24)
	-- Each column's bottom is measured from its own starting offset; the board
	-- height, scroll extent, and divider bottom follow the taller one.
	local leftBottom = topH + entriesH
	local bodyBottom = math.max(leftBottom, SUMMARY_CONTENT_TOP + summaryH)

	if panel.__sfRaidSignupSummaryTitle and panel.__sfRaidSignupSummaryTitle.SetPoint then
		-- Share the sidebar's left edge (the same offset as the summary host
		-- and its heading divider) instead of floating at the column's right.
		panel.__sfRaidSignupSummaryTitle:ClearAllPoints()
		panel.__sfRaidSignupSummaryTitle:SetPoint("TOPLEFT", host, "TOPLEFT", leftW + BOARD_COL_GAP, -2)
	end
	-- Position the + button first: the Signups heading line ends just before it.
	local plus = panel.__sfRaidSignupAddBtn
	if plus and plus.SetPoint then
		plus:ClearAllPoints()
		plus:SetPoint("TOPRIGHT", host, "TOPLEFT", leftW - 2, -4)
	end
	if panel.__sfRaidSignupLeftLine then
		panel.__sfRaidSignupLeftLine:ClearAllPoints()
		-- Stop ~7px before the button's left edge; tied to the button so the
		-- gap survives content-width changes. (Button top is y=-4, line y=-20.)
		panel.__sfRaidSignupLeftLine:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -20)
		if plus then
			panel.__sfRaidSignupLeftLine:SetPoint("TOPRIGHT", plus, "TOPLEFT", -7, -16)
		else
			panel.__sfRaidSignupLeftLine:SetPoint("TOPRIGHT", host, "TOPLEFT", leftW, -20)
		end
	end
	if panel.__sfRaidSignupRightLine then
		panel.__sfRaidSignupRightLine:ClearAllPoints()
		panel.__sfRaidSignupRightLine:SetPoint("TOPLEFT", host, "TOPLEFT", leftW + BOARD_COL_GAP, -20)
		panel.__sfRaidSignupRightLine:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -20)
	end
	if panel.__sfRaidSignupNickHeader then
		panel.__sfRaidSignupNickHeader:ClearAllPoints()
		panel.__sfRaidSignupNickHeader:SetPoint("TOPLEFT", host, "TOPLEFT", 0, headersY)
	end
	if panel.__sfRaidSignupMainHeader then
		panel.__sfRaidSignupMainHeader:ClearAllPoints()
		panel.__sfRaidSignupMainHeader:SetPoint("TOPLEFT", host, "TOPLEFT", geom.mainX, headersY)
	end
	if panel.__sfRaidSignupAltHeader then
		panel.__sfRaidSignupAltHeader:ClearAllPoints()
		panel.__sfRaidSignupAltHeader:SetPoint("TOPLEFT", host, "TOPLEFT", geom.altX, headersY)
	end
	if entriesHost then
		entriesHost:ClearAllPoints()
		entriesHost:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -topH)
		entriesHost:SetSize(leftW, entriesH)
	end
	if summaryHost then
		summaryHost:ClearAllPoints()
		summaryHost:SetPoint("TOPLEFT", host, "TOPLEFT", leftW + BOARD_COL_GAP, -SUMMARY_CONTENT_TOP)
		summaryHost:SetSize(rightW, summaryH)
	end
	local vdiv = panel.__sfRaidSignupVDivider
	if vdiv then
		vdiv:ClearAllPoints()
		vdiv:SetPoint("TOPLEFT", host, "TOPLEFT", leftW + math.floor(BOARD_COL_GAP / 2), -20)
		vdiv:SetPoint("BOTTOMLEFT", host, "TOPLEFT", leftW + math.floor(BOARD_COL_GAP / 2), -bodyBottom)
	end
	local status = panel.__sfRaidSignupStatusFs
	if status then
		status:ClearAllPoints()
		status:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -(topH + entriesH + 4))
		if status.SetWidth then
			status:SetWidth(leftW)
		end
	end

	local total = bodyBottom + BOARD_STATUS_H + 6
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

-- Roster-planning guidance colors for the role totals. These are advisory
-- heuristics owned by the guild, not Blizzard requirements or guarantees that
-- a composition can complete an encounter. Only the numeric text color
-- changes; icons, sizing, spacing, and hover regions are untouched.
local function FormatLoc(key, default, ...)
	return string.format(Loc(key, default), ...)
end

-- totals: { tank, healer, ranged, melee } completed-main counts.
-- Returns per-role { level = "yellow"|"orange"|"red", text = tooltip line }.
local function AssessRoleTotals(totals)
	totals = totals or {}
	local T = tonumber(totals.tank) or 0
	local H = tonumber(totals.healer) or 0
	local R = tonumber(totals.ranged) or 0
	local M = tonumber(totals.melee) or 0
	local N = T + H + M + R
	local D = M + R
	local result = {}

	-- Tanks: exactly two is the planning target; anything else is red.
	result.tank = {
		level = (T == 2) and "yellow" or "red",
		text = FormatLoc("RAID_SIGNUP_ASSESS_TANK", "%d tanks. Typical planning target: 2.", T),
	}

	-- Healers: below two is always red. For 10-30 total signups, grade against
	-- a roster-size band; outside that range the number stays normal yellow
	-- with an explicit not-assessed note (never called optimal).
	local healerLevel, healerText
	if H < 2 then
		healerLevel = "red"
		healerText = FormatLoc("RAID_SIGNUP_ASSESS_HEALER_MIN",
			"%d healers for %d signups. Typical planning guidance suggests at least 2 healers.", H, N)
	elseif N >= 10 and N <= 30 then
		local lower = math.max(2, math.floor(N / 5 + 0.5))
		local upper = math.max(lower, math.floor(N / 4))
		if H >= lower and H <= upper then
			healerLevel = "yellow"
			healerText = FormatLoc("RAID_SIGNUP_ASSESS_HEALER_OK",
				"%d healers for %d signups. Typical range: %d-%d.", H, N, lower, upper)
		elseif H == lower - 1 then
			healerLevel = "orange"
			healerText = FormatLoc("RAID_SIGNUP_ASSESS_HEALER_LOW",
				"%d healers for %d signups. Typical range: %d-%d. Slightly below the usual range.",
				H, N, lower, upper)
		elseif H == upper + 1 then
			healerLevel = "orange"
			healerText = FormatLoc("RAID_SIGNUP_ASSESS_HEALER_HIGH",
				"%d healers for %d signups. Typical range: %d-%d. Slightly above the usual range.",
				H, N, lower, upper)
		else
			healerLevel = "red"
			healerText = FormatLoc("RAID_SIGNUP_ASSESS_HEALER_OUT",
				"%d healers for %d signups. Outside the usual range (typical %d-%d).",
				H, N, lower, upper)
		end
	else
		healerLevel = "yellow"
		healerText = FormatLoc("RAID_SIGNUP_ASSESS_HEALER_UNGRADED",
			"%d healers for %d signups. Typical-balance guidance applies to rosters of 10-30 signups; not assessed at this size.",
			H, N)
	end
	result.healer = { level = healerLevel, text = healerText }

	-- DPS: the combined minimum overrides the split. With D >= 9, grade the
	-- melee share of combined DPS with integer comparisons so the 20%/65%/85%
	-- boundaries never suffer display-rounding errors. Both DPS numbers share
	-- the same balance color; ranged-heavy compositions stay orange at worst.
	local dpsLevel, dpsText
	if D < 9 then
		dpsLevel = "red"
		dpsText = FormatLoc("RAID_SIGNUP_ASSESS_DPS_MIN",
			"%d total DPS. Roster planning target: at least 9.", D)
	elseif 20 * M > 17 * D then
		dpsLevel = "red"
		dpsText = FormatLoc("RAID_SIGNUP_ASSESS_DPS_MELEE_OVER",
			"%d melee / %d ranged. Melee share outside the usual range; encounter-dependent.", M, R)
	elseif 5 * M < D or 20 * M > 13 * D then
		dpsLevel = "orange"
		if 5 * M < D then
			dpsText = FormatLoc("RAID_SIGNUP_ASSESS_DPS_RANGED_HEAVY",
				"%d melee / %d ranged. Ranged-heavy; fewer melee options for encounter assignments.", M, R)
		else
			dpsText = FormatLoc("RAID_SIGNUP_ASSESS_DPS_MELEE_HEAVY",
				"%d melee / %d ranged. Melee-heavy; fewer ranged options for encounter assignments.", M, R)
		end
	else
		dpsLevel = "yellow"
		dpsText = FormatLoc("RAID_SIGNUP_ASSESS_DPS_BALANCED",
			"%d melee / %d ranged. Balanced split; encounter-dependent.", M, R)
	end
	result.ranged = { level = dpsLevel, text = dpsText }
	result.melee = { level = dpsLevel, text = dpsText }

	return result
end
Page._AssessRoleTotalsForTests = AssessRoleTotals

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
	local assessment = AssessRoleTotals(totals)
	for _, key in ipairs(BOARD_ROLE_ORDER) do
		local slot = role[key]
		if slot and slot.count and slot.count.SetText then
			slot.count:SetText(tostring(totals[key] or 0))
			-- Recompute color and tooltip on every paint so counts returning to
			-- their normal range reset correctly.
			local assess = assessment[key]
			local color = assess and GUIDANCE_COLORS[assess.level] or GUIDANCE_COLORS.yellow
			slot.count:SetTextColor(color[1], color[2], color[3])
			if slot.hover then
				slot.hover.__sfRoleTooltip = assess and assess.text or nil
			end
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
	-- Provisional left anchor; LayoutBoard re-anchors to the sidebar's actual
	-- left edge once the column widths are known.
	summaryTitle:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -2)
	summaryTitle:SetText(Loc("RAID_SIGNUP_SECTION_SUMMARY", "Summary"))
	panel.__sfRaidSignupSummaryTitle = summaryTitle

	local function headingLine()
		local line = TrackRegionCreate(host:CreateTexture(nil, "ARTWORK"))
		line:SetHeight(1)
		line:SetColorTexture(1, 1, 1, 0.28)
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

	-- Role totals: small role icon + yellow count per group. The visible role
	-- names are gone; hovering the icon/count pair shows the full localized
	-- role name. Icons use the native circular LFG role icons: the gold-rimmed
	-- GroupFinder micro atlases first, then the plain Micro variants. Both
	-- damage roles stay distinct (ranged bow vs melee dagger). SetAtlas must
	-- not adopt the atlas's native size, so the final 14x14 size is enforced
	-- after the artwork is assigned on every path.
	local roleDefs = {
		{ key = "tank",
			atlas = "UI-LFG-RoleIcon-Tank-Micro-GroupFinder",
			fallbackAtlas = "UI-LFG-RoleIcon-Tank-Micro",
			fallbackTexCoord = { 0, 19 / 64, 22 / 64, 41 / 64 },
			name = Loc("RAID_SIGNUP_ROLE_TANKS", "Tanks") },
		{ key = "healer",
			atlas = "UI-LFG-RoleIcon-Healer-Micro-GroupFinder",
			fallbackAtlas = "UI-LFG-RoleIcon-Healer-Micro",
			fallbackTexCoord = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
			name = Loc("RAID_SIGNUP_ROLE_HEALERS", "Healers") },
		{ key = "ranged",
			atlas = "UI-LFG-RoleIcon-RangedDPS-Micro-GroupFinder",
			fallbackAtlas = "UI-LFG-RoleIcon-RangedDPS-Micro",
			fallbackTexCoord = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
			name = Loc("RAID_SIGNUP_ROLE_RANGED", "Ranged DPS") },
		{ key = "melee",
			atlas = "UI-LFG-RoleIcon-DPS-Micro-GroupFinder",
			fallbackAtlas = "UI-LFG-RoleIcon-DPS-Micro",
			fallbackTexCoord = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
			name = Loc("RAID_SIGNUP_ROLE_MELEE", "Melee DPS") },
	}
	local function RoleIconAtlasAvailable(name)
		return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
	end
	panel.__sfRaidSignupRole = {}
	for _, def in ipairs(roleDefs) do
		local icon = TrackRegionCreate(host:CreateTexture(nil, "ARTWORK"))
		local atlas = RoleIconAtlasAvailable(def.atlas) and def.atlas
			or (RoleIconAtlasAvailable(def.fallbackAtlas) and def.fallbackAtlas)
			or nil
		if atlas then
			icon:SetAtlas(atlas, false)
		else
			-- Last resort for clients without the LFG role atlases: the same
			-- circular role portraits BetterFriendlist crops from the classic
			-- group-finder sheet.
			icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
			if def.fallbackTexCoord then
				icon:SetTexCoord(unpack(def.fallbackTexCoord))
			end
		end
		icon:SetSize(ROLE_ICON_SIZE, ROLE_ICON_SIZE)
		local count = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
		count:SetText("0")
		count:SetTextColor(1, 0.82, 0.18)
		-- Informational hover over the icon+count pair (not clickable).
		local hover = TrackCreate(CreateFrame("Frame", nil, host))
		hover:EnableMouse(true)
		hover.__sfRoleName = def.name
		hover:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.__sfRoleName, 1, 1, 1)
			if self.__sfRoleTooltip then
				GameTooltip:AddLine(self.__sfRoleTooltip, 0.9, 0.9, 0.9, true)
			end
			GameTooltip:Show()
		end)
		hover:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		panel.__sfRaidSignupRole[def.key] = { icon = icon, count = count, hover = hover, name = def.name }
	end

	-- Column headers above the signup rows.
	local nickHeader = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	nickHeader:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -42)
	nickHeader:SetText(Loc("RAID_SIGNUP_COL_NICKNAME", "Nickname"))
	nickHeader:SetTextColor(0.8, 0.8, 0.8)
	panel.__sfRaidSignupNickHeader = nickHeader
	local mainHeader = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	mainHeader:SetPoint("TOPLEFT", host, "TOPLEFT", COL_MAIN_X, -42)
	mainHeader:SetText(Loc("RAID_SIGNUP_COL_MAIN", "Main"))
	mainHeader:SetTextColor(0.8, 0.8, 0.8)
	panel.__sfRaidSignupMainHeader = mainHeader
	local altHeader = TrackRegionCreate(host:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	altHeader:SetPoint("TOPLEFT", host, "TOPLEFT", COL_ALT_X, -42)
	altHeader:SetText(Loc("RAID_SIGNUP_COL_ALT", "Alt"))
	altHeader:SetTextColor(0.8, 0.8, 0.8)
	panel.__sfRaidSignupAltHeader = altHeader

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
		panel.__sfRaidSignupMainHeader = nil
		panel.__sfRaidSignupAltHeader = nil
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
