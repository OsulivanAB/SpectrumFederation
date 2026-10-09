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
L["RAID_CONSUMABLE_LOGS_TITLE"] = "Raid Consumable Logs"
L["RAID_CONSUMABLE_LOGS_NEWER"] = "Newer entries"
L["RAID_CONSUMABLE_LOGS_NEWER_BUTTON"] = "Newer"
L["RAID_CONSUMABLE_LOGS_OLDER"] = "Older entries"
L["RAID_CONSUMABLE_LOGS_OLDER_BUTTON"] = "Older"
L["RAID_CONSUMABLE_LOGS_HISTORY"] = "History"
L["RAID_CONSUMABLE_LOGS_GOAL_PROGRESS"] = "Goal Progress"
L["RAID_CONSUMABLE_REVIEW_TITLE"] = "Admin review"
L["RAID_CONSUMABLE_REVIEW_HELP"] = "During an active Loot Helper session, request the coordinator's pending observation summary. Approve or reject unresolved Guild Bank contributions. Preview as Non-Admin hides these controls."
L["RAID_CONSUMABLE_REVIEW_REQUEST"] = "Request pending review"
L["RAID_CONSUMABLE_REVIEW_REFRESH"] = "Refresh pending"
L["RAID_CONSUMABLE_REVIEW_PENDING_LIST"] = "Pending review"
L["RAID_CONSUMABLE_REVIEW_SELECTED"] = "Selected: %s donated %d %s"
L["RAID_CONSUMABLE_REVIEW_NONE_SELECTED"] = "Select a row to approve, reject, or correct."
L["RAID_CONSUMABLE_REVIEW_APPROVE_ALL"] = "Approve all pending"
L["RAID_CONSUMABLE_REVIEW_APPROVE_ALL_BUTTON"] = "Approve all"
L["RAID_CONSUMABLE_REVIEW_APPROVE"] = "Approve selected"
L["RAID_CONSUMABLE_REVIEW_APPROVE_BUTTON"] = "Approve"
L["RAID_CONSUMABLE_REVIEW_REJECT"] = "Reject selected"
L["RAID_CONSUMABLE_REVIEW_REJECT_BUTTON"] = "Reject"
L["RAID_CONSUMABLE_REVIEW_CORRECT"] = "Correct rejection"
L["RAID_CONSUMABLE_REVIEW_CORRECT_BUTTON"] = "Override reject"
L["RAID_CONSUMABLE_REVIEW_STATUS_PENDING"] = "Pending"
L["RAID_CONSUMABLE_REVIEW_STATUS_AMBIGUOUS"] = "Needs review"
L["RAID_CONSUMABLE_REVIEW_STATUS_REJECTED"] = "Rejected"
L["RAID_CONSUMABLE_REVIEW_ROW"] = "%s donated %d %s — %s (%d witnesses)"
L["RAID_CONSUMABLE_REVIEW_SOMEONE"] = "Someone"

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
