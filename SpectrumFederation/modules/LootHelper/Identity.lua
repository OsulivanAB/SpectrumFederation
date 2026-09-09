-- Linked-character identity reconstruction for Loot Helper profiles.
-- Projection is derived from append-only logs. Member caches are written by the owning profile.

local addonName, SF = ...

local Identity = {}
SF.LootHelperIdentity = Identity

local RING_INDEX = {
    Ring1 = 1,
    Ring2 = 2,
}
local TRINKET_INDEX = {
    Trinket1 = 1,
    Trinket2 = 2,
}

local function NormalizeId(id)
    if type(id) ~= "string" or id == "" then
        return nil
    end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(id) or id
    end
    return id
end

local function SamePlayer(a, b)
    a = NormalizeId(a)
    b = NormalizeId(b)
    if not a or not b then
        return false
    end
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

local function SortedUnique(ids)
    local seen = {}
    local out = {}
    if type(ids) ~= "table" then
        return out
    end
    for _, id in ipairs(ids) do
        local norm = NormalizeId(id)
        if norm and not seen[norm] then
            seen[norm] = true
            out[#out + 1] = norm
        end
    end
    table.sort(out)
    return out
end

local function ListToSet(list)
    local set = {}
    for _, id in ipairs(list or {}) do
        set[id] = true
    end
    return set
end

local function IsSubset(small, largeSet)
    if type(small) ~= "table" then
        return false
    end
    if #small == 0 then
        return false
    end
    for _, id in ipairs(small) do
        if not largeSet[id] then
            return false
        end
    end
    return true
end

local function GetLogType(log)
    if type(log) ~= "table" then
        return nil
    end
    if log.GetEventType then
        return log:GetEventType()
    end
    return log._eventType
end

local function GetLogData(log)
    if type(log) ~= "table" then
        return nil
    end
    if log.GetEventData then
        return log:GetEventData()
    end
    return log._data
end

function Identity.CompareLogs(a, b)
    local aTime = (a and a.GetTimestamp and a:GetTimestamp()) or (a and a._timestamp) or 0
    local bTime = (b and b.GetTimestamp and b:GetTimestamp()) or (b and b._timestamp) or 0
    if aTime ~= bTime then
        return aTime < bTime
    end

    local aAuthor = (a and a.GetAuthor and a:GetAuthor()) or (a and a._author) or ""
    local bAuthor = (b and b.GetAuthor and b:GetAuthor()) or (b and b._author) or ""
    if aAuthor ~= bAuthor then
        return aAuthor < bAuthor
    end

    local aCounter = (a and a.GetCounter and a:GetCounter()) or (a and a._counter) or 0
    local bCounter = (b and b.GetCounter and b:GetCounter()) or (b and b._counter) or 0
    if aCounter ~= bCounter then
        return aCounter < bCounter
    end

    local aId = (a and a.GetID and a:GetID()) or (a and a._id) or ""
    local bId = (b and b.GetID and b:GetID()) or (b and b._id) or ""
    return aId < bId
end

local function NewPartition()
    return {
        parent = {},
        groups = {},
    }
end

local function EnsureMember(partition, id)
    id = NormalizeId(id)
    if not id then
        return nil
    end
    if not partition.parent[id] then
        partition.parent[id] = id
        partition.groups[id] = { id }
    end
    return id
end

local function FindRoot(partition, id)
    id = NormalizeId(id)
    if not id then
        return nil
    end
    EnsureMember(partition, id)
    return partition.parent[id]
end

local function ComponentList(partition, id)
    local root = FindRoot(partition, id)
    if not root then
        return {}
    end
    local list = partition.groups[root] or {}
    local copy = {}
    for i = 1, #list do
        copy[i] = list[i]
    end
    table.sort(copy)
    return copy
end

local function ComponentSet(partition, id)
    return ListToSet(ComponentList(partition, id))
end

local function Union(partition, a, b)
    a = EnsureMember(partition, a)
    b = EnsureMember(partition, b)
    if not a or not b then
        return
    end
    local ra = FindRoot(partition, a)
    local rb = FindRoot(partition, b)
    if ra == rb then
        return
    end
    local keep, drop = ra, rb
    if rb < ra then
        keep, drop = rb, ra
    end
    local keepList = partition.groups[keep] or {}
    local dropList = partition.groups[drop] or {}
    for i = 1, #dropList do
        local memberId = dropList[i]
        partition.parent[memberId] = keep
        keepList[#keepList + 1] = memberId
    end
    partition.groups[keep] = keepList
    partition.groups[drop] = nil
end

local function Split(partition, id)
    id = EnsureMember(partition, id)
    if not id then
        return
    end
    local root = FindRoot(partition, id)
    local group = partition.groups[root] or {}
    if #group <= 1 then
        return
    end
    local rest = {}
    for i = 1, #group do
        local memberId = group[i]
        if memberId ~= id then
            rest[#rest + 1] = memberId
        end
    end
    partition.groups[root] = nil
    partition.parent[id] = id
    partition.groups[id] = { id }
    if #rest == 0 then
        return
    end
    table.sort(rest)
    local newRoot = rest[1]
    partition.groups[newRoot] = rest
    for i = 1, #rest do
        partition.parent[rest[i]] = newRoot
    end
end

local function EmptyArmor()
    local armor = {}
    if SF.ArmorSlots then
        for _, slotName in pairs(SF.ArmorSlots) do
            armor[slotName] = false
        end
    else
        armor.Head = false
        armor.Shoulder = false
        armor.Neck = false
        armor.Back = false
        armor.Chest = false
        armor.Bracers = false
        armor.Weapon = false
        armor.OffHand = false
        armor.Hands = false
        armor.Belt = false
        armor.Pants = false
        armor.Boots = false
        armor.Ring1 = false
        armor.Ring2 = false
        armor.Trinket1 = false
        armor.Trinket2 = false
    end
    return armor
end

local function NewFamilyOcc()
    return {
        occupied = { false, false },
        overflow = 0,
    }
end

local function NewIdentityOcc()
    return {
        ordinary = {},
        ring = NewFamilyOcc(),
        trinket = NewFamilyOcc(),
    }
end

local function CloneFamily(family)
    return {
        occupied = { family.occupied[1], family.occupied[2] },
        overflow = family.overflow,
    }
end

local function CloneOcc(occ)
    local ordinary = {}
    for slot, state in pairs(occ.ordinary) do
        ordinary[slot] = {
            occupied = state.occupied,
            overflow = state.overflow,
        }
    end
    return {
        ordinary = ordinary,
        ring = CloneFamily(occ.ring),
        trinket = CloneFamily(occ.trinket),
    }
end

local function FamilyForSlot(slot)
    if RING_INDEX[slot] then
        return "ring", RING_INDEX[slot]
    end
    if TRINKET_INDEX[slot] then
        return "trinket", TRINKET_INDEX[slot]
    end
    return "ordinary", slot
end

local function CompareOrigin(a, b)
    if a.log and b.log then
        if a.log ~= b.log then
            return Identity.CompareLogs(a.log, b.log)
        end
    elseif a.log then
        return true
    elseif b.log then
        return false
    end
    if a.member ~= b.member then
        return a.member < b.member
    end
    return tostring(a.slot) < tostring(b.slot)
end

local function PackLocals(memberIds, localArmor, localOrigin)
    local occ = NewIdentityOcc()
    local ringUsages = {}
    local trinketUsages = {}

    for i = 1, #memberIds do
        local memberId = memberIds[i]
        local armor = localArmor[memberId] or {}
        local origin = localOrigin[memberId] or {}
        for slot, used in pairs(armor) do
            if used then
                local family = FamilyForSlot(slot)
                if family == "ring" then
                    ringUsages[#ringUsages + 1] = {
                        log = origin[slot],
                        member = memberId,
                        slot = slot,
                    }
                elseif family == "trinket" then
                    trinketUsages[#trinketUsages + 1] = {
                        log = origin[slot],
                        member = memberId,
                        slot = slot,
                    }
                else
                    local state = occ.ordinary[slot]
                    if not state then
                        state = { occupied = false, overflow = 0 }
                        occ.ordinary[slot] = state
                    end
                    if state.occupied then
                        state.overflow = state.overflow + 1
                    else
                        state.occupied = true
                    end
                end
            end
        end
    end

    -- Singleton identities keep each character's local Ring1/Ring2 and
    -- Trinket1/Trinket2. Linked identities pack currently-active local usages
    -- chronologically onto projected Slot 1, then Slot 2, then overflow.
    local linked = #memberIds >= 2
    local function packFamily(usages, familyOcc, slotIndex)
        table.sort(usages, CompareOrigin)
        if not linked then
            for i = 1, #usages do
                local preferred = slotIndex[usages[i].slot]
                if preferred and not familyOcc.occupied[preferred] then
                    familyOcc.occupied[preferred] = true
                elseif preferred then
                    familyOcc.overflow = familyOcc.overflow + 1
                end
            end
            return
        end
        for i = 1, #usages do
            if i == 1 then
                familyOcc.occupied[1] = true
            elseif i == 2 then
                familyOcc.occupied[2] = true
            else
                familyOcc.overflow = familyOcc.overflow + 1
            end
        end
    end

    packFamily(ringUsages, occ.ring, RING_INDEX)
    packFamily(trinketUsages, occ.trinket, TRINKET_INDEX)
    return occ
end

local function ApplyIdentityArmor(occ, slot, action)
    local family, key = FamilyForSlot(slot)
    if family == "ordinary" then
        local state = occ.ordinary[key]
        if not state then
            state = { occupied = false, overflow = 0 }
            occ.ordinary[key] = state
        end
        if action == "USED" then
            if state.occupied then
                state.overflow = state.overflow + 1
            else
                state.occupied = true
            end
        elseif action == "AVAILABLE" then
            state.occupied = false
        end
        return
    end

    local familyOcc = occ[family]
    local index = key
    if action == "USED" then
        if familyOcc.occupied[index] then
            familyOcc.overflow = familyOcc.overflow + 1
        else
            familyOcc.occupied[index] = true
        end
    elseif action == "AVAILABLE" then
        familyOcc.occupied[index] = false
    end
end

local function OccupiedBool(occ, slot)
    local family, key = FamilyForSlot(slot)
    if family == "ordinary" then
        local state = occ.ordinary[key]
        -- Lua `and` would return nil for unused slots; Member:ToggleEquipment
        -- treats a missing key as an invalid slot.
        return (state and state.occupied) == true
    end
    return occ[family].occupied[key] == true
end

local function CopyArmor(src)
    local armor = EmptyArmor()
    if type(src) ~= "table" then
        return armor
    end
    for slot in pairs(armor) do
        armor[slot] = src[slot] == true
    end
    return armor
end

local function OverflowKeys(occ)
    local keys = {}
    if occ.ring.overflow > 0 then
        keys[#keys + 1] = "ring"
    end
    if occ.trinket.overflow > 0 then
        keys[#keys + 1] = "trinket"
    end
    for slot, state in pairs(occ.ordinary) do
        if state.overflow and state.overflow > 0 then
            keys[#keys + 1] = slot
        end
    end
    table.sort(keys)
    return keys
end

local function IdentityHasOverflow(occ)
    return #OverflowKeys(occ) > 0
end

local function ArmorFromOcc(occ)
    local armor = EmptyArmor()
    for slot in pairs(armor) do
        armor[slot] = OccupiedBool(occ, slot)
    end
    return armor
end

local function EventTypes()
    return (SF.LootLogEventTypes) or {}
end

local function ArmorActions()
    return (SF.LootLogArmorActions) or { USED = "USED", AVAILABLE = "AVAILABLE" }
end

local function MemberRoles()
    return (SF.MemberRoles) or { ADMIN = "admin", MEMBER = "member" }
end

local function IsIdentityArmor(data)
    return type(data) == "table" and data.scope == "identity"
end

local function CanonicalIdentityMembers(data)
    if type(data) ~= "table" then
        return {}
    end
    return SortedUnique(data.identityMembers)
end

local function CanonicalAdminMembersAtLink(data)
    if type(data) ~= "table" then
        return {}
    end
    return SortedUnique(data.adminMembersAtLink)
end

local function GetAmount(kind, data)
    if kind == "points" then
        if SF.LootLog and SF.LootLog.GetPointChangeAmount then
            return SF.LootLog.GetPointChangeAmount(data)
        end
        return tonumber(data and data.amount) or 1
    end
    if SF.LootLog and SF.LootLog.GetAttendanceChangeAmount then
        return SF.LootLog.GetAttendanceChangeAmount(data)
    end
    return tonumber(data and data.amount) or 1
end

local function ApplyAuthAdmin(auth, simulated, owner, memberId, isAdmin)
    memberId = NormalizeId(memberId)
    if not memberId then
        return
    end
    if SamePlayer(memberId, owner) then
        simulated[memberId] = true
        if isAdmin then
            auth[memberId] = "admin"
        end
        return
    end
    if isAdmin then
        auth[memberId] = "admin"
        simulated[memberId] = true
    else
        auth[memberId] = "member"
        simulated[memberId] = nil
    end
end

local function ComponentHasSimulatedAdmin(memberIds, simulated, owner)
    for i = 1, #memberIds do
        local memberId = memberIds[i]
        if simulated[memberId] or SamePlayer(memberId, owner) then
            return true
        end
    end
    return false
end

local function ImplyIdentityAdmins(memberIds, simulated, owner)
    for i = 1, #memberIds do
        local memberId = memberIds[i]
        simulated[memberId] = true
        if SamePlayer(memberId, owner) then
            simulated[memberId] = true
        end
    end
end

function Identity.NormalizeMemberId(id)
    return NormalizeId(id)
end

function Identity.SamePlayer(a, b)
    return SamePlayer(a, b)
end

function Identity.SortedUnique(ids)
    return SortedUnique(ids)
end

function Identity.AffectsProjection(eventType)
    return eventType == (EventTypes().CHARACTER_LINK)
        or eventType == (EventTypes().CHARACTER_UNLINK)
        or eventType == (EventTypes().MAIN_SWAP)
        or eventType == (EventTypes().POINT_CHANGE)
        or eventType == (EventTypes().ATTENDANCE_CHANGE)
        or eventType == (EventTypes().ARMOR_CHANGE)
        or eventType == (EventTypes().ADMIN_ADDED)
        or eventType == (EventTypes().ADMIN_REMOVED)
        or eventType == (EventTypes().ROLE_CHANGE)
end

function Identity.CanFanOutBalance(eventType)
    return eventType == (EventTypes().POINT_CHANGE)
        or eventType == (EventTypes().ATTENDANCE_CHANGE)
end

function Identity.ComponentHasOverflow(result, memberId)
    if type(result) ~= "table" or type(result.identityOf) ~= "table" then
        return false
    end
    memberId = NormalizeId(memberId)
    local group = memberId and result.identityOf[memberId]
    local root = group and group[1]
    return root and result.overflowByIdentity and result.overflowByIdentity[root] == true
end

function Identity.ComponentConflictKeys(result, memberId)
    if type(result) ~= "table" or type(result.identityOf) ~= "table" then
        return {}
    end
    memberId = NormalizeId(memberId)
    local group = memberId and result.identityOf[memberId]
    local root = group and group[1]
    if not root then
        return {}
    end
    return (result.overflowKeysByIdentity and result.overflowKeysByIdentity[root]) or {}
end

function Identity.IntroducedNewConflict(keysA, keysB, keysAfter)
    local before = {}
    for i = 1, #(keysA or {}) do
        before[keysA[i]] = true
    end
    for i = 1, #(keysB or {}) do
        before[keysB[i]] = true
    end
    for i = 1, #(keysAfter or {}) do
        if not before[keysAfter[i]] then
            return true
        end
    end
    return false
end

function Identity.LogsBefore(logs, incoming)
    local before = {}
    if type(logs) ~= "table" then
        return before
    end
    for i = 1, #logs do
        local log = logs[i]
        if Identity.CompareLogs(log, incoming) then
            before[#before + 1] = log
        end
    end
    return before
end

function Identity.PreOpTouchesOwner(logs, eventType, eventData, owner)
    local types = EventTypes()
    local result = Identity.Replay(logs or {}, { owner = owner })
    if eventType == types.CHARACTER_LINK then
        return Identity.SameIdentity(logs, owner, eventData.memberA, result)
            or Identity.SameIdentity(logs, owner, eventData.memberB, result)
    end
    if eventType == types.CHARACTER_UNLINK then
        return Identity.SameIdentity(logs, owner, eventData.member, result)
    end
    return false
end

function Identity.RequiresProfileRebuild(eventType)
    if Identity.CanFanOutBalance(eventType) then
        return false
    end
    return Identity.AffectsProjection(eventType)
        or eventType == (EventTypes().LOOT_MODE_CHANGE)
        or eventType == (EventTypes().REWARD_POT_CONFIG_CHANGE)
        or eventType == (EventTypes().REWARD_POT_CHANGE)
        or eventType == (EventTypes().PROFILE_NAME_CHANGE)
end

function Identity.Replay(logs, opts)
    Identity.replayCount = (Identity.replayCount or 0) + 1
    opts = opts or {}
    local owner = NormalizeId(opts.owner)
    local types = EventTypes()
    local actions = ArmorActions()
    local roles = MemberRoles()
    local partition = NewPartition()
    local localArmor = {}
    local localOrigin = {}
    local rawPoints = {}
    local rawAttendance = {}
    local auth = {}
    local simulated = {}
    local restoredSources = {}
    local identityArmorEvents = {}

    if owner then
        EnsureMember(partition, owner)
        simulated[owner] = true
    end

    local ordered = {}
    for i = 1, #(logs or {}) do
        ordered[i] = logs[i]
    end
    table.sort(ordered, function(a, b)
        return Identity.CompareLogs(a, b)
    end)

    local function ensureLocal(memberId)
        memberId = EnsureMember(partition, memberId)
        if not memberId then
            return nil
        end
        if not localArmor[memberId] then
            localArmor[memberId] = EmptyArmor()
            localOrigin[memberId] = {}
            rawPoints[memberId] = 0
            rawAttendance[memberId] = 0
        end
        return memberId
    end

    if owner then
        ensureLocal(owner)
    end

    for i = 1, #ordered do
        local log = ordered[i]
        local eventType = GetLogType(log)
        local data = GetLogData(log)
        if type(eventType) == "string" and type(data) == "table" then
            if eventType == types.MAIN_SWAP then
                local target = ensureLocal(data.member)
                local source = NormalizeId(data.sourceMember)
                if source then
                    if not localArmor[source] then
                        restoredSources[source] = true
                    end
                    ensureLocal(source)
                    Union(partition, source, target or source)
                end
            elseif eventType == types.CHARACTER_LINK then
                local memberA = ensureLocal(data.memberA)
                local memberB = ensureLocal(data.memberB)
                local preA = ComponentList(partition, memberA)
                local preB = ComponentList(partition, memberB)
                local preSet = ListToSet(preA)
                for j = 1, #preB do
                    preSet[preB[j]] = true
                end
                local evidence = CanonicalAdminMembersAtLink(data)
                for j = 1, #evidence do
                    local adminId = evidence[j]
                    if not preSet[adminId] then
                        if SF.Debug then
                            SF.Debug:Warn(
                                "IDENTITY",
                                "Ignoring out-of-component adminMembersAtLink entry %s on CHARACTER_LINK %s+%s",
                                tostring(adminId),
                                tostring(memberA),
                                tostring(memberB)
                            )
                        end
                    elseif auth[adminId] == "member" then
                        -- Explicit earlier removal wins over stale evidence.
                    elseif auth[adminId] == "admin" then
                        simulated[adminId] = true
                    else
                        simulated[adminId] = true
                    end
                end
                Union(partition, memberA, memberB)
                local resultIds = ComponentList(partition, memberA or memberB)
                if ComponentHasSimulatedAdmin(resultIds, simulated, owner) then
                    ImplyIdentityAdmins(resultIds, simulated, owner)
                end
            elseif eventType == types.CHARACTER_UNLINK then
                Split(partition, data.member)
                ensureLocal(data.member)
            elseif eventType == types.ADMIN_ADDED then
                ensureLocal(data.member)
                ApplyAuthAdmin(auth, simulated, owner, data.member, true)
            elseif eventType == types.ADMIN_REMOVED then
                ensureLocal(data.member)
                ApplyAuthAdmin(auth, simulated, owner, data.member, false)
            elseif eventType == types.ROLE_CHANGE then
                ensureLocal(data.member)
                if data.newRole == roles.ADMIN then
                    ApplyAuthAdmin(auth, simulated, owner, data.member, true)
                elseif data.newRole == roles.MEMBER then
                    ApplyAuthAdmin(auth, simulated, owner, data.member, false)
                end
            elseif eventType == types.POINT_CHANGE then
                local memberId = ensureLocal(data.member)
                if memberId then
                    local amount = GetAmount("points", data)
                    if data.change == (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.INCREMENT) then
                        rawPoints[memberId] = (rawPoints[memberId] or 0) + amount
                    elseif data.change == (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.DECREMENT) then
                        rawPoints[memberId] = (rawPoints[memberId] or 0) - amount
                    end
                end
            elseif eventType == types.ATTENDANCE_CHANGE then
                local memberId = ensureLocal(data.member)
                if memberId then
                    local amount = GetAmount("attendance", data)
                    if data.change == (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.INCREMENT) then
                        rawAttendance[memberId] = (rawAttendance[memberId] or 0) + amount
                    elseif data.change == (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.DECREMENT) then
                        rawAttendance[memberId] = (rawAttendance[memberId] or 0) - amount
                    end
                end
            elseif eventType == types.ARMOR_CHANGE then
                local memberId = ensureLocal(data.member)
                if memberId and type(data.slot) == "string" then
                    if IsIdentityArmor(data) then
                        identityArmorEvents[#identityArmorEvents + 1] = {
                            log = log,
                            member = memberId,
                            slot = data.slot,
                            action = data.action,
                            identityMembers = CanonicalIdentityMembers(data),
                        }
                    else
                        if data.action == actions.USED then
                            localArmor[memberId][data.slot] = true
                            localOrigin[memberId][data.slot] = log
                        elseif data.action == actions.AVAILABLE then
                            localArmor[memberId][data.slot] = false
                            localOrigin[memberId][data.slot] = nil
                        end
                    end
                end
            end
        end
    end

    local identityOf = {}
    local points = {}
    local attendance = {}
    local armor = {}
    local overflowByIdentity = {}
    local overflowKeysByIdentity = {}
    local occByRoot = {}
    local members = {}

    for memberId in pairs(partition.parent) do
        members[#members + 1] = memberId
        ensureLocal(memberId)
    end
    table.sort(members)

    local processedRoot = {}
    for i = 1, #members do
        local memberId = members[i]
        local root = FindRoot(partition, memberId)
        local ids = ComponentList(partition, memberId)
        identityOf[memberId] = ids
        if not processedRoot[root] then
            processedRoot[root] = true
            local pointTotal = 0
            local attendanceTotal = 0
            for j = 1, #ids do
                pointTotal = pointTotal + (rawPoints[ids[j]] or 0)
                attendanceTotal = attendanceTotal + (rawAttendance[ids[j]] or 0)
            end
            if attendanceTotal < 0 then
                attendanceTotal = 0
            end
            local occ = PackLocals(ids, localArmor, localOrigin)
            local idSet = ListToSet(ids)
            for j = 1, #identityArmorEvents do
                local ev = identityArmorEvents[j]
                if IsSubset(ev.identityMembers, idSet) then
                    ApplyIdentityArmor(occ, ev.slot, ev.action)
                end
            end
            occByRoot[root] = occ
            overflowByIdentity[root] = IdentityHasOverflow(occ)
            overflowKeysByIdentity[root] = OverflowKeys(occ)
            local projected = ArmorFromOcc(occ)
            for j = 1, #ids do
                points[ids[j]] = pointTotal
                attendance[ids[j]] = attendanceTotal
                armor[ids[j]] = CopyArmor(projected)
            end
        end
    end

    if owner then
        simulated[owner] = true
    end

    local simulatedList = {}
    for memberId in pairs(simulated) do
        if simulated[memberId] then
            simulatedList[#simulatedList + 1] = memberId
        end
    end
    table.sort(simulatedList)

    return {
        members = members,
        identityOf = identityOf,
        points = points,
        attendance = attendance,
        armor = armor,
        localArmor = localArmor,
        simulatedAdmins = simulated,
        simulatedAdminList = simulatedList,
        restoredSources = restoredSources,
        overflowByIdentity = overflowByIdentity,
        overflowKeysByIdentity = overflowKeysByIdentity,
        partition = partition,
    }
end

function Identity.ComponentMembers(logs, memberId, result)
    result = result or Identity.Replay(logs, {})
    memberId = NormalizeId(memberId)
    return (memberId and result.identityOf and result.identityOf[memberId]) or { memberId }
end

function Identity.SameIdentity(logs, a, b, result)
    a = NormalizeId(a)
    b = NormalizeId(b)
    if not a or not b then
        return false
    end
    if a == b then
        return true
    end
    result = result or Identity.Replay(logs, {})
    local group = result.identityOf and result.identityOf[a]
    if not group then
        return false
    end
    for i = 1, #group do
        if group[i] == b then
            return true
        end
    end
    return false
end

function Identity.FanOutBalance(profile, lootLog)
    if type(profile) ~= "table" or type(lootLog) ~= "table" then
        return false
    end
    local result = profile._identityProjection
    if type(result) ~= "table" or type(result.identityOf) ~= "table" then
        return false
    end
    local eventType = GetLogType(lootLog)
    if not Identity.CanFanOutBalance(eventType) then
        return false
    end
    local data = GetLogData(lootLog)
    local memberId = NormalizeId(data and data.member)
    local group = memberId and result.identityOf[memberId]
    if type(group) ~= "table" or #group == 0 then
        return false
    end
    local amount = GetAmount(eventType == EventTypes().POINT_CHANGE and "points" or "attendance", data)
    local delta = amount
    if data.change == (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.DECREMENT) then
        delta = -amount
    elseif data.change ~= (SF.LootLogPointChangeTypes and SF.LootLogPointChangeTypes.INCREMENT) then
        return false
    end
    if eventType == EventTypes().POINT_CHANGE then
        local nextValue = (result.points[memberId] or 0) + delta
        for i = 1, #group do
            local id = group[i]
            result.points[id] = nextValue
            local member = profile.getMemberByID and profile:getMemberByID(id)
            if member then
                if member.SetPoints then
                    member:SetPoints(nextValue)
                else
                    member.pointBalance = nextValue
                end
            end
        end
        return true
    end
    local nextValue = (result.attendance[memberId] or 0) + delta
    if nextValue < 0 then
        nextValue = 0
    end
    for i = 1, #group do
        local id = group[i]
        result.attendance[id] = nextValue
        local member = profile.getMemberByID and profile:getMemberByID(id)
        if member then
            if member.SetAttendance then
                member:SetAttendance(nextValue)
            else
                member.attendanceBalance = nextValue
            end
        end
    end
    return true
end

function Identity.ComponentAdmins(profile, memberA, memberB)
    if type(profile) ~= "table" then
        return {}
    end
    local result = profile._identityProjection
    if type(result) ~= "table" or type(result.identityOf) ~= "table" then
        local logs = profile.GetLootLogs and profile:GetLootLogs() or profile._lootLogs or {}
        local owner = profile.GetOwner and profile:GetOwner() or profile._owner
        result = Identity.Replay(logs, { owner = owner })
    end
    memberA = NormalizeId(memberA)
    memberB = NormalizeId(memberB)
    local owner = profile.GetOwner and profile:GetOwner() or profile._owner
    local seen = {}
    local admins = {}
    local function consider(id)
        if not id or seen[id] then
            return
        end
        seen[id] = true
        local isAdmin = false
        if profile.IsAdminMemberId and profile:IsAdminMemberId(id) then
            isAdmin = true
        elseif profile.IsOwner and profile:IsOwner(id) then
            isAdmin = true
        elseif SamePlayer(id, owner) then
            isAdmin = true
        end
        if isAdmin then
            admins[#admins + 1] = id
        end
    end
    local groupA = result.identityOf[memberA] or (memberA and { memberA } or {})
    local groupB = result.identityOf[memberB] or (memberB and { memberB } or {})
    for i = 1, #groupA do
        consider(groupA[i])
    end
    for i = 1, #groupB do
        consider(groupB[i])
    end
    table.sort(admins)
    return admins
end

function Identity.ApplyToProfileMembers(profile)
    if type(profile) ~= "table" then
        return nil
    end
    local logs = profile.GetLootLogs and profile:GetLootLogs() or profile._lootLogs or {}
    local owner = profile.GetOwner and profile:GetOwner() or profile._owner
    local result = Identity.Replay(logs, { owner = owner })

    local existing = {}
    if type(profile._members) == "table" then
        for _, member in ipairs(profile._members) do
            local id = (member.GetFullIdentifier and member:GetFullIdentifier()) or member.identifier
            id = NormalizeId(id)
            if id then
                existing[id] = member
            end
        end
    end

    for sourceId in pairs(result.restoredSources) do
        if not existing[sourceId] and SF.Member and SF.Member.new then
            local created = SF.Member.new(sourceId)
            if created then
                existing[sourceId] = created
            end
        end
    end

    for i = 1, #result.members do
        local memberId = result.members[i]
        if not existing[memberId] and SF.Member and SF.Member.new then
            existing[memberId] = SF.Member.new(memberId)
        end
    end

    profile._members = {}
    for memberId, member in pairs(existing) do
        member.pointBalance = result.points[memberId] or 0
        member.attendanceBalance = result.attendance[memberId] or 0
        member.armor = result.armor[memberId] or EmptyArmor()
        profile._members[#profile._members + 1] = member
    end
    table.sort(profile._members, function(a, b)
        local aid = (a.GetFullIdentifier and a:GetFullIdentifier()) or a.identifier or ""
        local bid = (b.GetFullIdentifier and b:GetFullIdentifier()) or b.identifier or ""
        return aid < bid
    end)
    profile._memberById = nil
    profile._identityProjection = result

    return result
end

function Identity.WriteProjection(profile, result)
    if not profile or type(result) ~= "table" then
        return
    end
    local members = profile._members
    if type(members) ~= "table" then
        return
    end
    for _, member in ipairs(members) do
        local memberId = (member.GetFullIdentifier and member:GetFullIdentifier()) or member.identifier
        if memberId then
            local points = result.points[memberId] or 0
            local attendance = result.attendance[memberId] or 0
            if member.SetPoints then
                member:SetPoints(points)
            else
                member.pointBalance = points
            end
            if member.SetAttendance then
                member:SetAttendance(attendance)
            else
                member.attendanceBalance = attendance
            end
            if member.SetArmor then
                member:SetArmor(result.armor[memberId] or EmptyArmor())
            else
                member.armor = result.armor[memberId] or EmptyArmor()
            end
        end
    end
    profile._identityProjection = result
end

function Identity.LinkedGroupsFromResult(result)
    local seen = {}
    local groups = {}
    for i = 1, #(result and result.members or {}) do
        local memberId = result.members[i]
        if not seen[memberId] then
            local group = result.identityOf and result.identityOf[memberId]
            if type(group) == "table" and #group >= 2 then
                for j = 1, #group do
                    seen[group[j]] = true
                end
                groups[#groups + 1] = group
            else
                seen[memberId] = true
            end
        end
    end
    return groups
end

function Identity.LinkedGroups(logs, result)
    result = result or Identity.Replay(logs, {})
    return Identity.LinkedGroupsFromResult(result)
end

function Identity.BuildMainSwapLineage(logs)
    local edges = {}
    local types = EventTypes()
    for i = 1, #(logs or {}) do
        local log = logs[i]
        if GetLogType(log) == types.MAIN_SWAP then
            local data = GetLogData(log)
            if type(data) == "table" then
                local source = NormalizeId(data.sourceMember)
                local target = NormalizeId(data.member)
                if source and target then
                    edges[#edges + 1] = { source = source, target = target }
                end
            end
        end
    end
    return edges
end

function Identity.MainSwapAncestors(edges, memberId)
    memberId = NormalizeId(memberId)
    if not memberId then
        return {}
    end
    local reverse = {}
    for i = 1, #(edges or {}) do
        local edge = edges[i]
        reverse[edge.target] = reverse[edge.target] or {}
        reverse[edge.target][#reverse[edge.target] + 1] = edge.source
    end
    local seen = { [memberId] = true }
    local stack = { memberId }
    local ancestors = {}
    while #stack > 0 do
        local current = table.remove(stack)
        local parents = reverse[current]
        if parents then
            for i = 1, #parents do
                local parent = parents[i]
                if parent and not seen[parent] then
                    seen[parent] = true
                    ancestors[#ancestors + 1] = parent
                    stack[#stack + 1] = parent
                end
            end
        end
    end
    return ancestors
end

Identity.RING_INDEX = RING_INDEX
Identity.TRINKET_INDEX = TRINKET_INDEX
