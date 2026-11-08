-- Guild Info roster snapshot for suggestions and membership status (#402).
-- Demand-driven; never scans the roster on every keystroke.
local addonName, SF = ...

SF.GuildInfo = SF.GuildInfo or {}
local GI = SF.GuildInfo

local cachedSnapshot = nil
local cachedGeneration = nil

local function NormalizeName(name)
    local NU = SF.NameUtil
    if NU and NU.NormalizeNameRealm then
        return NU.NormalizeNameRealm(name)
    end
    local GG = SF.GuildGossip
    if GG and GG.NormalizePlayer then
        return GG.NormalizePlayer(name)
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

local function LocStatus(kind)
    if kind == "departed" then
        if SF.LocaleText then
            return SF.LocaleText("GUILD_INFO_STATUS_DEPARTED", "(No longer in guild)")
        end
        return "(No longer in guild)"
    end
    if SF.LocaleText then
        return SF.LocaleText("GUILD_INFO_STATUS_UNKNOWN", "(Unknown / roster unavailable)")
    end
    return "(Unknown / roster unavailable)"
end

--- Build a fresh roster snapshot. Completeness requires demand-scope trust.
-- @return table snapshot
function GI.BuildRosterSnapshot()
    local GG = SF.GuildGossip
    local snap = {
        complete = false,
        reason = "not_ready",
        guildKey = nil,
        clubId = nil,
        members = {}, -- array
        byGuid = {},
        byNameLower = {}, -- nameRealm lower → guid or false if ambiguous
        generation = 0,
        builtAt = (GetTime and GetTime()) or 0,
    }

    if not GG or type(GG.GetGuildIdentity) ~= "function" then
        snap.reason = "identity_unavailable"
        return snap
    end
    local identity, idReason = GG.GetGuildIdentity()
    if not identity then
        snap.reason = idReason or "not_in_guild"
        return snap
    end
    snap.guildKey = identity.guildKey
    snap.clubId = identity.clubId

    -- Probe demand roster trust via ranks (fail closed while incomplete).
    local ranks, rankReason = GG.GetGuildRanks()
    if not ranks then
        snap.reason = rankReason or "roster_incomplete"
        return snap
    end

    if type(GetNumGuildMembers) ~= "function" or type(GetGuildRosterInfo) ~= "function" then
        snap.reason = "roster_unavailable"
        return snap
    end

    local totalRaw = GetNumGuildMembers()
    local total = tonumber(totalRaw) or 0
    if total <= 0 then
        snap.reason = "roster_incomplete"
        return snap
    end

    local members = {}
    local byGuid = {}
    local nameCounts = {}
    local skippedRows = 0

    for i = 1, total do
        local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17 =
            GetGuildRosterInfo(i)
        local rosterName, rankIndex, isOnline, classFileName, guid =
            a1, a3, a9, a11, a17
        local nameRealm = NormalizeName(rosterName)
        if nameRealm and type(guid) == "string" and guid ~= "" then
            local rankOrder = nil
            if C_GuildInfo and type(C_GuildInfo.GetGuildRankOrder) == "function" then
                rankOrder = tonumber(C_GuildInfo.GetGuildRankOrder(guid))
            end
            if not rankOrder then
                -- GetGuildRosterInfo rankIndex is 0-based in many clients.
                rankIndex = tonumber(rankIndex)
                if rankIndex and rankIndex >= 0 then
                    rankOrder = rankIndex + 1
                end
            end
            local classFile = nil
            if type(classFileName) == "string" and classFileName ~= "" then
                classFile = string.upper(classFileName)
            end
            local row = {
                guid = guid,
                nameRealm = nameRealm,
                classFile = classFile,
                online = isOnline and true or false,
                rankOrder = rankOrder,
                inGuild = true,
            }
            members[#members + 1] = row
            byGuid[guid] = row
            local lower = string.lower(nameRealm)
            nameCounts[lower] = (nameCounts[lower] or 0) + 1
        else
            -- Nonzero member count with a missing GUID/name row is incomplete:
            -- absence must not be treated as verified departure (E).
            skippedRows = skippedRows + 1
        end
    end
    if skippedRows > 0 then
        snap.reason = "roster_incomplete"
        snap.complete = false
        return snap
    end
    -- An empty-but-complete roster is valid only when GetNumGuildMembers was 0
    -- (handled above). Here every reported row produced a usable member.

    local byNameLower = {}
    for i = 1, #members do
        local row = members[i]
        local lower = string.lower(row.nameRealm)
        if nameCounts[lower] == 1 then
            byNameLower[lower] = row.guid
        else
            byNameLower[lower] = false -- ambiguous short collision across realms still unique via full Name-Realm
        end
    end

    -- Also index short names when unique across the roster.
    local shortCounts = {}
    for i = 1, #members do
        local short = members[i].nameRealm:match("^([^-]+)")
        if short then
            local sl = string.lower(short)
            shortCounts[sl] = (shortCounts[sl] or 0) + 1
        end
    end
    local shortToGuid = {}
    for i = 1, #members do
        local short = members[i].nameRealm:match("^([^-]+)")
        if short then
            local sl = string.lower(short)
            if shortCounts[sl] == 1 then
                shortToGuid[sl] = members[i].guid
            else
                shortToGuid[sl] = false
            end
        end
    end

    snap.complete = true
    snap.reason = nil
    snap.members = members
    snap.byGuid = byGuid
    snap.byNameLower = byNameLower
    snap.shortToGuid = shortToGuid
    snap.generation = (GG.GetGuildGeneration and GG.GetGuildGeneration()) or 0

    function snap:Resolve(ref)
        if type(ref) == "table" and type(ref.guid) == "string" then
            local row = self.byGuid[ref.guid]
            if row then
                return row
            end
            return nil, "not_a_member"
        end
        if type(ref) ~= "string" or ref == "" then
            return nil, "identity_unavailable"
        end
        -- GUID-shaped?
        if ref:match("^Player%-") and self.byGuid[ref] then
            return self.byGuid[ref]
        end
        -- Short name (no realm): require uniqueness across the roster. Do not
        -- silently fill the player's realm first — that would hide cross-realm
        -- duplicates (e.g. Bob-Garona vs Bob-Area52).
        if not ref:find("-", 1, true) then
            local shortLower = string.lower(strtrim(ref))
            local shortGuid = self.shortToGuid and self.shortToGuid[shortLower]
            if shortGuid == false then
                return nil, "ambiguous_name"
            end
            if type(shortGuid) == "string" and self.byGuid[shortGuid] then
                return self.byGuid[shortGuid]
            end
            return nil, "not_a_member"
        end
        local norm = NormalizeName(ref)
        if not norm then
            return nil, "identity_unavailable"
        end
        local lower = string.lower(norm)
        local guid = self.byNameLower[lower]
        if guid == false then
            return nil, "ambiguous_name"
        end
        if type(guid) == "string" and self.byGuid[guid] then
            return self.byGuid[guid]
        end
        return nil, "not_a_member"
    end

    --- Prefix/substring name suggestions from the current roster.
    -- Optional `predicate(row)` is applied before counting toward `limit` so
    -- role eligibility (and similar filters) cannot hide later eligible matches
    -- behind the visible-results cap (#470).
    function snap:Suggest(prefix, limit, predicate)
        limit = math.max(1, math.min(tonumber(limit) or 12, 32))
        local q = type(prefix) == "string" and string.lower(strtrim(prefix)) or ""
        local out = {}
        if q == "" then
            return out
        end
        local filter = type(predicate) == "function" and predicate or nil
        for i = 1, #self.members do
            local row = self.members[i]
            local nameLower = string.lower(row.nameRealm)
            local short = nameLower:match("^([^-]+)") or nameLower
            if nameLower:sub(1, #q) == q or short:sub(1, #q) == q or nameLower:find(q, 1, true) then
                if not filter or filter(row) then
                    out[#out + 1] = row
                    if #out >= limit then
                        break
                    end
                end
            end
        end
        table.sort(out, function(a, b)
            return string.lower(a.nameRealm) < string.lower(b.nameRealm)
        end)
        return out
    end

    return snap
end

--- Cached snapshot invalidated on guild generation change.
-- Incomplete snapshots are never reused: a later call may see a ready roster.
function GI.GetRosterSnapshot(force)
    local GG = SF.GuildGossip
    local gen = (GG and GG.GetGuildGeneration and GG.GetGuildGeneration()) or 0
    if (not force)
        and cachedSnapshot
        and cachedSnapshot.complete
        and cachedGeneration == gen then
        return cachedSnapshot
    end
    cachedSnapshot = GI.BuildRosterSnapshot()
    cachedGeneration = gen
    return cachedSnapshot
end

function GI.InvalidateRosterSnapshot()
    cachedSnapshot = nil
    cachedGeneration = nil
end

--- Membership presentation status for a stored character.
-- complete roster absent → departed; incomplete → unknown.
--- @param record optional already-validated guild record (avoids ValidateGuildRecord per row)
function GI.GetMembershipStatus(guid, roster, record)
    roster = roster or GI.GetRosterSnapshot()
    if type(guid) ~= "string" or guid == "" then
        return "unknown", "identity_unavailable"
    end
    if not roster then
        return "unknown", "roster_unavailable"
    end
    if not roster.complete then
        return "unknown", roster.reason or "roster_incomplete"
    end
    if roster.byGuid and roster.byGuid[guid] then
        local row = roster.byGuid[guid]
        -- Refresh last-known display from trustworthy roster.
        record = record or select(1, GI:GetCurrentRecord())
        if record then
            GI.UpdateCharacterDisplay(record, guid, row.nameRealm, row.classFile)
        end
        return "in_guild", nil, row
    end
    return "departed", nil
end

function GI.ColorizeName(nameRealm, classFile)
    local C = SF.Consumables
    if C and type(C.ColorizeCharacterName) == "function" then
        return C.ColorizeCharacterName(nameRealm, classFile)
    end
    if type(nameRealm) ~= "string" then
        return tostring(nameRealm or "")
    end
    local classData = classFile and SF.WOW_CLASSES and SF.WOW_CLASSES[string.upper(classFile)]
    local color = classData and classData.colorCode
    if type(color) ~= "table" then
        return nameRealm
    end
    local r = math.floor((tonumber(color.r) or 1) * 255 + 0.5)
    local g = math.floor((tonumber(color.g) or 1) * 255 + 0.5)
    local b = math.floor((tonumber(color.b) or 1) * 255 + 0.5)
    return string.format("|cff%02x%02x%02x%s|r", r, g, b, nameRealm)
end

--- Sorted display rows for Settings list.
function GI:GetAssignmentDisplayRows(roster)
    roster = roster or GI.GetRosterSnapshot()
    local groups, reason, record = GI:GetRelationshipGroups()
    if not groups then
        return {}, reason
    end
    local caps = GI:GetCapabilities()
    local canEdit = caps.canEdit and true or false

    local displayGroups = {}
    for i = 1, #groups do
        local g = groups[i]
        local mainChar = record and record.characters and record.characters[g.mainGuid]
        local mainName = (mainChar and mainChar.nameRealm) or g.mainGuid
        local mainClass = mainChar and mainChar.classFile or nil
        local mainStatus = select(1, GI.GetMembershipStatus(g.mainGuid, roster, record))
        if roster and roster.complete and roster.byGuid and roster.byGuid[g.mainGuid] then
            mainClass = roster.byGuid[g.mainGuid].classFile or mainClass
            mainName = roster.byGuid[g.mainGuid].nameRealm or mainName
        end

        local alts = {}
        for j = 1, #(g.altGuids or {}) do
            local ag = g.altGuids[j]
            local achar = record and record.characters and record.characters[ag]
            local aname = (achar and achar.nameRealm) or ag
            local aclass = achar and achar.classFile or nil
            local astatus = select(1, GI.GetMembershipStatus(ag, roster, record))
            if roster and roster.complete and roster.byGuid and roster.byGuid[ag] then
                aclass = roster.byGuid[ag].classFile or aclass
                aname = roster.byGuid[ag].nameRealm or aname
            end
            alts[#alts + 1] = {
                guid = ag,
                nameRealm = aname,
                classFile = aclass,
                status = astatus,
                sortKey = string.lower(aname),
            }
        end
        table.sort(alts, function(a, b)
            return a.sortKey < b.sortKey
        end)

        displayGroups[#displayGroups + 1] = {
            mainGuid = g.mainGuid,
            nameRealm = mainName,
            classFile = mainClass,
            status = mainStatus,
            alts = alts,
            sortKey = string.lower(mainName),
            canEdit = canEdit,
        }
    end
    table.sort(displayGroups, function(a, b)
        return a.sortKey < b.sortKey
    end)

    local rows = {}
    for i = 1, #displayGroups do
        local g = displayGroups[i]
        local statusSuffix = ""
        if g.status == "departed" then
            statusSuffix = " " .. LocStatus("departed")
        elseif g.status == "unknown" then
            statusSuffix = " " .. LocStatus("unknown")
        end
        rows[#rows + 1] = {
            id = "main:" .. g.mainGuid,
            clusterId = g.mainGuid,
            role = "main",
            guid = g.mainGuid,
            text = GI.ColorizeName(g.nameRealm, g.classFile) .. statusSuffix,
            canRemove = false,
            group = g,
        }
        for j = 1, #g.alts do
            local a = g.alts[j]
            local aSuffix = ""
            if a.status == "departed" then
                aSuffix = " " .. LocStatus("departed")
            elseif a.status == "unknown" then
                aSuffix = " " .. LocStatus("unknown")
            end
            rows[#rows + 1] = {
                id = "alt:" .. a.guid,
                clusterId = g.mainGuid,
                role = "alt",
                guid = a.guid,
                mainGuid = g.mainGuid,
                text = "    " .. GI.ColorizeName(a.nameRealm, a.classFile) .. aSuffix,
                canRemove = g.canEdit and true or false,
                group = g,
            }
        end
    end
    return rows, nil, displayGroups
end

--- GUID set of characters currently assigned as alts (read-only projection).
-- Includes alts of departed mains. Does not mutate durable state.
function GI.GetAssignedAltGuidSet(record)
    local set = {}
    if type(record) ~= "table" or type(record.graph) ~= "table" or type(record.graph.byGuid) ~= "table" then
        return set
    end
    for guid, info in pairs(record.graph.byGuid) do
        if type(guid) == "string" and type(info) == "table" and info.role == "alt" then
            set[guid] = info.mainGuid or true
        end
    end
    return set
end

--- Eligible Main-panel rows for the two-column Assignments UI (#468).
-- Rostered non-alts only. Incomplete/syncing roster yields no rows (never
-- treat unknown as departed). Confirmed departed mains are absent because they
-- are not rostered; their backend relationships are untouched.
function GI:GetEligibleMainDisplayRows(roster)
    roster = roster or GI.GetRosterSnapshot()
    if not roster or not roster.complete then
        return {}, (roster and roster.reason) or "roster_incomplete"
    end

    local groups, reason, record = GI:GetRelationshipGroups()
    if reason == "generation_syncing" then
        return {}, reason
    end
    if groups == nil and reason then
        return {}, reason
    end

    local altSet = GI.GetAssignedAltGuidSet(record)
    local rows = {}
    local seen = {}
    for i = 1, #(roster.members or {}) do
        local member = roster.members[i]
        local guid = member and member.guid
        if type(guid) == "string" and guid ~= "" and not seen[guid] and not altSet[guid] then
            seen[guid] = true
            local nameRealm = member.nameRealm or guid
            local classFile = member.classFile
            rows[#rows + 1] = {
                id = "main:" .. guid,
                clusterId = guid,
                role = "main",
                guid = guid,
                nameRealm = nameRealm,
                classFile = classFile,
                text = GI.ColorizeName(nameRealm, classFile),
                canRemove = false,
                canAction = false,
                sortKey = string.lower(nameRealm),
            }
        end
    end
    table.sort(rows, function(a, b)
        return a.sortKey < b.sortKey
    end)
    return rows, nil
end

--- Alts-panel rows for a selected main (#468).
-- Only currently rostered alts of that main. Confirmed departed alts are
-- omitted from the projection; unknown is never treated as departure.
-- Empty table when no main is selected or the main has no visible alts.
function GI:GetSelectedAltDisplayRows(mainGuid, roster)
    roster = roster or GI.GetRosterSnapshot()
    if type(mainGuid) ~= "string" or mainGuid == "" then
        return {}, nil
    end
    if not roster or not roster.complete then
        return {}, (roster and roster.reason) or "roster_incomplete"
    end

    local groups, reason, record = GI:GetRelationshipGroups()
    if reason == "generation_syncing" then
        return {}, reason
    end
    if groups == nil and reason then
        return {}, reason
    end

    local caps = GI:GetCapabilities()
    local canEdit = caps.canEdit and true or false

    local altGuids = {}
    local seenAlt = {}
    if record and record.graph then
        local group = record.graph.mains and record.graph.mains[mainGuid]
        if group and type(group.altGuids) == "table" then
            for i = 1, #group.altGuids do
                local ag = group.altGuids[i]
                if type(ag) == "string" and ag ~= "" and not seenAlt[ag] then
                    seenAlt[ag] = true
                    altGuids[#altGuids + 1] = ag
                end
            end
        end
        for guid, info in pairs(record.graph.byGuid or {}) do
            if type(info) == "table" and info.role == "alt" and info.mainGuid == mainGuid then
                if type(guid) == "string" and guid ~= "" and not seenAlt[guid] then
                    seenAlt[guid] = true
                    altGuids[#altGuids + 1] = guid
                end
            end
        end
    end

    local rows = {}
    for i = 1, #altGuids do
        local ag = altGuids[i]
        local status, _, memberRow = GI.GetMembershipStatus(ag, roster, record)
        if status == "in_guild" and memberRow then
            local nameRealm = memberRow.nameRealm or ag
            local classFile = memberRow.classFile
            rows[#rows + 1] = {
                id = "alt:" .. ag,
                clusterId = mainGuid,
                role = "alt",
                guid = ag,
                mainGuid = mainGuid,
                nameRealm = nameRealm,
                classFile = classFile,
                text = GI.ColorizeName(nameRealm, classFile),
                canRemove = canEdit,
                canAction = canEdit,
                sortKey = string.lower(nameRealm),
            }
        elseif status == "unknown" then
            -- Incomplete roster path: show truthful unknown, never as departed.
            local nameRealm, classFile = ag, nil
            if record and record.characters and record.characters[ag] then
                nameRealm = record.characters[ag].nameRealm or nameRealm
                classFile = record.characters[ag].classFile
            end
            rows[#rows + 1] = {
                id = "alt:" .. ag,
                clusterId = mainGuid,
                role = "alt",
                guid = ag,
                mainGuid = mainGuid,
                nameRealm = nameRealm,
                classFile = classFile,
                text = GI.ColorizeName(nameRealm, classFile) .. " " .. LocStatus("unknown"),
                canRemove = canEdit,
                canAction = false,
                sortKey = string.lower(nameRealm),
            }
        end
        -- status == "departed": hidden in this UI only; backend relationship retained.
    end
    table.sort(rows, function(a, b)
        return a.sortKey < b.sortKey
    end)
    return rows, nil
end

--- True when guid is still an eligible Main-panel selection.
function GI:IsEligibleMainSelection(guid, roster)
    if type(guid) ~= "string" or guid == "" then
        return false
    end
    local rows = GI:GetEligibleMainDisplayRows(roster)
    for i = 1, #rows do
        if rows[i].guid == guid then
            return true
        end
    end
    return false
end

