-- Grab the namespace
local addonName, SF = ...

local RC_AWARD_EVENT_WINDOW_SECONDS = 5
local RC_AWARD_ITEMINFO_RETRY_DELAY_SECONDS = 1
local RC_AWARD_ITEMINFO_MAX_RETRIES = 2
local RC_LOOT_COUNCIL_AUTHOR = "RC Loot Council"
local RC_LOOT_COUNCIL_SOURCE = "RCLootCouncil"
local RC_LOOT_COUNCIL_REASON = "RC_LOOT_COUNCIL"
local RC_LOOT_COUNCIL_REASSIGN_REASON = "RC_LOOT_COUNCIL_REASSIGN"
local RC_LOOT_COUNCIL_CONFLICT_REASON = "RC_LOOT_COUNCIL_SLOT_CONFLICT"
local RC_CHANGE_AWARD_PREFIX = "change award"
local RC_AWARD_CHAT_EVENTS = {
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER",
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
}

local RC_EQUIP_LOC_TO_ARMOR_SLOTS = {
    INVTYPE_HEAD = { "Head" },
    INVTYPE_NECK = { "Neck" },
    INVTYPE_SHOULDER = { "Shoulder" },
    INVTYPE_CLOAK = { "Back" },
    INVTYPE_CHEST = { "Chest" },
    INVTYPE_ROBE = { "Chest" },
    INVTYPE_WRIST = { "Bracers" },
    INVTYPE_HAND = { "Hands" },
    INVTYPE_WAIST = { "Belt" },
    INVTYPE_LEGS = { "Pants" },
    INVTYPE_FEET = { "Boots" },
    INVTYPE_FINGER = { "Ring1", "Ring2" },
    INVTYPE_TRINKET = { "Trinket1", "Trinket2" },
    INVTYPE_SHIELD = { "OffHand" },
    INVTYPE_HOLDABLE = { "OffHand" },
    INVTYPE_WEAPONOFFHAND = { "OffHand" },
    INVTYPE_WEAPON = { "Weapon", "OffHand" },
    INVTYPE_WEAPONMAINHAND = { "Weapon" },
    INVTYPE_2HWEAPON = { "Weapon" },
    INVTYPE_RANGED = { "Weapon" },
    INVTYPE_RANGEDRIGHT = { "Weapon" },
    INVTYPE_THROWN = { "Weapon" },
    INVTYPE_RELIC = { "OffHand" },
}

local function TrimText(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function NormalizeRCLootCouncilAwardReason(reasonText)
    local reason = TrimText(reasonText)
    reason = reason:gsub("[!%.%s]+$", "")
    return reason
end

-- WoW chat escapes literal pipes as double pipes, so normalize before parsing links/items.
local function NormalizeRCAwardMessageText(value)
    return type(value) == "string" and value:gsub("||", "|") or value
end

local function NormalizeRCAwardItemLink(itemLink)
    if type(itemLink) ~= "string" or itemLink == "" then
        return nil
    end

    local normalized = TrimText(NormalizeRCAwardMessageText(itemLink))
    local decoratedLink = normalized:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
    if decoratedLink and decoratedLink ~= "" then
        return decoratedLink
    end

    local plainLink = normalized:match("(|Hitem:.-|h%[.-%]|h)")
    if plainLink and plainLink ~= "" then
        return plainLink
    end

    return normalized ~= "" and normalized or nil
end

local function NormalizeRCAwardItemName(itemName)
    itemName = TrimText(itemName)
    local bracketed = itemName:match("^%[(.-)%]$")
    if bracketed and bracketed ~= "" then
        itemName = bracketed
    end
    return itemName
end

local function ExtractRCAwardItemLink(message)
    if type(message) ~= "string" or message == "" then
        return nil
    end

    return message:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
end

local function ExtractRCAwardItemReference(message)
    local itemLink = ExtractRCAwardItemLink(message)
    if itemLink then
        return NormalizeRCAwardItemLink(itemLink), "link"
    end

    local bracketedName = type(message) == "string" and message:match("(%b[])") or nil
    if bracketedName then
        local normalizedName = NormalizeRCAwardItemName(bracketedName)
        if normalizedName ~= "" then
            return normalizedName, "name"
        end
    end

    return nil, nil
end

local function ExtractRCAwardMessagePrefix(message)
    if type(message) ~= "string" then
        return nil, message
    end

    local prefix, remainder = message:match("^(%b())%s*(.*)$")
    if prefix and remainder and remainder ~= "" then
        return TrimText(prefix:sub(2, -2)), remainder
    end

    return nil, message
end

local function BuildRCAwardItemKey(itemReference)
    if type(itemReference) ~= "string" or itemReference == "" then
        return nil
    end

    local itemString = itemReference:match("|H(item:[^|]+)|h")
    if itemString and itemString ~= "" then
        return itemString
    end

    local normalizedName = NormalizeRCAwardItemName(itemReference)
    if normalizedName == "" then
        return nil
    end

    return normalizedName:lower()
end

local function FindProfileMemberIdByName(profile, winnerName)
    winnerName = TrimText(winnerName)
    local getMemberIds = profile.GetMemberIds or profile.getMemberIds
    if winnerName == "" or type(profile) ~= "table" or type(getMemberIds) ~= "function" then
        return nil
    end

    local normalizedWinner = SF.NameUtil and SF.NameUtil.NormalizeNameRealm and SF.NameUtil.NormalizeNameRealm(winnerName) or winnerName
    for _, memberId in ipairs(getMemberIds(profile) or {}) do
        if SF.NameUtil and SF.NameUtil.SamePlayer and normalizedWinner and SF.NameUtil.SamePlayer(memberId, normalizedWinner) then
            return memberId, "exact", nil
        end
    end

    local winnerShort = winnerName:match("^([^%-]+)")
    if not winnerShort then
        return nil, "not_found", nil
    end
    winnerShort = winnerShort:lower()

    local matches = {}
    for _, memberId in ipairs(getMemberIds(profile) or {}) do
        local shortName = tostring(memberId):match("^([^%-]+)")
        if shortName and shortName:lower() == winnerShort then
            table.insert(matches, memberId)
        end
    end

    if #matches == 1 then
        return matches[1], "short_name", matches
    end
    if #matches > 1 then
        return nil, "ambiguous_short_name", matches
    end

    return nil, "not_found", matches
end

local function ParseRCAwardMessage(message)
    if type(message) ~= "string" or message == "" then
        return nil
    end

    local normalizedMessage = NormalizeRCAwardMessageText(message)
    local prefixLabel, messageBody = ExtractRCAwardMessagePrefix(normalizedMessage)
    local itemReference, itemReferenceType = ExtractRCAwardItemReference(messageBody)
    if not itemReference then
        return nil
    end

    local awardPrefix = " was awarded with "
    local prefixStart = messageBody:find(awardPrefix, 1, true)
    local itemStart, itemEnd = messageBody:find(itemReference, 1, true)
    if not prefixStart or not itemStart or prefixStart >= itemStart then
        return nil
    end

    local winnerName = TrimText(messageBody:sub(1, prefixStart - 1))
    local afterItem = messageBody:sub(itemEnd + 1)
    local reasonPos = afterItem:find(" for ", 1, true)
    if not reasonPos then
        return nil
    end

    local reasonText = NormalizeRCLootCouncilAwardReason(afterItem:sub(reasonPos + 5))
    if winnerName == "" or reasonText == "" then
        return nil
    end

    return {
        winnerName = winnerName,
        itemLink = itemReference,
        itemKey = BuildRCAwardItemKey(itemReference),
        itemReferenceType = itemReferenceType,
        reasonText = reasonText,
        prefixLabel = prefixLabel,
        isChangeAward = type(prefixLabel) == "string" and prefixLabel:lower() == RC_CHANGE_AWARD_PREFIX,
    }
end

local function IsPotentialRCAwardMessage(message)
    if type(message) ~= "string" or message == "" then
        return false
    end

    return message:find(" was awarded with ", 1, true) ~= nil
        and message:find(" for ", 1, true) ~= nil
end

local function ResolveRCLootCouncilAwardSlots(itemLink)
    if type(itemLink) ~= "string" or itemLink == "" then
        return nil, nil, false, itemLink
    end

    local itemReference = itemLink
    local normalizedName = nil
    if not itemReference:find("|Hitem:", 1, true) then
        normalizedName = NormalizeRCAwardItemName(itemReference)
        itemReference = normalizedName
    end

    local resolvedItemLink = itemReference
    local equipLoc = nil

    if type(GetItemInfoInstant) == "function" then
        local _, _, _, instantEquipLoc = GetItemInfoInstant(itemReference)
        equipLoc = instantEquipLoc
    end

    if (not equipLoc or equipLoc == "") and type(GetItemInfo) == "function" then
        local _, itemLinkFromInfo, _, _, _, _, _, _, itemEquipLoc = GetItemInfo(itemReference)
        if itemLinkFromInfo and itemLinkFromInfo ~= "" then
            resolvedItemLink = itemLinkFromInfo
        elseif normalizedName and normalizedName ~= "" then
            resolvedItemLink = normalizedName
        end
        equipLoc = itemEquipLoc or equipLoc
    end

    if not equipLoc or equipLoc == "" then
        if type(GetItemInfo) == "function" then
            GetItemInfo(itemReference)
        end
        return nil, nil, true, resolvedItemLink
    end

    local slots = equipLoc and RC_EQUIP_LOC_TO_ARMOR_SLOTS[equipLoc] or nil
    return slots, equipLoc, false, resolvedItemLink
end

local function ClonePayload(payload)
    local copy = {}
    for key, value in pairs(payload or {}) do
        copy[key] = value
    end
    return copy
end

local function ScheduleRCLootCouncilAwardRetry(self, payload)
    if not (C_Timer and C_Timer.After) then
        return false, tonumber(payload.retryCount) or 0
    end

    local retryCount = tonumber(payload.retryCount) or 0
    if retryCount >= RC_AWARD_ITEMINFO_MAX_RETRIES then
        return false, retryCount
    end

    local retryPayload = ClonePayload(payload)
    local nextRetryCount = retryCount + 1
    retryPayload.retryCount = nextRetryCount

    C_Timer.After(RC_AWARD_ITEMINFO_RETRY_DELAY_SECONDS, function()
        self:ProcessRCLootCouncilAward(retryPayload)
    end)

    return true, nextRetryCount
end

local function SelectAvailableAwardSlot(member, slotCandidates)
    if type(member) ~= "table" or type(slotCandidates) ~= "table" then
        return nil
    end

    local armor = type(member.GetArmorStatuses) == "function" and member:GetArmorStatuses() or member.armor
    if type(armor) ~= "table" then
        return nil
    end

    for _, slotName in ipairs(slotCandidates) do
        if armor[slotName] == false then
            return slotName
        end
    end

    return nil
end

local function ForgetRecentAwardSignature(cache, signature)
    if type(cache) ~= "table" or type(signature) ~= "string" or signature == "" then
        return
    end

    cache[signature] = nil
end

local function JoinStringList(values)
    if type(values) ~= "table" then
        return ""
    end

    local items = {}
    for _, value in ipairs(values) do
        local text = TrimText(value)
        if text ~= "" then
            table.insert(items, text)
        end
    end

    return table.concat(items, ", ")
end

local function RememberRecentWarning(cache, warningId, now)
    if type(warningId) ~= "string" or warningId == "" then
        return false
    end

    cache[warningId] = cache[warningId] or 0
    if cache[warningId] > 0 and (now - cache[warningId]) < RC_AWARD_EVENT_WINDOW_SECONDS then
        return true
    end

    cache[warningId] = now
    return false
end

local function BroadcastRCLootCouncilAdminWarning(profile, payload)
    if type(profile) ~= "table" or type(payload) ~= "table" then
        return 0
    end
    if not (SF.LootHelperComm and SF.LootHelperSync and SF.LootHelperSync.MSG and SF.LootHelperSync.MSG.RC_AWARD_WARNING) then
        return 0
    end

    local getAdminMemberIds = profile.GetAdminMemberIds or profile.getAdminMemberIds
    local getProfileId = profile.GetProfileId or profile.getProfileId
    if type(getAdminMemberIds) ~= "function" or type(getProfileId) ~= "function" then
        return 0
    end

    local profileId = getProfileId(profile)
    local adminIds = getAdminMemberIds(profile) or {}
    if type(profileId) ~= "string" or profileId == "" then
        return 0
    end

    local selfId = SF.NameUtil and SF.NameUtil.GetSelfId and SF.NameUtil.GetSelfId() or nil
    local sentCount = 0
    local warningPayload = ClonePayload(payload)
    warningPayload.profileId = profileId

    for _, adminId in ipairs(adminIds) do
        if type(adminId) == "string" and adminId ~= "" then
            local isSelf = false
            if selfId and SF.NameUtil and SF.NameUtil.SamePlayer then
                isSelf = SF.NameUtil.SamePlayer(adminId, selfId)
            else
                isSelf = adminId == selfId
            end

            if not isSelf then
                local ok = SF.LootHelperComm:Send(
                    "CONTROL",
                    SF.LootHelperSync.MSG.RC_AWARD_WARNING,
                    warningPayload,
                    "WHISPER",
                    adminId,
                    "NORMAL"
                )
                if ok then
                    sentCount = sentCount + 1
                end
            end
        end
    end

    return sentCount
end

local function BuildRCLootCouncilAwardPayloadFromInternalMessage(session, winnerName, itemLink, rollType, status)
    winnerName = TrimText(winnerName)
    rollType = NormalizeRCLootCouncilAwardReason(rollType)
    if winnerName == "" or type(itemLink) ~= "string" or itemLink == "" or rollType == "" then
        return nil
    end

    return {
        session = session,
        winnerName = winnerName,
        itemLink = itemLink,
        rollType = rollType,
        sourceType = "internal",
        status = status,
    }
end

local function BuildRCLootCouncilAwardPayloadFromChatMessage(message, chatEvent)
    local parsed = ParseRCAwardMessage(message)
    if not parsed then
        return nil
    end

    return {
        winnerName = parsed.winnerName,
        itemLink = parsed.itemLink,
        itemKey = parsed.itemKey,
        itemReferenceType = parsed.itemReferenceType,
        rollType = parsed.reasonText,
        prefixLabel = parsed.prefixLabel,
        isChangeAward = parsed.isChangeAward,
        sourceType = "chat",
        chatEvent = chatEvent,
    }
end

function SF:ProcessRCLootCouncilAward(payload)
    if type(payload) ~= "table" then
        if SF.Debug then
            SF.Debug:Warn("RC_LOOT_COUNCIL", "Ignored RC award payload with invalid type: %s", type(payload))
        end
        return false
    end

    payload.itemLink = NormalizeRCAwardItemLink(payload.itemLink)

    if SF.Debug then
        SF.Debug:Verbose(
            "RC_LOOT_COUNCIL",
            "Processing RC award payload source=%s winner=%s item=%s rollType=%s status=%s",
            tostring(payload.sourceType or "unknown"),
            tostring(payload.winnerName),
            tostring(payload.itemLink),
            tostring(payload.rollType),
            tostring(payload.status)
        )
    end

    if not self.lootHelperDB or not self.lootHelperDB.enabled then
        if SF.Debug then
            SF.Debug:Verbose("RC_LOOT_COUNCIL", "Ignoring RC award because Loot Helper is disabled")
        end
        return false
    end

    local profile = self:GetActiveProfile()
    if not profile or type(profile.GetRCLootCouncilEnabled) ~= "function" or not profile:GetRCLootCouncilEnabled() then
        if SF.Debug then
            SF.Debug:Verbose("RC_LOOT_COUNCIL", "Ignoring RC award because RC Loot Council sync is disabled for the active profile")
        end
        return false
    end

    if not profile.IsCurrentUserAdmin or not profile:IsCurrentUserAdmin() then
        if SF.Debug then
            SF.Debug:Verbose("RC_LOOT_COUNCIL", "Ignoring RC award because current user is not an admin for the active profile")
        end
        return false
    end

    local configuredRollType = type(profile.GetRCLootCouncilRollType) == "function" and profile:GetRCLootCouncilRollType() or ""
    configuredRollType = NormalizeRCLootCouncilAwardReason(configuredRollType)
    if configuredRollType == "" then
        if SF.Debug then
            SF.Debug:Warn("RC_LOOT_COUNCIL", "Ignoring RC award because no RC roll type is configured")
        end
        return false
    end

    local payloadRollType = NormalizeRCLootCouncilAwardReason(payload.rollType)
    if payloadRollType == "" or payloadRollType:lower() ~= configuredRollType:lower() then
        if SF.Debug then
            SF.Debug:Verbose(
                "RC_LOOT_COUNCIL",
                "Ignoring RC award because payload roll type '%s' does not match configured '%s'",
                tostring(payloadRollType),
                tostring(configuredRollType)
            )
        end
        return false
    end

    local now = GetTime and GetTime() or 0
    local memberId, matchKind, matchCandidates = FindProfileMemberIdByName(profile, payload.winnerName)
    if not memberId then
        if matchKind == "ambiguous_short_name" then
            local warningId = table.concat({
                tostring(payload.winnerName),
                tostring(payload.itemLink),
                tostring(configuredRollType),
                "ambiguous_short_name",
            }, "\031")
            self._rcLootCouncilRecentWarnings = self._rcLootCouncilRecentWarnings or {}
            if not RememberRecentWarning(self._rcLootCouncilRecentWarnings, warningId, now) then
                local matchesText = JoinStringList(matchCandidates)
                local warningMessage = string.format(
                    "RC award for %s (%s) is ambiguous. Matching members: %s. Resolve it manually.",
                    tostring(payload.winnerName),
                    tostring(payload.itemLink),
                    matchesText ~= "" and matchesText or "multiple short-name matches"
                )
                SF:PrintWarning(warningMessage)
                BroadcastRCLootCouncilAdminWarning(profile, {
                    warningId = warningId,
                    message = warningMessage,
                })
            end
        end
        if SF.Debug then
            SF.Debug:Verbose(
                "RC_LOOT_COUNCIL",
                "Ignoring RC award with unmatched winner '%s' (matchKind=%s matches=%s)",
                tostring(payload.winnerName),
                tostring(matchKind),
                JoinStringList(matchCandidates)
            )
        end
        return false
    end

    self._rcLootCouncilRecentAwards = self._rcLootCouncilRecentAwards or {}
    local itemKey = payload.itemKey
    if not itemKey then
        itemKey = BuildRCAwardItemKey(payload.itemLink) or tostring(payload.itemLink)
    end
    local signature = table.concat({ tostring(memberId), tostring(itemKey), tostring(configuredRollType) }, "\031")
    local lastSeen = self._rcLootCouncilRecentAwards[signature]
    if lastSeen and (now - lastSeen) < RC_AWARD_EVENT_WINDOW_SECONDS then
        if SF.Debug then
            SF.Debug:Verbose(
                "RC_LOOT_COUNCIL",
                "Suppressing duplicate RC award for %s item=%s rollType=%s",
                tostring(memberId),
                tostring(payload.itemLink),
                tostring(configuredRollType)
            )
        end
        return false
    end

    local getMemberByID = profile.GetMemberByID or profile.getMemberByID
    local member = getMemberByID and getMemberByID(profile, memberId) or nil
    if not member or type(member.ApplyAwardedItem) ~= "function" then
        if SF.Debug then
            SF.Debug:Warn("RC_LOOT_COUNCIL", "Unable to apply RC award because member object is unavailable for %s", tostring(memberId))
        end
        return false
    end

    local slotCandidates, equipLoc, itemInfoPending, resolvedItemLink = ResolveRCLootCouncilAwardSlots(payload.itemLink)
    if resolvedItemLink and resolvedItemLink ~= "" then
        payload.itemLink = resolvedItemLink
        itemKey = BuildRCAwardItemKey(resolvedItemLink) or itemKey
        signature = table.concat({ tostring(memberId), tostring(itemKey), tostring(configuredRollType) }, "\031")
    end
    if itemInfoPending then
        local retryScheduled, retryCount = ScheduleRCLootCouncilAwardRetry(self, payload)
        if SF.Debug then
            SF.Debug:Warn(
                "RC_LOOT_COUNCIL",
                "Item info not ready for %s; retryScheduled=%s retryCount=%s item=%s",
                tostring(memberId),
                tostring(retryScheduled),
                tostring(retryCount),
                tostring(payload.itemLink)
            )
        end
        return false
    end

    self._rcLootCouncilItemAssignments = self._rcLootCouncilItemAssignments or {}
    local priorAssignment = payload.isChangeAward and itemKey and self._rcLootCouncilItemAssignments[itemKey] or nil
    if priorAssignment and priorAssignment.memberId ~= memberId then
        local priorMember = getMemberByID and getMemberByID(profile, priorAssignment.memberId) or nil
        if not priorMember or type(priorMember.ClearAwardedItem) ~= "function" then
            if SF.Debug then
                SF.Debug:Warn(
                    "RC_LOOT_COUNCIL",
                    "Unable to clear previous RC assignment for item=%s member=%s slot=%s",
                    tostring(payload.itemLink),
                    tostring(priorAssignment.memberId),
                    tostring(priorAssignment.slotName)
                )
            end
            return false
        end

        local cleared = priorMember:ClearAwardedItem(priorAssignment.slotName, {
            logAuthor = RC_LOOT_COUNCIL_AUTHOR,
            reason = RC_LOOT_COUNCIL_REASSIGN_REASON,
            source = RC_LOOT_COUNCIL_SOURCE,
            rollType = configuredRollType,
            itemLink = payload.itemLink,
        })
        if not cleared then
            if SF.Debug then
                SF.Debug:Warn(
                    "RC_LOOT_COUNCIL",
                    "Failed to clear previous RC assignment for item=%s member=%s slot=%s",
                    tostring(payload.itemLink),
                    tostring(priorAssignment.memberId),
                    tostring(priorAssignment.slotName)
                )
            end
            return false
        end

        ForgetRecentAwardSignature(
            self._rcLootCouncilRecentAwards,
            table.concat({ tostring(priorAssignment.memberId), tostring(itemKey), tostring(configuredRollType) }, "\031")
        )
    end

    if SF.Debug then
        SF.Debug:Verbose(
            "RC_LOOT_COUNCIL",
            "Resolved RC item %s to equipLoc=%s slotCandidates=%s",
            tostring(payload.itemLink),
            tostring(equipLoc),
            slotCandidates and table.concat(slotCandidates, ",") or "nil"
        )
    end
    local slotName = SelectAvailableAwardSlot(member, slotCandidates)
    if not slotName then
        if type(slotCandidates) == "table" and #slotCandidates > 0 then
            local candidateText = JoinStringList(slotCandidates)
            local warningId = table.concat({
                tostring(memberId),
                tostring(payload.itemLink),
                tostring(configuredRollType),
                "slot_conflict",
            }, "\031")
            local ok = member:DecrementPoints({
                logAuthor = RC_LOOT_COUNCIL_AUTHOR,
                reason = RC_LOOT_COUNCIL_CONFLICT_REASON,
                source = RC_LOOT_COUNCIL_SOURCE,
                rollType = configuredRollType,
                itemLink = payload.itemLink,
                conflictSlots = candidateText,
                winnerName = payload.winnerName,
            })

            if ok then
                local warningMessage = string.format(
                    "RC award conflict for %s: %s awarded %s, but candidate slots [%s] are already used. Points were decremented; resolve the slot manually.",
                    tostring(memberId),
                    tostring(payload.winnerName),
                    tostring(payload.itemLink),
                    candidateText
                )
                self._rcLootCouncilRecentAwards[signature] = now
                SF:PrintWarning(warningMessage)
                local sentCount = BroadcastRCLootCouncilAdminWarning(profile, {
                    warningId = warningId,
                    message = warningMessage,
                })
                if SF.Debug then
                    SF.Debug:Warn(
                        "RC_LOOT_COUNCIL",
                        "Processed RC award conflict for %s (equipLoc=%s, item=%s, candidates=%s, warningsSent=%d)",
                        tostring(memberId),
                        tostring(equipLoc),
                        tostring(payload.itemLink),
                        candidateText,
                        sentCount
                    )
                end
            elseif SF.Debug then
                SF.Debug:Warn(
                    "RC_LOOT_COUNCIL",
                    "Failed to record RC award conflict for %s (equipLoc=%s, item=%s, candidates=%s)",
                    tostring(memberId),
                    tostring(equipLoc),
                    tostring(payload.itemLink),
                    candidateText
                )
            end

            return ok
        end

        if SF.Debug then
            SF.Debug:Warn(
                "RC_LOOT_COUNCIL",
                "Unable to resolve an available slot for %s (equipLoc=%s, item=%s)",
                tostring(memberId),
                tostring(equipLoc),
                tostring(payload.itemLink)
            )
        end
        return false
    end

    local ok = member:ApplyAwardedItem(slotName, {
        logAuthor = RC_LOOT_COUNCIL_AUTHOR,
        reason = RC_LOOT_COUNCIL_REASON,
        source = RC_LOOT_COUNCIL_SOURCE,
        rollType = configuredRollType,
        itemLink = payload.itemLink,
    })

    if ok then
        self._rcLootCouncilRecentAwards[signature] = now
        if itemKey then
            self._rcLootCouncilItemAssignments[itemKey] = {
                memberId = memberId,
                slotName = slotName,
                assignedAt = now,
            }
        end
        if SF.Debug then
            SF.Debug:Info(
                "RC_LOOT_COUNCIL",
                "Processed RC award via %s for %s (%s -> %s)",
                tostring(payload.sourceType or "unknown"),
                tostring(memberId),
                tostring(payload.itemLink),
                tostring(slotName)
            )
        end
    elseif SF.Debug then
        SF.Debug:Warn(
            "RC_LOOT_COUNCIL",
            "Member award application failed for %s (%s -> %s)",
            tostring(memberId),
            tostring(payload.itemLink),
            tostring(slotName)
        )
    end

    return ok
end

function SF:HandleRCLootCouncilAwardMessage(message, chatEvent)
    -- TODO: Support custom RC awardText templates in the chat fallback path.
    local payload = BuildRCLootCouncilAwardPayloadFromChatMessage(message, chatEvent)
    if payload then
        if SF.Debug then
            SF.Debug:Verbose(
                "RC_LOOT_COUNCIL",
                "Parsed RC award from chat event=%s winner=%s item=%s rollType=%s",
                tostring(chatEvent),
                tostring(payload.winnerName),
                tostring(payload.itemLink),
                tostring(payload.rollType)
            )
        end
        self:ProcessRCLootCouncilAward(payload)
    elseif SF.Debug and IsPotentialRCAwardMessage(message) then
        SF.Debug:Verbose(
            "RC_LOOT_COUNCIL",
            "Saw possible RC award chat message but could not parse it from %s: %s",
            tostring(chatEvent),
            tostring(message)
        )
    end
end

function SF:TryHookRCLootCouncilIntegration()
    if self._rcLootCouncilHooked then
        return true
    end

    local rcLootCouncil = _G and _G.RCLootCouncil
    if type(rcLootCouncil) ~= "table" or type(rcLootCouncil.SendMessage) ~= "function" then
        if SF.Debug then
            SF.Debug:Verbose("RC_LOOT_COUNCIL", "RCLootCouncil SendMessage hook not available yet")
        end
        return false
    end

    hooksecurefunc(rcLootCouncil, "SendMessage", function(_, messageName, ...)
        if messageName ~= "RCMLAwardSuccess" then
            return
        end

        local session, winner, status, itemLink, responseText = ...
        if SF.Debug then
            SF.Debug:Verbose(
                "RC_LOOT_COUNCIL",
                "Received RCMLAwardSuccess session=%s winner=%s status=%s item=%s response=%s",
                tostring(session),
                tostring(winner),
                tostring(status),
                tostring(itemLink),
                tostring(responseText)
            )
        end
        local payload = BuildRCLootCouncilAwardPayloadFromInternalMessage(session, winner, itemLink, responseText, status)
        if payload then
            self:ProcessRCLootCouncilAward(payload)
        elseif SF.Debug then
            SF.Debug:Warn(
                "RC_LOOT_COUNCIL",
                "Failed to build RC internal payload session=%s winner=%s item=%s response=%s",
                tostring(session),
                tostring(winner),
                tostring(itemLink),
                tostring(responseText)
            )
        end
    end)

    self._rcLootCouncilHooked = true
    if SF.Debug then
        SF.Debug:Info("RC_LOOT_COUNCIL", "Hooked into RCLootCouncil SendMessage")
    end
    return true
end

function SF:InitRCLootCouncilListener()
    if self._rcLootCouncilFrame then
        return
    end

    local frame = CreateFrame("Frame")
    self._rcLootCouncilFrame = frame

    for _, eventName in ipairs(RC_AWARD_CHAT_EVENTS) do
        frame:RegisterEvent(eventName)
    end
    frame:RegisterEvent("ADDON_LOADED")

    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "ADDON_LOADED" then
            local loadedAddon = ...
            if loadedAddon == "RCLootCouncil" then
                if SF.Debug then
                    SF.Debug:Info("RC_LOOT_COUNCIL", "Detected RCLootCouncil addon load")
                end
                self:TryHookRCLootCouncilIntegration()
            end
            return
        end

        local message = ...
        self:HandleRCLootCouncilAwardMessage(message, event)
    end)

    self:TryHookRCLootCouncilIntegration()
    if SF.Debug then
        SF.Debug:Info("RC_LOOT_COUNCIL", "Initialized RC Loot Council listeners")
    end
end

-- Database Initialization for Loot Helper Module
-- @return: none
function SF:InitializeLootHelperDatabase()
    -- Initialize loot helper settings in main database if not present
    if not SpectrumFederationDB.lootHelper then
        SpectrumFederationDB.lootHelper = {
			enabled = false,
			showWindowOutsideRaid = false,
			lockLootWindow = false,
			showMembersNotInRaid = false,

			window = {},

            profiles = {},              -- Map: profileId -> LootProfile
            activeProfileId = nil       -- Active profile's stable ID
        }
        if SF.Debug then SF.Debug:Info("DATABASE", "Initialized loot helper database with profileId-based schema") end
    else
        if SF.Debug then SF.Debug:Info("DATABASE", "Loaded existing loot helper database") end
        
        -- Migration: Detect and convert legacy schema (no-op if already clean)
        SF:MigrateLootHelperSchema()

		local lh = SpectrumFederationDB.lootHelper
		if lh.enabled == nil then lh.enabled = false end
		if lh.showWindowOutsideRaid == nil then lh.showWindowOutsideRaid = false end
		if lh.lockLootWindow == nil then lh.lockLootWindow = false end
		if lh.showMembersNotInRaid == nil then lh.showMembersNotInRaid = false end

		if type(lh.window) ~= "table" then
			lh.window = {}
		end
    end

    SF.lootHelperDB = SpectrumFederationDB.lootHelper

    -- Restore metatables for profiles/members/logs after SavedVariables load
    if SF.RehydrateLootHelperDB then
        SF:RehydrateLootHelperDB()
    end

    -- Maintain legacy pointer
    SF.lootHelperDB.activeProfile = nil
    if SF.lootHelperDB.activeProfileId then
        SF:SetActiveProfileById(SF.lootHelperDB.activeProfileId)
    end

    -- Initialize Loot Helper Communications
    if SF.LootHelperComm then
        SF.LootHelperComm:Init()
    end

	-- Loot Helper Window
	if SF.LootHelperWindow and SF.LootHelperWindow.Controller and SF.LootHelperWindow.Controller.Init then
		SF.LootHelperWindow.Controller:Init()
	end

    SF:InitRCLootCouncilListener()
end

-- Migrate legacy schema to profileId-based canonical schema
-- Handles legacy patterns from development:
-- 1. Array-style: profiles[1], profiles[2], ...
-- 2. Map-by-name: profiles["ProfileName"]
-- 3. Mixed: Both array and map entries
--
-- This is a one-time migration for development data only.
-- @return: none
function SF:MigrateLootHelperSchema()
    local db = SpectrumFederationDB.lootHelper
    if not db or not db.profiles then return end
    
    -- Detect if migration is needed
    local needsMigration = false
    local legacyProfiles = {}
    
    -- Check for array-style storage (numeric keys)
    for i, profile in ipairs(db.profiles) do
        if type(profile) == "table" and profile.GetProfileId then
            needsMigration = true
            table.insert(legacyProfiles, profile)
        end
    end
    
    -- Check for map-by-name storage (string keys that aren't profileIds)
    for key, profile in pairs(db.profiles) do
        if type(key) == "string" and type(profile) == "table" then
            -- ProfileId format: "p_" prefix + hex digits
            if not key:match("^p_%x+") and profile.GetProfileId then
                needsMigration = true
                table.insert(legacyProfiles, profile)
            end
        end
    end
    
    if not needsMigration then
        if SF.Debug then SF.Debug:Verbose("DATABASE", "Schema is already up-to-date") end
        return
    end
    
    if SF.Debug then SF.Debug:Info("DATABASE", "Migrating loot helper schema to profileId-based storage") end
    
    -- Build new map keyed by profileId
    local newProfiles = {}
    for _, profile in ipairs(legacyProfiles) do
        local profileId = profile:GetProfileId()
        if profileId then
            newProfiles[profileId] = profile
            if SF.Debug then
                SF.Debug:Verbose("DATABASE", "Migrated profile: %s (ID: %s)", 
                    profile:GetProfileName() or "Unknown", profileId)
            end
        else
            if SF.Debug then
                SF.Debug:Warn("DATABASE", "Skipping profile without profileId: %s", 
                    tostring(profile:GetProfileName()))
            end
        end
    end
    
    -- Replace old profiles table with new map
    db.profiles = newProfiles
    
    -- Migrate activeProfile (pointer) to activeProfileId, then restore pointer
    if db.activeProfile and type(db.activeProfile) == "table" and db.activeProfile.GetProfileId then
        local profileId = db.activeProfile:GetProfileId()
        if profileId then
            db.activeProfileId = profileId
            -- Keep pointer for backward compatibility with existing code
            db.activeProfile = newProfiles[profileId]
            if SF.Debug then
                SF.Debug:Info("DATABASE", "Migrated active profile: %s -> %s", 
                    db.activeProfile:GetProfileName() or "Unknown", profileId)
            end
        end
    elseif db.activeProfileId and newProfiles[db.activeProfileId] then
        -- Restore pointer if activeProfileId exists but pointer was nil
        db.activeProfile = newProfiles[db.activeProfileId]
    else
        -- Clear if neither field is valid
        db.activeProfile = nil
        db.activeProfileId = nil
    end
    
    if SF.Debug then SF.Debug:Info("DATABASE", "Schema migration complete: %d profiles", 
        SF:TableSize(newProfiles)) end
end

-- Rehydrate LootHelper database by restoring metatables to instances
-- Called after loading SavedVariables to restore class methods
-- @return: none
function SF:RehydrateLootHelperDB()
	local db = self.lootHelperDB
	if not db or type(db.profiles) ~= "table" then
		if SF.Debug then
			SF.Debug:Verbose("DATABASE", "RehydrateLootHelperDB: No profiles to rehydrate")
		end
		return
	end

	local profileCount = 0
	local memberCount = 0
	local logCount = 0

	for id, profile in pairs(db.profiles) do
		if type(profile) == "table" then
			profileCount = profileCount + 1

			-- Restore LootProfile methods
			if self.LootProfile and getmetatable(profile) ~= self.LootProfile then
				setmetatable(profile, self.LootProfile)
			end

			if type(profile._EnsureRaidCheckConfig) == "function" then
				profile:_EnsureRaidCheckConfig()
			end
			if type(profile._EnsureRaidCheckEquipmentSnapshots) == "function" then
				profile:_EnsureRaidCheckEquipmentSnapshots()
			end

			-- Restore Member methods
			if type(profile._members) == "table" and self.Member then
				-- Helper function to extract member ID for deduplication
				-- Returns nil if no valid identifier found (member will be skipped)
				local function GetMemberId(m)
					if type(m.identifier) == "string" and m.identifier ~= "" then
						return m.identifier
					elseif type(m._identifier) == "string" and m._identifier ~= "" then
						return m._identifier
					else
						-- No valid identifier - log warning with member details
						if SF.Debug then
							SF.Debug:Warn("DATABASE", "Member has no valid identifier, skipping (type=%s, has_identifier=%s, has__identifier=%s)",
								type(m), tostring(m.identifier ~= nil), tostring(m._identifier ~= nil))
						end
						return nil
					end
				end
				
				-- Debug: check what type of structure _members is
				local arrayCount = #profile._members
				local totalKeys = 0
				for _ in pairs(profile._members) do
					totalKeys = totalKeys + 1
				end
				
				if SF.Debug and totalKeys > 0 then
					SF.Debug:Verbose("DATABASE", "Profile %s _members structure: arrayLen=%d, totalKeys=%d",
						tostring(profile._profileName or profile._profileId), arrayCount, totalKeys)
				end
				
				-- Try array iteration first (normal case)
				local arrayProcessed = {}
				for i, m in ipairs(profile._members) do
					if type(m) == "table" then
						if getmetatable(m) ~= self.Member then
							setmetatable(m, self.Member)
							memberCount = memberCount + 1
						end
						-- Track which members were found in array (using member ID)
						local memberId = GetMemberId(m)
						if memberId then
							arrayProcessed[memberId] = true
							if SF.Debug then
								SF.Debug:Verbose("DATABASE", "Array member[%d]: %s", i, memberId)
							end
						end
					end
				end
				
				if SF.Debug and memberCount > 0 then
					SF.Debug:Info("DATABASE", "Processed %d members via array iteration (ipairs)", memberCount)
				end
				
				-- Fallback: if we found fewer members via ipairs than total keys, there are map entries
				-- This handles legacy data that might have been stored as a map
				if memberCount < totalKeys then
					if SF.Debug then
						SF.Debug:Warn("DATABASE", "Profile %s has members stored as map (not array), migrating...",
							tostring(profile._profileName or profile._profileId))
						SF.Debug:Warn("DATABASE", "Migration triggered: arrayCount=%d, memberCount=%d, totalKeys=%d",
							arrayCount, memberCount, totalKeys)
					end
					
					-- Build array from all entries using pairs (includes both array and map entries)
					local memberArray = {}
					local processed = {}
					local mapOnlyCount = 0
					
					-- Process all entries (both array indices and string keys)
					for k, m in pairs(profile._members) do
						if type(m) == "table" then
							local memberId = GetMemberId(m)
							
							-- Only process if we have a valid ID and haven't seen this member yet
							if memberId and not processed[memberId] then
								if getmetatable(m) ~= self.Member then
									setmetatable(m, self.Member)
								end
								table.insert(memberArray, m)
								processed[memberId] = true
								
								-- Track whether this is a new map-only member
								local isMapOnly = not arrayProcessed[memberId]
								if isMapOnly then
									memberCount = memberCount + 1
									mapOnlyCount = mapOnlyCount + 1
									if SF.Debug then
										SF.Debug:Info("DATABASE", "Map-only member found (key=%s): %s", tostring(k), memberId)
									end
								end
							elseif not memberId then
								if SF.Debug then
									SF.Debug:Warn("DATABASE", "Skipping member with invalid ID at key: %s", tostring(k))
								end
							else
								if SF.Debug then
									SF.Debug:Verbose("DATABASE", "Duplicate member skipped (key=%s): %s", tostring(k), memberId)
								end
							end
						end
					end
					
					-- Replace with cleaned array
					profile._members = memberArray
					
					if SF.Debug then
						SF.Debug:Info("DATABASE", "Migration complete: %d total members (%d from array, %d from map-only)",
							#memberArray, memberCount - mapOnlyCount, mapOnlyCount)
					end
				end
			end

			-- Restore LootLog methods
			if type(profile._lootLogs) == "table" and self.LootLog then
				for i, log in ipairs(profile._lootLogs) do
					if type(log) == "table" and getmetatable(log) ~= self.LootLog then
						setmetatable(log, self.LootLog)
						logCount = logCount + 1
					end
				end
			end

			-- Rebuild indexes/counters if available
			if profile.RebuildLogIndex then
				profile:RebuildLogIndex()
			end

			-- Ensure owner is admin if you added that helper
			if profile._EnsureOwnerIsAdmin then
				profile:_EnsureOwnerIsAdmin()
			end
		end
	end

	if SF.Debug then
		SF.Debug:Info("DATABASE", "Rehydrated %d profiles, %d members, %d logs", profileCount, memberCount, logCount)
	end
end

-- Helper: Count entries in a table (works for maps and arrays)
-- @param t table Table to count
-- @return number Count of entries
function SF:TableSize(t)
    if not t or type(t) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Set the active loot profile by profileId (canonical method)
-- @param profileId (string) - Stable ID of the profile to set as active
-- @return (boolean) - true if set successfully, false otherwise
function SF:SetActiveProfileById(profileId)
    if type(profileId) ~= "string" or profileId == "" then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "SetActiveProfileById called with invalid profileId: %s", tostring(profileId))
        end
        return false
    end

    local profile = SF.lootHelperDB.profiles[profileId]
    if not profile then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "No loot profile found with ID '%s' to set as active", profileId)
        end
        SF.lootHelperDB.activeProfile = nil
        return false
    end

    -- Deactivate all profiles first
    for _, prof in pairs(SF.lootHelperDB.profiles) do
        if prof.SetActive then
            prof:SetActive(false)
        end
    end
    
    -- Set target profile as active
    if profile.SetActive then
        profile:SetActive(true)
    end

    -- Update BOTH canonical ID and legacy pointer
    -- TODO: We should probably update code to only use one or the other
    SF.lootHelperDB.activeProfileId = profileId
    SF.lootHelperDB.activeProfile = profile

    if SF.Debug then
        SF.Debug:Info("DATABASE", "Set loot profile '%s' (ID: %s) as active", 
            profile:GetProfileName() or "Unknown", profileId)
    end

    return true
end

-- Clear the active loot profile (used when deleting active profile)
-- @return nil
function SF:ClearActiveProfile()
    -- Deactivate all profiles
    for _, prof in pairs(SF.lootHelperDB.profiles) do
        if prof.SetActive then
            prof:SetActive(false)
        end
    end
    
    -- Clear both fields
    SF.lootHelperDB.activeProfileId = nil
    SF.lootHelperDB.activeProfile = nil
    
    if SF.Debug then
        SF.Debug:Info("DATABASE", "Cleared active profile")
    end
end

-- Get the active loot profile
-- @return (LootProfile|nil) - Active profile instance or nil
function SF:GetActiveProfile()
    return SF.lootHelperDB and SF.lootHelperDB.activeProfile or nil
end

-- Legacy function to set the active loot profile by name
-- DEPRECATED: Use SetActiveProfileById instead (kept for transition period)
-- @param profileName (string) - Name of the profile to set as active
-- @return (boolean) - true if set successfully, false otherwise
function SF:SetActiveLootProfile(profileName)
    if SF.Debug then
        SF.Debug:Warn("DATABASE", "SetActiveLootProfile (name-based) is deprecated, use SetActiveProfileById")
    end

    -- Find profile by name
    for profileId, profile in pairs(SF.lootHelperDB.profiles) do
        if profile:GetProfileName() == profileName then
            return SF:SetActiveProfileById(profileId)
        end
    end

    if SF.Debug then
        SF.Debug:Warn("DATABASE", "No loot profile found with name '%s' to set as active", profileName)
    end
    return false
end

-- function to add a loot profile to the profiles database
-- @param lootProfile (LootProfile) - Instance of LootProfile to add
-- @return (boolean) - true if added successfully, false otherwise
function SF:AddLootProfileToDatabase(lootProfile)

    if getmetatable(lootProfile) ~= SF.LootProfile then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "Attempted to add invalid LootProfile instance: %s", tostring(lootProfile))
        end
        return false
    end

    local profileId = lootProfile:GetProfileId()
    if not profileId then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "Cannot add profile without profileId")
        end
        return false
    end

    -- Check if profile already exists
    if SF.lootHelperDB.profiles[profileId] then
        if SF.Debug then
            SF.Debug:Warn("DATABASE", "Loot profile with ID '%s' already exists in database", profileId)
        end
        return false
    end

    SF.lootHelperDB.profiles[profileId] = lootProfile
    if SF.Debug then
        SF.Debug:Info("DATABASE", "Added loot profile '%s' (ID: %s) to database", 
            lootProfile:GetProfileName(), profileId)
    end

    -- Set new profile as active
    local success = self:SetActiveProfileById(profileId)

    return success
end

-- Get profile options for dropdown/UI selection
-- @return (table) - Array of { value = profileId, label = profileName }
function SF:GetLootHelperProfileOptions()
	local out = {}
	local db = self.lootHelperDB
	if not db or type(db.profiles) ~= "table" then return out end

	for id, profile in pairs(db.profiles) do
		local name = id
		if type(profile) == "table" then
			if profile.GetProfileName then
				name = profile:GetProfileName()
			elseif profile._profileName then
				name = profile._profileName
			end
		end
		table.insert(out, { value = id, label = tostring(name) })
	end

	table.sort(out, function(a, b)
		return tostring(a.label) < tostring(b.label)
	end)

	return out
end

-- Create a new loot helper profile
-- @param profileName (string) - Name for the new profile
-- @return (boolean, string|nil) - Success status and optional error message
function SF:CreateLootHelperProfile(profileName)
	profileName = tostring(profileName or ""):match("^%s*(.-)%s*$")
	if profileName == "" then return false, "Profile name cannot be empty." end
	if profileName:find("%.") then return false, "Profile name cannot contain '.'." end

	-- Enforce unique name (per your requirement)
	for _, prof in pairs(self.lootHelperDB.profiles or {}) do
		local n = (prof and prof.GetProfileName and prof:GetProfileName()) or (prof and prof._profileName)
		if n == profileName then
			if SF.Debug then
				SF.Debug:Warn("DATABASE", "Cannot create profile - name already exists: %s", profileName)
			end
			return false, "A profile with that name already exists."
		end
	end

	if not self.LootProfile or not self.LootProfile.new then
		if SF.Debug then
			SF.Debug:Error("DATABASE", "LootProfile class not loaded")
		end
		return false, "LootProfile class not loaded."
	end

	local p = self.LootProfile.new(profileName)
	if not p then
		if SF.Debug then
			SF.Debug:Error("DATABASE", "Failed to create profile instance for: %s", profileName)
		end
		return false, "Failed to create profile."
	end

	local ok = self:AddLootProfileToDatabase(p)
	if not ok then
		if SF.Debug then
			SF.Debug:Error("DATABASE", "Failed to add profile to database: %s", profileName)
		end
		return false, "Failed to add profile to database."
	end

	if SF.Debug then
		SF.Debug:Info("DATABASE", "Created new profile: %s (ID: %s)", profileName, p:GetProfileId())
	end

	return true
end

-- Delete a loot helper profile by ID
-- @param profileId (string) - Profile ID to delete
-- @return (boolean, string|nil) - Success status and optional error message
function SF:DeleteLootHelperProfile(profileId)
	if type(profileId) ~= "string" or profileId == "" then
		if SF.Debug then
			SF.Debug:Warn("DATABASE", "Cannot delete profile - invalid profileId: %s", tostring(profileId))
		end
		return false, "Invalid profile id."
	end

	local db = self.lootHelperDB
	if not db or not db.profiles or not db.profiles[profileId] then
		if SF.Debug then
			SF.Debug:Warn("DATABASE", "Cannot delete profile - not found: %s", profileId)
		end
		return false, "Profile not found."
	end

	local profileName = db.profiles[profileId]:GetProfileName()
	db.profiles[profileId] = nil

	if SF.Debug then
		SF.Debug:Info("DATABASE", "Deleted profile: %s (ID: %s)", profileName or "Unknown", profileId)
	end

	-- If we deleted the active profile, pick a new one or nil
	if db.activeProfileId == profileId then
		self:ClearActiveProfile()

		-- Pick first sorted option (nice UX, minimal logic)
		local opts = self:GetLootHelperProfileOptions()
		if #opts > 0 then
			self:SetActiveProfileById(opts[1].value)
			if SF.Debug then
				SF.Debug:Info("DATABASE", "Auto-selected new active profile: %s", opts[1].label)
			end
		else
			if SF.Debug then
				SF.Debug:Info("DATABASE", "No profiles remaining after deletion")
			end
		end
	end

	return true
end

-- Rename the active loot helper profile
-- @param newName (string) - New name for the profile
-- @return (boolean, string|nil) - Success status and optional error message
function SF:RenameActiveLootHelperProfile(newName)
	local p = self:GetActiveProfile()
	if not p then
		if SF.Debug then
			SF.Debug:Warn("DATABASE", "Cannot rename - no active profile")
		end
		return false, "No active profile."
	end

	local oldName = p:GetProfileName()
	newName = tostring(newName or ""):match("^%s*(.-)%s*$")
	if newName == "" then return false, "Profile name cannot be empty." end
	if newName:find("%.") then return false, "Profile name cannot contain '.'." end

	-- Unique name enforcement
	for _, prof in pairs(self.lootHelperDB.profiles or {}) do
		if prof ~= p then
			local n = (prof and prof.GetProfileName and prof:GetProfileName()) or (prof and prof._profileName)
			if n == newName then
				if SF.Debug then
					SF.Debug:Warn("DATABASE", "Cannot rename - name already exists: %s", newName)
				end
				return false, "A profile with that name already exists."
			end
		end
	end

	if p.SetProfileName then
		p:SetProfileName(newName)
		
		if SF.Debug then
			SF.Debug:Info("DATABASE", "Renamed profile: %s -> %s (ID: %s)", oldName, newName, p:GetProfileId())
		end
		return true
	end

	if SF.Debug then
		SF.Debug:Error("DATABASE", "Cannot rename - profile missing SetProfileName method")
	end
	return false, "Active profile cannot be renamed (missing SetProfileName)."
end

-- Add an admin to the active loot helper profile
-- @param memberId (string) - Member ID to add as admin
-- @return (boolean, string|nil) - Success status and optional error message
function SF:AddAdminToActiveLootHelperProfile(memberId)
	if SF.Debug then
		SF.Debug:Info("LOOTHELPER", "AddAdminToActiveLootHelperProfile called with memberId: %s", tostring(memberId))
	end
	
	local p = self:GetActiveProfile()
	if not p then 
		if SF.Debug then
			SF.Debug:Warn("LOOTHELPER", "No active profile")
		end
		return false, "No active profile." 
	end
	
	if not p.AddAdminMemberId then 
		if SF.Debug then
			SF.Debug:Warn("LOOTHELPER", "Profile missing AddAdminMemberId method")
		end
		return false, "Profile missing AddAdminMemberId." 
	end
	
	local ok, err = p:AddAdminMemberId(memberId)
	if SF.Debug then
		SF.Debug:Info("LOOTHELPER", "AddAdminMemberId returned: ok=%s, err=%s", tostring(ok), tostring(err))
	end
	return ok, err
end

-- Remove an admin from the active loot helper profile
-- @param memberId (string) - Member ID to remove from admins
-- @return (boolean, string|nil) - Success status and optional error message
function SF:RemoveAdminFromActiveLootHelperProfile(memberId)
	local p = self:GetActiveProfile()
	if not p then return false, "No active profile." end
	if not p.RemoveAdminMemberId then return false, "Profile missing RemoveAdminMemberId." end
	return p:RemoveAdminMemberId(memberId)
end

-- Reset all loot helper settings (dangerous operation)
-- @return (boolean, string|nil) - Success status and optional error message
function SF:ResetAllLootHelperSettings()
	local db = self.lootHelperDB
	if not db then
		if SF.Debug then
			SF.Debug:Error("DATABASE", "Cannot reset - LootHelper DB not initialized")
		end
		return false, "LootHelper DB not initialized."
	end

	local profileCount = 0
	for _ in pairs(db.profiles or {}) do
		profileCount = profileCount + 1
	end

	db.profiles = {}
	db.activeProfileId = nil
	db.activeProfile = nil

	if SF.Debug then
		SF.Debug:Info("DATABASE", "Reset all loot helper settings - cleared %d profiles", profileCount)
	end

	return true
end
