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

local function CanonicalAuthorKey(author)
    local norm = NormalizeId(author)
    if not norm then
        return nil
    end
    return string.lower(norm)
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

local function GetLogAuthor(log)
    if type(log) ~= "table" then
        return nil
    end
    if log.GetAuthor then
        return NormalizeId(log:GetAuthor())
    end
    return NormalizeId(log._author)
end

local function GetLogId(log)
    if type(log) ~= "table" then
        return nil
    end
    if log.GetID then
        return log:GetID()
    end
    return log._id
end

local function GetLogCounter(log)
    if type(log) ~= "table" then
        return nil
    end
    if log.GetCounter then
        return log:GetCounter()
    end
    return log._counter
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

-- Causal-then-deterministic order: per-author counters, writer-observed
-- preOpAuthorMax, sourceLogId grant edges, then CompareLogs among ready events.
-- Ready selection is a binary min-heap so the Kahn walk is O(n log n).
function Identity.OrderLogs(logs)
    if type(logs) ~= "table" then
        Identity.lastOrderStats = { n = 0, readyPops = 0, heapOps = 0, cacheHit = false }
        return {}
    end
    local n = #logs
    if n == 0 then
        Identity.lastOrderStats = { n = 0, readyPops = 0, heapOps = 0, cacheHit = false }
        return {}
    end

    local cache = Identity._orderCache
    if cache and cache.logs == logs and cache.n == n and cache.last == logs[n] then
        Identity.lastOrderStats = {
            n = n,
            readyPops = cache.readyPops or n,
            heapOps = cache.heapOps or 0,
            cacheHit = true,
        }
        return cache.ordered
    end

    local ordered = {}
    local heapOps = 0
    local idOf = {}
    local byId = {}
    for i = 1, n do
        local log = logs[i]
        local id = GetLogId(log)
        if type(id) ~= "string" or id == "" or byId[id] then
            id = string.format("__idx:%d", i)
        end
        idOf[log] = id
        byId[id] = log
    end

    local byAuthor = {}
    for i = 1, n do
        local log = logs[i]
        local key = CanonicalAuthorKey(GetLogAuthor(log) or (log and log._author))
        local counter = tonumber(GetLogCounter(log))
        if key and counter then
            local bucket = byAuthor[key]
            if not bucket then
                bucket = { byCounter = {}, sorted = {} }
                byAuthor[key] = bucket
            end
            local existing = bucket.byCounter[counter]
            if not existing or Identity.CompareLogs(log, existing) then
                bucket.byCounter[counter] = log
            end
        end
    end
    for _, bucket in pairs(byAuthor) do
        local sorted = bucket.sorted
        for counter in pairs(bucket.byCounter) do
            sorted[#sorted + 1] = counter
        end
        table.sort(sorted)
    end

    local function bestAtOrBefore(author, counter)
        local key = CanonicalAuthorKey(author)
        local bucket = key and byAuthor[key]
        if not bucket then
            return nil
        end
        local exact = bucket.byCounter[counter]
        if exact then
            return exact
        end
        local sorted = bucket.sorted
        local lo, hi, best = 1, #sorted, nil
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local c = sorted[mid]
            if c <= counter then
                best = c
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        if not best then
            return nil
        end
        return bucket.byCounter[best]
    end

    local indegree = {}
    local successors = {}
    for i = 1, n do
        local id = idOf[logs[i]]
        indegree[id] = 0
        successors[id] = {}
    end

    local function addEdge(predLog, succLog)
        if not predLog or not succLog or predLog == succLog then
            return
        end
        local a, b = idOf[predLog], idOf[succLog]
        if not a or not b or a == b then
            return
        end
        local list = successors[a]
        for i = 1, #list do
            if list[i] == b then
                return
            end
        end
        list[#list + 1] = b
        indegree[b] = (indegree[b] or 0) + 1
    end

    for i = 1, n do
        local log = logs[i]
        local author = GetLogAuthor(log) or (log and log._author)
        local counter = tonumber(GetLogCounter(log))
        if author and counter then
            addEdge(bestAtOrBefore(author, counter - 1), log)
        end
        local data = GetLogData(log)
        local pre = data and data.preOpAuthorMax
        if type(pre) == "table" then
            for j = 1, #pre do
                local entry = pre[j]
                if type(entry) == "table" then
                    local pAuthor = entry.author
                    local pCounter = tonumber(entry.counter)
                    if type(pAuthor) == "string" and pAuthor ~= "" and pCounter then
                        addEdge(bestAtOrBefore(pAuthor, pCounter), log)
                    end
                end
            end
        end
        local sourceLogId = data and data.sourceLogId
        if type(sourceLogId) == "string" and sourceLogId ~= "" then
            local sourceLog = byId[sourceLogId]
            if sourceLog then
                addEdge(sourceLog, log)
            end
        end
    end

    local heap = {}
    local function heapLess(i, j)
        return Identity.CompareLogs(heap[i].log, heap[j].log)
    end
    local function heapSwap(i, j)
        heap[i], heap[j] = heap[j], heap[i]
        heapOps = heapOps + 1
    end
    local function heapUp(i)
        while i > 1 do
            local parent = math.floor(i / 2)
            if not heapLess(i, parent) then
                break
            end
            heapSwap(i, parent)
            i = parent
        end
    end
    local function heapDown(i)
        local size = #heap
        while true do
            local left = i * 2
            local right = left + 1
            local smallest = i
            if left <= size and heapLess(left, smallest) then
                smallest = left
            end
            if right <= size and heapLess(right, smallest) then
                smallest = right
            end
            if smallest == i then
                break
            end
            heapSwap(i, smallest)
            i = smallest
        end
    end
    local function heapPush(id, log)
        heap[#heap + 1] = { id = id, log = log }
        heapOps = heapOps + 1
        heapUp(#heap)
    end
    local function heapPop()
        local size = #heap
        if size == 0 then
            return nil, nil
        end
        local top = heap[1]
        heap[1] = heap[size]
        heap[size] = nil
        heapOps = heapOps + 1
        if #heap > 0 then
            heapDown(1)
        end
        return top.id, top.log
    end

    local remaining = {}
    for i = 1, n do
        local id = idOf[logs[i]]
        remaining[id] = logs[i]
        if (indegree[id] or 0) <= 0 then
            heapPush(id, logs[i])
        end
    end

    local readyPops = 0
    while true do
        local id, log = heapPop()
        if not log then
            break
        end
        if remaining[id] then
            readyPops = readyPops + 1
            ordered[#ordered + 1] = log
            remaining[id] = nil
            local succs = successors[id] or {}
            for i = 1, #succs do
                local sid = succs[i]
                indegree[sid] = (indegree[sid] or 0) - 1
                if remaining[sid] and (indegree[sid] or 0) <= 0 then
                    heapPush(sid, remaining[sid])
                end
            end
        end
    end

    local leftover = {}
    for _, log in pairs(remaining) do
        leftover[#leftover + 1] = log
    end
    if #leftover > 0 then
        table.sort(leftover, function(a, b)
            return Identity.CompareLogs(a, b)
        end)
        if SF.Debug then
            SF.Debug:Warn("IDENTITY", "Causal order fell back for %d events", #leftover)
        end
        for i = 1, #leftover do
            ordered[#ordered + 1] = leftover[i]
        end
    end

    Identity.lastOrderStats = {
        n = n,
        readyPops = readyPops,
        heapOps = heapOps,
        leftover = #leftover,
        cacheHit = false,
    }
    Identity._orderCache = {
        logs = logs,
        n = n,
        last = logs[n],
        ordered = ordered,
        readyPops = readyPops,
        heapOps = heapOps,
    }
    return ordered
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

local function MergeFamily(dst, src)
    dst.overflow = (dst.overflow or 0) + (src.overflow or 0)
    for i = 1, 2 do
        if src.occupied[i] then
            if dst.occupied[i] then
                dst.overflow = dst.overflow + 1
            else
                dst.occupied[i] = true
            end
        end
    end
end

local function MergeOcc(dst, src)
    MergeFamily(dst.ring, src.ring)
    MergeFamily(dst.trinket, src.trinket)
    for slot, state in pairs(src.ordinary) do
        local current = dst.ordinary[slot]
        local dstOccupied = current and current.occupied == true
        local srcOccupied = state.occupied == true
        local overflow = (current and current.overflow or 0) + (state.overflow or 0)
        if dstOccupied and srcOccupied then
            overflow = overflow + 1
        end
        -- Overflow is leftover extra uses. It must not refill a slot that
        -- AVAILABLE already cleared in its own scope.
        dst.ordinary[slot] = {
            occupied = dstOccupied or srcOccupied,
            overflow = overflow,
        }
    end
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

local function PackLocals(memberIds, localArmor, localOrigin, familyFilter)
    local occ = NewIdentityOcc()
    local ringUsages = {}
    local trinketUsages = {}
    local packOrdinary = (not familyFilter) or familyFilter == "ordinary"
    local packRing = (not familyFilter) or familyFilter == "ring"
    local packTrinket = (not familyFilter) or familyFilter == "trinket"

    for i = 1, #memberIds do
        local memberId = memberIds[i]
        local armor = localArmor[memberId] or {}
        local origin = localOrigin[memberId] or {}
        for slot, used in pairs(armor) do
            if used then
                local family = FamilyForSlot(slot)
                if family == "ring" and packRing then
                    ringUsages[#ringUsages + 1] = {
                        log = origin[slot],
                        member = memberId,
                        slot = slot,
                    }
                elseif family == "trinket" and packTrinket then
                    trinketUsages[#trinketUsages + 1] = {
                        log = origin[slot],
                        member = memberId,
                        slot = slot,
                    }
                elseif family == "ordinary" and packOrdinary then
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
            -- Ordinary slots have one opportunity. Clearing the recorded
            -- scope suppresses that scope's packed locals, including overflow.
            state.occupied = false
            state.overflow = 0
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

local function OverflowCounts(occ)
    local counts = {}
    if occ.ring.overflow > 0 then
        counts.ring = occ.ring.overflow
    end
    if occ.trinket.overflow > 0 then
        counts.trinket = occ.trinket.overflow
    end
    for slot, state in pairs(occ.ordinary) do
        if state.overflow and state.overflow > 0 then
            counts[slot] = state.overflow
        end
    end
    return counts
end

local function OverflowKeys(occ)
    local keys = {}
    local counts = OverflowCounts(occ)
    for key in pairs(counts) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function LatestLocalOriginForSlot(ids, slot, localOrigin)
    local family = FamilyForSlot(slot)
    local latest = nil
    local function consider(log)
        if not log then
            return
        end
        if not latest or Identity.CompareLogs(latest, log) then
            latest = log
        end
    end
    for i = 1, #ids do
        local origin = localOrigin[ids[i]] or {}
        if family == "ordinary" then
            consider(origin[slot])
        elseif family == "ring" then
            consider(origin.Ring1)
            consider(origin.Ring2)
        elseif family == "trinket" then
            consider(origin.Trinket1)
            consider(origin.Trinket2)
        end
    end
    return latest
end

local function IdentityEventSupersededByLocals(ev, ids, localOrigin)
    local latest = LatestLocalOriginForSlot(ids, ev.slot, localOrigin)
    if not latest or not ev.log then
        return false
    end
    return Identity.CompareLogs(ev.log, latest)
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

local function IsCanonicalAdminAt(memberId, simulated, auth, owner)
    memberId = NormalizeId(memberId)
    if not memberId then
        return false
    end
    if auth[memberId] == "member" then
        return false
    end
    if simulated[memberId] then
        return true
    end
    if auth[memberId] == "admin" then
        return true
    end
    return SamePlayer(memberId, owner)
end

local function IsEffectiveOwnerAt(memberId, partition, owner)
    owner = NormalizeId(owner)
    memberId = NormalizeId(memberId)
    if not owner or not memberId then
        return false
    end
    if SamePlayer(memberId, owner) then
        return true
    end
    local ownerRoot = FindRoot(partition, owner)
    local memberRoot = FindRoot(partition, memberId)
    return ownerRoot and memberRoot and ownerRoot == memberRoot
end

local function RelationshipTouchesOwnerAt(eventType, eventData, partition, owner)
    local types = EventTypes()
    if eventType == types.CHARACTER_LINK then
        return IsEffectiveOwnerAt(eventData.memberA, partition, owner)
            or IsEffectiveOwnerAt(eventData.memberB, partition, owner)
    end
    if eventType == types.CHARACTER_UNLINK then
        return IsEffectiveOwnerAt(eventData.member, partition, owner)
    end
    return false
end

local function RelationshipAuthorizedAt(log, eventType, eventData, partition, simulated, auth, owner)
    local author = GetLogAuthor(log)
    if not IsCanonicalAdminAt(author, simulated, auth, owner) then
        return false
    end
    if RelationshipTouchesOwnerAt(eventType, eventData, partition, owner)
        and not IsEffectiveOwnerAt(author, partition, owner)
    then
        return false
    end
    return true
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

local function IsIdentityArmor(data)
    return type(data) == "table" and data.scope == "identity"
end

local function CanonicalIdentityMembers(data)
    if type(data) ~= "table" then
        return {}
    end
    return SortedUnique(data.identityMembers)
end

local function IdentityMembersKey(memberIds)
    if type(memberIds) ~= "table" then
        return ""
    end
    return table.concat(memberIds, "\0")
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

local function ImplyIdentityAdmins(memberIds, simulated, owner, impliedAdminSource, sourceLogId)
    for i = 1, #memberIds do
        local memberId = memberIds[i]
        if memberId and not SamePlayer(memberId, owner) and not simulated[memberId] then
            if impliedAdminSource and type(sourceLogId) == "string" and sourceLogId ~= "" then
                impliedAdminSource[memberId] = sourceLogId
            end
        end
        simulated[memberId] = true
    end
end

function Identity.EnsureLegacyCanonicalAdmins(profile)
    if type(profile) ~= "table" then
        return {}
    end
    if type(profile._legacyCanonicalAdmins) == "table" then
        return profile._legacyCanonicalAdmins
    end
    local types = EventTypes()
    local roles = MemberRoles()
    local granted = {}
    local logs = profile.GetLootLogs and profile:GetLootLogs() or profile._lootLogs or {}
    for i = 1, #logs do
        local log = logs[i]
        local eventType = GetLogType(log)
        local data = GetLogData(log)
        if eventType == types.ADMIN_ADDED and type(data) == "table" then
            local id = NormalizeId(data.member)
            if id then
                granted[id] = true
            end
        elseif eventType == types.ROLE_CHANGE and type(data) == "table" and data.newRole == roles.ADMIN then
            local id = NormalizeId(data.member)
            if id then
                granted[id] = true
            end
        end
    end
    local owner = NormalizeId((profile.GetOwnerId and profile:GetOwnerId()) or profile._owner)
    if owner then
        granted[owner] = true
    end
    local legacy = {}
    local seen = {}
    for _, id in ipairs(profile._adminUsers or {}) do
        local norm = NormalizeId(id)
        if norm and not granted[norm] and not seen[norm] then
            seen[norm] = true
            legacy[#legacy + 1] = norm
        end
    end
    table.sort(legacy)
    profile._legacyCanonicalAdmins = legacy
    return legacy
end

function Identity.UnrosteredAttributedMembers(logs, rosterSet)
    local types = EventTypes()
    local found = {}
    rosterSet = rosterSet or {}
    for i = 1, #(logs or {}) do
        local data = GetLogData(logs[i])
        local eventType = GetLogType(logs[i])
        if type(data) == "table" then
            local candidates = { data.member, data.memberA, data.memberB, data.sourceMember }
            if eventType == types.RC_LOOT_COUNCIL or eventType == types.POINT_CHANGE
                or eventType == types.ATTENDANCE_CHANGE or eventType == types.ARMOR_CHANGE
                or eventType == types.ADMIN_ADDED or eventType == types.ADMIN_REMOVED
                or eventType == types.ROLE_CHANGE
            then
                candidates[#candidates + 1] = data.member
            end
            for j = 1, #candidates do
                local id = NormalizeId(candidates[j])
                if id and not rosterSet[id] then
                    found[id] = true
                end
            end
        end
    end
    local out = {}
    for id in pairs(found) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
end

function Identity.AttributedMemberIds(logs)
    local found = {}
    for i = 1, #(logs or {}) do
        local data = GetLogData(logs[i])
        if type(data) == "table" then
            local candidates = { data.member, data.memberA, data.memberB, data.sourceMember }
            for j = 1, #candidates do
                local id = NormalizeId(candidates[j])
                if id then
                    found[id] = true
                end
            end
        end
    end
    local out = {}
    for id in pairs(found) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
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

function Identity.SnapshotPreOpAuthorMax(profile)
    local out = {}
    if type(profile) ~= "table" or type(profile._authorCounters) ~= "table" then
        return out
    end
    local byKey = {}
    for author, counter in pairs(profile._authorCounters) do
        local n = tonumber(counter)
        if type(author) == "string" and author ~= "" and n and n > 0 then
            local key = CanonicalAuthorKey(author)
            local display = NormalizeId(author) or author
            if key then
                local existing = byKey[key]
                local floorN = math.floor(n)
                if not existing then
                    byKey[key] = { author = display, counter = floorN }
                else
                    if floorN > existing.counter then
                        existing.counter = floorN
                        existing.author = display
                    elseif floorN == existing.counter and tostring(display) < tostring(existing.author) then
                        existing.author = display
                    end
                end
            end
        end
    end
    for _, entry in pairs(byKey) do
        out[#out + 1] = entry
    end
    table.sort(out, function(a, b)
        return tostring(a.author) < tostring(b.author)
    end)
    return out
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
    local counts = Identity.ComponentConflictCounts(result, memberId)
    local keys = {}
    for key in pairs(counts) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

function Identity.ComponentConflictCounts(result, memberId)
    if type(result) ~= "table" or type(result.identityOf) ~= "table" then
        return {}
    end
    memberId = NormalizeId(memberId)
    local group = memberId and result.identityOf[memberId]
    local root = group and group[1]
    if not root then
        return {}
    end
    return (result.overflowCountsByIdentity and result.overflowCountsByIdentity[root]) or {}
end

function Identity.IntroducedNewConflict(countsA, countsB, countsAfter)
    local function asCounts(value)
        if type(value) ~= "table" then
            return {}
        end
        if value[1] ~= nil then
            local counts = {}
            for i = 1, #value do
                counts[value[i]] = 1
            end
            return counts
        end
        return value
    end
    countsA = asCounts(countsA)
    countsB = asCounts(countsB)
    countsAfter = asCounts(countsAfter)
    local before = {}
    for key, count in pairs(countsA) do
        before[key] = math.max(before[key] or 0, tonumber(count) or 0)
    end
    for key, count in pairs(countsB) do
        before[key] = math.max(before[key] or 0, tonumber(count) or 0)
    end
    for key, count in pairs(countsAfter) do
        if (tonumber(count) or 0) > (before[key] or 0) then
            return true
        end
    end
    return false
end

function Identity.LogsBefore(logs, incoming)
    local combined = {}
    if type(logs) == "table" then
        for i = 1, #logs do
            combined[#combined + 1] = logs[i]
        end
    end
    if incoming then
        combined[#combined + 1] = incoming
    end
    local ordered = Identity.OrderLogs(combined)
    local before = {}
    local incomingId = GetLogId(incoming)
    for i = 1, #ordered do
        local log = ordered[i]
        if log == incoming or (incomingId and GetLogId(log) == incomingId) then
            break
        end
        before[#before + 1] = log
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
    local types = EventTypes()
    local owner = NormalizeId(opts.owner)
    if not owner then
        for i = 1, #(logs or {}) do
            local log = logs[i]
            if GetLogType(log) == types.PROFILE_CREATION then
                owner = GetLogAuthor(log)
                break
            end
        end
    end
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
    local appliedRelationshipIds = {}
    local impliedAdminSource = {}

    if owner then
        EnsureMember(partition, owner)
        simulated[owner] = true
    end

    local legacyAdmins = opts.legacyAdmins
    if type(legacyAdmins) == "table" then
        for i = 1, #legacyAdmins do
            local legacyId = NormalizeId(legacyAdmins[i])
            if legacyId and not SamePlayer(legacyId, owner) then
                EnsureMember(partition, legacyId)
                simulated[legacyId] = true
                auth[legacyId] = "admin"
            end
        end
    end

    local ordered = Identity.OrderLogs(logs)

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
                local alreadyUnified = memberA and memberB
                    and FindRoot(partition, memberA) == FindRoot(partition, memberB)
                local preA = ComponentList(partition, memberA)
                local preB = ComponentList(partition, memberB)
                if RelationshipAuthorizedAt(log, eventType, data, partition, simulated, auth, owner) then
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
                    local preAHasAdmin = ComponentHasSimulatedAdmin(preA, simulated, owner)
                    local preBHasAdmin = ComponentHasSimulatedAdmin(preB, simulated, owner)
                    Union(partition, memberA, memberB)
                    local linkId = GetLogId(log)
                    if type(linkId) == "string" and linkId ~= "" then
                        appliedRelationshipIds[linkId] = true
                    end
                    -- Redundant LINKs remain valid history and may source a
                    -- writer grant, but they are not a new admin-propagation
                    -- boundary. Do not imply across an already-unified component.
                    if not alreadyUnified then
                        if preAHasAdmin then
                            ImplyIdentityAdmins(preB, simulated, owner, impliedAdminSource, linkId)
                        end
                        if preBHasAdmin then
                            ImplyIdentityAdmins(preA, simulated, owner, impliedAdminSource, linkId)
                        end
                    end
                end
            elseif eventType == types.CHARACTER_UNLINK then
                if RelationshipAuthorizedAt(log, eventType, data, partition, simulated, auth, owner) then
                    Split(partition, data.member)
                    local unlinkId = GetLogId(log)
                    if type(unlinkId) == "string" and unlinkId ~= "" then
                        appliedRelationshipIds[unlinkId] = true
                    end
                end
                ensureLocal(data.member)
            elseif eventType == types.ADMIN_ADDED then
                ensureLocal(data.member)
                local sourceLogId = data.sourceLogId
                if type(sourceLogId) == "string" and sourceLogId ~= "" then
                    if appliedRelationshipIds[sourceLogId] then
                        ApplyAuthAdmin(auth, simulated, owner, data.member, true)
                    end
                else
                    ApplyAuthAdmin(auth, simulated, owner, data.member, true)
                end
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
                            -- Keep AVAILABLE origins so later local actions supersede
                            -- older identity-scoped corrections after unlink/relink.
                            localOrigin[memberId][data.slot] = log
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
    local overflowCountsByIdentity = {}
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
            local idSet = ListToSet(ids)
            local latestByKey = {}
            for j = 1, #identityArmorEvents do
                local ev = identityArmorEvents[j]
                if IsSubset(ev.identityMembers, idSet)
                    and not IdentityEventSupersededByLocals(ev, ev.identityMembers, localOrigin)
                then
                    local key = IdentityMembersKey(ev.identityMembers) .. "\0" .. tostring(ev.slot)
                    local prev = latestByKey[key]
                    if not prev or Identity.CompareLogs(prev.log, ev.log) then
                        latestByKey[key] = ev
                    end
                end
            end
            -- Corrections occupy their recorded identityMembers scope, then
            -- merge. A same-component AVAILABLE cannot clear another scope's
            -- USED, and it cannot resurrect locals it already suppressed.
            local scopes = {}
            for _, ev in pairs(latestByKey) do
                local scopeKey = IdentityMembersKey(ev.identityMembers)
                local scope = scopes[scopeKey]
                if not scope then
                    scope = { members = ev.identityMembers, events = {} }
                    scopes[scopeKey] = scope
                end
                scope.events[#scope.events + 1] = ev
            end
            local scopeOrder = {}
            for scopeKey in pairs(scopes) do
                scopeOrder[#scopeOrder + 1] = scopeKey
            end
            table.sort(scopeOrder)
            local occ = NewIdentityOcc()
            local claimed = { ordinary = {}, ring = {}, trinket = {} }
            for s = 1, #scopeOrder do
                local scope = scopes[scopeOrder[s]]
                local scopeIds = {}
                for j = 1, #scope.members do
                    local scopeMember = scope.members[j]
                    if idSet[scopeMember] then
                        scopeIds[#scopeIds + 1] = scopeMember
                    end
                end
                table.sort(scopeIds)
                local byFamily = { ordinary = {}, ring = {}, trinket = {} }
                for j = 1, #scope.events do
                    local ev = scope.events[j]
                    local family = FamilyForSlot(ev.slot)
                    byFamily[family][#byFamily[family] + 1] = ev
                end
                local families = { "ordinary", "ring", "trinket" }
                for f = 1, #families do
                    local family = families[f]
                    local familyEvents = byFamily[family]
                    if #familyEvents > 0 then
                        for j = 1, #scopeIds do
                            claimed[family][scopeIds[j]] = true
                        end
                        local packed = PackLocals(scopeIds, localArmor, localOrigin, family)
                        table.sort(familyEvents, function(a, b)
                            return Identity.CompareLogs(a.log, b.log)
                        end)
                        for j = 1, #familyEvents do
                            local ev = familyEvents[j]
                            ApplyIdentityArmor(packed, ev.slot, ev.action)
                        end
                        MergeOcc(occ, packed)
                    end
                end
            end
            local function leftoverIds(family)
                local leftover = {}
                for j = 1, #ids do
                    if not claimed[family][ids[j]] then
                        leftover[#leftover + 1] = ids[j]
                    end
                end
                return leftover
            end
            MergeOcc(occ, PackLocals(leftoverIds("ordinary"), localArmor, localOrigin, "ordinary"))
            MergeOcc(occ, PackLocals(leftoverIds("ring"), localArmor, localOrigin, "ring"))
            MergeOcc(occ, PackLocals(leftoverIds("trinket"), localArmor, localOrigin, "trinket"))
            occByRoot[root] = occ
            overflowByIdentity[root] = IdentityHasOverflow(occ)
            overflowKeysByIdentity[root] = OverflowKeys(occ)
            overflowCountsByIdentity[root] = OverflowCounts(occ)
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
        appliedRelationshipIds = appliedRelationshipIds,
        impliedAdminSource = impliedAdminSource,
        orderedLogs = ordered,
        overflowByIdentity = overflowByIdentity,
        overflowKeysByIdentity = overflowKeysByIdentity,
        overflowCountsByIdentity = overflowCountsByIdentity,
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
        local owner = (profile.GetOwnerId and profile:GetOwnerId()) or profile._owner
        result = Identity.Replay(logs, { owner = owner })
    end
    memberA = NormalizeId(memberA)
    memberB = NormalizeId(memberB)
    local owner = (profile.GetOwnerId and profile:GetOwnerId()) or profile._owner
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

function Identity.ApplyCanonicalAdmins(profile, result)
    if type(profile) ~= "table" then
        return
    end
    result = result or profile._identityProjection
    local logs = profile.GetLootLogs and profile:GetLootLogs() or profile._lootLogs or {}
    local types = EventTypes()
    local roles = MemberRoles()
    local appliedLinks = (result and result.appliedRelationshipIds) or {}
    local adminSet = {}
    local owner = NormalizeId((profile.GetOwnerId and profile:GetOwnerId()) or profile._owner)
    if owner then
        adminSet[owner] = true
    end
    local legacy = profile._legacyCanonicalAdmins or {}
    for i = 1, #legacy do
        local id = NormalizeId(legacy[i])
        if id then
            adminSet[id] = true
        end
    end
    local orderedLogs = (result and result.orderedLogs) or Identity.OrderLogs(logs)
    for i = 1, #orderedLogs do
        local log = orderedLogs[i]
        local eventType = GetLogType(log)
        local data = GetLogData(log)
        if type(eventType) == "string" and type(data) == "table" then
            if eventType == types.ADMIN_ADDED then
                local memberId = NormalizeId(data.member)
                local sourceLogId = data.sourceLogId
                if memberId then
                    if type(sourceLogId) == "string" and sourceLogId ~= "" then
                        if appliedLinks[sourceLogId] then
                            adminSet[memberId] = true
                        end
                    else
                        adminSet[memberId] = true
                    end
                end
            elseif eventType == types.ADMIN_REMOVED then
                local memberId = NormalizeId(data.member)
                if memberId then
                    adminSet[memberId] = nil
                end
            elseif eventType == types.ROLE_CHANGE then
                local memberId = NormalizeId(data.member)
                if memberId and data.newRole == roles.ADMIN then
                    adminSet[memberId] = true
                elseif memberId and data.newRole == roles.MEMBER then
                    adminSet[memberId] = nil
                end
            end
        end
    end
    if owner then
        adminSet[owner] = true
    end
    local admins = {}
    for id in pairs(adminSet) do
        admins[#admins + 1] = id
    end
    table.sort(admins)
    profile._adminUsers = admins
    if SF.MemberRoles then
        for _, member in ipairs(profile._members or {}) do
            local mid = NormalizeId((member.GetFullIdentifier and member:GetFullIdentifier()) or member.identifier)
            if mid and adminSet[mid] then
                member.role = SF.MemberRoles.ADMIN
            elseif member then
                member.role = SF.MemberRoles.MEMBER
            end
        end
    end
end

function Identity.ApplyToProfileMembers(profile)
    if type(profile) ~= "table" then
        return nil
    end
    local logs = profile.GetLootLogs and profile:GetLootLogs() or profile._lootLogs or {}
    local owner = (profile.GetOwnerId and profile:GetOwnerId()) or profile._owner
    local legacyAdmins = Identity.EnsureLegacyCanonicalAdmins(profile)
    local result = Identity.Replay(logs, { owner = owner, legacyAdmins = legacyAdmins })

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

    local rosterSet = {}
    for memberId in pairs(existing) do
        rosterSet[memberId] = true
    end
    local unrostered = Identity.UnrosteredAttributedMembers(logs, rosterSet)
    for i = 1, #unrostered do
        local sourceId = unrostered[i]
        if not existing[sourceId] and SF.Member and SF.Member.new then
            local created = SF.Member.new(sourceId)
            if created then
                existing[sourceId] = created
                result.restoredSources[sourceId] = true
                if SF.PrintWarning and not (profile._warnedUnrosteredRestore and profile._warnedUnrosteredRestore[sourceId]) then
                    profile._warnedUnrosteredRestore = profile._warnedUnrosteredRestore or {}
                    profile._warnedUnrosteredRestore[sourceId] = true
                    SF:PrintWarning(("Loot Helper restored %s from historical logs with no Main Swap lineage. Link it manually if it should share an identity."):format(tostring(sourceId)))
                end
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
    Identity.ApplyCanonicalAdmins(profile, result)

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
