-- Guild Info → Main / Alt Assignments (#402).
local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

SF.SettingsUI:RegisterCategory({
	id = "guildInfo",
	name = Loc("GUILD_INFO_CATEGORY_NAME", "Guild Info"),
	navLabel = Loc("GUILD_INFO_CATEGORY_NAV", "Guild Info"),
	group = "Loot Tools",
	description = Loc("GUILD_INFO_CATEGORY_DESC",
		"Guild-wide character relationships maintained by officers."),
	order = 17,
})

local Page = {
	id = "guildInfoMainAlt",
	categoryId = "guildInfo",
	name = Loc("GUILD_INFO_MAIN_ALT_NAME", "Main / Alt Assignments"),
	navLabel = Loc("GUILD_INFO_MAIN_ALT_NAV", "Main / Alt Assignments"),
	contentHeading = Loc("GUILD_INFO_MAIN_ALT_HEADING", "Main / Alt Assignments"),
	group = "Loot Tools",
	description = Loc("GUILD_INFO_MAIN_ALT_DESC",
		"Guild-owned main and alt relationships. Independent of Loot Helper and Guild Supplies."),
	order = 17.1,
}

local function GI()
	return SF.GuildInfo
end

local passCache = nil
local refreshQueued = false
local rosterInvalidatePending = false
local rosterFrame = nil
local uiHooked = false

-- Session field state (not SavedVariables).
local mainText = ""
local altText = ""
local mainResolved = nil -- { guid, nameRealm, classFile }
local altResolved = nil
local selectedGroupMainGuid = nil
local changeMainCandidate = nil

local function BeginRenderPass()
	passCache = {}
end

local function EndRenderPass()
	passCache = nil
end

local function Caps()
	if passCache and passCache.caps then
		return passCache.caps
	end
	local g = GI()
	local caps
	if not g or not g.GetCapabilities then
		caps = { canEdit = false, canRead = false, reason = "not_ready" }
	else
		caps = g:GetCapabilities()
	end
	if passCache then
		passCache.caps = caps
	end
	return caps
end

local function Roster()
	if passCache and passCache.roster then
		return passCache.roster
	end
	local g = GI()
	local snap = g and g.GetRosterSnapshot and g.GetRosterSnapshot() or nil
	if passCache then
		passCache.roster = snap
	end
	return snap
end

local function PanelVisible(panel)
	panel = panel or Page.panel
	return panel and panel.IsVisible and panel:IsVisible()
end

local function RefreshPageControls()
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
end

local function RunQueuedRefresh()
	refreshQueued = false
	local needRoster = rosterInvalidatePending
	rosterInvalidatePending = false
	if not PanelVisible() then
		if needRoster then
			local g = GI()
			if g and g.InvalidateRosterSnapshot then
				g.InvalidateRosterSnapshot()
			end
		end
		return
	end
	if needRoster then
		local g = GI()
		if g and g.InvalidateRosterSnapshot then
			g.InvalidateRosterSnapshot()
		end
	end
	RefreshPageControls()
end

local function ScheduleRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	if C_Timer and C_Timer.After then
		C_Timer.After(0, RunQueuedRefresh)
	else
		RunQueuedRefresh()
	end
end

--- Lightweight control refresh for local form-state (no roster rescan).
local function QueueFormRefresh()
	if not PanelVisible() then
		return
	end
	ScheduleRefresh()
end

--- Roster/guild-driven refresh: invalidate cached roster once, then refresh controls.
local function QueueRosterRefresh()
	rosterInvalidatePending = true
	if not PanelVisible() then
		local g = GI()
		if g and g.InvalidateRosterSnapshot then
			g.InvalidateRosterSnapshot()
		end
		rosterInvalidatePending = false
		return
	end
	ScheduleRefresh()
end

-- Durable UI listener uses roster-aware refresh.
local function QueueRefresh()
	QueueRosterRefresh()
end

local function ReportStatus(ctx, status, reason, extra)
	local g = GI()
	local message, severity
	if g and g.FormatMutationFeedback then
		message, severity = g.FormatMutationFeedback(status, reason)
	else
		message = tostring(status or "rejected")
		severity = (status == "accepted" and "success")
			or (status == "duplicate" and "info")
			or "error"
	end
	if type(extra) == "string" and extra ~= "" then
		message = message .. " " .. extra
	end
	if ctx and ctx.section and ctx.section.SetMessage then
		ctx.section:SetMessage(message, severity)
	end
	RefreshPageControls()
end

local function SuggestionItems(prefix)
	local g = GI()
	local roster = Roster()
	if not roster or not roster.complete or not roster.Suggest then
		return {}
	end
	local rows = roster:Suggest(prefix, 10)
	local out = {}
	for i = 1, #rows do
		local row = rows[i]
		local label = row.nameRealm
		if g and g.ColorizeName then
			label = g.ColorizeName(row.nameRealm, row.classFile)
		end
		out[#out + 1] = {
			value = row.guid,
			guid = row.guid,
			nameRealm = row.nameRealm,
			classFile = row.classFile,
			label = label,
			text = row.nameRealm,
		}
	end
	return out
end

local function BothResolvedDistinct()
	return mainResolved and altResolved
		and mainResolved.guid and altResolved.guid
		and mainResolved.guid ~= altResolved.guid
end

local function AssignEnabled()
	local caps = Caps()
	if not caps.canEdit then
		return false
	end
	local roster = Roster()
	if not roster or not roster.complete then
		return false
	end
	return BothResolvedDistinct()
end

local function TryResolveField(text, current)
	local roster = Roster()
	if not roster or not roster.complete or not roster.Resolve then
		return nil
	end
	-- Keep current resolution if text still matches its name.
	if current and current.nameRealm and text == current.nameRealm then
		local row = roster.byGuid and roster.byGuid[current.guid]
		if row then
			return {
				guid = row.guid,
				nameRealm = row.nameRealm,
				classFile = row.classFile,
			}
		end
	end
	local row, err = roster:Resolve(text)
	if not row then
		return nil, err
	end
	return {
		guid = row.guid,
		nameRealm = row.nameRealm,
		classFile = row.classFile,
	}
end

local function CharacterLabel(guid, record, roster)
	local g = GI()
	local name, class = guid, nil
	if record and record.characters and record.characters[guid] then
		name = record.characters[guid].nameRealm or name
		class = record.characters[guid].classFile
	end
	if roster and roster.byGuid and roster.byGuid[guid] then
		name = roster.byGuid[guid].nameRealm or name
		class = roster.byGuid[guid].classFile or class
	end
	if g and g.ColorizeName then
		return g.ColorizeName(name, class)
	end
	return name
end

local function DoAssign(ctx, moveConfirmed, expectedOldMain)
	local g = GI()
	if not g or not g.AssignAlt then
		ReportStatus(ctx, "rejected", "not_ready")
		return
	end
	-- Recheck resolution at click time.
	mainResolved = select(1, TryResolveField(mainText, mainResolved))
	altResolved = select(1, TryResolveField(altText, altResolved))
	if not BothResolvedDistinct() then
		ReportStatus(ctx, "rejected", "identity_unavailable")
		return
	end
	local status, reason, meta = g:AssignAlt(mainResolved, altResolved, {
		roster = Roster(),
		moveConfirmed = moveConfirmed,
		expectedOldMain = expectedOldMain,
	})
	if status == "rejected" and reason == "move_confirmation_required" and meta then
		local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
		local record = select(1, g:GetCurrentRecord())
		local roster = Roster()
		local oldLabel = CharacterLabel(meta.oldMainGuid, record, roster)
		local newLabel = CharacterLabel(
			meta.newMainGuid or (mainResolved and mainResolved.guid),
			record,
			roster
		)
		local altLabel = CharacterLabel(
			meta.altGuid or (altResolved and altResolved.guid),
			record,
			roster
		)
		local msg = Loc("GUILD_INFO_MOVE_CONFIRM",
			"Move %s from %s to %s?"):format(altLabel, oldLabel, newLabel)
		if dialogs and dialogs.Confirm then
			dialogs:Confirm(msg, Loc("GUILD_INFO_MOVE_CONFIRM_BUTTON", "Move"), function()
				DoAssign(ctx, true, meta.oldMainGuid)
			end)
		else
			ReportStatus(ctx, "rejected", "move_confirmation_required")
		end
		return
	end
	if status == "accepted" or status == "duplicate" then
		mainText, altText = "", ""
		mainResolved, altResolved = nil, nil
	end
	ReportStatus(ctx, status, reason)
end

local function ChangeMainOptions()
	local g = GI()
	local roster = Roster()
	local opts = {}
	if not selectedGroupMainGuid or not g then
		return opts
	end
	local _, _, displayGroups = g:GetAssignmentDisplayRows(roster)
	if type(displayGroups) ~= "table" then
		return opts
	end
	for i = 1, #displayGroups do
		local group = displayGroups[i]
		if group.mainGuid == selectedGroupMainGuid then
			for j = 1, #group.alts do
				local a = group.alts[j]
				if a.status == "in_guild" then
					local label = a.nameRealm
					if g.ColorizeName then
						label = g.ColorizeName(a.nameRealm, a.classFile)
					end
					opts[#opts + 1] = { value = a.guid, label = label }
				end
			end
			break
		end
	end
	return opts
end

local function AccessStatusText()
	local caps = Caps()
	local roster = Roster()
	local g = GI()
	local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	if record and g.IsBaselineComplete and not g.IsBaselineComplete(record) then
		return Loc("GUILD_INFO_STATUS_GENERATION_SYNCING",
			"Synchronizing a newer Guild Info history generation. Assignments stay unavailable until the baseline finishes loading.")
	end
	if not caps.canRead then
		return Loc("GUILD_INFO_STATUS_MEMBERSHIP_PENDING",
			"Guild membership is still being verified. Shared Guild Info stays hidden until then.")
	end
	if not roster or not roster.complete then
		return Loc("GUILD_INFO_STATUS_ROSTER_WAIT",
			"Guild roster is loading or unavailable. Existing assignments remain; new targets stay disabled.")
	end
	if caps.canEdit then
		return Loc("GUILD_INFO_STATUS_EDITOR",
			"You can assign, move, unassign, and change mains (guild ranks 1–3).")
	end
	return Loc("GUILD_INFO_STATUS_READONLY",
		"View only. Guild ranks 1–3 may change assignments.")
end

local function CleanupConfirmMessage()
	local g = GI()
	local preview = g and g.PreviewCleanup and g:PreviewCleanup() or {}
	local recover = preview.capacityRecovered
		and Loc("GUILD_INFO_CLEANUP_RECOVER_YES", "Yes — obsolete history will free capacity.")
		or Loc("GUILD_INFO_CLEANUP_RECOVER_NO", "No meaningful capacity recovery (active relationships fill the limits, or nothing obsolete remains).")
	return Loc(
		"GUILD_INFO_CLEANUP_CONFIRM",
		"Clean up retained Guild Info history?\n\nPreserve %d active relationship group(s) (%d characters, %d groups).\nRemove approximately %d solo-main shell(s), %d unassign tombstone(s), and %d forwarding alias/obsolete group(s).\nCapacity recovery: %s\n\nWarning: your currently known relationships become the new guild-wide baseline. Offline or unsynchronized edits from the previous generation will not be imported."
	):format(
		tonumber(preview.relationships) or 0,
		tonumber(preview.retainedMembers) or 0,
		tonumber(preview.retainedGroups) or 0,
		tonumber(preview.discardSoloShells) or 0,
		tonumber(preview.discardTombstones) or 0,
		tonumber(preview.discardAliases) or 0,
		recover
	)
end

local function FieldsEnabled()
	local caps = Caps()
	local roster = Roster()
	local g = GI()
	local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	if record and g.IsBaselineComplete and not g.IsBaselineComplete(record) then
		return false
	end
	return caps.canEdit and roster and roster.complete
end

local function AssignButtonEnabled()
	if not FieldsEnabled() then
		return false
	end
	if BothResolvedDistinct() then
		return true
	end
	-- Exact unique typed matches also enable Assign without a suggestion click.
	local m = select(1, TryResolveField(mainText, mainResolved))
	local a = select(1, TryResolveField(altText, altResolved))
	if m and a and m.guid ~= a.guid then
		return true
	end
	return false
end

local function Definition()
	-- Closures must call Caps()/Roster() live so Page:Refresh() sees current
	-- authority and roster completeness without rebuilding the page (A).
	return {
		sections = {
			{
				id = "guildInfoMainAltStatus",
				title = Loc("GUILD_INFO_SECTION_STATUS", "Status"),
				items = {
					{
						type = "display",
						label = Loc("GUILD_INFO_STATUS_ROW_LABEL", "Access"),
						get = AccessStatusText,
					},
				},
			},
			{
				id = "guildInfoMainAltAssign",
				title = Loc("GUILD_INFO_SECTION_ASSIGN", "Assign"),
				items = {
					{
						type = "autocomplete",
						label = Loc("GUILD_INFO_MAIN_FIELD", "Main name"),
						hint = Loc("GUILD_INFO_NAME_HINT", "Type a guild member name"),
						width = 240,
						maxLetters = 96,
						enabled = FieldsEnabled,
						get = function()
							return mainText
						end,
						set = function(v)
							mainText = tostring(v or "")
						end,
						getSuggestions = function(_, prefix)
							return SuggestionItems(prefix or mainText)
						end,
						onResolved = function(_, item)
							if item then
								mainResolved = {
									guid = item.guid,
									nameRealm = item.nameRealm or item.text,
									classFile = item.classFile,
								}
								mainText = mainResolved.nameRealm
							else
								mainResolved = nil
							end
							QueueFormRefresh()
						end,
						onTextChanged = function(_, text)
							mainText = text or ""
							mainResolved = nil
							QueueFormRefresh()
						end,
					},
					{
						type = "autocomplete",
						label = Loc("GUILD_INFO_ALT_FIELD", "Alt name"),
						hint = Loc("GUILD_INFO_NAME_HINT", "Type a guild member name"),
						width = 240,
						maxLetters = 96,
						enabled = FieldsEnabled,
						get = function()
							return altText
						end,
						set = function(v)
							altText = tostring(v or "")
						end,
						getSuggestions = function(_, prefix)
							return SuggestionItems(prefix or altText)
						end,
						onResolved = function(_, item)
							if item then
								altResolved = {
									guid = item.guid,
									nameRealm = item.nameRealm or item.text,
									classFile = item.classFile,
								}
								altText = altResolved.nameRealm
							else
								altResolved = nil
							end
							QueueFormRefresh()
						end,
						onTextChanged = function(_, text)
							altText = text or ""
							altResolved = nil
							QueueFormRefresh()
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_INFO_ASSIGN_LABEL", "Assign alt to main"),
						buttonText = Loc("GUILD_INFO_ASSIGN_BUTTON", "Assign"),
						enabled = AssignButtonEnabled,
						onClick = function(ctx)
							-- Resolve exact unique typed names if suggestions were not clicked.
							if not mainResolved then
								mainResolved = select(1, TryResolveField(mainText, nil))
							end
							if not altResolved then
								altResolved = select(1, TryResolveField(altText, nil))
							end
							DoAssign(ctx, false, nil)
						end,
					},
				},
			},
			{
				id = "guildInfoMainAltList",
				title = Loc("GUILD_INFO_SECTION_LIST", "Assignments"),
				items = {
					{
						type = "scrollList",
						label = Loc("GUILD_INFO_LIST_LABEL", "Mains and alts"),
						height = 220,
						border = true,
						enabled = function()
							return Caps().canRead
						end,
						getItems = function()
							local gi = GI()
							if not gi or not gi.GetAssignmentDisplayRows then
								return {}
							end
							local rows = gi:GetAssignmentDisplayRows(Roster())
							return rows or {}
						end,
						getSelectedKey = function()
							return selectedGroupMainGuid
						end,
						onSelect = function(_, item)
							if item and item.clusterId then
								selectedGroupMainGuid = item.clusterId
								changeMainCandidate = nil
								RefreshPageControls()
							end
						end,
						onRemove = function(ctx, item)
							if not item or item.role ~= "alt" or not item.guid then
								return
							end
							local gi = GI()
							if not gi or not gi.UnassignAlt then
								return
							end
							-- Capture the displayed relationship for stale confirmation.
							local expectedMainGuid = item.mainGuid
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							local msg = Loc("GUILD_INFO_UNASSIGN_CONFIRM",
								"Unassign this alt from its main?")
							local function commit()
								local status, reason = gi:UnassignAlt(item.guid, {
									expectedMainGuid = expectedMainGuid,
								})
								ReportStatus(ctx, status, reason)
							end
							if dialogs and dialogs.Confirm then
								dialogs:Confirm(msg, Loc("GUILD_INFO_UNASSIGN_BUTTON", "Unassign"), commit)
							else
								commit()
							end
						end,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_INFO_CHANGE_MAIN_FIELD", "New main (selected group)"),
						defaultText = Loc("GUILD_INFO_CHANGE_MAIN_DEFAULT", "Select a rostered alt"),
						enabled = function()
							return Caps().canEdit and selectedGroupMainGuid ~= nil and #ChangeMainOptions() > 0
						end,
						get = function()
							return changeMainCandidate
						end,
						set = function(v)
							changeMainCandidate = v
							QueueFormRefresh()
						end,
						options = function()
							return ChangeMainOptions()
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_INFO_CHANGE_MAIN_LABEL", "Change Main"),
						buttonText = Loc("GUILD_INFO_CHANGE_MAIN_BUTTON", "Change Main"),
						enabled = function()
							return Caps().canEdit
								and selectedGroupMainGuid ~= nil
								and changeMainCandidate ~= nil
						end,
						onClick = function(ctx)
							local gi = GI()
							if not gi or not gi.ChangeMain then
								return
							end
							local oldMain = selectedGroupMainGuid
							local newMain = changeMainCandidate
							local record = select(1, gi:GetCurrentRecord())
							local r = Roster()
							local msg = Loc("GUILD_INFO_CHANGE_MAIN_CONFIRM",
								"Promote %s to main? %s becomes an alt; all other alts stay in the group."):format(
								CharacterLabel(newMain, record, r),
								CharacterLabel(oldMain, record, r)
							)
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							local function commit()
								local status, reason = gi:ChangeMain(oldMain, newMain, { roster = r })
								if status == "accepted" then
									selectedGroupMainGuid = newMain
									changeMainCandidate = nil
								end
								ReportStatus(ctx, status, reason)
							end
							if dialogs and dialogs.Confirm then
								dialogs:Confirm(msg, Loc("GUILD_INFO_CHANGE_MAIN_BUTTON", "Change Main"), commit)
							else
								commit()
							end
						end,
					},
				},
			},
			{
				id = "guildInfoMainAltCleanup",
				title = Loc("GUILD_INFO_SECTION_CLEANUP", "History cleanup"),
				items = {
					{
						type = "display",
						label = Loc("GUILD_INFO_CLEANUP_HELP_LABEL", "About cleanup"),
						get = function()
							return Loc(
								"GUILD_INFO_CLEANUP_HELP",
								"Removes obsolete solo-main shells, unassign tombstones, and forwarding aliases while keeping currently known active relationships. This is not Delete All Assignments."
							)
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_INFO_CLEANUP_LABEL", "Clean up retained Guild Info history"),
						buttonText = Loc("GUILD_INFO_CLEANUP_BUTTON", "Clean up history"),
						enabled = function()
							local gi = GI()
							local record = gi and gi.GetCurrentRecord and select(1, gi:GetCurrentRecord()) or nil
							if record and gi.IsBaselineComplete and not gi.IsBaselineComplete(record) then
								return false
							end
							return Caps().canEdit
						end,
						onClick = function(ctx)
							local gi = GI()
							if not gi or not gi.CleanupHistory then
								return
							end
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							local msg = CleanupConfirmMessage()
							local function commit()
								local status, reason = gi:CleanupHistory({})
								ReportStatus(ctx, status, reason)
							end
							if dialogs and dialogs.Confirm then
								dialogs:Confirm(msg, Loc("GUILD_INFO_CLEANUP_BUTTON", "Clean up history"), commit)
							else
								commit()
							end
						end,
					},
				},
			},
		},
	}
end

local function EnsureRosterListener()
	if rosterFrame or type(CreateFrame) ~= "function" then
		return
	end
	local frame = CreateFrame("Frame")
	rosterFrame = frame
	frame:RegisterEvent("GUILD_ROSTER_UPDATE")
	if frame.RegisterEvent then
		pcall(frame.RegisterEvent, frame, "PLAYER_GUILD_UPDATE")
	end
	frame:SetScript("OnEvent", function()
		local g = GI()
		if g and g.InvalidateRosterSnapshot then
			g.InvalidateRosterSnapshot()
		end
		QueueRefresh()
	end)
end

local function EnsureUIListener()
	if uiHooked then
		return
	end
	local g = GI()
	if not g or not g.RegisterUIListener then
		return
	end
	uiHooked = true
	g.RegisterUIListener(function()
		QueueRefresh()
	end)
end

function Page:Build(panel)
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer or not renderer.Build then
		return
	end
	EnsureRosterListener()
	EnsureUIListener()
	BeginRenderPass()
	renderer:Build(panel, Definition())
	EndRenderPass()
	self.panel = panel
	if panel.HookScript and not panel.__sfGuildInfoMainAltHook then
		panel.__sfGuildInfoMainAltHook = true
		panel:HookScript("OnShow", function()
			QueueRefresh()
		end)
	end
end

function Page:Refresh(panel)
	panel = panel or self.panel
	if not PanelVisible(panel) then
		return
	end
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if renderer and renderer.Refresh then
		BeginRenderPass()
		renderer:Refresh(panel)
		EndRenderPass()
	end
end

function Page:OnHide()
	refreshQueued = false
	rosterInvalidatePending = false
end

EnsureRosterListener()
EnsureUIListener()

SF.SettingsUI:RegisterPage(Page)
