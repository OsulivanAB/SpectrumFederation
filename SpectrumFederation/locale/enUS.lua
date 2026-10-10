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
L["RAID_CONSUMABLE_LOGS_HELP"] = "Newest entries are first. Pending Guild Bank observations appear until verified. Each page shows up to %d verified entries, including manual adjustments and configuration clears from every generation."
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
L["RAID_CONSUMABLE_ADJUST_TITLE"] = "Manual adjustment"
L["RAID_CONSUMABLE_ADJUST_HELP"] = "Admins can correct received quantities or record supplies received outside Guild Bank verification. Adjustments are permanent ledger entries. Preview as Non-Admin hides these controls."
L["RAID_CONSUMABLE_ADJUST_ITEM"] = "Requested item"
L["RAID_CONSUMABLE_ADJUST_ITEM_DEFAULT"] = "Select a requested item"
L["RAID_CONSUMABLE_ADJUST_MEMBER"] = "Credit to"
L["RAID_CONSUMABLE_ADJUST_MEMBER_DEFAULT"] = "Unattributed / Miscellaneous"
L["RAID_CONSUMABLE_ADJUST_UNATTRIBUTED"] = "Unattributed / Miscellaneous"
L["RAID_CONSUMABLE_ADJUST_QUANTITY"] = "Quantity (+/-)"
L["RAID_CONSUMABLE_ADJUST_PREVIEW"] = "Preview"
L["RAID_CONSUMABLE_ADJUST_PREVIEW_EMPTY"] = "Select an item and enter a non-zero quantity to preview the resulting totals."
L["RAID_CONSUMABLE_ADJUST_APPLY"] = "Apply adjustment"
L["RAID_CONSUMABLE_ADJUST_APPLY_BUTTON"] = "Confirm"
L["RAID_CONSUMABLE_ADJUST_CONFIRM_HEADER"] = "Adjust %s by %+d?"
L["RAID_CONSUMABLE_ADJUST_CONFIRM_RECEIVED"] = "Received: %d → %d"
L["RAID_CONSUMABLE_ADJUST_CONFIRM_PLAYER"] = "Player contribution: %d → %d"
L["RAID_CONSUMABLE_ADJUST_CONFIRM_CREDIT"] = "Credit: %s"
L["RAID_CONSUMABLE_ADJUST_SUCCESS"] = "Adjustment recorded."
L["RAID_CONSUMABLE_ADJUST_PENDING"] = "Adjustment queued for synchronization."
L["RAID_CONSUMABLE_ADJUST_ADMIN_FALLBACK"] = "An admin"
L["RAID_CONSUMABLE_ADJUST_HISTORY_ATTRIBUTED"] = "%s adjusted %s by %+d (credited to %s)."
L["RAID_CONSUMABLE_ADJUST_HISTORY_UNATTRIBUTED"] = "%s adjusted %s by %+d (unattributed / miscellaneous)."
L["RAID_CONSUMABLE_ADJUST_ERR_ITEM"] = "Select a requested consumable."
L["RAID_CONSUMABLE_ADJUST_ERR_QUANTITY"] = "Enter a non-zero whole-number quantity."
L["RAID_CONSUMABLE_ADJUST_ERR_TOO_LARGE"] = "That quantity is too large."
L["RAID_CONSUMABLE_ADJUST_ERR_MEMBER"] = "Choose a valid profile member, or leave the adjustment unattributed."
L["RAID_CONSUMABLE_ADJUST_ERR_NOT_MEMBER"] = "That player is not a current profile member."
L["RAID_CONSUMABLE_ADJUST_ERR_ITEM_NEGATIVE"] = "Received quantity cannot become negative."
L["RAID_CONSUMABLE_ADJUST_ERR_PLAYER_NEGATIVE"] = "That player's contribution cannot become negative."
L["RAID_CONSUMABLE_ADJUST_ERR_MISSING_ADMIN"] = "Missing admin."
L["RAID_CONSUMABLE_ADJUST_ERR_ADMIN_ONLY"] = "Only a profile admin can adjust raid supplies."
L["RAID_CONSUMABLE_ADJUST_ERR_PREVIEW"] = "Could not preview that adjustment."
L["RAID_CONSUMABLE_ADJUST_ERR_PREVIEW_NON_ADMIN"] = "Raid Consumables settings are in Preview as Non-Admin mode."
L["RAID_CONSUMABLE_ADJUST_ERR_CREATE"] = "Could not create that adjustment."
L["RAID_CONSUMABLE_ADJUST_ERR_NO_PROFILE"] = "No active profile."
L["RAID_CONSUMABLE_ADJUST_ERR_PROFILE_CHANGED"] = "The active profile changed, so the adjustment was not applied."
L["RAID_CONSUMABLE_ADJUST_ERR_COMMIT"] = "Could not record that adjustment."

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
