-- Guild Supplies → Rankings (#447/#450). Officer-only campaign contribution chart.
-- Derived view of retained logs + valuation snapshots; never persists a board.
-- Always projects the guild record's active campaign; no independent selector (#450).
local _, SF = ...

local function Loc(key, default)
	if SF.LocaleText then
		return SF.LocaleText(key, default)
	end
	return default or key
end

local Page = {
	id = "guildSuppliesRankings",
	categoryId = "guildSupplies",
	name = Loc("GUILD_SUPPLIES_RANKINGS_NAME", "Rankings"),
	navLabel = Loc("GUILD_SUPPLIES_RANKINGS_NAV", "Rankings"),
	contentHeading = Loc("GUILD_SUPPLIES_RANKINGS_HEADING", "Raid Supplies Rankings"),
	group = "Raid Tools",
	description = Loc("GUILD_SUPPLIES_RANKINGS_DESC",
		"Compare campaign contribution value by current main for eligible officers."),
	order = 19.25,
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

local refreshQueued = false
local rosterFrame = nil
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
		caps = { canRead = false, canEdit = false, reason = "not_ready" }
	else
		caps = g:GetCapabilities()
	end
	if passCache then
		passCache.caps = caps
	end
	return caps
end

local function CanViewRankings()
	return Caps().canEdit == true
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

--- Active campaign only. Follows guild-record rollover; never uses Configuration's
-- rename-target selection, Logs campaign pickers, or Loot Helper profiles (#450).
local function ActiveCampaignId()
	if not CanViewRankings() then
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

local function MembershipHelpText()
	local caps = Caps()
	local g = GS()
	local formatReason = g and g.FormatReasonText or function(r)
		return tostring(r or "unknown")
	end
	if CanViewRankings() then
		return nil
	end
	if caps.reason == "preview_non_admin" then
		return Loc("GUILD_SUPPLIES_RANKINGS_PREVIEW",
			"Rankings are hidden while Preview as Non-Admin is active.")
	end
	return Loc("GUILD_SUPPLIES_RANKINGS_NO_ACCESS",
		"Rankings are available to officers who meet the shared guild officer rank.")
		.. " (" .. formatReason(caps.reason or "unauthorized") .. ")"
end

local function RankingsForActiveCampaign()
	if passCache and passCache.rankingsChecked then
		return passCache.rankings
	end
	local result = {
		rows = {},
		maxPositive = 0,
		hasHistory = false,
		emptyReason = "no_access",
		emptyText = nil,
	}
	if not CanViewRankings() then
		result.emptyText = MembershipHelpText()
		if passCache then
			passCache.rankingsChecked = true
			passCache.rankings = result
		end
		return result
	end
	local campaignId = ActiveCampaignId()
	local g = GS()
	if not campaignId or not g or not g.ProjectCampaignRankings then
		-- No active campaign: leave chart content blank; keep page navigation (#450).
		result.emptyReason = "no_campaign"
		if passCache then
			passCache.rankingsChecked = true
			passCache.rankings = result
		end
		return result
	end
	local projected = g:ProjectCampaignRankings(campaignId)
	if type(projected) ~= "table" then
		result.emptyReason = "no_campaign"
	else
		result = projected
	end
	if passCache then
		passCache.rankingsChecked = true
		passCache.rankings = result
	end
	return result
end

local function Definition()
	return {
		sections = {
			{
				id = "gsRankingsStatus",
				title = Loc("GUILD_SUPPLIES_RANKINGS_TITLE", "Contribution rankings"),
				-- Fill leftover Settings page height (#447/#450).
				fillHeight = true,
				items = {
					{
						type = "contributionRankingChart",
						-- No InitRow label column: reclaim Contributors gutter (#450).
						height = 320,
						fillHeight = true,
						getRankings = function()
							return RankingsForActiveCampaign()
						end,
						enabled = function()
							return CanViewRankings()
						end,
						getDisabledTooltip = function()
							return MembershipHelpText()
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

--- Legitimate show/context start only. Ordinary Page:Refresh / NotifyUI must not
-- touch catch-up lifecycle — that cancels in-flight work or re-runs a completed
-- pass (#447). Keep pricing-job start/cancel separate from rendering.
local function MaybeStartValuationCatchup(panel)
	if not PanelVisible(panel) or not CanViewRankings() then
		return
	end
	local supplies = GS()
	-- Prefer Ensure so a still-running Logs/prior catch-up is not cancelled when
	-- Rankings is shown; Start remains the fallback for older builds.
	if supplies and supplies.EnsureValuationCatchup then
		supplies.EnsureValuationCatchup("rankings-show")
	elseif supplies and supplies.StartValuationCatchup then
		supplies.StartValuationCatchup("rankings-show")
	end
end

local function CancelValuationCatchup()
	local supplies = GS()
	if supplies and supplies.CancelValuationCatchup then
		supplies.CancelValuationCatchup("rankings-hide")
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

--- Roster/guild membership can grant or revoke Rankings without a GS durable
-- write. Route through Settings availability revalidation (coalesced); page
-- refresh alone cannot update tabs or fall back before the panel exists (#447).
local availabilityQueued = false
local function QueueAvailabilityRevalidation()
	if availabilityQueued then return end
	availabilityQueued = true
	local function run()
		availabilityQueued = false
		local win = SF.SettingsWindow
		if win and type(win.HandleDurableAvailabilityChange) == "function" then
			win:HandleDurableAvailabilityChange()
		end
		QueueRefresh()
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
	display.RegisterRefresh("guildSuppliesRankings", function()
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
		QueueAvailabilityRevalidation()
	end)
end

local durableListenerRegistered = false
local function EnsureDurableListener()
	if durableListenerRegistered then
		return
	end
	local supplies = SF.GuildSupplies
	if supplies and type(supplies.RegisterUIListener) == "function" then
		supplies.RegisterUIListener(function()
			QueueRefresh()
		end)
	end
	local GI = SF.GuildInfo
	if GI and type(GI.RegisterUIListener) == "function" then
		GI.RegisterUIListener(function()
			QueueRefresh()
		end)
	end
	local GO = SF.GuildOfficer
	if GO and type(GO.RegisterUIListener) == "function" then
		GO.RegisterUIListener(function()
			-- Officer policy can flip canEdit without roster events.
			QueueAvailabilityRevalidation()
		end)
	end
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
	renderer:Build(panel, Definition())
	EndRenderPass()
	self.panel = panel
	if panel.HookScript and not panel.__sfGuildSuppliesRankingsHook then
		panel.__sfGuildSuppliesRankingsHook = true
		panel:HookScript("OnShow", function()
			QueueRefresh()
			MaybeStartValuationCatchup(panel)
		end)
		panel:HookScript("OnHide", function()
			CancelValuationCatchup()
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
		renderer:Refresh(panel)
		EndRenderPass()
	end
	-- Access lost while visible: stop catch-up. Do not Ensure/Start here —
	-- valuation NotifyUI would otherwise restart scans from Refresh (#447).
	if not CanViewRankings() then
		CancelValuationCatchup()
	end
end

function Page:OnHide()
	refreshQueued = false
	CancelValuationCatchup()
end

EnsureRosterListener()
EnsureDurableListener()
EnsureItemDisplayListener()

SF.SettingsUI:RegisterPage(Page)
