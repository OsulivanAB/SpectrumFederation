-- Guild Supplies → Manage (#453). Officer-only requested items and quantity adjustments.
-- Campaign setup, bank tab, and personal preferences stay on Configuration.
local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

local Page = {
	id = "guildSuppliesManage",
	categoryId = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_MANAGE_NAME", "Manage"),
	navLabel = Loc("GUILD_SUPPLIES_MANAGE_NAV", "Manage"),
	contentHeading = Loc("GUILD_SUPPLIES_MANAGE_HEADING", "Raid Supplies Manage"),
	group = "Raid Tools",
	description = Loc("GUILD_SUPPLIES_MANAGE_DESC",
		"Officer tools for requested items and quantity adjustments."),
	order = 19.15,
	-- Shared officer threshold via Guild Supplies canEdit (Preview as Non-Admin
	-- and unknown policy fail closed). Tabs/search/direct nav all consult this.
	available = function()
		local g = SF.GuildSupplies
		if not g or type(g.GetCapabilities) ~= "function" then
			return false
		end
		local caps = g:GetCapabilities()
		return type(caps) == "table" and caps.canEdit == true
	end,
}

local function GS()
	return SF.GuildSupplies
end

-- Per build/refresh pass only: reuse validated read context across controls.
local passCache = nil

local function BeginRenderPass()
	passCache = {}
end

local function EndRenderPass()
	passCache = nil
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

--- True only for first-time setup (no dataset). Permission-only nil records are recovery.
local function IsNotConfigured()
	local _, reason = CurrentRecord()
	return reason == "not_configured"
end

local function CurrentGuildKey()
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	if ctx and type(ctx.guildKey) == "string" and ctx.guildKey ~= "" then
		return ctx.guildKey
	end
	return nil
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

--- True only for first-time setup (no dataset). Permission-only nil records are recovery.
local function IsNotConfigured()
	local _, reason = CurrentRecord()
	return reason == "not_configured"
end

local function CurrentBankTab()
	if not Caps().canRead then
		return nil
	end
	local rec = CurrentRecord()
	local tab = rec and rec.accounting and rec.accounting._consumables
		and rec.accounting._consumables.bankTab
	return tab ~= nil and tonumber(tab) or nil
end

local function CurrentGuildKey()
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext() or nil
	if ctx and type(ctx.guildKey) == "string" and ctx.guildKey ~= "" then
		return ctx.guildKey
	end
	return nil
end

local function ClearBankTabCatalog()
	bankTabCatalog.guildKey = nil
	bankTabCatalog.loaded = false
	bankTabCatalog.entries = {}
end

--- Drop catalog entries when the player changes guilds.
local function SyncBankTabCatalogGuild()
	local key = CurrentGuildKey()
	if key == nil then
		if bankTabCatalog.guildKey ~= nil or bankTabCatalog.loaded then
			ClearBankTabCatalog()
		end
		return
	end
	if bankTabCatalog.guildKey ~= nil and bankTabCatalog.guildKey ~= key then
		ClearBankTabCatalog()
	end
end

--- Read purchased, named Guild Bank tabs. Only marks loaded when the API returns
-- coherent names; never invents labels. Caches viewable names for Settings.
-- @return boolean true when the catalog was refreshed from live API data
local function ObserveGuildBankTabs()
	SyncBankTabCatalogGuild()
	local key = CurrentGuildKey()
	if key == nil then
		return false
	end
	if type(GetNumGuildBankTabs) ~= "function" or type(GetGuildBankTabInfo) ~= "function" then
		return false
	end
	local okNum, num = pcall(GetNumGuildBankTabs)
	if not okNum or type(num) ~= "number" or num ~= math.floor(num) or num < 0 then
		return false
	end
	local maxTab = 8
	local g = GS()
	if g and tonumber(g.MAX_BANK_TAB) then
		maxTab = tonumber(g.MAX_BANK_TAB)
	end
	num = math.min(num, maxTab)
	local nextEntries = {}
	for i = 1, num do
		local ok, name, _, isViewable = pcall(GetGuildBankTabInfo, i)
		if not ok then
			return false
		end
		-- Purchased tabs must expose a non-empty name; empty means data not ready.
		if type(name) ~= "string" or name == "" then
			return false
		end
		nextEntries[i] = {
			name = name,
			viewable = isViewable == true,
		}
	end
	bankTabCatalog.guildKey = key
	bankTabCatalog.entries = nextEntries
	bankTabCatalog.loaded = true
	return true
end

local function BankTabCatalogLoaded()
	SyncBankTabCatalogGuild()
	return bankTabCatalog.loaded == true
		and bankTabCatalog.guildKey ~= nil
		and bankTabCatalog.guildKey == CurrentGuildKey()
end

local function FormatBankTabLabel(index, name)
	if type(name) == "string" and name ~= "" then
		return Loc("GUILD_SUPPLIES_BANK_TAB_OPTION_FMT", "Tab %d — %s")
			:format(index, name)
	end
	return Loc("GUILD_SUPPLIES_BANK_TAB_NUMBER_FMT", "Tab %d"):format(index)
end

--- Dropdown options: clear sentinel + purchased viewable tabs only.
local function BankTabOptions()
	local opts = {}
	if not BankTabCatalogLoaded() then
		return opts
	end
	opts[#opts + 1] = {
		value = BANK_TAB_UNSET,
		label = Loc("GUILD_SUPPLIES_BANK_TAB_CLEAR", "Not configured"),
	}
	local indices = {}
	for index, entry in pairs(bankTabCatalog.entries) do
		if entry and entry.viewable and type(entry.name) == "string" and entry.name ~= "" then
			indices[#indices + 1] = index
		end
	end
	table.sort(indices)
	for i = 1, #indices do
		local index = indices[i]
		local entry = bankTabCatalog.entries[index]
		opts[#opts + 1] = {
			value = index,
			label = FormatBankTabLabel(index, entry.name),
		}
	end
	return opts
end

--- Default button text when the configured value is not among selectable options.
local function BankTabDefaultText()
	local tab = CurrentBankTab()
	if tab == nil then
		if BankTabCatalogLoaded() then
			return Loc("GUILD_SUPPLIES_BANK_TAB_CLEAR", "Not configured")
		end
		return Loc("GUILD_SUPPLIES_BANK_TAB_SELECT", "Select a bank tab")
	end
	SyncBankTabCatalogGuild()
	local entry = bankTabCatalog.entries[tab]
	if entry and type(entry.name) == "string" and entry.name ~= "" then
		if entry.viewable then
			return FormatBankTabLabel(tab, entry.name)
		end
		-- Known but not selectable for this character: show number only, no private name.
		return Loc("GUILD_SUPPLIES_BANK_TAB_UNAVAILABLE_FMT", "Tab %d — unavailable")
			:format(tab)
	end
	-- Configured value preserved without inventing a name.
	return Loc("GUILD_SUPPLIES_BANK_TAB_NUMBER_FMT", "Tab %d"):format(tab)
end

local function BankTabDropdownValue()
	local tab = CurrentBankTab()
	if tab == nil then
		return BANK_TAB_UNSET
	end
	return tab
end

local function RequestedItemRows()
	local rows = {}
	-- Shared campaign/item data stays redacted until membership canRead is verified.
	if not Caps().canRead then
		return rows
	end
	local record = CurrentRecord()
	if not record or type(record.currentCampaignId) ~= "string" then
		return rows
	end
	local items = record.accounting and record.accounting._consumables
		and record.accounting._consumables.requestedItems
	if type(items) ~= "table" then
		return rows
	end
	-- Cap before constructing controls. Count every raw entry, including invalid;
	-- over-cap maps stay unavailable rather than becoming a truncated UI list.
	local C = SF.Consumables
	local maxItems = (C and C.MAX_REQUESTED_ITEMS) or 256
	local inspected = 0
	local canEdit = Caps().canEdit
	for _, row in pairs(items) do
		inspected = inspected + 1
		if inspected > maxItems then
			return {}
		end
		if type(row) == "table" and tonumber(row.itemId) then
			local described = DescribeItem(row.itemId)
			rows[#rows + 1] = {
				text = described.name,
				icon = described.icon,
				itemId = row.itemId,
				goal = tonumber(row.goal) or 0,
				canRemove = canEdit,
				canEditGoal = canEdit,
			}
		end
	end
	table.sort(rows, function(a, b)
		return (a.itemId or 0) < (b.itemId or 0)
	end)
	return rows
end

---------------------------------------------------------------------------
-- Session-local Apply Adjustment draft (#426). Never SavedVariables / Gossip.
-- Cleared when dataset or current campaign identity changes. Ordinary refreshes
-- and delayed item-name loads must not reset valid in-progress input.
---------------------------------------------------------------------------
local ADJUST_UNASSIGNED = false -- UI-only sentinel; stored attribution stays nil.
-- attributed: Unassigned (false) or an explicitly/exactly resolved character name.
-- attributionText: search-box draft, kept separate so prefixes are never credited.
-- attributionResolved: false while nonempty search text has no exact resolution.
local adjustDraft = {
	itemId = nil,
	quantityText = "",
	attributed = ADJUST_UNASSIGNED,
	attributionText = "",
	attributionResolved = true,
}
local adjustDraftContextKey = nil

local function AdjustDraftContextKey()
	local rec = CurrentRecord()
	if not rec then
		return "none"
	end
	return tostring(rec.datasetId or "") .. "|" .. tostring(rec.currentCampaignId or "")
end

local function SyncAdjustDraftContext()
	local key = AdjustDraftContextKey()
	if key == adjustDraftContextKey then
		return
	end
	adjustDraftContextKey = key
	adjustDraft.itemId = nil
	adjustDraft.quantityText = ""
	adjustDraft.attributed = ADJUST_UNASSIGNED
	adjustDraft.attributionText = ""
	adjustDraft.attributionResolved = true
end

local function FormatAdjustItemLabel(itemId)
	local id = tonumber(itemId)
	if not id then
		return Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item")
	end
	local described = DescribeItem(id)
	local name = described and described.name
	if type(name) ~= "string" or name == "" then
		return Loc("GUILD_SUPPLIES_ITEM_FALLBACK", "item %s"):format(tostring(id))
	end
	-- Stable item IDs distinguish quality variants that share a display name.
	return string.format("%s (#%d)", name, id)
end

local function AdjustItemOptions()
	SyncAdjustDraftContext()
	local options = {}
	local rows = RequestedItemRows()
	local selectedStillPresent = false
	for i = 1, #rows do
		local row = rows[i]
		local itemId = tonumber(row and row.itemId)
		if itemId then
			if adjustDraft.itemId == itemId then
				selectedStillPresent = true
			end
			options[#options + 1] = {
				value = itemId,
				label = FormatAdjustItemLabel(itemId),
			}
		end
	end
	if adjustDraft.itemId ~= nil and not selectedStillPresent then
		adjustDraft.itemId = nil
	end
	return options
end

local function AdjustItemDefaultText()
	SyncAdjustDraftContext()
	local options = AdjustItemOptions()
	if #options == 0 then
		return Loc("GUILD_SUPPLIES_ADJUST_EMPTY",
			"Add requested items to the current campaign before applying an adjustment.")
	end
	if adjustDraft.itemId ~= nil then
		return FormatAdjustItemLabel(adjustDraft.itemId)
	end
	return Loc("GUILD_SUPPLIES_ADJUST_ITEM_DEFAULT", "Select a requested item")
end

-- Session roster name cache for attribution autocomplete. Full scan once per
-- guild/roster generation; getSuggestions filters the in-memory list only so
-- keystrokes never rescan GetGuildRosterInfo (#430).
local adjustRosterCache = {
	guildKey = nil,
	generation = nil,
	names = {}, -- sorted normalized names
	byLower = {}, -- lower(name) -> normalized name
}

local function AdjustRosterGeneration()
	local GG = SF.GuildGossip
	if GG and GG.GetGuildGeneration then
		return tonumber(GG.GetGuildGeneration()) or 0
	end
	return 0
end

local function InvalidateAdjustRosterCache()
	adjustRosterCache.guildKey = nil
	adjustRosterCache.generation = nil
	adjustRosterCache.names = {}
	adjustRosterCache.byLower = {}
end

local function EnsureAdjustRosterCache()
	local key = CurrentGuildKey() or "none"
	local gen = AdjustRosterGeneration()
	if adjustRosterCache.guildKey == key
		and adjustRosterCache.generation == gen
		and type(adjustRosterCache.names) == "table" then
		return adjustRosterCache
	end
	local names = {}
	local byLower = {}
	if type(GetNumGuildMembers) == "function" and type(GetGuildRosterInfo) == "function" then
		-- GetNumGuildMembers returns several numbers. Keep only the first before
		-- tonumber; passing the rest makes Lua treat the second value as a base.
		local total = GetNumGuildMembers()
		total = tonumber(total) or 0
		if total < 0 then
			total = 0
		end
		for i = 1, total do
			local rosterName = GetGuildRosterInfo(i)
			local norm = rosterName
			if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
				norm = SF.NameUtil.NormalizeNameRealm(rosterName) or rosterName
			end
			if type(norm) == "string" and norm ~= "" then
				local lower = string.lower(norm)
				if not byLower[lower] then
					byLower[lower] = norm
					names[#names + 1] = norm
				end
			end
		end
		table.sort(names)
	end
	adjustRosterCache.guildKey = key
	adjustRosterCache.generation = gen
	adjustRosterCache.names = names
	adjustRosterCache.byLower = byLower
	return adjustRosterCache
end

local function AdjustAttributionText()
	SyncAdjustDraftContext()
	-- Prefer the search draft so unfinished typing survives blur/refresh.
	if type(adjustDraft.attributionText) == "string" then
		return adjustDraft.attributionText
	end
	if adjustDraft.attributionResolved
		and type(adjustDraft.attributed) == "string"
		and adjustDraft.attributed ~= "" then
		return adjustDraft.attributed
	end
	return ""
end

local function AdjustAttributionIsUnresolved()
	SyncAdjustDraftContext()
	return not adjustDraft.attributionResolved
end

local function AdjustAttributionSuggestions(prefix)
	SyncAdjustDraftContext()
	local cache = EnsureAdjustRosterCache()
	local raw = tostring(prefix or "")
	local needle = string.lower((raw:match("^%s*(.-)%s*$") or ""))
	local out = {}
	local unassignedLabel = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	local maxSuggestions = 8
	-- Empty / Unassigned prefix keeps Unassigned selectable as the default.
	if needle == "" or string.find(string.lower(unassignedLabel), needle, 1, true) == 1 then
		out[#out + 1] = {
			value = ADJUST_UNASSIGNED,
			label = unassignedLabel,
			text = "",
		}
	end
	local names = cache.names or {}
	for i = 1, #names do
		if #out >= maxSuggestions then
			break
		end
		local name = names[i]
		local lower = string.lower(name)
		if needle == "" or string.find(lower, needle, 1, true) == 1 then
			out[#out + 1] = {
				value = name,
				label = name,
				text = name,
			}
		end
	end
	-- Keep a previously resolved credit visible through temporary roster lag.
	-- Never promote unresolved search prefixes into suggestions (#430).
	if adjustDraft.attributionResolved
		and type(adjustDraft.attributed) == "string"
		and adjustDraft.attributed ~= "" then
		local lowerSel = string.lower(adjustDraft.attributed)
		if not cache.byLower[lowerSel]
			and (needle == "" or string.find(lowerSel, needle, 1, true) == 1) then
			local exists = false
			for i = 1, #out do
				if out[i].value == adjustDraft.attributed then
					exists = true
					break
				end
			end
			if not exists and #out < maxSuggestions then
				out[#out + 1] = {
					value = adjustDraft.attributed,
					label = adjustDraft.attributed,
					text = adjustDraft.attributed,
				}
			end
		end
	end
	return out
end

--- Update search draft. Only Unassigned or an exact roster match resolves.
-- Unmatched nonempty text stays searchable and blocks Apply/submit; it is never
-- stored as a credited identity (#430).
local function SetAdjustAttributionFromText(text)
	SyncAdjustDraftContext()
	local trimmed = tostring(text or ""):match("^%s*(.-)%s*$") or ""
	if trimmed == "" then
		adjustDraft.attributed = ADJUST_UNASSIGNED
		adjustDraft.attributionText = ""
		adjustDraft.attributionResolved = true
		return
	end
	local unassignedLabel = Loc("GUILD_SUPPLIES_ADJUST_UNASSIGNED", "Unassigned")
	if string.lower(trimmed) == string.lower(unassignedLabel) then
		adjustDraft.attributed = ADJUST_UNASSIGNED
		adjustDraft.attributionText = ""
		adjustDraft.attributionResolved = true
		return
	end
	local cache = EnsureAdjustRosterCache()
	local exact = cache.byLower[string.lower(trimmed)]
	if exact then
		adjustDraft.attributed = exact
		adjustDraft.attributionText = exact
		adjustDraft.attributionResolved = true
		return
	end
	-- Unchanged display of an already-resolved identity survives temporary roster
	-- incompleteness on blur / ClearFocus after selection (#430).
	if adjustDraft.attributionResolved
		and type(adjustDraft.attributed) == "string"
		and adjustDraft.attributed ~= ""
		and string.lower(trimmed) == string.lower(adjustDraft.attributed) then
		adjustDraft.attributionText = adjustDraft.attributed
		return
	end
	adjustDraft.attributionText = trimmed
	adjustDraft.attributed = ADJUST_UNASSIGNED
	adjustDraft.attributionResolved = false
end

local function AdjustCanEdit()
	local rec = CurrentRecord()
	return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
end

local function AdjustHasRequestedItems()
	return #AdjustItemOptions() > 0
end

local function AdjustQuantityValid(text)
	local g = GS()
	if not g or not g.ParseAdjustmentQuantity then
		return false
	end
	return g.ParseAdjustmentQuantity(text or "") ~= nil
end

local function AdjustApplyButtonEnabled(text)
	if not AdjustCanEdit() or not AdjustHasRequestedItems() then
		return false
	end
	if adjustDraft.itemId == nil then
		return false
	end
	if AdjustAttributionIsUnresolved() then
		return false
	end
	return AdjustQuantityValid(text or adjustDraft.quantityText or "")
end

---------------------------------------------------------------------------
-- Quick Withdraw recipes (#457). Session-local editor draft; campaign scoped.
---------------------------------------------------------------------------
local recipeEditorDraft = {
	open = false,
	contextKey = nil,
	outputItemId = nil,
	isExisting = false,
	-- Bound at open for stale Save/Delete protection.
	boundGuildKey = nil,
	boundDatasetId = nil,
	boundCampaignId = nil,
	boundConfigSeq = nil,
	boundRecipeRevision = nil, -- Canonical fingerprint of reagents at open
	reagentTexts = {},
	-- Saved reagents that are no longer in the requested-item list; keep until
	-- the editor explicitly clears/repairs them.
	orphanReagentIds = {},
}
local recipeEditorUi = nil
local recipeEditorSection = nil

-- Forward declaration: CommitConfig is defined later with the shared Manage
-- mutation path; Delete must call it without a lexical upvalue hole.
local CommitConfig

local function RecipeDraftContextKey()
	local rec = CurrentRecord()
	if not rec then
		return "none"
	end
	local cfg = rec.accounting and rec.accounting._consumables
	local g = GS()
	local guildKey = rec._guildKey or (g and g.GetCurrentContext and select(1, g:GetCurrentContext()) and g:GetCurrentContext().guildKey)
	if type(guildKey) ~= "string" then
		local ctx = g and g.GetCurrentContext and g:GetCurrentContext()
		guildKey = ctx and ctx.guildKey
	end
	return table.concat({
		tostring(guildKey or ""),
		tostring(rec.datasetId or ""),
		tostring(rec.currentCampaignId or ""),
		tostring(cfg and cfg.configSeq or ""),
	}, "|")
end

local function RecipeFingerprint(reagents)
	if type(reagents) ~= "table" then
		return ""
	end
	local keys = {}
	for k in pairs(reagents) do
		keys[#keys + 1] = tostring(k)
	end
	table.sort(keys)
	local parts = {}
	for i = 1, #keys do
		local k = keys[i]
		parts[#parts + 1] = k .. "=" .. tostring(tonumber(reagents[k]) or 0)
	end
	return table.concat(parts, ";")
end

local function SyncRecipeEditorContext()
	local key = RecipeDraftContextKey()
	if not recipeEditorDraft.open then
		recipeEditorDraft.contextKey = key
		return
	end
	if recipeEditorDraft.contextKey ~= key then
		recipeEditorDraft.open = false
		recipeEditorDraft.outputItemId = nil
		recipeEditorDraft.isExisting = false
		recipeEditorDraft.reagentTexts = {}
		recipeEditorDraft.orphanReagentIds = {}
		recipeEditorDraft.boundGuildKey = nil
		recipeEditorDraft.boundDatasetId = nil
		recipeEditorDraft.boundCampaignId = nil
		recipeEditorDraft.boundConfigSeq = nil
		recipeEditorDraft.boundRecipeRevision = nil
		recipeEditorDraft.contextKey = key
		if recipeEditorUi and recipeEditorUi.frame then
			recipeEditorUi.frame:Hide()
		end
	end
end

local function RecipeCanEdit()
	return AdjustCanEdit()
end

local function RecipeHasRequestedReagents()
	return #RequestedItemRows() > 0
end

local function FindSavedRecipe(outputItemId)
	local id = tonumber(outputItemId)
	if not id then
		return nil
	end
	local record = CurrentRecord()
	local cfg = record and record.accounting and record.accounting._consumables
	local recipes = cfg and cfg.recipes
	if type(recipes) ~= "table" then
		return nil
	end
	return recipes[tostring(id)]
end

local function RecipeAvailabilityWarning(record, recipe)
	local g = GS()
	if not g or not g.RecipeAvailability or type(recipe) ~= "table" then
		return nil
	end
	-- Dot call: RecipeAvailability is a plain function, not a method.
	local ok, err, missing = g.RecipeAvailability(record, recipe)
	if ok then
		return nil
	end
	if err == "reagent_not_requested" and type(missing) == "table" and #missing > 0 then
		local names = {}
		for i = 1, math.min(#missing, 4) do
			local itemId = tonumber(missing[i])
			if itemId then
				names[#names + 1] = DescribeItem(itemId).name
			end
		end
		if #names > 0 then
			return Loc("GUILD_SUPPLIES_RECIPE_UNAVAILABLE_FMT",
				"Missing requested reagents: %s"):format(table.concat(names, ", "))
		end
	end
	return Loc("GUILD_SUPPLIES_RECIPE_UNAVAILABLE",
		"This recipe is not fully available for Quick Withdraw.")
end

local function RecipeRows()
	local rows = {}
	if not Caps().canRead then
		return rows
	end
	local record = CurrentRecord()
	if not record or type(record.currentCampaignId) ~= "string" then
		return rows
	end
	local g = GS()
	if not g or not g.ListCampaignRecipes then
		return rows
	end
	-- Dot call: ListCampaignRecipes is a plain function, not a method.
	local list = g.ListCampaignRecipes(record)
	for i = 1, #list do
		local entry = list[i]
		local itemId = tonumber(entry and entry.itemId)
		if itemId then
			local described = DescribeItem(itemId)
			local recipe = {
				itemId = itemId,
				reagents = entry.reagents,
			}
			rows[#rows + 1] = {
				text = described.name,
				icon = described.icon,
				itemId = itemId,
				key = itemId,
				leadingText = Loc("GUILD_SUPPLIES_RECIPE_EDIT", "Edit"),
				tooltip = RecipeAvailabilityWarning(record, recipe),
			}
		end
	end
	return rows
end

--- Editor rows = current requested reagents + preserved unavailable orphans.
local function RecipeEditorIngredientRows()
	local rows = RequestedItemRows()
	local out = {}
	local seen = {}
	for i = 1, #rows do
		local itemId = tonumber(rows[i] and rows[i].itemId)
		if itemId then
			seen[itemId] = true
			out[#out + 1] = { itemId = itemId, orphan = false }
		end
	end
	local orphans = recipeEditorDraft.orphanReagentIds or {}
	local keys = {}
	for k in pairs(orphans) do
		keys[#keys + 1] = tostring(k)
	end
	table.sort(keys)
	for i = 1, #keys do
		local itemId = tonumber(keys[i])
		if itemId and not seen[itemId] then
			out[#out + 1] = { itemId = itemId, orphan = true }
		end
	end
	return out
end

local function RecipeSaveTargetStillValid(bound)
	if type(bound) ~= "table" then
		return false, "stale"
	end
	if not RecipeCanEdit() then
		return false, "unauthorized"
	end
	local rec = CurrentRecord()
	if not rec then
		return false, "stale"
	end
	local cfg = rec.accounting and rec.accounting._consumables
	if tostring(rec.datasetId or "") ~= tostring(bound.datasetId or "") then
		return false, "dataset_changed"
	end
	if tostring(rec.currentCampaignId or "") ~= tostring(bound.campaignId or "") then
		return false, "campaign_changed"
	end
	if tostring(cfg and cfg.configSeq or "") ~= tostring(bound.configSeq or "") then
		return false, "config_changed"
	end
	local g = GS()
	local ctx = g and g.GetCurrentContext and g:GetCurrentContext()
	if tostring(ctx and ctx.guildKey or rec._guildKey or "") ~= tostring(bound.guildKey or "") then
		return false, "guild_changed"
	end
	local outputId = tonumber(bound.outputItemId)
	if not outputId then
		return false, "stale"
	end
	local live = FindSavedRecipe(outputId)
	if bound.isExisting then
		if type(live) ~= "table" then
			return false, "recipe_deleted"
		end
		if RecipeFingerprint(live.reagents) ~= tostring(bound.recipeRevision or "") then
			return false, "recipe_changed"
		end
	else
		if type(live) == "table" then
			return false, "recipe_exists"
		end
	end
	return true
end

local function RecipesHelpText()
	if not Caps().canRead then
		return Loc("GUILD_SUPPLIES_STATUS_MEMBERSHIP_PENDING",
			"Guild membership is still being verified. Shared Guild Supplies details stay hidden until then.")
	end
	local record = CurrentRecord()
	local hasCampaign = record and type(record.currentCampaignId) == "string" and record.currentCampaignId ~= ""
	if not hasCampaign then
		return Loc("GUILD_SUPPLIES_RECIPES_NEED_CAMPAIGN",
			"Start a New Campaign before configuring Quick Withdraw recipes.")
	end
	if RecipeHasRequestedReagents() then
		return Loc("GUILD_SUPPLIES_RECIPES_HELP",
			"Define how many of each requested reagent is consumed to craft one output item for Quick Withdraw.")
	end
	return Loc("GUILD_SUPPLIES_RECIPES_EMPTY",
		"Add requested items to the current campaign before configuring recipes.")
end

local function ParseRecipeReagentQty(text)
	local raw = tostring(text or ""):match("^%s*(.-)%s*$") or ""
	if raw == "" then
		return 0
	end
	local n = tonumber(raw)
	if not n or n ~= math.floor(n) or n < 0 then
		return nil
	end
	local g = GS()
	local maxPer = (g and tonumber(g.MAX_RECIPE_PER_CRAFT)) or 10000
	if n > maxPer then
		return nil
	end
	return n
end

local function CaptureRecipeEditorDraftFromUi()
	if not recipeEditorUi or not recipeEditorUi.reagentEdits then
		return
	end
	local texts = recipeEditorDraft.reagentTexts or {}
	for itemId, edit in pairs(recipeEditorUi.reagentEdits) do
		if edit and edit.GetText then
			texts[tostring(itemId)] = edit:GetText() or ""
		end
	end
	recipeEditorDraft.reagentTexts = texts
end

local function BuildRecipeReagentsFromDraft()
	CaptureRecipeEditorDraftFromUi()
	local reagents = {}
	local rows = RecipeEditorIngredientRows()
	for i = 1, #rows do
		local itemId = tonumber(rows[i] and rows[i].itemId)
		if itemId then
			local qty = ParseRecipeReagentQty(recipeEditorDraft.reagentTexts[tostring(itemId)])
			if qty == nil then
				return nil, itemId
			end
			if qty > 0 then
				reagents[tostring(itemId)] = qty
			end
		end
	end
	return reagents, nil
end

local function EnsureRecipeEditorUi()
	if recipeEditorUi and recipeEditorUi.frame then
		return recipeEditorUi
	end
	if type(CreateFrame) ~= "function" then
		return nil
	end
	local ui = {}
	local frame = CreateFrame("Frame", "SFGuildSuppliesRecipeEditor", UIParent, "BackdropTemplate")
	frame:SetSize(440, 460)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetFrameLevel(200)
	frame:Hide()
	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		frame:SetBackdropColor(0, 0, 0, 0.92)
	end
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function()
		CaptureRecipeEditorDraftFromUi()
		recipeEditorDraft.open = false
		recipeEditorDraft.reagentTexts = {}
		frame:Hide()
	end)

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", frame, "TOP", 0, -12)
	ui.title = title

	local outputIcon = frame:CreateTexture(nil, "ARTWORK")
	outputIcon:SetSize(20, 20)
	outputIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -36)
	ui.outputIcon = outputIcon

	local outputText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	outputText:SetPoint("LEFT", outputIcon, "RIGHT", 6, 0)
	outputText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	outputText:SetJustifyH("LEFT")
	if outputText.SetWordWrap then
		outputText:SetWordWrap(true)
	end
	ui.outputText = outputText

	local help = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", outputIcon, "BOTTOMLEFT", 0, -8)
	help:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	help:SetJustifyH("LEFT")
	help:SetText(Loc("GUILD_SUPPLIES_RECIPE_EDITOR_HELP",
		"How many of each reagent are needed for one craft? Enter 0 when a reagent is unused."))
	ui.help = help

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -10)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 52)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(380, 1)
	scroll:SetScrollChild(content)
	ui.scroll = scroll
	ui.content = content
	ui.reagentRows = {}
	ui.reagentEdits = {}
	ui.warnings = {}

	local save = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	save:SetSize(90, 22)
	save:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
	save:SetText(Loc("GUILD_SUPPLIES_RECIPE_EDITOR_SAVE", "Save"))
	ui.save = save

	local cancel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	cancel:SetSize(90, 22)
	cancel:SetPoint("LEFT", save, "RIGHT", 8, 0)
	cancel:SetText(Loc("GUILD_SUPPLIES_RECIPE_EDITOR_CANCEL", "Cancel"))
	ui.cancel = cancel

	local delete = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	delete:SetSize(90, 22)
	delete:SetPoint("LEFT", cancel, "RIGHT", 8, 0)
	delete:SetText(Loc("GUILD_SUPPLIES_RECIPE_EDITOR_DELETE", "Delete"))
	ui.delete = delete

	cancel:SetScript("OnClick", function()
		recipeEditorDraft.open = false
		recipeEditorDraft.reagentTexts = {}
		frame:Hide()
	end)

	ui.frame = frame
	recipeEditorUi = ui
	return ui
end

local function LayoutRecipeEditorReagentRow(row, y, itemId, qtyText, warningText)
	local described = DescribeItem(itemId)
	if row.Icon then
		if described.icon then
			row.Icon:SetTexture(described.icon)
			row.Icon:Show()
		else
			row.Icon:Hide()
		end
	end
	row.Name:SetText(described.name or Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item"))
	if row.Warning then
		if type(warningText) == "string" and warningText ~= "" then
			row.Warning:SetText("|cffff2020" .. warningText .. "|r")
			row.Warning:Show()
		else
			row.Warning:SetText("")
			row.Warning:Hide()
		end
	end
	local editing = row.Edit and row.Edit.HasFocus and row.Edit:HasFocus()
	if not editing then
		row.Edit:SetText(qtyText or "0")
	end
	row:ClearAllPoints()
	row:SetPoint("TOPLEFT", recipeEditorUi.content, "TOPLEFT", 0, -y)
	row:SetPoint("TOPRIGHT", recipeEditorUi.content, "TOPRIGHT", 0, -y)
	row:Show()
	return 28
end

local function SyncOrphanReagentsFromSavedAndDraft()
	-- Requested-item mutations often leave configSeq unchanged. Rebuild orphans
	-- from the saved recipe + current draft texts whenever the editor refreshes
	-- so Save cannot silently drop unavailable ingredients.
	CaptureRecipeEditorDraftFromUi()
	local outputId = tonumber(recipeEditorDraft.outputItemId)
	local saved = FindSavedRecipe(outputId)
	local reagentMap = saved and saved.reagents
	local requested = {}
	local reqRows = RequestedItemRows()
	for i = 1, #reqRows do
		local rid = tonumber(reqRows[i] and reqRows[i].itemId)
		if rid then
			requested[rid] = true
		end
	end
	local orphans = {}
	local texts = recipeEditorDraft.reagentTexts or {}
	if type(reagentMap) == "table" then
		for k, v in pairs(reagentMap) do
			local rid = tonumber(k)
			local qty = tonumber(v) or 0
			if rid and qty > 0 and not requested[rid] then
				orphans[tostring(rid)] = true
				if texts[tostring(rid)] == nil then
					texts[tostring(rid)] = tostring(qty)
				end
			end
		end
	end
	for k, text in pairs(texts) do
		local rid = tonumber(k)
		local qty = ParseRecipeReagentQty(text)
		if rid and qty and qty > 0 and not requested[rid] then
			orphans[tostring(rid)] = true
		end
	end
	recipeEditorDraft.reagentTexts = texts
	recipeEditorDraft.orphanReagentIds = orphans
end

local function RefreshRecipeEditor()
	SyncRecipeEditorContext()
	local ui = EnsureRecipeEditorUi()
	if not ui or not recipeEditorDraft.open or not ui.frame:IsShown() then
		return
	end
	local outputId = tonumber(recipeEditorDraft.outputItemId)
	if not outputId then
		return
	end
	SyncOrphanReagentsFromSavedAndDraft()
	local described = DescribeItem(outputId)
	if ui.outputIcon and described.icon then
		ui.outputIcon:SetTexture(described.icon)
		ui.outputIcon:Show()
	else
		ui.outputIcon:Hide()
	end
	ui.outputText:SetText(described.name or FormatAdjustItemLabel(outputId))
	if recipeEditorDraft.isExisting then
		ui.title:SetText(Loc("GUILD_SUPPLIES_RECIPE_EDITOR_TITLE_EDIT",
			"Edit Quick Withdraw recipe"))
	else
		ui.title:SetText(Loc("GUILD_SUPPLIES_RECIPE_EDITOR_TITLE_NEW",
			"New Quick Withdraw recipe"))
	end
	ui.delete:SetShown(recipeEditorDraft.isExisting == true)

	local record = CurrentRecord()
	local rows = RecipeEditorIngredientRows()
	-- Drop stale edit-box identity map; rebind each visible row to its item ID.
	ui.reagentEdits = {}
	local y = 0
	for i = 1, #rows do
		local itemId = tonumber(rows[i].itemId)
		local isOrphan = rows[i].orphan == true
		if itemId then
			if not ui.reagentRows[i] then
				local r = CreateFrame("Frame", nil, ui.content)
				r:SetHeight(26)
				local icon = r:CreateTexture(nil, "ARTWORK")
				icon:SetSize(16, 16)
				icon:SetPoint("LEFT", r, "LEFT", 0, 0)
				r.Icon = icon
				local name = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
				name:SetPoint("LEFT", icon, "RIGHT", 4, 0)
				name:SetWidth(210)
				name:SetJustifyH("LEFT")
				if name.SetWordWrap then name:SetWordWrap(false) end
				r.Name = name
				local edit = CreateFrame("EditBox", nil, r, "InputBoxTemplate")
				edit:SetAutoFocus(false)
				edit:SetSize(56, 20)
				edit:SetPoint("RIGHT", r, "RIGHT", 0, 0)
				edit:SetNumeric(true)
				edit:SetMaxLetters(5)
				r.Edit = edit
				local warn = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
				warn:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
				warn:SetPoint("RIGHT", r, "RIGHT", 0, 0)
				warn:SetJustifyH("LEFT")
				r.Warning = warn
				ui.reagentRows[i] = r
			end
			local row = ui.reagentRows[i]
			row._boundItemId = itemId
			-- Rebind OnTextChanged to the currently displayed item ID every layout.
			row.Edit:SetScript("OnTextChanged", function(self)
				local boundId = row._boundItemId
				if boundId then
					recipeEditorDraft.reagentTexts[tostring(boundId)] = self:GetText() or ""
				end
			end)
			ui.reagentEdits[itemId] = row.Edit
			local qtyText = recipeEditorDraft.reagentTexts[tostring(itemId)]
			if qtyText == nil then
				qtyText = "0"
				recipeEditorDraft.reagentTexts[tostring(itemId)] = qtyText
			end
			local perCraft = ParseRecipeReagentQty(qtyText) or 0
			local rowRecipe = { itemId = outputId, reagents = { [tostring(itemId)] = perCraft } }
			local warnText = nil
			if isOrphan then
				warnText = Loc("GUILD_SUPPLIES_RECIPE_ORPHAN_REAGENT",
					"No longer a requested reagent — clear the quantity or restore the requested item.")
			elseif perCraft > 0 then
				warnText = RecipeAvailabilityWarning(record, rowRecipe)
			end
			y = y + LayoutRecipeEditorReagentRow(row, y, itemId, qtyText, warnText)
		end
	end
	for j = #rows + 1, #ui.reagentRows do
		local stale = ui.reagentRows[j]
		if stale then
			stale._boundItemId = nil
			if stale.Edit then
				stale.Edit:SetScript("OnTextChanged", nil)
			end
			stale:Hide()
		end
	end
	ui.content:SetHeight(math.max(1, y))
end

local function CloseRecipeEditor(discardDraft)
	if discardDraft then
		recipeEditorDraft.reagentTexts = {}
	end
	recipeEditorDraft.open = false
	if recipeEditorUi and recipeEditorUi.frame then
		recipeEditorUi.frame:Hide()
	end
end

local function CommitRecipeEditorSave()
	local ctx = recipeEditorSection
	if not ctx or not ctx.section then
		return
	end
	SyncRecipeEditorContext()
	CaptureRecipeEditorDraftFromUi()
	local outputId = tonumber(recipeEditorDraft.outputItemId)
	local bound = {
		contextKey = recipeEditorDraft.contextKey,
		guildKey = recipeEditorDraft.boundGuildKey,
		datasetId = recipeEditorDraft.boundDatasetId,
		campaignId = recipeEditorDraft.boundCampaignId,
		configSeq = recipeEditorDraft.boundConfigSeq,
		recipeRevision = recipeEditorDraft.boundRecipeRevision,
		isExisting = recipeEditorDraft.isExisting,
		outputItemId = outputId,
	}
	local okTarget, targetWhy = RecipeSaveTargetStillValid(bound)
	if not okTarget then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_REASON_STALE_HANDLE",
				"the page is out of date — refresh and try again"),
			"error")
		CloseRecipeEditor(true)
		RefreshPageControls()
		return
	end
	if not RecipeHasRequestedReagents() and not next(recipeEditorDraft.orphanReagentIds or {}) then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_RECIPES_EMPTY",
				"Add requested items to the current campaign before configuring recipes."),
			"warn")
		return
	end
	local reagents, badId = BuildRecipeReagentsFromDraft()
	if reagents == nil then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_RECIPE_REAGENT_QTY",
				"Enter a whole-number reagent quantity from 0 to %d for each requested item.")
				:format((GS() and tonumber(GS().MAX_RECIPE_PER_CRAFT)) or 10000),
			"error")
		return
	end
	local g = GS()
	if g and g.NormalizeRecipeValue then
		-- Dot call: NormalizeRecipeValue is a plain function, not a method.
		local normalized, normErr = g.NormalizeRecipeValue({
			itemId = outputId,
			reagents = reagents,
		})
		if not normalized then
			if normErr == "empty_reagents" then
				ctx.section:SetMessage(
					Loc("GUILD_SUPPLIES_ERR_RECIPE_REAGENTS_EMPTY",
						"Enter at least one reagent quantity of 1 or higher."),
					"error")
			else
				ctx.section:SetMessage(
					Loc("GUILD_SUPPLIES_ERR_RECIPE_REAGENT_QTY",
						"Enter a whole-number reagent quantity from 0 to %d for each requested item.")
						:format((g and tonumber(g.MAX_RECIPE_PER_CRAFT)) or 10000),
					"error")
			end
			return
		end
		reagents = normalized.reagents
	end
	-- Re-check bound target immediately before mutation (authority + concurrent edit).
	okTarget, targetWhy = RecipeSaveTargetStillValid(bound)
	if not okTarget or RecipeDraftContextKey() ~= bound.contextKey then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_REASON_STALE_HANDLE",
				"the page is out of date — refresh and try again"),
			"error")
		CloseRecipeEditor(true)
		RefreshPageControls()
		return
	end
	ctx.section:ClearMessage()
	local op, prepStatus, prepReason = g:NewConfigOperation("set-recipe", { itemId = outputId }, {
		itemId = outputId,
		reagents = reagents,
		removed = false,
	})
	if not op then
		ReportStatus(ctx, prepStatus or "rejected", prepReason)
		return
	end
	local status, reason = g:ApplyStagedConfigOperation(op)
	if status == "accepted" or status == "duplicate" then
		CloseRecipeEditor(true)
	end
	ReportStatus(ctx, status, reason)
end

local function CommitRecipeEditorDelete()
	local ctx = recipeEditorSection
	if not ctx or not ctx.section then
		return
	end
	local outputId = tonumber(recipeEditorDraft.outputItemId)
	if not outputId or not recipeEditorDraft.isExisting then
		return
	end
	local bound = {
		contextKey = recipeEditorDraft.contextKey,
		guildKey = recipeEditorDraft.boundGuildKey,
		datasetId = recipeEditorDraft.boundDatasetId,
		campaignId = recipeEditorDraft.boundCampaignId,
		configSeq = recipeEditorDraft.boundConfigSeq,
		recipeRevision = recipeEditorDraft.boundRecipeRevision,
		isExisting = true,
		outputItemId = outputId,
	}
	local accept = function()
		SyncRecipeEditorContext()
		local okTarget = RecipeSaveTargetStillValid(bound)
		if not okTarget or RecipeDraftContextKey() ~= bound.contextKey then
			ctx.section:SetMessage(
				Loc("GUILD_SUPPLIES_REASON_STALE_HANDLE",
					"the page is out of date — refresh and try again"),
				"error")
			CloseRecipeEditor(true)
			RefreshPageControls()
			return
		end
		CloseRecipeEditor(true)
		CommitConfig(ctx, "set-recipe", { itemId = outputId }, { removed = true })
	end
	local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
	local msg = Loc("GUILD_SUPPLIES_RECIPE_DELETE_CONFIRM",
		"Delete this Quick Withdraw recipe for %s?"):format(FormatAdjustItemLabel(outputId))
	if dialogs and dialogs.Confirm then
		dialogs:Confirm(msg, Loc("GUILD_SUPPLIES_RECIPE_EDITOR_DELETE", "Delete"), accept)
	else
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_CONFIRM_UNAVAILABLE",
				"Confirmation is required and is unavailable right now."),
			"error")
	end
end

local function OpenRecipeEditor(ctx, outputItemId, existingRecipe)
	SyncRecipeEditorContext()
	local itemId = tonumber(outputItemId)
	if not itemId then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_RECIPE_OUTPUT",
				"Enter a valid output item ID or paste an item link."),
			"error")
		return
	end
	if not RecipeCanEdit() or not RecipeHasRequestedReagents() then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_RECIPES_EMPTY",
				"Add requested items to the current campaign before configuring recipes."),
			"warn")
		return
	end
	local ui = EnsureRecipeEditorUi()
	if not ui then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	local rec = CurrentRecord()
	local cfg = rec and rec.accounting and rec.accounting._consumables
	local g = GS()
	local ctxInfo = g and g.GetCurrentContext and g:GetCurrentContext()
	recipeEditorSection = ctx
	recipeEditorDraft.open = true
	recipeEditorDraft.contextKey = RecipeDraftContextKey()
	recipeEditorDraft.outputItemId = itemId
	recipeEditorDraft.isExisting = type(existingRecipe) == "table"
	recipeEditorDraft.boundGuildKey = (ctxInfo and ctxInfo.guildKey) or (rec and rec._guildKey)
	recipeEditorDraft.boundDatasetId = rec and rec.datasetId
	recipeEditorDraft.boundCampaignId = rec and rec.currentCampaignId
	recipeEditorDraft.boundConfigSeq = cfg and cfg.configSeq
	local texts = {}
	local orphans = {}
	local saved = existingRecipe
	if type(saved) ~= "table" then
		saved = FindSavedRecipe(itemId)
		recipeEditorDraft.isExisting = type(saved) == "table"
	end
	local reagentMap = saved and saved.reagents
	recipeEditorDraft.boundRecipeRevision = RecipeFingerprint(reagentMap)
	local requested = {}
	local rows = RequestedItemRows()
	for i = 1, #rows do
		local rid = tonumber(rows[i].itemId)
		if rid then
			requested[rid] = true
			local qty = 0
			if type(reagentMap) == "table" then
				qty = tonumber(reagentMap[tostring(rid)]) or 0
			end
			texts[tostring(rid)] = tostring(qty)
		end
	end
	-- Preserve unavailable saved ingredients until the editor repairs them.
	if type(reagentMap) == "table" then
		for k, v in pairs(reagentMap) do
			local rid = tonumber(k)
			local qty = tonumber(v) or 0
			if rid and qty > 0 and not requested[rid] then
				orphans[tostring(rid)] = true
				texts[tostring(rid)] = tostring(qty)
			end
		end
	end
	recipeEditorDraft.reagentTexts = texts
	recipeEditorDraft.orphanReagentIds = orphans
	ui.save:SetScript("OnClick", CommitRecipeEditorSave)
	ui.delete:SetScript("OnClick", CommitRecipeEditorDelete)
	ui.frame:Show()
	RefreshRecipeEditor()
	ctx.section:ClearMessage()
end

local function ResolveAddRecipeOutputId(ctx, text)
	local C = SF.Consumables
	local itemId = C and C.ItemIdFromText and C.ItemIdFromText(text) or tonumber(text)
	if not itemId then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_RECIPE_OUTPUT",
				"Enter a valid output item ID or paste an item link."),
			"error")
		return nil
	end
	local existing = FindSavedRecipe(itemId)
	if existing then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_RECIPE_EXISTS",
				"That output item already has a recipe. Edit it in the list below."),
			"warn")
		OpenRecipeEditor(ctx, itemId, existing)
		return nil
	end
	return itemId
end

local function AddRecipeFromCursor(ctx)
	if not RecipeCanEdit() or not RecipeHasRequestedReagents() then
		return
	end
	if type(GetCursorInfo) ~= "function" then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	local kind, payload = GetCursorInfo()
	if kind ~= "item" then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_RECIPE_CURSOR",
				"Pick up an item, then click Use item on cursor without placing it in a bag."),
			"error")
		return
	end
	local C = SF.Consumables
	local itemId = tonumber(payload)
	if not itemId and C and C.ItemIdFromText and type(payload) == "string" then
		itemId = C.ItemIdFromText(payload)
	end
	if not itemId then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_RECIPE_OUTPUT",
				"Enter a valid output item ID or paste an item link."),
			"error")
		return
	end
	local existing = FindSavedRecipe(itemId)
	if existing then
		ctx.section:SetMessage(
			Loc("GUILD_SUPPLIES_ERR_RECIPE_EXISTS",
				"That output item already has a recipe. Edit it in the list below."),
			"warn")
		OpenRecipeEditor(ctx, itemId, existing)
		return
	end
	OpenRecipeEditor(ctx, itemId, nil)
end

local function ItemsHelpText()
	if not Caps().canRead then
		return Loc("GUILD_SUPPLIES_STATUS_MEMBERSHIP_PENDING",
			"Guild membership is still being verified. Shared Guild Supplies details stay hidden until then.")
	end
	local record = CurrentRecord()
	local hasCampaign = record and type(record.currentCampaignId) == "string" and record.currentCampaignId ~= ""
	if hasCampaign then
		return Loc("GUILD_SUPPLIES_ITEMS_HELP",
			"Add exact item IDs for the current campaign. Goal edits keep contribution history.")
	end
	return Loc("GUILD_SUPPLIES_ITEMS_NEED_CAMPAIGN",
		"Start a New Campaign before adding requested items.")
end

CommitConfig = function(ctx, kind, target, value)
	local g = GS()
	if not g then
		ctx.section:SetMessage(Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."), "error")
		return
	end
	ctx.section:ClearMessage()
	local op, prepStatus, prepReason = g:NewConfigOperation(kind, target, value)
	if not op then
		ReportStatus(ctx, prepStatus or "rejected", prepReason)
		return
	end
	local status, reason = g:ApplyStagedConfigOperation(op)
	ReportStatus(ctx, status, reason)
end

local function DisabledMembershipTip()
	return Loc("GUILD_SUPPLIES_DISABLED_MEMBERSHIP",
		"Join a guild with a verified membership before using Guild Supplies.")
end

local function DisabledUnauthorizedTip(action)
	return Loc("GUILD_SUPPLIES_DISABLED_UNAUTHORIZED_FMT",
		"Your guild rank does not permit %s."):format(action)
end

--- Permission/membership gate shared by privileged Configuration controls.
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

local function DisabledNeedRecordTip(actionNoun)
	local auth = DisabledAuthTip(actionNoun, false)
	if auth then
		return auth
	end
	if CurrentRecord() ~= nil then
		return nil
	end
	if IsNotConfigured() then
		return Loc("GUILD_SUPPLIES_DISABLED_NEED_INIT",
			"Initialize Guild Supplies for this guild first.")
	end
	-- canRead but record unavailable (permission-only / redacted): no guild detail.
	return Loc("GUILD_SUPPLIES_DISABLED_DATA_UNAVAILABLE",
		"Guild Supplies data is unavailable right now.")
end

local function DisabledNeedCampaignTip(actionNoun)
	local tip = DisabledNeedRecordTip(actionNoun)
	if tip then
		return tip
	end
	local rec = CurrentRecord()
	if rec and type(rec.currentCampaignId) == "string" then
		return nil
	end
	return Loc("GUILD_SUPPLIES_DISABLED_NEED_CAMPAIGN",
		"Start a New Campaign before continuing.")
end


local function Definition()
	return {
		isAdmin = function()
			return Caps().canEdit == true
		end,
		sections = {
			{
				id = "gsItems",
				title = Loc("GUILD_SUPPLIES_ITEMS_TITLE", "Requested items"),
				tooltip = Loc("GUILD_SUPPLIES_ITEMS_TIP",
					"Campaign-owned. A New Campaign starts with an empty list."),
				items = {
					{
						type = "help",
						indent = "label",
						getText = ItemsHelpText,
					},
					{
						type = "editboxButton",
						label = Loc("GUILD_SUPPLIES_ADD_ITEM", "Add item"),
						adminOnly = true,
						hint = Loc("GUILD_SUPPLIES_ADD_ITEM_HINT", "Item ID or link"),
						buttonText = Loc("GUILD_SUPPLIES_ADD_ITEM_BUTTON", "Add"),
						buttonWidth = 90,
						editWidth = 170,
						enabled = function()
							local rec = CurrentRecord()
							return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
						end,
						getDisabledTooltip = function()
							return DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ITEMS", "editing requested items"))
						end,
						onSubmit = function(ctx, text)
							local C = SF.Consumables
							local itemId = C and C.ItemIdFromText and C.ItemIdFromText(text) or tonumber(text)
							if not itemId then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ITEM", "Enter an item ID or paste an item link."),
									"error")
								return
							end
							-- Fresh mutation-time read (not the render pass cache).
							local g = GS()
							local live = g and select(1, g:GetCurrentRecord())
							local items = live and live.accounting and live.accounting._consumables
								and live.accounting._consumables.requestedItems
							if type(items) == "table" and type(items[tostring(itemId)]) == "table" then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ITEM_EXISTS",
										"That item is already requested. Change its goal in the list instead of adding it again."),
									"warn")
								return
							end
							CommitConfig(ctx, "set-requested-item", { itemId = itemId }, {
								itemId = itemId,
								goal = 0,
								removed = false,
							})
						end,
					},
					{
						type = "consumableRequestedList",
						label = Loc("GUILD_SUPPLIES_ITEM_LIST", "Current campaign items"),
						adminOnly = true,
						height = 180,
						showItemIcons = true,
						getItems = RequestedItemRows,
						enabled = function()
							local rec = CurrentRecord()
							return Caps().canEdit and rec and type(rec.currentCampaignId) == "string"
						end,
						getDisabledTooltip = function()
							return DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ITEMS", "editing requested items"))
						end,
						onRemove = function(ctx, item)
							if not item or not item.itemId then return end
							CommitConfig(ctx, "set-requested-item", { itemId = item.itemId }, { removed = true })
						end,
						onGoalCommit = function(ctx, item, goal)
							if not item or not item.itemId then return end
							local C = SF.Consumables
							local gnum = C and C.ValidGoal and C.ValidGoal(goal) or nil
							if gnum == nil then
								local maxGoal = (C and tonumber(C.MAX_GOAL)) or 100000
								local raw = tonumber(goal)
								if raw and raw == math.floor(raw) and raw >= 0 and raw > maxGoal then
									ctx.section:SetMessage(
										Loc("GUILD_SUPPLIES_ERR_GOAL_RANGE",
											"Enter a whole-number goal from 0 to %d."):format(maxGoal),
										"error")
								else
									ctx.section:SetMessage(
										Loc("GUILD_SUPPLIES_ERR_GOAL", "Enter a non-negative whole-number goal."),
										"error")
								end
								return
							end
							CommitConfig(ctx, "set-requested-item", { itemId = item.itemId }, {
								itemId = item.itemId,
								goal = gnum,
								removed = false,
							})
						end,
					},
				},
			},
			{
				id = "gsAdjust",
				title = Loc("GUILD_SUPPLIES_ADJUST_TITLE", "Quantity adjustment"),
				tooltip = Loc("GUILD_SUPPLIES_ADJUST_TIP",
					"Authenticated editors may adjust item totals. Adjustments never verify Guild Bank deposits."),
				items = {
					{
						type = "help",
						indent = "label",
						getText = function()
							SyncAdjustDraftContext()
							if AdjustCanEdit() and not AdjustHasRequestedItems() then
								return Loc("GUILD_SUPPLIES_ADJUST_EMPTY",
									"Add requested items to the current campaign before applying an adjustment.")
							end
							return Loc("GUILD_SUPPLIES_ADJUST_HELP",
								"Choose a current campaign item, enter a whole-number change such as 10 or -10, and optionally credit a character. Leave attribution on Unassigned to change only the item total. Changes apply to the guild-owned Guild Supplies ledger and never verify Guild Bank deposits.")
						end,
					},
					{
						type = "dropdown",
						label = Loc("GUILD_SUPPLIES_ADJUST_ITEM", "Requested item"),
						adminOnly = true,
						width = 260,
						defaultText = AdjustItemDefaultText,
						options = AdjustItemOptions,
						get = function()
							SyncAdjustDraftContext()
							return adjustDraft.itemId
						end,
						set = function() end,
						enabled = function()
							return AdjustCanEdit() and AdjustHasRequestedItems()
						end,
						getDisabledTooltip = function()
							local tip = DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADJUST", "adjusting quantities"))
							if tip then
								return tip
							end
							if not AdjustHasRequestedItems() then
								return Loc("GUILD_SUPPLIES_ADJUST_EMPTY",
									"Add requested items to the current campaign before applying an adjustment.")
							end
							return nil
						end,
						onValueChanged = function(ctx, value)
							SyncAdjustDraftContext()
							local itemId = tonumber(value)
							if not itemId then
								return
							end
							-- Require the choice to still be a current requested item.
							local options = AdjustItemOptions()
							local found = false
							for i = 1, #options do
								if options[i].value == itemId then
									found = true
									break
								end
							end
							if not found then
								adjustDraft.itemId = nil
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ADJUST_ITEM",
										"Select a requested campaign item before applying an adjustment."),
									"error")
								RefreshPageControls()
								return
							end
							adjustDraft.itemId = itemId
							RefreshPageControls()
						end,
					},
					{
						type = "autocomplete",
						label = Loc("GUILD_SUPPLIES_ADJUST_ATTR", "Attribution"),
						adminOnly = true,
						width = 220,
						maxLetters = 96,
						maxSuggestions = 8,
						hint = Loc("GUILD_SUPPLIES_ADJUST_ATTR_HINT",
							"Unassigned (type a guild character to credit)"),
						enabled = function()
							return AdjustCanEdit() and AdjustHasRequestedItems()
						end,
						getDisabledTooltip = function()
							return DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADJUST", "adjusting quantities"))
						end,
						get = AdjustAttributionText,
						-- Bound setter alone owns typing / blur / selection text
						-- updates. Do not also wire onTextChanged: AddAutocomplete
						-- would run both and double the draft update + refresh (#430).
						set = function(v)
							SetAdjustAttributionFromText(v)
							-- Quantity Apply depends on attribution validity; refresh
							-- the bound editboxButton without requiring a qty retype.
							RefreshPageControls()
						end,
						getSuggestions = function(_, prefix)
							return AdjustAttributionSuggestions(prefix)
						end,
						onResolved = function(_, item)
							SyncAdjustDraftContext()
							-- Typing notifies nil before set. Do not refresh here:
							-- get() still has the prior search draft and would
							-- rewrite the edit mid-keystroke. set refreshes after
							-- the draft catches up.
							if not item then
								adjustDraft.attributed = ADJUST_UNASSIGNED
								adjustDraft.attributionResolved = false
								return
							end
							if item.value == ADJUST_UNASSIGNED or item.value == nil then
								adjustDraft.attributed = ADJUST_UNASSIGNED
								adjustDraft.attributionText = ""
								adjustDraft.attributionResolved = true
								RefreshPageControls()
								return
							end
							if type(item.value) == "string" and item.value ~= "" then
								adjustDraft.attributed = item.value
								adjustDraft.attributionText = item.text or item.label or item.value
								adjustDraft.attributionResolved = true
								RefreshPageControls()
								return
							end
							SetAdjustAttributionFromText(item.text or item.label or "")
							RefreshPageControls()
						end,
					},
					{
						type = "editboxButton",
						label = Loc("GUILD_SUPPLIES_ADJUST_QTY", "Quantity change"),
						adminOnly = true,
						hint = Loc("GUILD_SUPPLIES_ADJUST_QTY_HINT", "10 or -10"),
						buttonText = Loc("GUILD_SUPPLIES_ADJUST_APPLY", "Apply adjustment"),
						buttonWidth = 140,
						editWidth = 120,
						maxLetters = 8,
						get = function()
							SyncAdjustDraftContext()
							return adjustDraft.quantityText or ""
						end,
						getSelectionKey = function()
							SyncAdjustDraftContext()
							return AdjustDraftContextKey()
						end,
						enabled = function()
							-- Keep the quantity input editable once an item is
							-- selected; Apply uses buttonEnabled independently.
							return AdjustCanEdit()
								and AdjustHasRequestedItems()
								and adjustDraft.itemId ~= nil
						end,
						buttonEnabled = function(text)
							return AdjustApplyButtonEnabled(text)
						end,
						getDisabledTooltip = function()
							local tip = DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_ADJUST", "adjusting quantities"))
							if tip then
								return tip
							end
							if not AdjustHasRequestedItems() then
								return Loc("GUILD_SUPPLIES_ADJUST_EMPTY",
									"Add requested items to the current campaign before applying an adjustment.")
							end
							if adjustDraft.itemId == nil then
								return Loc("GUILD_SUPPLIES_ERR_ADJUST_ITEM",
									"Select a requested campaign item before applying an adjustment.")
							end
							if AdjustAttributionIsUnresolved() then
								return Loc("GUILD_SUPPLIES_ERR_ADJUST_ATTR",
									"Select Unassigned or a guild character from the suggestions. Typed search text is not credited until you select a match.")
							end
							if not AdjustQuantityValid(adjustDraft.quantityText or "") then
								return Loc("GUILD_SUPPLIES_ERR_ADJUST_FORMAT",
									"Enter a whole-number quantity such as 10 or -10. Do not use a leading plus sign.")
							end
							return nil
						end,
						onTextChanged = function(text)
							SyncAdjustDraftContext()
							adjustDraft.quantityText = tostring(text or "")
						end,
						onSubmit = function(ctx, text)
							SyncAdjustDraftContext()
							local g = GS()
							local dialogs = SF.SettingsUI and SF.SettingsUI.Dialogs
							if not g or not g.NewAdjustmentOperation or not g.ParseAdjustmentQuantity then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_UNAVAILABLE", "Guild Supplies is unavailable."),
									"error")
								return
							end
							-- Preserve typed quantity across cancel/failure.
							adjustDraft.quantityText = tostring(text or "")
							local itemId = tonumber(adjustDraft.itemId)
							if not itemId then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ADJUST_ITEM",
										"Select a requested campaign item before applying an adjustment."),
									"error")
								return
							end
							local quantity, qtyErr = g.ParseAdjustmentQuantity(adjustDraft.quantityText)
							if not quantity then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ADJUST_FORMAT",
										"Enter a whole-number quantity such as 10 or -10. Do not use a leading plus sign."),
									"error")
								return
							end
							if AdjustAttributionIsUnresolved() then
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_ADJUST_ATTR",
										"Select Unassigned or a guild character from the suggestions. Typed search text is not credited until you select a match."),
									"error")
								return
							end
							local attributed = nil
							if type(adjustDraft.attributed) == "string" and adjustDraft.attributed ~= "" then
								attributed = adjustDraft.attributed
							end
							-- Capture draft identity so success only clears when context matches.
							local boundItemId = itemId
							local boundContext = AdjustDraftContextKey()
							local op, prepStatus, prepReason = g:NewAdjustmentOperation(
								itemId, quantity, attributed)
							if not op then
								ReportStatus(ctx, prepStatus or "rejected", prepReason or qtyErr)
								return
							end
							local preview = g.PreviewAdjustment
								and g:PreviewAdjustment(itemId, quantity, attributed) or nil
							local confirmMsg
							if preview and g.FormatAdjustmentConfirmation then
								confirmMsg = g.FormatAdjustmentConfirmation(
									preview, FormatAdjustItemLabel(itemId))
							else
								confirmMsg = Loc("GUILD_SUPPLIES_ADJUST_CONFIRM",
									"Adjust item %s by %+d on the Guild Supplies ledger?")
									:format(FormatAdjustItemLabel(itemId), quantity)
							end
							local accept = function()
								-- Revalidate permissions/context/item/totals/goal at commit.
								SyncAdjustDraftContext()
								if AdjustDraftContextKey() ~= boundContext
									or tonumber(adjustDraft.itemId) ~= boundItemId
									or not AdjustCanEdit() then
									ctx.section:SetMessage(
										Loc("GUILD_SUPPLIES_REASON_STALE_HANDLE",
											"the page is out of date — refresh and try again"),
										"error")
									RefreshPageControls()
									return
								end
								ctx.section:ClearMessage()
								local status, reason = g:ApplyStagedConfigOperation(op)
								if status == "accepted" or status == "duplicate" then
									if AdjustDraftContextKey() == boundContext
										and tonumber(adjustDraft.itemId) == boundItemId then
										adjustDraft.quantityText = ""
									end
								end
								ReportStatus(ctx, status, reason)
								RefreshPageControls()
							end
							if dialogs and dialogs.Confirm then
								dialogs:Confirm(confirmMsg,
									Loc("GUILD_SUPPLIES_ADJUST_APPLY", "Apply adjustment"), accept)
							else
								ctx.section:SetMessage(
									Loc("GUILD_SUPPLIES_ERR_CONFIRM_UNAVAILABLE",
										"Confirmation is required and is unavailable right now."),
									"error")
							end
						end,
					},
				},
			},
			{
				id = "gsRecipes",
				title = Loc("GUILD_SUPPLIES_RECIPES_TITLE", "Quick Withdraw recipes"),
				tooltip = Loc("GUILD_SUPPLIES_RECIPES_TIP",
					"Campaign-owned craft recipes for Quick Withdraw. Each output item can have one recipe."),
				items = {
					{
						type = "help",
						indent = "label",
						getText = RecipesHelpText,
					},
					{
						type = "editboxButton",
						label = Loc("GUILD_SUPPLIES_RECIPES_ADD", "Add recipe output"),
						adminOnly = true,
						hint = Loc("GUILD_SUPPLIES_RECIPES_ADD_HINT", "Output item ID or link"),
						buttonText = Loc("GUILD_SUPPLIES_RECIPES_ADD_BUTTON", "Add"),
						buttonWidth = 90,
						editWidth = 170,
						enabled = function()
							return RecipeCanEdit() and RecipeHasRequestedReagents()
						end,
						getDisabledTooltip = function()
							local tip = DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_RECIPES", "editing Quick Withdraw recipes"))
							if tip then
								return tip
							end
							if not RecipeHasRequestedReagents() then
								return Loc("GUILD_SUPPLIES_RECIPES_EMPTY",
									"Add requested items to the current campaign before configuring recipes.")
							end
							return nil
						end,
						onSubmit = function(ctx, text)
							local itemId = ResolveAddRecipeOutputId(ctx, text)
							if not itemId then
								return
							end
							OpenRecipeEditor(ctx, itemId, nil)
						end,
					},
					{
						type = "button",
						label = Loc("GUILD_SUPPLIES_RECIPES_CURSOR", "Use item on cursor"),
						adminOnly = true,
						buttonText = Loc("GUILD_SUPPLIES_RECIPES_CURSOR_BUTTON", "Use cursor item"),
						width = 140,
						tooltip = Loc("GUILD_SUPPLIES_RECIPES_CURSOR_TIP",
							"Reads the item on your cursor without moving it. Pick up an output item first."),
						enabled = function()
							return RecipeCanEdit() and RecipeHasRequestedReagents()
						end,
						getDisabledTooltip = function()
							local tip = DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_RECIPES", "editing Quick Withdraw recipes"))
							if tip then
								return tip
							end
							if not RecipeHasRequestedReagents() then
								return Loc("GUILD_SUPPLIES_RECIPES_EMPTY",
									"Add requested items to the current campaign before configuring recipes.")
							end
							return nil
						end,
						onClick = function(ctx)
							AddRecipeFromCursor(ctx)
						end,
					},
					{
						type = "scrollList",
						label = Loc("GUILD_SUPPLIES_RECIPES_LIST", "Saved recipes"),
						adminOnly = true,
						height = 160,
						showItemIcons = true,
						leadingColumn = true,
						showDetailTooltip = true,
						getItems = RecipeRows,
						enabled = function()
							return RecipeCanEdit() and RecipeHasRequestedReagents()
						end,
						getDisabledTooltip = function()
							local tip = DisabledNeedCampaignTip(
								Loc("GUILD_SUPPLIES_DISABLED_ACTION_RECIPES", "editing Quick Withdraw recipes"))
							if tip then
								return tip
							end
							if not RecipeHasRequestedReagents() then
								return Loc("GUILD_SUPPLIES_RECIPES_EMPTY",
									"Add requested items to the current campaign before configuring recipes.")
							end
							return nil
						end,
						onSelect = function(ctx, item)
							if not item or not item.itemId then
								return
							end
							local existing = FindSavedRecipe(item.itemId)
							OpenRecipeEditor(ctx, item.itemId, existing)
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
	display.RegisterRefresh("guildSuppliesManage", function()
		if recipeEditorDraft.open then
			RefreshRecipeEditor()
		end
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
		InvalidateAdjustRosterCache()
		QueueRefresh()
	end)
end

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

local durableListenerRegistered = false
local function EnsureDurableListener()
	if durableListenerRegistered or Page.__sfGuildSuppliesDurableHook then
		return
	end
	local supplies = SF.GuildSupplies
	if not supplies or type(supplies.RegisterUIListener) ~= "function" then
		return
	end
	durableListenerRegistered = true
	Page.__sfGuildSuppliesDurableHook = true
	supplies.RegisterUIListener(function()
		QueueRefresh()
	end)
end

function Page:Build(panel)
	local renderer = SF.SettingsUI and SF.SettingsUI.DefinitionRenderer
	if not renderer or not renderer.Build then
		return
	end
	EnsureRosterListener()
	EnsureOfficerListener()
	EnsureDurableListener()
	EnsureItemDisplayListener()
	BeginRenderPass()
	renderer:Build(panel, Definition())
	EndRenderPass()
	self.panel = panel
	if panel.HookScript and not panel.__sfGuildSuppliesManageHook then
		panel.__sfGuildSuppliesManageHook = true
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
	if recipeEditorDraft.open then
		RefreshRecipeEditor()
	end
end

function Page:OnHide()
	refreshQueued = false
	CloseRecipeEditor(true)
end

-- Test hooks for behavioral coverage (#453 / #457).
Page.__sfTest = {
	Definition = Definition,
	RecipeRows = RecipeRows,
	OpenRecipeEditor = OpenRecipeEditor,
	CloseRecipeEditor = CloseRecipeEditor,
	BuildRecipeReagentsFromDraft = BuildRecipeReagentsFromDraft,
	SyncOrphanReagentsFromSavedAndDraft = SyncOrphanReagentsFromSavedAndDraft,
	RefreshRecipeEditor = RefreshRecipeEditor,
	RecipeEditorDraft = function()
		return recipeEditorDraft
	end,
}

EnsureRosterListener()
EnsureDurableListener()
EnsureItemDisplayListener()

SF.SettingsUI:RegisterPage(Page)
