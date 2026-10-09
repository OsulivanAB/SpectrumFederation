local addonName, ns = ...

-- Localization table
ns.L = ns.L or {}
local L = ns.L

-- English (default) strings
L["ADDON_LOADED_MSG"] = "Spectrum Federation loaded successfully!"

-- Raid Supplies Guild Bank donation helper (#352)
L["RAID_SUPPLIES_OVERALL_PROGRESS"] = "Overall progress"
L["RAID_SUPPLIES_NO_GOALS_CONFIGURED"] = "No goals configured."
L["RAID_SUPPLIES_NO_GOAL"] = "No Goal"
L["RAID_SUPPLIES_GOAL_ALREADY_MET"] = "That item's donation goal is already met."

-- Raid Consumable Logs / Guild Bank verification (#366)
L["RAID_CONSUMABLE_LOGS_HELP"] = "Newest entries are first. Pending Guild Bank observations appear until verified. Each page shows up to %d verified entries, including configuration clears from every generation."
L["RAID_CONSUMABLE_REVIEW_TITLE"] = "Admin review"
L["RAID_CONSUMABLE_REVIEW_HELP"] = "During an active Loot Helper session, request the coordinator's pending observation summary. Approve or reject unresolved Guild Bank contributions. Preview as Non-Admin hides these controls."

-- Resolve a locale key with an English fallback when the table is incomplete.
function ns.LocaleText(key, default)
	local value = L[key]
	if type(value) == "string" and value ~= "" then
		return value
	end
	if type(default) == "string" then
		return default
	end
	return tostring(key or "")
end
