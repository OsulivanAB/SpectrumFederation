-- Guild Supplies → Troubleshooting (#422). Staged dataset adoption and
-- configuration conflicts. Domain semantics stay in SF.GuildSupplies; this page
-- only hosts the infrequently used recovery controls moved off Configuration.
local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

local Page = {
	id = "guildSuppliesTroubleshooting",
	categoryId = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_TROUBLESHOOTING_NAME", "Troubleshooting"),
	navLabel = Loc("GUILD_SUPPLIES_TROUBLESHOOTING_NAV", "Troubleshooting"),
	contentHeading = Loc("GUILD_SUPPLIES_TROUBLESHOOTING_HEADING", "Raid Supplies Troubleshooting"),
	group = "Raid Tools",
	description = Loc("GUILD_SUPPLIES_TROUBLESHOOTING_DESC",
		"Recover from staged dataset mismatches and resolve configuration conflicts."),
	order = 19.3,
}

local function GS()
	return SF.GuildSupplies
end

-- Per build/refresh pass only: reuse validated read context across controls.
-- Cleared after the pass so mutations always recheck authority/base freshly.
local passCache = nil

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
	local g = GS()
	local caps
	if not g or not g.GetCapabilities then
		caps = { canEdit = false, canRead = false, canRecoverPolicy = false, reason = "not_ready" }
	else
		caps = g:GetCapabilities()
	end
	if passCache then
		passCache.caps = caps
	end
	return caps
end

local refreshQueued = false
local rosterFrame = nil

-- Session-local UI selection only; never persisted. Survives tab switches so
-- an in-progress adoption is not cancelled by leaving this page.
local pendingAdoptionPeer = nil
local pendingAdoptionDataset = nil
local pendingConflictTarget = nil
local pendingConflictChosen = nil

local function ClearPendingAdoptionChoice()
	pendingAdoptionPeer = nil
	pendingAdoptionDataset = nil
end

local function ClearPendingConflictChoice()
	pendingConflictTarget = nil
	pendingConflictChosen = nil
end

--- Refresh controls through Page:Refresh so passCache bounds the render.
local function RefreshPageControls()
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
end

local function ReportStatus(ctx, status, reason)
	local g = GS()
	local message, severity
	if g and g.FormatMutationFeedback then
		message, severity = g.FormatMutationFeedback(status, reason)
	else
		message = tostring(status or "rejected")
		severity = (status == "accepted" and "success")
			or (status == "duplicate" and "info")
			or (status == "pending" and "warn")
			or "error"
	end
	ctx.section:SetMessage(message, severity)
	RefreshPageControls()
end

local function AdoptionSourceOptions()
	local opts = {}
	local g = GS()
	if not g or not g.ListPeerDatasets then
		return opts
	end
	local localRecord = g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	local localMarker = localRecord and localRecord.liveCutover
		and localRecord.liveCutover.cutoverMarker or nil
	local conflict = g.GetLiveActivationConflictState
		and g:GetLiveActivationConflictState() or nil
	local conflictMarkers = {}
	if conflict and conflict.blocked then
		for i = 1, #(conflict.peers or {}) do
			local cp = conflict.peers[i]
			if cp and type(cp.peerName) == "string" and type(cp.cutoverMarker) == "string" then
				conflictMarkers[cp.peerName] = cp.cutoverMarker
			end
		end
	end
	local peers = g:ListPeerDatasets()
	for i = 1, #peers do
		local p = peers[i]
		if p then
			local cutoverResolve = p.sameAsLocal
				and conflictMarkers[p.peerName]
				and conflictMarkers[p.peerName] ~= localMarker
			if (not p.sameAsLocal) or cutoverResolve then
				local label
				if cutoverResolve then
					label = Loc("GUILD_SUPPLIES_ADOPTION_CUTOVER_SOURCE_FMT",
						"%s — resolve live cutover to %s")
						:format(tostring(p.peerName), tostring(conflictMarkers[p.peerName]))
				else
					label = Loc("GUILD_SUPPLIES_ADOPTION_SOURCE_FMT", "%s — %s")
						:format(tostring(p.peerName), tostring(p.datasetId))
				end
				opts[#opts + 1] = {
					value = tostring(p.peerName) .. "\0" .. tostring(p.datasetId),
					label = label,
					peerName = p.peerName,
					datasetId = p.datasetId,
					cutoverResolution = cutoverResolve and true or false,
				}
			end
		end
	end
	return opts
end

local function ConflictHelpText()
	local g = GS()
	local conflicts = g and g.ListOpenConflicts and g:ListOpenConflicts() or {}
	if #conflicts == 0 then
		return Loc("GUILD_SUPPLIES_CONFLICT_NONE", "No open configuration conflicts.")
	end
	return Loc("GUILD_SUPPLIES_CONFLICT_HELP",
		"Both candidates are preserved. Choosing one creates a new authenticated resolution without rewriting the original operations.")
end

local function ConflictTargetOptions()
	local opts = {}
	local g = GS()
	local conflicts = g and g.ListOpenConflicts and g:ListOpenConflicts() or {}
	for i = 1, #conflicts do
		local entry = conflicts[i]
		if entry and type(entry.targetKey) == "string" then
			opts[#opts + 1] = {
				value = entry.targetKey,
				label = Loc("GUILD_SUPPLIES_CONFLICT_TARGET_FMT", "Conflict: %s (%d candidates)")
					:format(entry.targetKey, entry.candidates and #entry.candidates or 0),
			}
		end
	end
	return opts
end

local function ConflictCandidateOptions()
	local opts = {}
	local g = GS()
	if not pendingConflictTarget then
		return opts
	end
	local conflicts = g and g.ListOpenConflicts and g:ListOpenConflicts() or {}
	local entry = nil
	for i = 1, #conflicts do
		if conflicts[i].targetKey == pendingConflictTarget then
			entry = conflicts[i]
			break
		end
	end
	if not entry or type(entry.candidates) ~= "table" then
		return opts
	end
	for i = 1, #entry.candidates do
		local c = entry.candidates[i]
		if c and type(c.id) == "string" then
			local body = c.body
			local summary = tostring(c.id)
			if type(body) == "table" then
				local author = body.actorName or "?"
				local value = body.value
				if type(value) == "table" then
					value = value.goal or value.itemId or "?"
				end
				summary = Loc("GUILD_SUPPLIES_CONFLICT_CANDIDATE_FMT", "%s — %s (by %s)")
					:format(tostring(c.id), tostring(value), tostring(author))
			end
			opts[#opts + 1] = {
				value = c.id,
				label = summary,
			}
		end
	end
	return opts
end

local function CommitConflictChoice(ctx, targetKey, chosenOpId, competingOpIds)
	local g = GS()
	if not g or not g.NewConflictResolutionOperation then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	ctx.section:ClearMessage()
	-- Revalidate the open conflict and chosen id before preparing resolution.
	local conflicts = g:ListOpenConflicts() or {}
	local entry = nil
	for i = 1, #conflicts do
		if conflicts[i].targetKey == targetKey then
			entry = conflicts[i]
			break
		end
	end
	if not entry or type(entry.candidates) ~= "table" then
		ReportStatus(ctx, "rejected", "no_open_conflict")
		ClearPendingConflictChoice()
		return
	end
	local ids = competingOpIds
	if type(ids) ~= "table" then
		ids = {}
		for i = 1, #entry.candidates do
			ids[#ids + 1] = entry.candidates[i].id
		end
	end
	local found = false
	for i = 1, #ids do
		if ids[i] == chosenOpId then
			found = true
			break
		end
	end
	if not found then
		ReportStatus(ctx, "rejected", "invalid_resolution")
		return
	end
	local op, prepStatus, prepReason = g:NewConflictResolutionOperation(targetKey, chosenOpId, ids)
	if not op then
		ReportStatus(ctx, prepStatus or "rejected", prepReason)
		return
	end
	local status, reason = g:ApplyStagedConflictResolution(op)
	if status == "accepted" then
		ClearPendingConflictChoice()
	end
	ReportStatus(ctx, status, reason)
end

--- Begin adoption transfer (does not commit). Commit is a separate control once ready.
local function BeginAdoptionTransfer(ctx)
	local g = GS()
	local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
	if not g or not pendingAdoptionPeer or not pendingAdoptionDataset then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	local peer = pendingAdoptionPeer
	local datasetId = pendingAdoptionDataset
	local cutoverResolution = false
	do
		local opts = AdoptionSourceOptions()
		for i = 1, #opts do
			if opts[i].peerName == peer and opts[i].datasetId == datasetId
				and opts[i].cutoverResolution then
				cutoverResolution = true
				break
			end
		end
	end
	local accept = function()
		ctx.section:ClearMessage()
		local session, status, reason = g:BeginDatasetAdoption(peer, datasetId)
		if status ~= "accepted" then
			ReportStatus(ctx, status or "rejected", reason)
			return
		end
		ReportStatus(ctx, "pending", "incomplete_transfer")
		RefreshPageControls()
	end
	if dialogs and dialogs.Confirm then
		local confirmText = cutoverResolution
			and Loc("GUILD_SUPPLIES_ADOPTION_CUTOVER_CONFIRM",
				"Replace this client's live Guild Supplies cutover with the selected peer's authenticated complete dataset and cutover marker? Local divergent live state is not merged. Cancel leaves the current blocked state unchanged.")
			or Loc("GUILD_SUPPLIES_ADOPTION_CONFIRM",
				"Replace this client's local staged Guild Supplies configuration/dataset with the selected source dataset? The two datasets are not merged. Cancel leaves local state unchanged. This does not activate live bank accounting.")
		dialogs:Confirm(
			confirmText,
			Loc("GUILD_SUPPLIES_ADOPTION_BUTTON", "Adopt selected dataset"),
			accept
		)
	else
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_CONFIRM_UNAVAILABLE",
				"Confirmation is required and is unavailable right now."),
			"error")
	end
end

local function CommitAdoptionTransfer(ctx)
	local g = GS()
	if not g or not g.CommitDatasetAdoption then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	ctx.section:ClearMessage()
	local adop = g:GetPendingAdoption()
	if type(adop) ~= "table" then
		ReportStatus(ctx, "rejected", "no_adoption")
		return
	end
	-- Overlapping commits while replay is already running are rejected.
	if type(adop.replayTemp) == "table" then
		ReportStatus(ctx, "pending", "replay_in_progress")
		RefreshPageControls()
		return
	end
	if not adop.ready then
		ReportStatus(ctx, "pending", "incomplete_transfer")
		return
	end
	local commitStatus, commitReason = g:CommitDatasetAdoption()
	if commitStatus == "accepted" then
		ClearPendingAdoptionChoice()
	end
	ReportStatus(ctx, commitStatus or "rejected", commitReason)
	RefreshPageControls()
end

local function DisabledMembershipTip()
	return Loc("GUILD_SUPPLIES_DISABLED_MEMBERSHIP",
		"Join a guild with a verified membership before using Guild Supplies.")
end

local function DisabledUnauthorizedTip(action)
	return Loc("GUILD_SUPPLIES_DISABLED_UNAUTHORIZED_FMT",
		"Your guild rank does not permit %s."):format(action)
end

--- Permission/membership gate shared by privileged Troubleshooting controls.
-- @param action string short action phrase for unauthorized copy
-- @param allowRecover boolean|nil also accept canRecoverPolicy
-- @return string|nil tip when blocked, else nil
local function DisabledAuthTip(action, allowRecover)
	local c = Caps()
	if not c.canRead then
		return DisabledMembershipTip()
	end
	if c.canEdit then
		return nil
	end
	if allowRecover and c.canRecoverPolicy then
		return nil
	end
	return DisabledUnauthorizedTip(action)
end

local function DisabledAdoptionSourceTip()
	local auth = DisabledAuthTip(
		Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADOPTION", "adopting a dataset"), true)
	if auth then
		return auth
	end
	local g = GS()
	local adop = g and g.GetPendingAdoption and g:GetPendingAdoption()
	if type(adop) == "table" then
		return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_IN_PROGRESS",
			"Finish or cancel the current dataset adoption before selecting a new source.")
	end
	if #AdoptionSourceOptions() > 0 then
		return nil
	end
	return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_NO_SOURCES",
		"No eligible peer datasets are currently available for adoption.")
end

local function DisabledAdoptionBeginTip()
	local auth = DisabledAuthTip(
		Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADOPTION", "adopting a dataset"), true)
	if auth then
		return auth
	end
	local g = GS()
	local adop = g and g.GetPendingAdoption and g:GetPendingAdoption()
	if type(adop) == "table" then
		return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_IN_PROGRESS",
			"Finish or cancel the current dataset adoption before selecting a new source.")
	end
	if pendingAdoptionPeer == nil or pendingAdoptionDataset == nil then
		if #AdoptionSourceOptions() == 0 then
			return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_NO_SOURCES",
				"No eligible peer datasets are currently available for adoption.")
		end
		return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_SELECT_SOURCE",
			"Select a source dataset first.")
	end
	return nil
end

local function DisabledAdoptionCommitTip()
	local auth = DisabledAuthTip(
		Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADOPTION", "adopting a dataset"), true)
	if auth then
		return auth
	end
	local g = GS()
	local adop = g and g.GetPendingAdoption and g:GetPendingAdoption()
	if type(adop) ~= "table" then
		return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_NONE_COMMIT",
			"There is no adoption ready to commit.")
	end
	if type(adop.replayTemp) == "table" then
		return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_REPLAY",
			"Wait for the dataset transfer to finish applying before committing.")
	end
	if adop.ready ~= true then
		return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_WAIT_TRANSFER",
			"Wait for the dataset transfer to finish before committing.")
	end
	return nil
end

local function DisabledAdoptionCancelTip()
	local g = GS()
	local adop = g and g.GetPendingAdoption and g:GetPendingAdoption()
	if type(adop) == "table" then
		return nil
	end
	return Loc("GUILD_SUPPLIES_DISABLED_ADOPTION_NONE_CANCEL",
		"There is no adoption in progress.")
end

local function DisabledConflictTargetTip()
	local auth = DisabledAuthTip(
		Loc("GUILD_SUPPLIES_DISABLED_ACTION_CONFLICTS", "resolving configuration conflicts"), false)
	if auth then
		return auth
	end
	if #ConflictTargetOptions() > 0 then
		return nil
	end
	return Loc("GUILD_SUPPLIES_DISABLED_CONFLICT_NONE",
		"There are no unresolved configuration conflicts.")
end

local function DisabledConflictCandidateTip()
	local auth = DisabledAuthTip(
		Loc("GUILD_SUPPLIES_DISABLED_ACTION_CONFLICTS", "resolving configuration conflicts"), false)
	if auth then
		return auth
	end
	if pendingConflictTarget == nil then
		if #ConflictTargetOptions() == 0 then
			return Loc("GUILD_SUPPLIES_DISABLED_CONFLICT_NONE",
				"There are no unresolved configuration conflicts.")
		end
		return Loc("GUILD_SUPPLIES_DISABLED_CONFLICT_SELECT",
			"Select an open configuration conflict first.")
	end
	if #ConflictCandidateOptions() < 2 then
		return Loc("GUILD_SUPPLIES_DISABLED_CONFLICT_CANDIDATES",
			"Select a conflict that still has competing candidate values.")
	end
	return nil
end

local function DisabledConflictChooseTip()
	local auth = DisabledAuthTip(
		Loc("GUILD_SUPPLIES_DISABLED_ACTION_CONFLICTS", "resolving configuration conflicts"), false)
	if auth then
		return auth
	end
	if pendingConflictTarget == nil then
		if #ConflictTargetOptions() == 0 then
			return Loc("GUILD_SUPPLIES_DISABLED_CONFLICT_NONE",
				"There are no unresolved configuration conflicts.")
		end
		return Loc("GUILD_SUPPLIES_DISABLED_CONFLICT_SELECT",
			"Select an open configuration conflict first.")
	end
	if pendingConflictChosen == nil or #ConflictCandidateOptions() < 2 then
		return Loc("GUILD_SUPPLIES_DISABLED_CONFLICT_CHOOSE",
			"Select a conflict and a candidate value before resolving it.")
	end
	return nil
end

local function Definition()
	return {
		isAdmin = function()
			return Caps().canEdit or Caps().canRecoverPolicy
		end,
		sections = {
			{
				id = "gsAdoption",
				title = Loc("GUILD_SUPPLIES_ADOPTION_TITLE", "Staged dataset adoption"),
				tooltip = Loc("GUILD_SUPPLIES_ADOPTION_TIP",
					"When another authorized editor has a different staged dataset, choose one source. Adoption replaces this client's local staged Guild Supplies configuration; datasets are never merged."),
				items = {
					{
						type = "help",
						indent = "label",
						getText = function()
							local opts = AdoptionSourceOptions()
							if #opts == 0 then
								local g = GS()
								local adop = g and g.GetPendingAdoption and g:GetPendingAdoption()
								if type(adop) == "table" then
									return Loc("GUILD_SUPPLIES_ADOPTION_PENDING",
										"Adoption in progress for dataset %s from %s. Waiting for a complete validated transfer before switching.")
										:format(tostring(adop.sourceDatasetId), tostring(adop.sourcePeer))
								end
								return Loc("GUILD_SUPPLIES_ADOPTION_EMPTY",
									"No conflicting peer datasets are available right now. Empty clients wait for an authenticated editor source.")
							end
							return Loc("GUILD_SUPPLIES_ADOPTION_HELP",
								"Adoption is a local staged-development action. It does not activate live bank accounting or establish guild-wide production authority.")
						end,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_ADOPTION_SOURCE", "Source dataset"),
						adminOnly = true,
						defaultText = Loc("GUILD_SUPPLIES_ADOPTION_NONE", "Select a source"),
						options = AdoptionSourceOptions,
						get = function()
							if pendingAdoptionPeer and pendingAdoptionDataset then
								return tostring(pendingAdoptionPeer) .. "\0" .. tostring(pendingAdoptionDataset)
							end
							return nil
						end,
						set = function() end,
						enabled = function()
							local c = Caps()
							return c.canEdit == true and #AdoptionSourceOptions() > 0
						end,
						getDisabledTooltip = DisabledAdoptionSourceTip,
						onValueChanged = function(ctx, value)
							if type(value) ~= "string" then
								ClearPendingAdoptionChoice()
								return
							end
							local peer, datasetId = value:match("^(.-)\0(.+)$")
							if peer and datasetId then
								pendingAdoptionPeer = peer
								pendingAdoptionDataset = datasetId
							else
								ClearPendingAdoptionChoice()
							end
							RefreshPageControls()
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_ADOPTION_TITLE", "Staged dataset adoption"),
						adminOnly = true,
						buttonText = Loc("GUILD_SUPPLIES_ADOPTION_BEGIN", "Start adoption transfer"),
						width = 220,
						enabled = function()
							local c = Caps()
							local g = GS()
							local adop = g and g.GetPendingAdoption and g:GetPendingAdoption()
							return c.canEdit == true
								and pendingAdoptionPeer ~= nil
								and pendingAdoptionDataset ~= nil
								and type(adop) ~= "table"
						end,
						getDisabledTooltip = DisabledAdoptionBeginTip,
						onClick = function(ctx)
							BeginAdoptionTransfer(ctx)
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_ADOPTION_COMMIT", "Commit adoption"),
						adminOnly = true,
						buttonText = Loc("GUILD_SUPPLIES_ADOPTION_COMMIT", "Commit adoption"),
						width = 180,
						enabled = function()
							local c = Caps()
							local g = GS()
							local adop = g and g.GetPendingAdoption and g:GetPendingAdoption()
							return c.canEdit == true
								and type(adop) == "table"
								and adop.ready == true
								and type(adop.replayTemp) ~= "table"
						end,
						getDisabledTooltip = DisabledAdoptionCommitTip,
						onClick = function(ctx)
							CommitAdoptionTransfer(ctx)
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_ADOPTION_CANCEL", "Cancel adoption"),
						adminOnly = true,
						buttonText = Loc("GUILD_SUPPLIES_ADOPTION_CANCEL", "Cancel adoption"),
						width = 160,
						enabled = function()
							local g = GS()
							local adop = g and g.GetPendingAdoption and g:GetPendingAdoption()
							return type(adop) == "table"
						end,
						getDisabledTooltip = DisabledAdoptionCancelTip,
						onClick = function(ctx)
							local g = GS()
							ctx.section:ClearMessage()
							if g and g.CancelDatasetAdoption then
								g:CancelDatasetAdoption()
							end
							ClearPendingAdoptionChoice()
							ctx.section:SetMessage(
								Loc("GUILD_SUPPLIES_STATUS_ADOPTION_CANCELLED",
									"Dataset adoption cancelled. Local staged configuration was left unchanged."),
								"info")
							RefreshPageControls()
						end,
					},
				},
			},
			{
				id = "gsConflicts",
				title = Loc("GUILD_SUPPLIES_CONFLICT_TITLE", "Configuration conflicts"),
				tooltip = Loc("GUILD_SUPPLIES_CONFLICT_TIP",
					"Same-field or concurrent campaign edits stay unresolved until an authorized editor chooses a result."),
				items = {
					{
						type = "help",
						indent = "label",
						getText = ConflictHelpText,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_CONFLICT_TARGET", "Open conflict"),
						adminOnly = true,
						defaultText = Loc("GUILD_SUPPLIES_CONFLICT_TARGET_NONE", "Select a conflict"),
						options = ConflictTargetOptions,
						get = function()
							return pendingConflictTarget
						end,
						set = function() end,
						enabled = function()
							return Caps().canEdit and #ConflictTargetOptions() > 0
						end,
						getDisabledTooltip = DisabledConflictTargetTip,
						onValueChanged = function(ctx, value)
							if type(value) == "string" and value ~= "" then
								pendingConflictTarget = value
								pendingConflictChosen = nil
							else
								ClearPendingConflictChoice()
							end
							RefreshPageControls()
						end,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_CONFLICT_CANDIDATE", "Candidate"),
						adminOnly = true,
						defaultText = Loc("GUILD_SUPPLIES_CONFLICT_CANDIDATE_NONE", "Select a candidate"),
						options = ConflictCandidateOptions,
						get = function()
							return pendingConflictChosen
						end,
						set = function() end,
						enabled = function()
							return Caps().canEdit
								and pendingConflictTarget ~= nil
								and #ConflictCandidateOptions() >= 2
						end,
						getDisabledTooltip = DisabledConflictCandidateTip,
						onValueChanged = function(ctx, value)
							if type(value) == "string" and value ~= "" then
								pendingConflictChosen = value
							else
								pendingConflictChosen = nil
							end
							RefreshPageControls()
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_CONFLICT_TITLE", "Configuration conflicts"),
						adminOnly = true,
						buttonText = Loc("GUILD_SUPPLIES_CONFLICT_CHOOSE", "Use this value"),
						width = 160,
						enabled = function()
							return Caps().canEdit
								and pendingConflictTarget ~= nil
								and pendingConflictChosen ~= nil
								and #ConflictCandidateOptions() >= 2
						end,
						getDisabledTooltip = DisabledConflictChooseTip,
						onClick = function(ctx)
							CommitConflictChoice(ctx, pendingConflictTarget, pendingConflictChosen, nil)
						end,
					},
				},
			},
		},
	}
end

-- Standalone Settings can hide the parent while the page panel stays IsShown.
-- Prefer IsVisible so roster-driven work does not run against a closed window.
local function PanelVisible(panel)
	if not panel then return false end
	if panel.IsVisible then
		return panel:IsVisible() and true or false
	end
	if panel.IsShown then
		return panel:IsShown() and true or false
	end
	return false
end

local function QueueRefresh()
	local panel = Page.panel
	if not panel or not Page.Refresh then return end
	if not PanelVisible(panel) then return end
	if refreshQueued then return end
	refreshQueued = true
	local function run()
		refreshQueued = false
		if not Page.panel or not Page.Refresh then return end
		if not PanelVisible(Page.panel) then return end
		Page:Refresh(Page.panel)
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0, run)
	else
		run()
	end
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
		QueueRefresh()
	end)
end

--- Durable GS changes (conflicts, peer advertisements) while this tab is visible.
local durableListenerRegistered = false
local function EnsureDurableListener()
	if durableListenerRegistered then
		return
	end
	local mod = SF.GuildSupplies
	if not mod or type(mod.RegisterUIListener) ~= "function" then
		return
	end
	mod.RegisterUIListener(function()
		QueueRefresh()
	end)
	durableListenerRegistered = true
end

--- Coalesced refresh when adoption ready/expiry flips asynchronously.
-- Chains onto any prior hook (Configuration keeps status warnings current).
local adoptionHooked = false
local function EnsureAdoptionListener()
	if adoptionHooked then
		return
	end
	local g = GS()
	if not g then
		return
	end
	adoptionHooked = true
	local previous = g.OnAdoptionStateChanged
	g.OnAdoptionStateChanged = function(reason)
		if previous then
			pcall(previous, reason)
		end
		QueueRefresh()
	end
end

--- Shared officer-policy changes can grant or revoke edit rights without roster events.
local officerHooked = false
local function EnsureOfficerListener()
	if officerHooked or Page.__sfOfficerHook then
		return
	end
	local GO = SF.GuildOfficer
	if not GO or type(GO.RegisterUIListener) ~= "function" then
		return
	end
	officerHooked = true
	Page.__sfOfficerHook = true
	GO.RegisterUIListener(function()
		QueueRefresh()
	end)
end

function Page:Build(panel)
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer or not renderer.Build then
		self.panel = panel
		return
	end
	EnsureRosterListener()
	EnsureDurableListener()
	EnsureAdoptionListener()
	EnsureOfficerListener()
	BeginRenderPass()
	renderer:Build(panel, Definition())
	EndRenderPass()
	self.panel = panel
	if panel.HookScript and not panel.__sfGuildSuppliesTroubleshootingHook then
		panel.__sfGuildSuppliesTroubleshootingHook = true
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
	-- Do not cancel adoption or clear pending UI choices on hide; tab switches
	-- must not interrupt an in-progress transfer or drop selection state.
end

EnsureRosterListener()
EnsureDurableListener()
EnsureAdoptionListener()

SF.SettingsUI:RegisterPage(Page)
