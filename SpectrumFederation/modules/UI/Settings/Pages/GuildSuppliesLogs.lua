-- Guild Supplies → Logs (#453). Current-campaign contribution table.
-- Member-readable. Goals/progress live on Configuration. Archived history retained.
local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

local Page = {
	id = "guildSuppliesLogs",
	categoryId = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_LOGS_NAME", "Logs"),
	navLabel = Loc("GUILD_SUPPLIES_LOGS_NAV", "Logs"),
	contentHeading = Loc("GUILD_SUPPLIES_LOGS_HEADING", "Raid Supplies Logs"),
	group = "Raid Tools",
	description = Loc("GUILD_SUPPLIES_LOGS_DESC",
		"Review current-campaign donations and quantity adjustments."),
	order = 19.2,
	layout = {
		disablePageScroll = true,
	},
}

local function GS()
	return SF.GuildSupplies
end

-- Ephemeral filter / scroll identity only; never persisted.
local FILTER_ALL = false
local filterContributor = FILTER_ALL
local filterItemId = FILTER_ALL
local filterContextKey = nil
local cachedProjectedRows = nil
local cachedProjectionKey = nil
local refreshQueued = false
local rosterFrame = nil
local passCache = nil
local OpenEditContributorDialog

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
		caps = { canRead = false, reason = "not_ready" }
	else
		caps = g:GetCapabilities()
	end
	if passCache then
		passCache.caps = caps
	end
	return caps
end

local function CurrentRecord()
	if passCache and passCache.recordChecked then
		return passCache.record, passCache.recordReason
	end
	local g = GS()
	local record, reason
	if g and g.GetCurrentRecord then
		record, reason = g:GetCurrentRecord()
	else
		reason = "not_ready"
	end
	if passCache then
		passCache.recordChecked = true
		passCache.record = record
		passCache.recordReason = reason
	end
	return record, reason
end

--- Always the guild record's active campaign; follows rollover automatically (#453).
local function ActiveCampaignId()
	if not Caps().canRead then
		return nil
	end
	local record = CurrentRecord()
	if not record then
		return nil
	end
	local id = record.currentCampaignId
	if type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

local function FilterContextKey()
	local rec = CurrentRecord()
	if not rec then
		return "none"
	end
	return tostring(rec.datasetId or "") .. "|" .. tostring(rec.currentCampaignId or "")
end

local function SyncFilterContext()
	local key = FilterContextKey()
	if key == filterContextKey then
		return
	end
	filterContextKey = key
	filterContributor = FILTER_ALL
	filterItemId = FILTER_ALL
	cachedProjectedRows = nil
	cachedProjectionKey = nil
end

--- Scroll identity includes campaign/dataset plus active filters (#453).
local function ScrollContextKey()
	SyncFilterContext()
	return FilterContextKey()
		.. "|" .. tostring(filterContributor)
		.. "|" .. tostring(filterItemId)
end

local function DescribeItem(itemId)
	local display = SF.ItemDisplay
	if display and type(display.Describe) == "function" then
		return display.Describe(itemId)
	end
	return {
		itemId = itemId,
		status = "unknown",
		name = Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item"),
		icon = nil,
	}
end

local function ItemNameForHistory(itemId)
	local described = DescribeItem(itemId)
	if type(described.name) == "string" and described.name ~= "" then
		return described.name
	end
	return nil
end

--- One validated Guild Info record + name index per projection pass (#453).
-- Avoids calling GI:GetCurrentRecord (full validation) once per history row.
local function GuildClassLookup()
	if passCache and passCache.guildClassLookupChecked then
		return passCache.guildClassLookup
	end
	local lookup = {
		byGuid = nil,
		byName = nil,
		getCurrentRecordCalls = 0,
	}
	local GI = SF.GuildInfo
	if GI and type(GI.GetCurrentRecord) == "function" then
		lookup.getCurrentRecordCalls = lookup.getCurrentRecordCalls + 1
		local record = GI:GetCurrentRecord()
		if type(record) == "table" and type(record.characters) == "table" then
			lookup.byGuid = record.characters
			local byName = {}
			for _, row in pairs(record.characters) do
				if type(row) == "table"
					and type(row.nameRealm) == "string" and row.nameRealm ~= ""
					and type(row.classFile) == "string" and row.classFile ~= "" then
					byName[string.lower(row.nameRealm)] = row.classFile
				end
			end
			lookup.byName = byName
		end
	end
	if passCache then
		passCache.guildClassLookupChecked = true
		passCache.guildClassLookup = lookup
	end
	return lookup
end

local function LookupClassFile(guid, nameRealm)
	local lookup = GuildClassLookup()
	if type(guid) == "string" and guid ~= "" and type(lookup.byGuid) == "table" then
		local row = lookup.byGuid[guid]
		if type(row) == "table" and type(row.classFile) == "string" and row.classFile ~= "" then
			return row.classFile
		end
	end
	if type(nameRealm) == "string" and nameRealm ~= "" and type(lookup.byName) == "table" then
		return lookup.byName[string.lower(nameRealm)]
	end
	return nil
end

--- Color the displayed contributor identity (#453).
-- Class must belong to the same identity as the displayed name. Prefer the
-- resolved display name; allow a GUID fallback only when that GUID's character
-- row is the displayed name (never a linked alt's class for a main name).
local function ColorizeContributor(name, guid)
	if type(name) ~= "string" or name == "" then
		return name
	end
	local classFile = LookupClassFile(nil, name)
	if not classFile and type(guid) == "string" and guid ~= "" then
		local lookup = GuildClassLookup()
		local row = type(lookup.byGuid) == "table" and lookup.byGuid[guid] or nil
		if type(row) == "table"
			and type(row.nameRealm) == "string" and row.nameRealm ~= ""
			and string.lower(row.nameRealm) == string.lower(name)
			and type(row.classFile) == "string" and row.classFile ~= "" then
			classFile = row.classFile
		end
	end
	local GI = SF.GuildInfo
	if GI and type(GI.ColorizeName) == "function" then
		return GI.ColorizeName(name, classFile)
	end
	local C = SF.Consumables
	if C and type(C.ColorizeCharacterName) == "function" then
		return C.ColorizeCharacterName(name, classFile)
	end
	return name
end

local function ClassifyHistoryRow(row)
	if type(row) ~= "table" then
		return nil
	end
	local t = row.type
	-- #457: withdrawals must be explicit before the donation fallback.
	if t == "withdrawal" then
		return "withdrawal"
	end
	local GS = SF.GuildSupplies
	if GS and GS.LEDGER_EVENT and t == GS.LEDGER_EVENT.WITHDRAWAL then
		return "withdrawal"
	end
	if t == "adjustment" or t == "CONSUMABLE_ADJUSTMENT" then
		return "adjustment"
	end
	if t == "donation" or t == "CONSUMABLE_DONATION" then
		return "donation"
	end
	-- History projection only emits donation/adjustment/withdrawal rows; prefer
	-- attribution and verification hints when type is unexpectedly missing.
	if row.attributed ~= nil or row.displayAttributed ~= nil then
		return "adjustment"
	end
	if type(row.verification) == "string" then
		return "donation"
	end
	local qty = tonumber(row.quantity)
	if qty and qty < 0 then
		return "adjustment"
	end
	return "donation"
end

local function GoalRowIcon(described)
	if type(described) == "table" then
		local icon = described.icon
		if icon ~= nil and icon ~= false and icon ~= "" then
			return icon
		end
	end
	local display = SF.ItemDisplay
	if display and display.QUESTION_MARK then
		return display.QUESTION_MARK
	end
	return nil
end

local function FormatItemCell(itemId)
	local described = DescribeItem(itemId)
	local name = described.name or Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item")
	local g = GS()
	if g and g.FormatHistoryInlineIcon then
		local markup = g.FormatHistoryInlineIcon(GoalRowIcon(described))
		if type(markup) == "string" and markup ~= "" then
			return markup .. " " .. name
		end
	end
	return name
end

local function BuildProjectedRows()
	SyncFilterContext()
	local key = FilterContextKey()
	if cachedProjectedRows and cachedProjectionKey == key then
		return cachedProjectedRows
	end
	-- Own a render pass only when called outside Page Build/Refresh (tests).
	-- Nested BeginRenderPass would wipe the page's Caps/record cache mid-refresh.
	local ownedPass = false
	if not passCache then
		BeginRenderPass()
		ownedPass = true
	end
	local function finish(rows)
		cachedProjectedRows = rows
		cachedProjectionKey = key
		if ownedPass then
			EndRenderPass()
		end
		return rows
	end
	local rows = {}
	if not Caps().canRead then
		return finish(rows)
	end
	local campaignId = ActiveCampaignId()
	local g = GS()
	if not campaignId or not g or not g.ListCampaignHistory then
		return finish(rows)
	end
	-- No limit: every retained current-campaign entry must remain reachable (#453).
	local history = g:ListCampaignHistory(campaignId, nil, 0, ItemNameForHistory)
	if type(history) ~= "table" then
		return finish(rows)
	end
	local unassigned = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	local adjustPrefix = Loc("GUILD_SUPPLIES_LOGS_ADJUST_MARK", "Adjustment")
	local withdrawPrefix = Loc("GUILD_SUPPLIES_LOGS_WITHDRAW_MARK", "Withdrawal")
	-- Warm the pass-scoped guild class lookup once before coloring rows.
	GuildClassLookup()
	for i = 1, #history do
		local event = history[i]
		local kind = ClassifyHistoryRow(event)
		local contributorName
		local contributorGuid
		local quantityText
		if event.creditUnavailable then
			-- Reconstruction blocked: never restore durable donor/attributed (#459).
			contributorName = Loc("GUILD_SUPPLIES_HISTORY_CREDIT_UNAVAILABLE", "Credit unavailable")
			contributorGuid = nil
			if kind == "adjustment" then
				local qty = tonumber(event.quantity) or 0
				quantityText = Loc("GUILD_SUPPLIES_LOGS_QTY_SIGNED", "%+d"):format(qty)
			else
				local qty = math.abs(tonumber(event.quantity) or 0)
				quantityText = Loc("GUILD_SUPPLIES_LOGS_QTY_PLAIN", "%d"):format(qty)
			end
		elseif kind == "adjustment" then
			local hasCorrection = type(event.creditCorrection) == "table"
			local credited = event.displayAttributed
			if credited == nil and hasCorrection then
				credited = event.effectiveAttributed
			elseif credited == nil then
				credited = event.effectiveAttributed or event.attributed
			end
			if type(credited) == "string" and credited ~= "" then
				contributorName = credited
				-- Pair name with effective GUID only; never original attributed GUID
				-- when a correction cleared or changed identity (#459).
				contributorGuid = event.effectiveAttributedGuid
				if not hasCorrection then
					contributorGuid = event.effectiveAttributedGuid or event.attributedGuid
				end
			else
				-- Legitimate Unassigned while credit projection is available.
				contributorName = unassigned
				contributorGuid = nil
			end
			local qty = tonumber(event.quantity) or 0
			quantityText = Loc("GUILD_SUPPLIES_LOGS_QTY_SIGNED", "%+d"):format(qty)
		else
			local hasCorrection = type(event.creditCorrection) == "table"
			contributorName = event.displayActor
			if contributorName == nil and hasCorrection then
				contributorName = event.effectiveAttributed
			elseif contributorName == nil then
				contributorName = event.effectiveAttributed or event.actor
					or Loc("GUILD_SUPPLIES_HISTORY_SOMEONE", "Someone")
			end
			if hasCorrection then
				contributorGuid = event.effectiveAttributedGuid
			else
				contributorGuid = event.effectiveAttributedGuid
					or event.actorGuid or event.donorGuid
			end
			local qty = math.abs(tonumber(event.quantity) or 0)
			quantityText = Loc("GUILD_SUPPLIES_LOGS_QTY_PLAIN", "%d"):format(qty)
		end
		local contributorDisplay = ColorizeContributor(contributorName, contributorGuid)
		if kind == "adjustment" then
			contributorDisplay = Loc("GUILD_SUPPLIES_LOGS_ADJUST_CONTRIBUTOR", "%s · %s")
				:format(adjustPrefix, contributorDisplay)
		elseif kind == "withdrawal" then
			contributorDisplay = Loc("GUILD_SUPPLIES_LOGS_WITHDRAW_CONTRIBUTOR", "%s · %s")
				:format(withdrawPrefix, contributorDisplay)
		end
		local itemId = tonumber(event.itemId)
		local itemText = FormatItemCell(itemId)
		local detail = g.FormatCampaignHistoryDetail
			and g.FormatCampaignHistoryDetail(event, ItemNameForHistory(itemId))
		if kind == "adjustment" then
			local officer = event.actor
			if type(officer) == "string" and officer ~= "" then
				local officerLine = Loc("GUILD_SUPPLIES_LOGS_ADJUST_OFFICER",
					"Adjusted by %s."):format(officer)
				if type(detail) == "string" and detail ~= "" then
					detail = detail .. "\n" .. officerLine
				else
					detail = officerLine
				end
			end
		end
		-- Edit only production-credited current-campaign rows (#459).
		local record = CurrentRecord()
		local productionOk = event.gsProductionCredit == true
			or (event.uncredited ~= true and event.gsProductionCredit ~= false
				and type(event.creditCorrection) == "table")
		-- Prefer the explicit production flag when present.
		productionOk = event.gsProductionCredit == true
		local campaignOk = type(record) == "table"
			and type(record.currentCampaignId) == "string"
			and event.campaignId == record.currentCampaignId
		local canEdit = Caps().canEdit == true
			and type(event.id) == "string"
			and event.id ~= ""
			and productionOk
			and campaignOk
			and event.creditUnavailable ~= true
		local effectiveName = event.effectiveAttributed
		local effectiveGuid = event.effectiveAttributedGuid
		if kind == "donation" and effectiveName == nil and effectiveGuid == nil
			and type(event.creditCorrection) ~= "table" then
			effectiveName = event.actor
			effectiveGuid = event.actorGuid or event.donorGuid
		elseif kind == "adjustment" and effectiveName == nil and effectiveGuid == nil
			and type(event.creditCorrection) ~= "table" then
			effectiveName = event.attributed
			effectiveGuid = event.attributedGuid
		end
		-- Concrete character identity for edit prefill; display may be current-main.
		local concreteName = effectiveName
		if kind == "adjustment" and concreteName == nil and effectiveGuid == nil then
			concreteName = nil -- Unassigned
		end
		rows[#rows + 1] = {
			contributor = contributorDisplay,
			contributorKey = contributorName,
			quantity = quantityText,
			item = itemText,
			itemId = itemId,
			tooltip = detail,
			id = event.id,
			kind = kind,
			timestamp = event.timestamp,
			creditUnavailable = event.creditUnavailable == true or nil,
			showAction = canEdit,
			actionLabel = Loc("GUILD_SUPPLIES_LOGS_EDIT_ACTION", "Edit"),
			onAction = canEdit and OpenEditContributorDialog or nil,
			_eventKind = kind,
			_contributorName = contributorName,
			_effectiveName = concreteName,
			_effectiveGuid = effectiveGuid,
			_displayMain = contributorName,
			_quantityText = quantityText,
			_itemText = itemText,
			_gsProductionCredit = productionOk,
			_campaignId = event.campaignId,
		}
	end
	return finish(rows)
end

---------------------------------------------------------------------------
-- Officer Edit contributor (#459). Session-only dialog state; no chat output.
---------------------------------------------------------------------------

local EDIT_UNASSIGNED = false

local editRosterCache = {
	guildKey = nil,
	generation = nil,
	names = {},
	byLower = {},
	guidByLower = {},
}

-- Session-only editor state captured at open; never persisted (#459).
local editSession = nil
-- Confirmation binds to one immutable payload; selection/session changes bump
-- the token so a stale Confirm callback cannot commit a different edit (#459).
local confirmGeneration = 0
local pendingConfirm = nil

local function EditRosterGeneration()
	local GG = SF.GuildGossip
	if GG and GG.GetGuildGeneration then
		return tonumber(GG.GetGuildGeneration()) or 0
	end
	return 0
end

local function InvalidatePendingConfirm()
	confirmGeneration = confirmGeneration + 1
	pendingConfirm = nil
end

local function ClearEditSession()
	InvalidatePendingConfirm()
	-- Cancellation contract (#459): page/session replacement drops any in-flight
	-- authorized local save so timers cannot mutate after the editor left.
	do
		local g = GS()
		local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
		if g and g.CancelLocalContributorCorrectionSave and type(record) == "table" then
			g.CancelLocalContributorCorrectionSave(record, "session_cleared")
		end
	end
	editSession = nil
end

local function EnsureEditRosterCache()
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	local key = (ctx and ctx.guildKey) or "none"
	local gen = EditRosterGeneration()
	if editRosterCache.guildKey == key
		and editRosterCache.generation == gen
		and type(editRosterCache.names) == "table" then
		return editRosterCache
	end
	local names = {}
	local byLower = {}
	local guidByLower = {}
	if type(GetNumGuildMembers) == "function" and type(GetGuildRosterInfo) == "function" then
		-- GetNumGuildMembers returns several numbers. Keep only the first before
		-- tonumber; passing the rest makes Lua treat the second value as a base.
		local total = GetNumGuildMembers()
		total = tonumber(total) or 0
		if total < 0 then
			total = 0
		end
		for i = 1, total do
			-- Include offline members; GetGuildRosterInfo still returns them.
			local rosterName, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, rosterGuid =
				GetGuildRosterInfo(i)
			local norm = rosterName
			if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
				norm = SF.NameUtil.NormalizeNameRealm(rosterName) or rosterName
			end
			if type(norm) == "string" and norm ~= "" then
				local lower = string.lower(norm)
				if not byLower[lower] then
					byLower[lower] = norm
					names[#names + 1] = norm
					if type(rosterGuid) == "string" and rosterGuid ~= "" then
						guidByLower[lower] = rosterGuid
					end
				end
			end
		end
		table.sort(names)
	end
	editRosterCache.guildKey = key
	editRosterCache.generation = gen
	editRosterCache.names = names
	editRosterCache.byLower = byLower
	editRosterCache.guidByLower = guidByLower
	return editRosterCache
end

local function ResolveEditAttribution(text, allowUnassigned)
	local trimmed = tostring(text or ""):match("^%s*(.-)%s*$") or ""
	local unassigned = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	if trimmed == "" or string.lower(trimmed) == string.lower(unassigned) then
		if allowUnassigned then
			return nil, nil, true, nil
		end
		return nil, nil, false, "invalid_attribution"
	end
	local cache = EnsureEditRosterCache()
	local lower = string.lower(trimmed)
	local exact = cache.byLower[lower]
	if exact then
		return exact, cache.guidByLower[lower], true, nil
	end
	-- Short-name fallback only when the typed text omits a realm. A failed
	-- exact realm-qualified lookup must not resolve a different realm.
	local hasRealm = trimmed:find("-", 1, true) ~= nil
	if hasRealm then
		return nil, nil, false, "invalid_attribution"
	end
	local short = trimmed:match("^([^%-]+)") or trimmed
	local shortLower = string.lower(short)
	local unique = nil
	local uniqueGuid = nil
	local ambiguous = false
	for nameLower, norm in pairs(cache.byLower) do
		local rosterShort = (norm:match("^([^%-]+)") or norm)
		if string.lower(rosterShort) == shortLower then
			if unique and unique ~= norm then
				ambiguous = true
				break
			end
			unique = norm
			uniqueGuid = cache.guidByLower[nameLower]
		end
	end
	if unique and not ambiguous then
		return unique, uniqueGuid, true, nil
	end
	if ambiguous then
		return nil, nil, false, "ambiguous_character"
	end
	return nil, nil, false, "invalid_attribution"
end

local function EditAttributionSuggestions(prefix)
	if type(editSession) ~= "table" then
		return {}
	end
	local cache = EnsureEditRosterCache()
	local raw = tostring(prefix or "")
	local needle = string.lower((raw:match("^%s*(.-)%s*$") or ""))
	local out = {}
	local unassignedLabel = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	local maxSuggestions = 8
	if editSession.allowUnassigned then
		if needle == "" or string.find(string.lower(unassignedLabel), needle, 1, true) == 1 then
			out[#out + 1] = {
				value = EDIT_UNASSIGNED,
				label = unassignedLabel,
				text = "",
			}
		end
	end
	local names = cache.names or {}
	for i = 1, #names do
		if #out >= maxSuggestions then
			break
		end
		local name = names[i]
		if needle == "" or string.find(string.lower(name), needle, 1, true) == 1
			or string.find(string.lower(name:match("^([^%-]+)") or name), needle, 1, true) == 1 then
			out[#out + 1] = {
				value = name,
				label = name,
				text = name,
			}
		end
	end
	-- Keep a previously resolved credit visible through temporary roster lag.
	if editSession.attributionResolved
		and type(editSession.attributed) == "string"
		and editSession.attributed ~= "" then
		local lowerSel = string.lower(editSession.attributed)
		local present = false
		for i = 1, #out do
			if type(out[i].value) == "string" and string.lower(out[i].value) == lowerSel then
				present = true
				break
			end
		end
		if not present and (needle == "" or string.find(lowerSel, needle, 1, true) == 1) then
			out[#out + 1] = {
				value = editSession.attributed,
				label = editSession.attributed,
				text = editSession.attributed,
			}
		end
	end
	return out
end

--- Cancel an in-flight authorized local save when the visible recipient changes
-- away from the confirmed intent (#459 C5). Never let pendingLocalOp commit a
-- different recipient than the editor currently displays.
local function CancelPendingLocalSaveOnRecipientChange()
	if type(editSession) ~= "table" or editSession.pendingLocal ~= true then
		return
	end
	local g = GS()
	local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	if g and g.CancelLocalContributorCorrectionSave and type(record) == "table" then
		g.CancelLocalContributorCorrectionSave(record, "recipient_changed")
	end
	editSession.pendingLocalOp = nil
	editSession.pendingLocal = nil
end

local SetEditAttributionFromText
local function ApplyEditAttributionSuggestion(item)
	if type(editSession) ~= "table" then
		return
	end
	InvalidatePendingConfirm()
	if not item then
		CancelPendingLocalSaveOnRecipientChange()
		editSession.attributionResolved = false
		return
	end
	if item.value == EDIT_UNASSIGNED or item.value == nil then
		if editSession.allowUnassigned then
			if editSession.attributed ~= nil or editSession.attributedGuid ~= nil then
				CancelPendingLocalSaveOnRecipientChange()
			end
			editSession.attributed = nil
			editSession.attributedGuid = nil
			editSession.attributionText = ""
			editSession.attributionResolved = true
		else
			CancelPendingLocalSaveOnRecipientChange()
			editSession.attributionResolved = false
		end
		return
	end
	if type(item.value) == "string" and item.value ~= "" then
		local cache = EnsureEditRosterCache()
		local newGuid = cache.guidByLower[string.lower(item.value)]
		local g = GS()
		local changed = true
		if g and g.CreditIdentitiesEqual then
			changed = not g.CreditIdentitiesEqual(
				editSession.attributed, editSession.attributedGuid,
				item.value, newGuid)
		else
			changed = editSession.attributed ~= item.value
				or editSession.attributedGuid ~= newGuid
		end
		if changed then
			CancelPendingLocalSaveOnRecipientChange()
		end
		editSession.attributed = item.value
		editSession.attributedGuid = newGuid
		editSession.attributionText = item.text or item.label or item.value
		editSession.attributionResolved = true
		return
	end
	SetEditAttributionFromText(item.text or item.label or "")
end

SetEditAttributionFromText = function(v)
	if type(editSession) ~= "table" then
		return
	end
	-- Changing the reviewed recipient invalidates any open confirmation.
	InvalidatePendingConfirm()
	local text = tostring(v or "")
	editSession.attributionText = text
	local name, guid, ok = ResolveEditAttribution(text, editSession.allowUnassigned)
	if ok then
		local priorName = editSession.attributed
		local priorGuid = editSession.attributedGuid
		local g = GS()
		local changed = true
		if g and g.CreditIdentitiesEqual then
			changed = not g.CreditIdentitiesEqual(priorName, priorGuid, name, guid)
		else
			changed = priorName ~= name or priorGuid ~= guid
		end
		if changed then
			CancelPendingLocalSaveOnRecipientChange()
		end
		editSession.attributed = name
		editSession.attributedGuid = guid
		editSession.attributionResolved = true
		return
	end
	-- Preserve prior resolved selection when the typed text still matches it.
	if editSession.attributionResolved
		and type(editSession.attributed) == "string"
		and editSession.attributed ~= ""
		and string.lower(text:match("^%s*(.-)%s*$") or "") == string.lower(editSession.attributed) then
		return
	end
	-- Unresolved typed text is also a visible recipient change away from the
	-- confirmed pending intent.
	CancelPendingLocalSaveOnRecipientChange()
	editSession.attributionResolved = false
end

local function ReportLogsStatus(status, reason)
	local panel = Page.panel
	local section = panel and panel.__sfPrimarySection
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
	if section and section.SetMessage then
		section:SetMessage(message, severity)
	end
	cachedProjectedRows = nil
	cachedProjectionKey = nil
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
end

local function EditSessionStillFresh(session)
	if type(session) ~= "table" then
		return false, "stale_credit"
	end
	local g = GS()
	if not g then
		return false, "api_unavailable"
	end
	local ctx = g.GetCurrentContext and g:GetCurrentContext() or nil
	if not ctx or ctx.guildKey ~= session.guildKey then
		return false, "stale_guild"
	end
	local record = g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	if type(record) ~= "table" then
		return false, "not_configured"
	end
	if record.datasetId ~= session.datasetId then
		return false, "dataset_mismatch"
	end
	if record.currentCampaignId ~= session.campaignId then
		return false, "stale_campaign"
	end
	local event = g.FindLedgerEventById and g.FindLedgerEventById(record, session.eventId)
	if not event then
		return false, "missing_event"
	end
	local curName, curGuid, _, creditStatus = nil, nil, nil, nil
	if g.ResolveEffectiveCreditIdentity then
		curName, curGuid, _, creditStatus = g.ResolveEffectiveCreditIdentity(record, event)
	end
	if creditStatus == (g.CREDIT_UNAVAILABLE or "credit_unavailable") then
		return false, "credit_unavailable"
	end
	-- Genuine Unassigned (nil==nil) stays fresh; unavailable must not look Unassigned.
	if g.CreditIdentitiesEqual
		and not g.CreditIdentitiesEqual(
			curName, curGuid, session.effectiveName, session.effectiveGuid) then
		return false, "stale_credit"
	end
	local tKey = g.CorrectionTargetKey and g.CorrectionTargetKey(record, event.id)
		or (g.ComputeTargetKey
			and g.ComputeTargetKey(g.KIND and g.KIND.CORRECT_CONTRIBUTOR, event.id))
	local headId = tKey and record.operations and record.operations.heads
		and record.operations.heads[tKey]
	local expected = session.baseTargetRevision
	local noPriorHead = expected == nil or expected == record.datasetId
	if noPriorHead then
		if headId ~= nil then
			return false, "stale_credit"
		end
	elseif expected ~= headId then
		return false, "stale_credit"
	end
	return true, nil, record, event
end

--- Commit one immutable confirmation payload (not the live mutable session).
local function CommitCapturedEdit(payload)
	if Caps().canEdit ~= true then
		ReportLogsStatus("rejected", "unauthorized")
		ClearEditSession()
		return
	end
	if type(payload) ~= "table" then
		ReportLogsStatus("rejected", "stale_credit")
		return
	end
	-- Stale Confirm callbacks must not apply after selection/session change.
	if pendingConfirm ~= payload
		or payload.confirmGeneration ~= confirmGeneration then
		ReportLogsStatus("rejected", "stale_credit")
		return
	end
	if not payload.attributionResolved then
		ReportLogsStatus("rejected", "invalid_attribution")
		return
	end
	local fresh, reason = EditSessionStillFresh(payload)
	if not fresh then
		ClearEditSession()
		ReportLogsStatus("rejected", reason or "stale_credit")
		return
	end
	-- Live session must still describe the same reviewed entry/recipient.
	local session = editSession
	if type(session) ~= "table"
		or session.eventId ~= payload.eventId
		or session.datasetId ~= payload.datasetId
		or session.campaignId ~= payload.campaignId
		or session.guildKey ~= payload.guildKey
		or session.baseTargetRevision ~= payload.baseTargetRevision then
		ClearEditSession()
		ReportLogsStatus("rejected", "stale_credit")
		return
	end
	local g = GS()
	if g and g.CreditIdentitiesEqual then
		if not g.CreditIdentitiesEqual(
			session.attributed, session.attributedGuid,
			payload.attributed, payload.attributedGuid) then
			ClearEditSession()
			ReportLogsStatus("rejected", "stale_credit")
			return
		end
	elseif session.attributed ~= payload.attributed
		or session.attributedGuid ~= payload.attributedGuid then
		ClearEditSession()
		ReportLogsStatus("rejected", "stale_credit")
		return
	end
	if not g or not g.NewContributorCorrectionOperation then
		ReportLogsStatus("rejected", "unsupported_kind")
		return
	end
	-- Retain ONE immutable authorized local save identity across work_budget
	-- slices (#459 / discussion_r4480434323). Do not mint a new operation id.
	local op = session.pendingLocalOp
	if type(op) ~= "table" then
		local status, prepReason
		op, status, prepReason = g:NewContributorCorrectionOperation(
			payload.eventId, payload.attributed, payload.attributedGuid)
		if not op then
			ClearEditSession()
			ReportLogsStatus(status or "rejected", prepReason or "invalid_value")
			return
		end
	end
	-- Reconfirm open-time revision still matches prepare-time head.
	if op.baseTargetRevision ~= payload.baseTargetRevision then
		ClearEditSession()
		ReportLogsStatus("rejected", "stale_credit")
		return
	end
	local applyStatus, applyReason = g:ApplyStagedConfigOperation(op)
	if applyStatus == "pending" and applyReason == "work_budget" then
		-- Keep truthful pending UI; timers complete through the local resume path.
		session.pendingLocalOp = op
		session.pendingLocal = true
		InvalidatePendingConfirm()
		ReportLogsStatus(applyStatus, applyReason)
		return
	end
	-- Soft-clear session without cancelling an already-accepted local save.
	InvalidatePendingConfirm()
	editSession = nil
	ReportLogsStatus(applyStatus, applyReason)
end

local function CommitEditSession()
	local session = editSession
	if type(session) ~= "table" then
		ReportLogsStatus("rejected", "stale_credit")
		return
	end
	-- Immediate commit (no dialog): capture the current session as the payload.
	InvalidatePendingConfirm()
	local payload = {
		confirmGeneration = confirmGeneration,
		eventId = session.eventId,
		kind = session.kind,
		allowUnassigned = session.allowUnassigned,
		effectiveName = session.effectiveName,
		effectiveGuid = session.effectiveGuid,
		baseTargetRevision = session.baseTargetRevision,
		guildKey = session.guildKey,
		datasetId = session.datasetId,
		campaignId = session.campaignId,
		quantityText = session.quantityText,
		itemText = session.itemText,
		attributed = session.attributed,
		attributedGuid = session.attributedGuid,
		attributionResolved = session.attributionResolved,
	}
	pendingConfirm = payload
	CommitCapturedEdit(payload)
end

OpenEditContributorDialog = function(eventId, rowData)
	if Caps().canEdit ~= true then
		ReportLogsStatus("rejected", "unauthorized")
		return
	end
	if type(eventId) ~= "string" or eventId == "" then
		ReportLogsStatus("rejected", "missing_event")
		return
	end
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
	if not ctx or type(record) ~= "table" then
		ReportLogsStatus("rejected", "not_ready")
		return
	end
	local event = g.FindLedgerEventById and g.FindLedgerEventById(record, eventId)
	if not event then
		ReportLogsStatus("rejected", "missing_event")
		return
	end
	if event.gsProductionCredit ~= true then
		ReportLogsStatus("rejected", "not_credited")
		return
	end
	if event.campaignId ~= record.currentCampaignId then
		ReportLogsStatus("rejected", "stale_campaign")
		return
	end
	local kind = rowData and rowData._eventKind or rowData and rowData.kind
	if kind ~= "donation" and kind ~= "adjustment" then
		if event.type == (g.LEDGER_EVENT and g.LEDGER_EVENT.ADJUSTMENT) or event.type == "CONSUMABLE_ADJUSTMENT" then
			kind = "adjustment"
		else
			kind = "donation"
		end
	end
	local allowUnassigned = kind == "adjustment"
	local effectiveName, effectiveGuid, _, creditStatus = nil, nil, nil, nil
	if g.ResolveEffectiveCreditIdentity then
		effectiveName, effectiveGuid, _, creditStatus = g.ResolveEffectiveCreditIdentity(record, event)
	end
	if creditStatus == (g.CREDIT_UNAVAILABLE or "credit_unavailable") then
		ClearEditSession()
		ReportLogsStatus("rejected", "credit_unavailable")
		return
	end
	local tKey = g.CorrectionTargetKey and g.CorrectionTargetKey(record, event.id)
		or (g.ComputeTargetKey
			and g.ComputeTargetKey(g.KIND and g.KIND.CORRECT_CONTRIBUTOR, event.id))
	local headRev = tKey and record.operations and record.operations.heads
		and record.operations.heads[tKey] or nil
	-- Match CurrentTargetRevision: datasetId stands in when no correction head.
	local baseRev = headRev or record.datasetId
	local prefill = effectiveName
	local prefillGuid = effectiveGuid
	local unassigned = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	-- Opening another entry invalidates confirmation and any resumable local save.
	ClearEditSession()
	editSession = {
		eventId = event.id,
		kind = kind,
		allowUnassigned = allowUnassigned,
		effectiveName = effectiveName,
		effectiveGuid = effectiveGuid,
		displayMain = (rowData and rowData._displayMain) or effectiveName or unassigned,
		baseTargetRevision = baseRev,
		guildKey = ctx.guildKey,
		datasetId = record.datasetId,
		campaignId = record.currentCampaignId,
		quantityText = (rowData and rowData._quantityText) or tostring(event.quantity or ""),
		itemText = (rowData and rowData._itemText) or "",
		attributed = prefill,
		attributedGuid = prefillGuid,
		attributionText = prefill or "",
		attributionResolved = true,
	}
	EnsureEditRosterCache()
	cachedProjectedRows = nil
	cachedProjectionKey = nil
	if Page.Refresh and Page.panel then
		Page:Refresh(Page.panel)
	end
end

local function ConfirmAndSaveEdit()
	if Caps().canEdit ~= true then
		ReportLogsStatus("rejected", "unauthorized")
		return
	end
	local session = editSession
	if type(session) ~= "table" then
		ReportLogsStatus("rejected", "stale_credit")
		return
	end
	if not session.attributionResolved then
		ReportLogsStatus("rejected", "invalid_attribution")
		return
	end
	local fresh, reason = EditSessionStillFresh(session)
	if not fresh then
		ClearEditSession()
		ReportLogsStatus("rejected", reason or "stale_credit")
		return
	end
	-- Freeze the reviewed recipient/entry before the confirm dialog opens.
	InvalidatePendingConfirm()
	local payload = {
		confirmGeneration = confirmGeneration,
		eventId = session.eventId,
		kind = session.kind,
		allowUnassigned = session.allowUnassigned,
		effectiveName = session.effectiveName,
		effectiveGuid = session.effectiveGuid,
		baseTargetRevision = session.baseTargetRevision,
		guildKey = session.guildKey,
		datasetId = session.datasetId,
		campaignId = session.campaignId,
		quantityText = session.quantityText,
		itemText = session.itemText,
		attributed = session.attributed,
		attributedGuid = session.attributedGuid,
		attributionResolved = session.attributionResolved,
	}
	pendingConfirm = payload
	local Dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
	if not Dialogs or not Dialogs.Confirm then
		-- Fall back to immediate save when dialogs are unavailable (tests).
		CommitCapturedEdit(payload)
		return
	end
	local newLabel = payload.attributed
		or Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	local current = payload.effectiveName
		or Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	local confirm = Loc("GUILD_SUPPLIES_LOGS_EDIT_CONFIRM",
		"Move contribution credit for %s × %s\nfrom %s\nto %s?\nItem, quantity, and original evidence stay unchanged.")
		:format(
			tostring(payload.quantityText),
			tostring(payload.itemText),
			tostring(current),
			tostring(newLabel))
	Dialogs:Confirm(confirm, Loc("GUILD_SUPPLIES_LOGS_EDIT_SAVE", "Save correction"), function()
		CommitCapturedEdit(payload)
	end)
end

local function FilteredRows()
	local all = BuildProjectedRows()
	local out = {}
	for i = 1, #all do
		local row = all[i]
		if (filterContributor == FILTER_ALL or row.contributorKey == filterContributor)
			and (filterItemId == FILTER_ALL or row.itemId == filterItemId) then
			out[#out + 1] = row
		end
	end
	return out
end

local function ContributorFilterOptions()
	SyncFilterContext()
	local opts = {
		{
			value = FILTER_ALL,
			label = Loc("GUILD_SUPPLIES_LOGS_FILTER_ALL_CONTRIBUTORS", "All contributors"),
		},
	}
	if not Caps().canRead then
		return opts
	end
	local seen = {}
	local names = {}
	local rows = BuildProjectedRows()
	for i = 1, #rows do
		local key = rows[i].contributorKey
		if type(key) == "string" and key ~= "" and not seen[key] then
			seen[key] = true
			names[#names + 1] = key
		end
	end
	table.sort(names)
	for i = 1, #names do
		opts[#opts + 1] = { value = names[i], label = names[i] }
	end
	return opts
end

local function ItemFilterOptions()
	SyncFilterContext()
	local opts = {
		{
			value = FILTER_ALL,
			label = Loc("GUILD_SUPPLIES_LOGS_FILTER_ALL_ITEMS", "All items"),
		},
	}
	if not Caps().canRead then
		return opts
	end
	local seen = {}
	local items = {}
	local rows = BuildProjectedRows()
	for i = 1, #rows do
		local itemId = tonumber(rows[i].itemId)
		if itemId and not seen[itemId] then
			seen[itemId] = true
			items[#items + 1] = itemId
		end
	end
	table.sort(items)
	-- Distinct IDs can share a display name or unresolved placeholder; keep the
	-- filter value as itemId and disambiguate via localized ID tooltip (#453).
	local nameCounts = {}
	local labels = {}
	for i = 1, #items do
		local itemId = items[i]
		local described = DescribeItem(itemId)
		local name = described.name
		if type(name) ~= "string" or name == "" then
			name = Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item")
		end
		labels[itemId] = name
		nameCounts[name] = (nameCounts[name] or 0) + 1
	end
	for i = 1, #items do
		local itemId = items[i]
		local name = labels[itemId]
		local label = name
		if nameCounts[name] > 1 then
			label = Loc("GUILD_SUPPLIES_LOGS_FILTER_ITEM_LABEL_ID", "%s (%d)")
				:format(name, itemId)
		end
		opts[#opts + 1] = {
			value = itemId,
			label = label,
			tooltip = Loc("GUILD_SUPPLIES_LOGS_FILTER_ITEM_ID_TIP", "Item ID: %d")
				:format(itemId),
		}
	end
	return opts
end

local function EmptyLogsText()
	if not Caps().canRead then
		return Loc("GUILD_SUPPLIES_LOGS_NO_READ",
			"Join a guild with a verified membership to inspect Guild Supplies logs.")
	end
	if not ActiveCampaignId() then
		return Loc("GUILD_SUPPLIES_LOGS_EMPTY_NO_CAMPAIGN",
			"No current campaign is available yet.")
	end
	local all = BuildProjectedRows()
	if #all == 0 then
		return Loc("GUILD_SUPPLIES_LOGS_EMPTY_HISTORY",
			"No donations or adjustments are recorded for the current campaign yet.")
	end
	return Loc("GUILD_SUPPLIES_LOGS_EMPTY_FILTERED",
		"No logs match the selected contributor and item filters.")
end

local function Definition()
	return {
		sections = {
			{
				id = "gsLogsTable",
				title = Loc("GUILD_SUPPLIES_LOGS_TITLE", "Campaign history"),
				fillHeight = true,
				items = {
					{
						type = "inlineControls",
						spacing = 10,
						items = {
							{
								type = "dropdown",
								tooltip = Loc("GUILD_SUPPLIES_LOGS_FILTER_CONTRIBUTOR_TIP",
									"Show only entries for one contributor. Applies together with the item filter."),
								defaultText = Loc("GUILD_SUPPLIES_LOGS_FILTER_ALL_CONTRIBUTORS", "All contributors"),
								width = 200,
								options = ContributorFilterOptions,
								get = function()
									SyncFilterContext()
									return filterContributor
								end,
								set = function(value)
									SyncFilterContext()
									filterContributor = value
								end,
								enabled = function()
									return Caps().canRead
								end,
								onValueChanged = function()
									if Page.Refresh and Page.panel then
										Page:Refresh(Page.panel)
									end
								end,
							},
							{
								type = "dropdown",
								tooltip = Loc("GUILD_SUPPLIES_LOGS_FILTER_ITEM_TIP",
									"Show only entries for one item, including items later removed from Requested Items."),
								defaultText = Loc("GUILD_SUPPLIES_LOGS_FILTER_ALL_ITEMS", "All items"),
								width = 200,
								options = ItemFilterOptions,
								get = function()
									SyncFilterContext()
									return filterItemId
								end,
								set = function(value)
									SyncFilterContext()
									filterItemId = value
								end,
								enabled = function()
									return Caps().canRead
								end,
								onValueChanged = function()
									if Page.Refresh and Page.panel then
										Page:Refresh(Page.panel)
									end
								end,
							},
							{
								type = "button",
								buttonText = Loc("GUILD_SUPPLIES_LOGS_FILTER_CLEAR", "Clear"),
								tooltip = Loc("GUILD_SUPPLIES_LOGS_FILTER_CLEAR_TIP",
									"Clear contributor and item filters."),
								width = 90,
								onClick = function()
									SyncFilterContext()
									filterContributor = FILTER_ALL
									filterItemId = FILTER_ALL
									if Page.Refresh and Page.panel then
										Page:Refresh(Page.panel)
									end
								end,
							},
						},
					},
					{
						type = "autocomplete",
						label = Loc("GUILD_SUPPLIES_LOGS_EDIT_LABEL", "Edit contributor"),
						adminOnly = true,
						width = 220,
						maxLetters = 96,
						maxSuggestions = 8,
						visible = function()
							return type(editSession) == "table"
						end,
						hint = Loc("GUILD_SUPPLIES_LOGS_EDIT_HINT",
							"Search guild roster (offline included). Unchanged selection saves nothing."),
						enabled = function()
							return Caps().canEdit == true and type(editSession) == "table"
						end,
						get = function()
							if type(editSession) ~= "table" then
								return ""
							end
							if type(editSession.attributionText) == "string" then
								return editSession.attributionText
							end
							return editSession.attributed or ""
						end,
						set = function(v)
							SetEditAttributionFromText(v)
							if Page.Refresh and Page.panel then
								Page:Refresh(Page.panel)
							end
						end,
						getSuggestions = function(_, prefix)
							return EditAttributionSuggestions(prefix)
						end,
						onResolved = function(_, item)
							-- Typing notifies nil before set. Do not refresh here:
							-- get() still has the prior draft and would rewrite the
							-- edit mid-keystroke (#459 discussion_r4496331290).
							-- set refreshes after the draft catches up (Manage pattern).
							if not item then
								ApplyEditAttributionSuggestion(nil)
								return
							end
							ApplyEditAttributionSuggestion(item)
							if Page.Refresh and Page.panel then
								Page:Refresh(Page.panel)
							end
						end,
					},
					{
						type = "buttonRow",
						adminOnly = true,
						visible = function()
							return type(editSession) == "table"
						end,
						{
							text = Loc("GUILD_SUPPLIES_LOGS_EDIT_CONTINUE", "Continue"),
							width = 100,
							enabled = function()
								return Caps().canEdit == true
									and type(editSession) == "table"
									and editSession.attributionResolved == true
							end,
							onClick = function()
								ConfirmAndSaveEdit()
							end,
						},
						{
							text = Loc("GUILD_SUPPLIES_LOGS_EDIT_CANCEL", "Cancel"),
							width = 90,
							onClick = function()
								ClearEditSession()
								cachedProjectedRows = nil
								cachedProjectionKey = nil
								if Page.Refresh and Page.panel then
									Page:Refresh(Page.panel)
								end
							end,
						},
					},
					{
						type = "logTable",
						fillHeight = true,
						minHeight = 280,
						rowHeight = 22,
						virtualize = true,
						columns = {
							{
								key = "contributor",
								label = Loc("GUILD_SUPPLIES_LOGS_COL_CONTRIBUTOR", "Contributor"),
								width = 180,
							},
							{
								key = "quantity",
								label = Loc("GUILD_SUPPLIES_LOGS_COL_QUANTITY", "Quantity"),
								width = 80,
								justifyH = "RIGHT",
							},
							{
								key = "item",
								label = Loc("GUILD_SUPPLIES_LOGS_COL_ITEM", "Item"),
							},
							{
								key = "editAction",
								kind = "action",
								label = Loc("GUILD_SUPPLIES_LOGS_COL_EDIT", "Edit"),
								width = 70,
							},
						},
						emptyText = EmptyLogsText,
						getScrollContextKey = ScrollContextKey,
						getRows = function()
							if not Caps().canRead then
								return {}
							end
							return FilteredRows()
						end,
					},
				},
			},
		},
	}
end

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

local function MaybeStartValuationCatchup(panel)
	if not PanelVisible(panel) then
		return
	end
	local supplies = GS()
	if supplies and supplies.StartValuationCatchup then
		supplies.StartValuationCatchup("logs-show")
	end
end

local function CancelValuationCatchup()
	local supplies = GS()
	if supplies and supplies.CancelValuationCatchup then
		supplies.CancelValuationCatchup("logs-hide")
	end
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

local function EnsureItemDisplayListener()
	local display = SF.ItemDisplay
	if not display or type(display.RegisterRefresh) ~= "function" then
		return
	end
	display.RegisterRefresh("guildSuppliesLogs", function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		QueueRefresh()
	end)
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
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		QueueRefresh()
	end)
end

local durableListenerRegistered = false
local function EnsureDurableListener()
	if durableListenerRegistered then
		return
	end
	local supplies = SF.GuildSupplies
	if not supplies or type(supplies.RegisterUIListener) ~= "function" then
		return
	end
	supplies.RegisterUIListener(function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		-- Reconcile resumable local save UI with GS retain / accepted storage.
		if type(editSession) == "table" and editSession.pendingLocal
			and type(editSession.pendingLocalOp) == "table" then
			local g = GS()
			local record = g and g.GetCurrentRecord and select(1, g:GetCurrentRecord()) or nil
			local opId = editSession.pendingLocalOp.id
			local retained = g and g.GetLocalContributorCorrectionSave
				and g.GetLocalContributorCorrectionSave(record)
			local accepted = type(record) == "table"
				and record.operations and record.operations.records
				and record.operations.records[opId]
			if accepted then
				InvalidatePendingConfirm()
				editSession = nil
				ReportLogsStatus("accepted")
			elseif retained == nil then
				InvalidatePendingConfirm()
				editSession = nil
				ReportLogsStatus("rejected", "stale_credit")
			end
		end
		QueueRefresh()
	end)
	durableListenerRegistered = true
end

function Page:Build(panel)
	EnsureRosterListener()
	EnsureDurableListener()
	EnsureItemDisplayListener()
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer or not renderer.Build then
		self.panel = panel
		return
	end
	BeginRenderPass()
	SyncFilterContext()
	cachedProjectedRows = nil
	renderer:Build(panel, Definition())
	EndRenderPass()
	self.panel = panel
	if panel.HookScript and not panel.__sfGuildSuppliesLogsHook then
		panel.__sfGuildSuppliesLogsHook = true
		panel:HookScript("OnShow", function()
			QueueRefresh()
			MaybeStartValuationCatchup(panel)
		end)
		panel:HookScript("OnHide", function()
			CancelValuationCatchup()
			-- Page leave cancels any in-flight authorized local save (#459).
			ClearEditSession()
		end)
	end
	MaybeStartValuationCatchup(panel)
end

function Page:Refresh(panel)
	panel = panel or self.panel
	if not PanelVisible(panel) then
		return
	end
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if renderer and renderer.Refresh then
		BeginRenderPass()
		SyncFilterContext()
		-- Rebuild projection when refresh is requested; durable hooks clear the cache.
		renderer:Refresh(panel)
		EndRenderPass()
	end
end

function Page:OnHide()
	refreshQueued = false
	cachedProjectedRows = nil
	cachedProjectionKey = nil
	ClearEditSession()
	CancelValuationCatchup()
end

-- Test hooks for behavioral coverage (#453).
Page.__sfTest = {
	ActiveCampaignId = function()
		return ActiveCampaignId()
	end,
	BuildProjectedRows = function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		return BuildProjectedRows()
	end,
	FilteredRows = function()
		return FilteredRows()
	end,
	SetFilters = function(contributor, itemId)
		SyncFilterContext()
		filterContributor = contributor == nil and FILTER_ALL or contributor
		filterItemId = itemId == nil and FILTER_ALL or itemId
	end,
	ClearFilters = function()
		SyncFilterContext()
		filterContributor = FILTER_ALL
		filterItemId = FILTER_ALL
	end,
	FilterAll = FILTER_ALL,
	SyncFilterContext = SyncFilterContext,
	ClassifyHistoryRow = ClassifyHistoryRow,
	ScrollContextKey = ScrollContextKey,
	EmptyLogsText = EmptyLogsText,
	ItemFilterOptions = ItemFilterOptions,
	--- Project rows and return (rows, guildInfoGetCurrentRecordCalls) for #453.
	ProjectWithGuildLookupStats = function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
		BeginRenderPass()
		local rows = BuildProjectedRows()
		local lookup = passCache and passCache.guildClassLookup
		local calls = lookup and tonumber(lookup.getCurrentRecordCalls) or 0
		EndRenderPass()
		return rows, calls
	end,
	OpenEditContributorDialog = OpenEditContributorDialog,
	ResolveEditAttribution = ResolveEditAttribution,
	GetEditSession = function()
		return editSession
	end,
	GetPendingConfirm = function()
		return pendingConfirm
	end,
	ClearEditSession = ClearEditSession,
	InvalidatePendingConfirm = InvalidatePendingConfirm,
	CommitEditSession = CommitEditSession,
	CommitCapturedEdit = CommitCapturedEdit,
	ConfirmAndSaveEdit = ConfirmAndSaveEdit,
	EnsureEditRosterCache = EnsureEditRosterCache,
	SetEditAttributionFromText = SetEditAttributionFromText,
	EditAttributionSuggestions = EditAttributionSuggestions,
	--- Apply an autocomplete suggestion through the real onResolved path (#459 C5).
	ResolveEditAttributionSuggestion = ApplyEditAttributionSuggestion,
	--- Production onResolved(nil) only — must not refresh (#459 4496331290).
	NotifyEditAttributionResolvedNil = function()
		ApplyEditAttributionSuggestion(nil)
	end,
	--- Production AddAutocomplete OnTextChanged order: onResolved(nil) then set
	-- (refresh only from set). Used to regress mid-keystroke draft restore
	-- (#459 discussion_r4496331290).
	SimulateEditAttributionTextChanged = function(text)
		ApplyEditAttributionSuggestion(nil)
		SetEditAttributionFromText(text)
		if Page.Refresh and Page.panel then
			Page:Refresh(Page.panel)
		end
	end,
	--- Production suggestion selection: onResolved(item) then refresh.
	SimulateEditAttributionSuggestionResolved = function(item)
		ApplyEditAttributionSuggestion(item)
		if Page.Refresh and Page.panel then
			Page:Refresh(Page.panel)
		end
	end,
	--- Peek the page projection cache without rebuilding (#459 B4).
	PeekCachedProjectedRows = function()
		return cachedProjectedRows, cachedProjectionKey
	end,
	ClearProjectedRowCache = function()
		cachedProjectedRows = nil
		cachedProjectionKey = nil
	end,
}

EnsureRosterListener()
EnsureDurableListener()
EnsureItemDisplayListener()

SF.SettingsUI:RegisterPage(Page)
