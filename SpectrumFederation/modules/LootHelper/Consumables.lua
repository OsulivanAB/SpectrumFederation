-- Raid Consumables domain, ledger, and projections.
-- Configuration lives on the LootProfile. Accounting is append-only events.
local _, SF = ...

SF.Consumables = SF.Consumables or {}
local C = SF.Consumables

C.EVENT = {
    DONATION = "CONSUMABLE_DONATION",
    RECEIPT = "CONSUMABLE_CRAFTER_RECEIPT",
    CUSTODY = "CONSUMABLE_CUSTODY",
    RESOLVE = "CONSUMABLE_CUSTODY_RESOLVE",
    RESET = "CONSUMABLE_CONFIG_RESET",
}

C.ACTION = {
    WITHDRAW = "withdraw",
    TRANSFER = "transfer",
    RETURN = "return",
    DELIVER = "deliver",
}

C.MAX_ASSIGNMENT_PAIRS = 256
C.MAX_ASSIGNMENT_HISTORY = 8
C.MAX_LEDGER_EVENTS = 4096
C.MAX_ARCHIVED_EVENTS = 4096
C.MAX_VISIBLE_HISTORY = 200
C.MAX_EVENTS_PER_ACTOR = 512
C.MAX_EVENT_SEQ = 2147483647
C.MAX_EVENT_ID = 192
C.MAX_EVENT_NAME = 64
C.MAX_EVENT_REASON = 128

C.RESOLVE_REASONS = {
    "Used",
    "Lost/Destroyed",
    "Transferred outside Spectrum",
    "Correction",
    "Other",
}

local projectionCache = setmetatable({}, { __mode = "k" })
local listeners = {}
local notifying = false

local function Debug(level, message, ...)
    if SF.Debug and SF.Debug[level] then
        SF.Debug[level](SF.Debug, "CONSUMABLES", message, ...)
    end
end

local function Now()
    if type(C._clock) == "function" then
        return C._clock()
    end
    return time()
end

C.Now = Now

local function Same(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b) and true or false
    end
    return a ~= nil and a == b
end

local function Norm(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name) or name
    end
    return name
end

local function IsItemId(itemId)
    return type(itemId) == "number" and itemId > 0 and itemId == math.floor(itemId)
end

local function IsBankTab(tab)
    return type(tab) == "number" and tab >= 1 and tab <= 8 and tab == math.floor(tab)
end

local function ItemKey(itemId)
    return tostring(itemId)
end

local function SortedCopy(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, #list do
        local name = Norm(list[i])
        if name then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

local function SameSet(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function Contains(list, name)
    for i = 1, #list do
        if Same(list[i], name) then return true end
    end
    return false
end

local function Without(list, name)
    local out = {}
    for i = 1, #list do
        if not Same(list[i], name) then
            out[#out + 1] = list[i]
        end
    end
    return out
end

local function CopyCrafterRoster(list)
    local sorted = SortedCopy(list)
    local out = {}
    for i = 1, #sorted do
        local name = sorted[i]
        if #name <= C.MAX_EVENT_NAME and not Contains(out, name) then
            out[#out + 1] = name
        end
        if #out >= C.MAX_ASSIGNMENT_PAIRS then break end
    end
    return out
end

local function Notify()
    if notifying then return end
    notifying = true
    for i = 1, #listeners do
        local fn = listeners[i]
        if type(fn) == "function" then
            local ok, err = pcall(fn)
            if not ok then
                Debug("Error", "UI listener failed: %s", tostring(err))
            end
        end
    end
    notifying = false
end

function C.RegisterUIListener(fn)
    if type(fn) ~= "function" then return nil end
    listeners[#listeners + 1] = fn
    return fn
end

local function Invalidate(profile)
    projectionCache[profile] = nil
end

local FINGERPRINT_MOD = 1000000007

local function Xor32(a, b)
    a = math.floor((tonumber(a) or 0) % 4294967296)
    b = math.floor((tonumber(b) or 0) % 4294967296)
    local result = 0
    local bitValue = 1
    for _ = 1, 32 do
        if (a % 2) ~= (b % 2) then
            result = result + bitValue
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitValue = bitValue * 2
    end
    return result
end

local HASH_BYTES = 256

local function IdHash(id)
    if type(id) ~= "string" or id == "" then return 0 end
    local hash = 2166136261 % FINGERPRINT_MOD
    local limit = #id
    if limit > HASH_BYTES then limit = HASH_BYTES end
    for i = 1, limit do
        hash = (hash * 131 + string.byte(id, i)) % FINGERPRINT_MOD
    end
    return hash
end

local function FingerprintToken(id, order)
    if type(id) ~= "string" or id == "" then return nil end
    order = tonumber(order)
    if order and order > 0 then
        return id .. "\0" .. tostring(math.floor(order))
    end
    return id
end

local function MixFingerprint(current, id, order)
    local token = FingerprintToken(id, order)
    if not token then return tonumber(current) or 0 end
    return Xor32(current or 0, IdHash(token))
end

local function RetargetFingerprint(cfg, id, oldOrder, newOrder)
    if type(cfg) ~= "table" then return end
    local oldToken = FingerprintToken(id, oldOrder)
    local newToken = FingerprintToken(id, newOrder)
    if oldToken == newToken then return end
    local fingerprint = tonumber(cfg.eventFingerprint) or 0
    if oldToken then fingerprint = Xor32(fingerprint, IdHash(oldToken)) end
    if newToken then fingerprint = Xor32(fingerprint, IdHash(newToken)) end
    cfg.eventFingerprint = fingerprint
end

local function AdoptedEventSeq(id)
    if type(id) ~= "string" then return nil end
    local digits = id:match(":(%d+)$")
    if not digits then return nil end
    local seq = tonumber(digits)
    if not seq or seq ~= math.floor(seq) or seq < 1 or seq > C.MAX_EVENT_SEQ then
        return nil
    end
    return seq
end

local function ArchiveStats(profile)
    local archive = profile._consumableEventArchive
    local fingerprint = 0
    local count = 0
    if type(archive) == "table" then
        count = #archive
        for i = 1, count do
            local archived = archive[i]
            if type(archived) == "table" then
                fingerprint = MixFingerprint(fingerprint, archived.id, archived.order)
            end
        end
    end
    return count, fingerprint
end

local function StoreArchiveStats(profile)
    local cfg = profile._consumables
    if type(cfg) ~= "table" then return end
    local count, fingerprint = ArchiveStats(profile)
    cfg.archiveCount = count
    cfg.archiveFingerprint = fingerprint
end

local function RetargetArchiveFingerprint(cfg, id, oldOrder, newOrder)
    if type(cfg) ~= "table" then return end
    local oldToken = FingerprintToken(id, oldOrder)
    local newToken = FingerprintToken(id, newOrder)
    if oldToken == newToken then return end
    local fingerprint = tonumber(cfg.archiveFingerprint) or 0
    if oldToken then fingerprint = Xor32(fingerprint, IdHash(oldToken)) end
    if newToken then fingerprint = Xor32(fingerprint, IdHash(newToken)) end
    cfg.archiveFingerprint = fingerprint
end

local function IsArchivedRecord(profile, stored)
    if type(profile) ~= "table" or type(stored) ~= "table" then return false end
    local archive = profile._consumableEventArchive
    if type(archive) ~= "table" then return false end
    for i = 1, #archive do
        if archive[i] == stored then return true end
    end
    return false
end

local function EventQuotaKey(event)
    if type(event) ~= "table" then return nil end
    local key = Norm(event.writer)
    if not key then key = Norm(event.actor) end
    if key and #key > C.MAX_EVENT_NAME then return nil end
    return key
end

local ANON_QUOTA = {}

local function QuotaBucket(event)
    return EventQuotaKey(event) or ANON_QUOTA
end

local function ArchiveQuotaExempt(event)
    return type(event) == "table" and event.type == C.EVENT.RESET
end

local function NoteArchiveQuota(counts, event)
    if ArchiveQuotaExempt(event) then return end
    local key = QuotaBucket(event)
    counts[key] = (counts[key] or 0) + 1
end

local function NoteQuota(counts, event)
    if type(event) ~= "table" then return end
    local gen = tonumber(event.generation)
    if not gen then return end
    local row = counts[gen]
    if not row then
        row = {}
        counts[gen] = row
    end
    local key = QuotaBucket(event)
    row[key] = (row[key] or 0) + 1
end

local function IsLiveRecord(profile, stored)
    if type(profile) ~= "table" or type(stored) ~= "table" then return false end
    local events = profile._consumableEvents
    if type(events) ~= "table" then return false end
    for i = 1, #events do
        if events[i] == stored then return true end
    end
    return false
end

-- The index is rebuilt once per login and kept beside the profile. Saving it on
-- the profile would write a second copy of every ledger record.
local eventIndexes = setmetatable({}, { __mode = "k" })
local indexBound = setmetatable({}, { __mode = "k" })

local function EventIds(profile)
    local bound = eventIndexes[profile]
    if not bound then
        bound = { ids = {}, count = 0 }
        eventIndexes[profile] = bound
    end
    return bound
end

function C.EventIndex(profile)
    if type(profile) ~= "table" then return {} end
    C.Ensure(profile)
    return EventIds(profile).ids
end

function C.InvalidateEventIndex(profile)
    if type(profile) == "table" then
        indexBound[profile] = nil
        eventIndexes[profile] = nil
    end
end

local function RebuildIndex(profile)
    local index = {}
    local actorCounts = {}
    local events = profile._consumableEvents or {}
    local maxSeq = 0
    local maxOrder = 0
    local fingerprint = 0
    for i = 1, #events do
        local event = events[i]
        if type(event) == "table" and type(event.id) == "string" then
            index[event.id] = event
            NoteQuota(actorCounts, event)
            local seq = AdoptedEventSeq(event.id)
            if seq and seq > maxSeq then maxSeq = seq end
            local order = tonumber(event.order)
            if order and order > maxOrder then maxOrder = order end
            fingerprint = MixFingerprint(fingerprint, event.id, event.order)
        end
    end
    local archiveCounts = {}
    local archive = profile._consumableEventArchive
    if type(archive) == "table" then
        for i = 1, #archive do
            local archived = archive[i]
            if type(archived) == "table" and type(archived.id) == "string" then
                index[archived.id] = archived
                local seq = AdoptedEventSeq(archived.id)
                if seq and seq > maxSeq then maxSeq = seq end
                NoteArchiveQuota(archiveCounts, archived)
            end
        end
    end
    local bound = EventIds(profile)
    bound.ids = index
    bound.actorCounts = actorCounts
    bound.archiveCounts = archiveCounts
    bound.count = #events
    profile._consumableEventIds = nil
    profile._consumableIndexCount = nil
    local cfg = profile._consumables
    if cfg then
        if maxSeq > (tonumber(cfg.eventSeq) or 0) then
            cfg.eventSeq = maxSeq
        end
        if maxOrder > (tonumber(cfg.ledgerSeq) or 0) then
            cfg.ledgerSeq = maxOrder
        end
        cfg.eventFingerprint = fingerprint
        StoreArchiveStats(profile)
    end
end

function C.Ensure(profile)
    if type(profile) ~= "table" then return nil end
    if type(profile._consumables) ~= "table" then
        profile._consumables = {
            generation = 1,
            configSeq = 0,
            eventSeq = 0,
            guild = nil,
            bankTab = nil,
            crafters = {},
            assignments = {},
        }
    end
    local cfg = profile._consumables
    if type(cfg.generation) ~= "number" or cfg.generation < 1 then cfg.generation = 1 end
    if type(cfg.configSeq) ~= "number" or cfg.configSeq < 0 then cfg.configSeq = 0 end
    if type(cfg.eventSeq) ~= "number" or cfg.eventSeq < 0 or cfg.eventSeq ~= math.floor(cfg.eventSeq) then
        cfg.eventSeq = 0
    elseif cfg.eventSeq >= 9007199254740992 then
        cfg.eventSeq = C.MAX_EVENT_SEQ
    end
    if type(cfg.ledgerSeq) ~= "number" or cfg.ledgerSeq < 0 then cfg.ledgerSeq = 0 end
    if type(cfg.crafters) ~= "table" then cfg.crafters = {} end
    if type(cfg.assignments) ~= "table" then cfg.assignments = {} end
    if cfg.guild ~= nil and type(cfg.guild) ~= "table" then cfg.guild = nil end
    if type(profile._consumableEvents) ~= "table" then
        profile._consumableEvents = {}
    end
    profile._consumableEventIds = nil
    profile._consumableIndexCount = nil
    local bound = eventIndexes[profile]
    if not indexBound[profile] or not bound or bound.count ~= #profile._consumableEvents then
        RebuildIndex(profile)
    end
    indexBound[profile] = true
    return cfg
end

local function ArchiveList(profile)
    if type(profile._consumableEventArchive) ~= "table" then
        profile._consumableEventArchive = {}
    end
    return profile._consumableEventArchive
end

local function TrimArchive(profile)
    local archive = ArchiveList(profile)
    local overflow = #archive - C.MAX_ARCHIVED_EVENTS
    if overflow <= 0 then return false end
    local bound = EventIds(profile)
    for i = 1, overflow do
        local evicted = archive[i]
        if type(evicted) == "table" and type(evicted.id) == "string" and bound.ids[evicted.id] == evicted then
            bound.ids[evicted.id] = nil
        end
    end
    local kept = {}
    for i = overflow + 1, #archive do
        kept[#kept + 1] = archive[i]
    end
    profile._consumableEventArchive = kept
    StoreArchiveStats(profile)
    local counts = {}
    for i = 1, #kept do
        local archived = kept[i]
        if type(archived) == "table" then
            NoteArchiveQuota(counts, archived)
        end
    end
    EventIds(profile).archiveCounts = counts
    return true
end

local function ShelveEvents(profile, shouldArchive)
    local kept = {}
    local archive = ArchiveList(profile)
    local moved = false
    local events = profile._consumableEvents
    local bound = EventIds(profile)
    local counts = bound.archiveCounts
    if type(counts) ~= "table" then
        counts = {}
        bound.archiveCounts = counts
    end
    for i = 1, #events do
        local event = events[i]
        local eventGen = type(event) == "table" and tonumber(event.generation) or nil
        if shouldArchive(eventGen) then
            local archiveIt = true
            if type(event) == "table" and not ArchiveQuotaExempt(event) then
                local key = QuotaBucket(event)
                local used = counts[key] or 0
                if used >= C.MAX_EVENTS_PER_ACTOR then
                    archiveIt = false
                else
                    counts[key] = used + 1
                end
            end
            if archiveIt then
                archive[#archive + 1] = event
            end
            moved = true
        else
            kept[#kept + 1] = event
        end
    end
    if not moved then return false end
    profile._consumableEvents = kept
    TrimArchive(profile)
    RebuildIndex(profile)
    return true
end

function C.ShelvePriorGenerations(profile)
    local cfg = C.Ensure(profile)
    local generation = tonumber(cfg.generation) or 1
    return ShelveEvents(profile, function(eventGen)
        return eventGen and eventGen < generation
    end)
end

function C.RetainCurrentGeneration(profile)
    local cfg = C.Ensure(profile)
    local generation = tonumber(cfg.generation) or 1
    return ShelveEvents(profile, function(eventGen)
        return eventGen ~= generation
    end)
end

local function RestoreAdoptedGeneration(profile)
    local archive = profile._consumableEventArchive
    if type(archive) ~= "table" or #archive == 0 then return false end
    local generation = tonumber(profile._consumables.generation) or 1
    local live = profile._consumableEvents
    if type(live) ~= "table" then
        live = {}
        profile._consumableEvents = live
    end
    local kept = {}
    local moved = false
    for i = 1, #archive do
        local event = archive[i]
        local eventGen = type(event) == "table" and tonumber(event.generation) or nil
        if type(event) == "table" and eventGen == generation and event.type ~= C.EVENT.RESET
            and #live < C.MAX_LEDGER_EVENTS then
            live[#live + 1] = event
            moved = true
        else
            kept[#kept + 1] = event
        end
    end
    if not moved then return false end
    profile._consumableEventArchive = kept
    RebuildIndex(profile)
    return true
end

local function MixConfigText(hash, text)
    return Xor32(hash, IdHash(text))
end

local function ConfigFingerprint(cfg)
    local guid = ""
    if type(cfg.guild) == "table" and type(cfg.guild.guid) == "string" then
        guid = cfg.guild.guid
    end
    local hash = MixConfigText(0, "g:" .. guid)
    hash = MixConfigText(hash, "t:" .. tostring(tonumber(cfg.bankTab) or 0))
    local crafters = SortedCopy(cfg.crafters)
    local crafterCount = #crafters
    if crafterCount > C.MAX_ASSIGNMENT_PAIRS then
        crafterCount = C.MAX_ASSIGNMENT_PAIRS
    end
    hash = MixConfigText(hash, "c:" .. tostring(#crafters))
    for i = 1, crafterCount do
        hash = MixConfigText(hash, tostring(i) .. ":" .. crafters[i])
    end
    local keys = {}
    for key, row in pairs(cfg.assignments or {}) do
        if type(row) == "table" and type(row.crafters) == "table" and #row.crafters > 0 then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    local keyCount = #keys
    if keyCount > C.MAX_ASSIGNMENT_PAIRS then
        keyCount = C.MAX_ASSIGNMENT_PAIRS
    end
    hash = MixConfigText(hash, "a:" .. tostring(#keys))
    local mixed = 0
    for i = 1, keyCount do
        local row = cfg.assignments[keys[i]]
        hash = MixConfigText(hash, tostring(row.itemId) .. ":" .. tostring(tonumber(row.epoch) or 0))
        local names = SortedCopy(row.crafters)
        for n = 1, #names do
            if mixed >= C.MAX_ASSIGNMENT_PAIRS then break end
            hash = MixConfigText(hash, tostring(row.itemId) .. ":" .. tostring(n) .. ":" .. names[n])
            mixed = mixed + 1
        end
        if mixed >= C.MAX_ASSIGNMENT_PAIRS then break end
    end
    return hash
end

function C.Descriptor(profile)
    local cfg = C.Ensure(profile)
    return {
        generation = cfg.generation,
        configSeq = cfg.configSeq,
        configFingerprint = ConfigFingerprint(cfg),
        eventCount = #(profile._consumableEvents or {}),
        eventFingerprint = tonumber(cfg.eventFingerprint) or 0,
        archiveCount = tonumber(cfg.archiveCount) or #(profile._consumableEventArchive or {}),
        archiveFingerprint = tonumber(cfg.archiveFingerprint) or 0,
    }
end

function C.IsCanonicalAdmin(profile, actor)
    actor = Norm(actor)
    if not actor or type(profile) ~= "table" then return false end
    if type(profile.IsAdminMemberId) == "function" then
        return profile:IsAdminMemberId(actor) and true or false
    end
    for _, id in ipairs(profile._adminUsers or {}) do
        if Same(id, actor) then return true end
    end
    return false
end

local function AllowAdmin(profile, actor, opts)
    opts = opts or {}
    if opts.asAdmin ~= nil then
        return opts.asAdmin and true or false
    end
    return C.IsCanonicalAdmin(profile, actor)
end

function C.IsCrafter(profile, actor)
    actor = Norm(actor)
    if not actor then return false end
    local cfg = C.Ensure(profile)
    return Contains(cfg.crafters, actor)
end

function C.CanEditAssignment(profile, actor, crafterName, opts)
    actor = Norm(actor)
    crafterName = Norm(crafterName)
    if not actor or not crafterName then return false end
    if AllowAdmin(profile, actor, opts) then return true end
    return Same(actor, crafterName) and C.IsCrafter(profile, actor)
end

local function Assignment(cfg, itemId)
    return cfg.assignments[ItemKey(itemId)]
end

function C.IsRequested(profile, itemId)
    itemId = tonumber(itemId)
    if not IsItemId(itemId) then return false end
    local row = Assignment(C.Ensure(profile), itemId)
    return row and type(row.crafters) == "table" and #row.crafters > 0 or false
end

function C.AssignedCrafters(profile, itemId)
    local row = Assignment(C.Ensure(profile), tonumber(itemId))
    if not row then return {} end
    return SortedCopy(row.crafters)
end

function C.CrafterHasItem(profile, crafterName, itemId)
    return Contains(C.AssignedCrafters(profile, itemId), Norm(crafterName))
end

function C.CrafterAssignedAtEpoch(profile, crafterName, itemId, epoch)
    crafterName = Norm(crafterName)
    epoch = tonumber(epoch)
    itemId = tonumber(itemId)
    if not crafterName or not epoch or not IsItemId(itemId) then return false end
    local row = Assignment(C.Ensure(profile), itemId)
    if not row then return false end
    if epoch == (tonumber(row.epoch) or 0) then
        return Contains(row.crafters or {}, crafterName)
    end
    local history = row.history
    if type(history) ~= "table" then return false end
    for i = 1, #history do
        local prior = history[i]
        if type(prior) == "table" and tonumber(prior.epoch) == epoch then
            return Contains(prior.crafters or {}, crafterName)
        end
    end
    return false
end

function C.RequestedItemIds(profile)
    local cfg = C.Ensure(profile)
    local ids = {}
    for _, row in pairs(cfg.assignments) do
        if type(row) == "table" and type(row.crafters) == "table" and #row.crafters > 0 and IsItemId(tonumber(row.itemId)) then
            ids[#ids + 1] = tonumber(row.itemId)
        end
    end
    table.sort(ids)
    return ids
end

local function BumpConfig(profile)
    local cfg = C.Ensure(profile)
    cfg.configSeq = (tonumber(cfg.configSeq) or 0) + 1
    Invalidate(profile)
end

local function CopyHistory(history)
    if type(history) ~= "table" then return nil end
    local out = {}
    local count = #history
    local startAt = 1
    if count > C.MAX_ASSIGNMENT_HISTORY then
        startAt = count - C.MAX_ASSIGNMENT_HISTORY + 1
    end
    for i = startAt, count do
        local row = history[i]
        if type(row) == "table" then
            local epoch = tonumber(row.epoch)
            if epoch and epoch >= 1 and epoch == math.floor(epoch) then
                local crafters = {}
                local names = row.crafters
                if type(names) == "table" then
                    local limit = #names
                    if limit > 64 then limit = 64 end
                    for n = 1, limit do
                        local name = Norm(names[n])
                        if name then crafters[#crafters + 1] = name end
                    end
                    table.sort(crafters)
                end
                out[#out + 1] = { epoch = epoch, crafters = crafters }
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

local function PruneRetiredAssignments(cfg)
    local retired = {}
    for key, row in pairs(cfg.assignments) do
        local crafters = type(row) == "table" and row.crafters or nil
        if type(crafters) ~= "table" or #crafters == 0 then
            retired[#retired + 1] = {
                key = key,
                epoch = type(row) == "table" and tonumber(row.epoch) or 0,
            }
        end
    end
    if #retired <= C.MAX_ASSIGNMENT_HISTORY then return end
    table.sort(retired, function(a, b)
        if a.epoch ~= b.epoch then return a.epoch < b.epoch end
        return tostring(a.key) < tostring(b.key)
    end)
    local extra = #retired - C.MAX_ASSIGNMENT_HISTORY
    for i = 1, extra do
        cfg.assignments[retired[i].key] = nil
    end
end

local function CommitSet(cfg, itemId, nextCrafters)
    local key = ItemKey(itemId)
    local current = cfg.assignments[key]
    local before = current and SortedCopy(current.crafters) or {}
    local after = SortedCopy(nextCrafters)
    if SameSet(before, after) then
        return false
    end
    local epoch = current and tonumber(current.epoch) or 0
    local history = CopyHistory(current and current.history) or {}
    if current and epoch >= 1 then
        history[#history + 1] = { epoch = epoch, crafters = before }
        while #history > C.MAX_ASSIGNMENT_HISTORY do
            table.remove(history, 1)
        end
    end
    cfg.assignments[key] = {
        itemId = itemId,
        epoch = epoch + 1,
        crafters = after,
        history = #history > 0 and history or nil,
    }
    PruneRetiredAssignments(cfg)
    return true
end

function C.AddCrafter(profile, actor, crafterName, opts)
    actor = Norm(actor)
    crafterName = Norm(crafterName)
    if not actor or not crafterName then
        return false, "Enter a character name."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can add a Crafter."
    end
    if #crafterName > C.MAX_EVENT_NAME then
        return false, "That character name is too long."
    end
    if C.IsCrafter(profile, crafterName) then
        return false, "That character is already a Crafter."
    end
    local cfg = C.Ensure(profile)
    if #cfg.crafters >= C.MAX_ASSIGNMENT_PAIRS then
        return false, "The Crafter list is full."
    end
    cfg.crafters[#cfg.crafters + 1] = crafterName
    table.sort(cfg.crafters)
    BumpConfig(profile)
    Debug("Info", "Added Crafter %s", crafterName)
    Notify()
    return true
end

function C.RemoveCrafter(profile, actor, crafterName, opts)
    actor = Norm(actor)
    crafterName = Norm(crafterName)
    if not actor or not crafterName then
        return false, "Enter a character name."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can remove a Crafter."
    end
    if not C.IsCrafter(profile, crafterName) then
        return false, "That character is not a Crafter."
    end
    local cfg = C.Ensure(profile)
    cfg.crafters = Without(cfg.crafters, crafterName)
    local pending = {}
    for _, row in pairs(cfg.assignments) do
        if type(row) == "table" and Contains(row.crafters or {}, crafterName) then
            pending[#pending + 1] = tonumber(row.itemId)
        end
    end
    for i = 1, #pending do
        local itemId = pending[i]
        local row = cfg.assignments[ItemKey(itemId)]
        if type(row) == "table" then
            CommitSet(cfg, itemId, Without(row.crafters, crafterName))
        end
    end
    BumpConfig(profile)
    Debug("Info", "Removed Crafter %s", crafterName)
    Notify()
    return true
end

function C.AddAssignment(profile, actor, itemId, crafterName, opts)
    opts = opts or {}
    itemId = tonumber(itemId)
    actor = Norm(actor)
    crafterName = Norm(crafterName)
    if not IsItemId(itemId) then
        return false, "Enter a valid item ID."
    end
    if not actor or not crafterName then
        return false, "Choose a Crafter."
    end
    if not C.IsCrafter(profile, crafterName) then
        return false, "That character is not a Crafter."
    end
    if not C.CanEditAssignment(profile, actor, crafterName, opts) then
        return false, "You can only edit your own requested materials."
    end
    if opts.transferable == false or (opts.requireTransferable and opts.transferable ~= true) then
        return false, "That item cannot be traded."
    end
    if C.CrafterHasItem(profile, crafterName, itemId) then
        return false, "That Crafter already requests this exact item."
    end
    local cfg = C.Ensure(profile)
    local pairCount = 0
    for _, row in pairs(cfg.assignments) do
        if type(row) == "table" and type(row.crafters) == "table" then
            pairCount = pairCount + #row.crafters
        end
    end
    if pairCount >= C.MAX_ASSIGNMENT_PAIRS then
        return false, "Raid Consumables already has the maximum number of assignments."
    end
    local nextCrafters = C.AssignedCrafters(profile, itemId)
    nextCrafters[#nextCrafters + 1] = crafterName
    CommitSet(cfg, itemId, nextCrafters)
    BumpConfig(profile)
    Debug("Info", "Assigned item %s to %s", tostring(itemId), crafterName)
    Notify()
    return true
end

function C.RemoveAssignment(profile, actor, itemId, crafterName, opts)
    opts = opts or {}
    itemId = tonumber(itemId)
    actor = Norm(actor)
    crafterName = Norm(crafterName)
    if not IsItemId(itemId) or not actor or not crafterName then
        return false, "Choose a requested material."
    end
    if not C.CanEditAssignment(profile, actor, crafterName, opts) then
        return false, "You can only edit your own requested materials."
    end
    if not C.CrafterHasItem(profile, crafterName, itemId) then
        return false, "That material is not assigned to that Crafter."
    end
    local cfg = C.Ensure(profile)
    CommitSet(cfg, itemId, Without(C.AssignedCrafters(profile, itemId), crafterName))
    BumpConfig(profile)
    Debug("Info", "Removed item %s from %s", tostring(itemId), crafterName)
    Notify()
    return true
end

function C.SetGuild(profile, actor, guild, bankTab, opts)
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can set the guild."
    end
    if type(guild) ~= "table" or type(guild.guid) ~= "string" or guild.guid == "" then
        return false, "A stable guild id is required."
    end
    bankTab = tonumber(bankTab)
    if not IsBankTab(bankTab) then
        return false, "Choose a guild bank tab from 1 to 8."
    end
    local cfg = C.Ensure(profile)
    if cfg.guild and type(cfg.guild.guid) == "string" and cfg.guild.guid ~= "" then
        return false, "Guild configuration is locked. Clear Guild Configuration to change it."
    end
    cfg.guild = {
        guid = guild.guid,
        name = type(guild.name) == "string" and guild.name or "",
        realm = type(guild.realm) == "string" and guild.realm or "",
    }
    cfg.bankTab = bankTab
    BumpConfig(profile)
    Debug("Info", "Set guild %s tab %s", cfg.guild.guid, tostring(bankTab))
    Notify()
    return true
end

function C.SetBankTab(profile, actor, bankTab, opts)
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can change the guild bank tab."
    end
    local cfg = C.Ensure(profile)
    if not cfg.guild or type(cfg.guild.guid) ~= "string" or cfg.guild.guid == "" then
        return false, "Set the guild first."
    end
    bankTab = tonumber(bankTab)
    if not IsBankTab(bankTab) then
        return false, "Choose a guild bank tab from 1 to 8."
    end
    if cfg.bankTab == bankTab then
        return true
    end
    cfg.bankTab = bankTab
    BumpConfig(profile)
    Debug("Info", "Set guild bank tab %s", tostring(bankTab))
    Notify()
    return true
end

local function BoundedName(value)
    value = Norm(value)
    if type(value) ~= "string" or #value > C.MAX_EVENT_NAME then
        return nil
    end
    return value
end

local function BoundedReason(value)
    if type(value) ~= "string" or value == "" then return nil end
    if #value > C.MAX_EVENT_REASON then
        return value:sub(1, C.MAX_EVENT_REASON)
    end
    return value
end

local function CopyEvent(event)
    local source = event.source
    if source ~= "trade" and source ~= "guildbank" then
        source = nil
    end
    local action = event.action
    if action ~= C.ACTION.WITHDRAW and action ~= C.ACTION.TRANSFER
        and action ~= C.ACTION.RETURN and action ~= C.ACTION.DELIVER then
        action = nil
    end
    return {
        id = event.id,
        type = event.type,
        generation = tonumber(event.generation),
        timestamp = tonumber(event.timestamp),
        actor = BoundedName(event.actor),
        itemId = tonumber(event.itemId),
        quantity = tonumber(event.quantity),
        source = source,
        crafter = BoundedName(event.crafter),
        epoch = tonumber(event.epoch),
        action = action,
        holder = BoundedName(event.holder),
        fromHolder = BoundedName(event.fromHolder),
        toHolder = BoundedName(event.toHolder),
        reason = BoundedReason(event.reason),
        order = tonumber(event.order),
        tradeToken = type(event.tradeToken) == "string" and #event.tradeToken <= 128 and event.tradeToken or nil,
        withdrawToken = type(event.withdrawToken) == "string" and #event.withdrawToken <= 128 and event.withdrawToken or nil,
        writer = type(event.writer) == "string" and event.writer ~= "" and #event.writer <= C.MAX_EVENT_NAME and event.writer or nil,
    }
end

function C.AppendArchivedEvent(profile, event)
    C.Ensure(profile)
    if type(event) ~= "table" or type(event.type) ~= "string" then
        return false, "Invalid accounting event."
    end
    if type(event.id) == "string" and #event.id > C.MAX_EVENT_ID then
        return false, "invalid"
    end
    if type(event.id) ~= "string" or event.id == "" then
        event.id = C.NextEventId(profile, event.actor)
    end
    local bound = EventIds(profile)
    if bound.ids[event.id] then
        return true, "duplicate"
    end
    local generation = tonumber(event.generation)
    if not generation or generation ~= math.floor(generation) or generation < 1 then
        return false, "invalid"
    end
    local record = CopyEvent(event)
    local quotaKey = QuotaBucket(record)
    local exempt = ArchiveQuotaExempt(record)
    bound.archiveCounts = bound.archiveCounts or {}
    if not exempt and (bound.archiveCounts[quotaKey] or 0) >= C.MAX_EVENTS_PER_ACTOR then
        return false, "quota"
    end
    local archive = ArchiveList(profile)
    archive[#archive + 1] = record
    bound.ids[record.id] = record
    if not TrimArchive(profile) then
        local cfg = profile._consumables
        cfg.archiveCount = #profile._consumableEventArchive
        cfg.archiveFingerprint = MixFingerprint(cfg.archiveFingerprint, record.id, record.order)
        if not exempt then
            bound.archiveCounts[quotaKey] = (bound.archiveCounts[quotaKey] or 0) + 1
        end
    end
    return true, "archived"
end

function C.StampOrder(profile, event)
    if type(event) ~= "table" then return nil end
    local cfg = C.Ensure(profile)
    local existing = tonumber(event.order)
    if existing and existing > 0 then
        if existing > (tonumber(cfg.ledgerSeq) or 0) then
            cfg.ledgerSeq = existing
        end
        return existing
    end
    local bound = EventIds(profile)
    local stored = type(event.id) == "string" and bound.ids[event.id] or nil
    local previous = type(stored) == "table" and tonumber(stored.order) or nil
    if previous and previous > 0 then
        event.order = previous
        if previous > (tonumber(cfg.ledgerSeq) or 0) then
            cfg.ledgerSeq = previous
        end
        return previous
    end
    cfg.ledgerSeq = (tonumber(cfg.ledgerSeq) or 0) + 1
    event.order = cfg.ledgerSeq
    if type(stored) == "table" and stored ~= event then
        stored.order = event.order
    end
    local live = type(stored) == "table" and stored or event
    if IsLiveRecord(profile, live) then
        RetargetFingerprint(cfg, event.id, nil, event.order)
    elseif IsArchivedRecord(profile, live) then
        RetargetArchiveFingerprint(cfg, event.id, nil, event.order)
    end
    Invalidate(profile)
    return event.order
end

function C.NextEventId(profile, actor)
    local cfg = C.Ensure(profile)
    cfg.eventSeq = (tonumber(cfg.eventSeq) or 0) + 1
    actor = Norm(actor) or "unknown"
    if #actor > C.MAX_EVENT_NAME then
        actor = actor:sub(1, C.MAX_EVENT_NAME)
    end
    local profileId = tostring(profile._profileId or "profile")
    if #profileId > C.MAX_EVENT_NAME then
        profileId = profileId:sub(1, C.MAX_EVENT_NAME)
    end
    return string.format("ce:%s:%s:%d", profileId, actor, cfg.eventSeq)
end

function C.AppendEvent(profile, event, opts)
    opts = opts or {}
    if type(event) ~= "table" or type(event.type) ~= "string" then
        return false, "Invalid accounting event."
    end
    C.Ensure(profile)
    if type(event.id) == "string" and #event.id > C.MAX_EVENT_ID then
        return false, "invalid"
    end
    if type(event.id) ~= "string" or event.id == "" then
        event.id = C.NextEventId(profile, event.actor)
    end
    local bound = EventIds(profile)
    local stored = bound.ids[event.id]
    if stored then
        local incoming = tonumber(event.order)
        local storedOrder = type(stored) == "table" and tonumber(stored.order) or nil
        local replaceOrder = opts.replaceOrder and incoming and storedOrder and storedOrder ~= incoming
        if incoming and type(stored) == "table" and (storedOrder == nil or replaceOrder) then
            if IsLiveRecord(profile, stored) then
                RetargetFingerprint(profile._consumables, event.id, storedOrder, incoming)
            else
                RetargetArchiveFingerprint(profile._consumables, event.id, storedOrder, incoming)
            end
            stored.order = incoming
            local cfg = profile._consumables
            if incoming > (tonumber(cfg.ledgerSeq) or 0) then
                cfg.ledgerSeq = incoming
            end
            Invalidate(profile)
        end
        return true, "duplicate"
    end
    local eventGen = tonumber(event.generation)
    local currentGen = tonumber(profile._consumables.generation) or 1
    if eventGen and (eventGen ~= math.floor(eventGen) or eventGen < 1) then
        return false, "invalid"
    end
    if eventGen and eventGen > currentGen then
        return false, "future"
    end
    if eventGen and eventGen < currentGen then
        return C.AppendArchivedEvent(profile, event)
    end
    if #profile._consumableEvents >= C.MAX_LEDGER_EVENTS then
        local madeRoom = C.ShelvePriorGenerations(profile) and #profile._consumableEvents < C.MAX_LEDGER_EVENTS
        if not madeRoom then
            return false, "full"
        end
    end
    local actorKey = EventQuotaKey(event)
    local quotaKey = actorKey or ANON_QUOTA
    local quotaRow = bound.actorCounts and bound.actorCounts[currentGen]
    if (quotaRow and quotaRow[quotaKey] or 0) >= C.MAX_EVENTS_PER_ACTOR then
        return false, "quota"
    end
    event.timestamp = tonumber(event.timestamp) or Now()
    event.generation = tonumber(event.generation) or C.Ensure(profile).generation
    if event.actor then event.actor = Norm(event.actor) or event.actor end
    if event.crafter then event.crafter = Norm(event.crafter) or event.crafter end
    if event.holder then event.holder = Norm(event.holder) or event.holder end
    if event.fromHolder then event.fromHolder = Norm(event.fromHolder) or event.fromHolder end
    if event.toHolder then event.toHolder = Norm(event.toHolder) or event.toHolder end
    local record = CopyEvent(event)
    profile._consumableEvents[#profile._consumableEvents + 1] = record
    bound.ids[event.id] = record
    bound.count = #profile._consumableEvents
    bound.actorCounts = bound.actorCounts or {}
    local storedGen = tonumber(record.generation) or currentGen
    local storedRow = bound.actorCounts[storedGen]
    if not storedRow then
        storedRow = {}
        bound.actorCounts[storedGen] = storedRow
    end
    storedRow[quotaKey] = (storedRow[quotaKey] or 0) + 1
    local cfg = profile._consumables
    cfg.eventFingerprint = MixFingerprint(cfg.eventFingerprint, event.id, record.order)
    local order = tonumber(record.order)
    if order and order > (tonumber(cfg.ledgerSeq) or 0) then
        cfg.ledgerSeq = order
    end
    local seq = AdoptedEventSeq(event.id)
    if seq and seq > (tonumber(cfg.eventSeq) or 0) then
        cfg.eventSeq = seq
    end
    Invalidate(profile)
    if not opts.silent then
        Debug("Info", "Recorded %s %s", event.type, event.id)
        Notify()
    end
    return true
end

function C.Clear(profile, actor, opts)
    actor = Norm(actor)
    if not actor then
        return false, "Only a profile admin can clear Raid Consumables."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can clear Raid Consumables."
    end
    local cfg = C.Ensure(profile)
    local generation = cfg.generation
    local reset = {
        type = C.EVENT.RESET,
        generation = generation,
        actor = actor,
        timestamp = Now(),
    }
    local resetOk = C.AppendEvent(profile, reset, { silent = true })
    cfg.generation = generation + 1
    C.ShelvePriorGenerations(profile)
    if not resetOk and not EventIds(profile).ids[reset.id] then
        C.AppendArchivedEvent(profile, reset)
    end
    cfg.guild = nil
    cfg.bankTab = nil
    cfg.crafters = {}
    cfg.assignments = {}
    BumpConfig(profile)
    Debug("Info", "%s cleared Raid Consumables", actor)
    Notify()
    return true
end

local function EventLess(a, b)
    local oa = tonumber(a.order)
    local ob = tonumber(b.order)
    if oa and ob then
        if oa ~= ob then return oa < ob end
    elseif oa or ob then
        return oa ~= nil
    end
    local ta = tonumber(a.timestamp) or 0
    local tb = tonumber(b.timestamp) or 0
    if ta ~= tb then return ta < tb end
    return tostring(a.id) < tostring(b.id)
end

local function CustodyKey(holder, itemId)
    return tostring(holder) .. "|" .. tostring(itemId)
end

local function BuildProjection(profile, cfg)
    local ordered = {}
    for i = 1, #profile._consumableEvents do
        ordered[i] = profile._consumableEvents[i]
    end
    table.sort(ordered, EventLess)

    local receipts = {}
    local contributions = {}
    local bags = {}

    local function addBag(holder, itemId, qty)
        if not holder or not itemId or qty <= 0 then return end
        local key = CustodyKey(holder, itemId)
        bags[key] = (bags[key] or 0) + qty
    end

    local function takeBag(holder, itemId, qty)
        if not holder or not itemId or qty <= 0 then return 0 end
        local key = CustodyKey(holder, itemId)
        local have = bags[key] or 0
        local moved = math.min(have, qty)
        bags[key] = have - moved
        return moved
    end

    for i = 1, #ordered do
        local event = ordered[i]
        if tonumber(event.generation) == cfg.generation then
            local itemId = tonumber(event.itemId)
            local qty = tonumber(event.quantity) or 0
            if event.type == C.EVENT.DONATION and event.actor and itemId and qty > 0 then
                contributions[event.actor] = contributions[event.actor] or {}
                contributions[event.actor][itemId] = (contributions[event.actor][itemId] or 0) + qty
            elseif event.type == C.EVENT.RECEIPT and event.crafter and itemId and qty > 0 then
                local row = Assignment(cfg, itemId)
                if row and #(row.crafters or {}) > 0 and tonumber(event.epoch) == tonumber(row.epoch) and Contains(row.crafters, event.crafter) then
                    receipts[itemId] = receipts[itemId] or {}
                    receipts[itemId][event.crafter] = (receipts[itemId][event.crafter] or 0) + qty
                end
            elseif event.type == C.EVENT.CUSTODY and itemId and qty > 0 then
                if event.action == C.ACTION.WITHDRAW then
                    addBag(event.holder, itemId, qty)
                elseif event.action == C.ACTION.TRANSFER then
                    local moved = takeBag(event.fromHolder, itemId, qty)
                    addBag(event.toHolder, itemId, moved)
                elseif event.action == C.ACTION.RETURN or event.action == C.ACTION.DELIVER then
                    takeBag(event.holder or event.fromHolder, itemId, qty)
                end
            elseif event.type == C.EVENT.RESOLVE and event.holder and itemId then
                bags[CustodyKey(event.holder, itemId)] = 0
            end
        end
    end

    local custody = {}
    for key, qty in pairs(bags) do
        if qty > 0 then
            local holder, itemText = key:match("^(.-)|(%d+)$")
            local itemId = tonumber(itemText)
            if holder and itemId then
                custody[#custody + 1] = {
                    holder = holder,
                    itemId = itemId,
                    quantity = qty,
                    retired = not C.IsRequested(profile, itemId),
                }
            end
        end
    end
    table.sort(custody, function(a, b)
        if a.holder ~= b.holder then return a.holder < b.holder end
        return a.itemId < b.itemId
    end)

    return {
        receipts = receipts,
        contributions = contributions,
        custody = custody,
    }
end

function C.Project(profile)
    local cfg = C.Ensure(profile)
    local cached = projectionCache[profile]
    local key = tostring(cfg.generation) .. ":" .. tostring(cfg.configSeq) .. ":" .. tostring(#profile._consumableEvents)
    if cached and cached.key == key then
        return cached.value
    end
    local value = BuildProjection(profile, cfg)
    projectionCache[profile] = { key = key, value = value }
    return value
end

function C.ReceiptTotal(profile, itemId, crafterName)
    itemId = tonumber(itemId)
    crafterName = Norm(crafterName)
    local receipts = C.Project(profile).receipts
    local byItem = receipts[itemId]
    if not byItem or not crafterName then return 0 end
    local total = 0
    for key, qty in pairs(byItem) do
        if Same(key, crafterName) then
            total = total + (tonumber(qty) or 0)
        end
    end
    return total
end

function C.ContributionTotal(profile, memberId, itemId)
    memberId = Norm(memberId)
    if not memberId then return 0 end
    local members = { memberId }
    if type(profile.GetIdentityMembers) == "function" then
        local ids = profile:GetIdentityMembers(memberId)
        if type(ids) == "table" and #ids > 0 then
            members = ids
        end
    end
    local contributions = C.Project(profile).contributions
    local total = 0
    itemId = tonumber(itemId)
    for i = 1, #members do
        local name = Norm(members[i]) or members[i]
        local byItem = contributions[name]
        if byItem then
            if itemId then
                total = total + (byItem[itemId] or 0)
            else
                for _, qty in pairs(byItem) do
                    total = total + qty
                end
            end
        end
    end
    return total
end

function C.CustodyFor(profile, holder, itemId)
    holder = Norm(holder)
    itemId = tonumber(itemId)
    local custody = C.Project(profile).custody
    for i = 1, #custody do
        local entry = custody[i]
        if entry.itemId == itemId and Same(entry.holder, holder) then
            return entry
        end
    end
    return nil
end

local function ReasonOk(reason)
    for i = 1, #C.RESOLVE_REASONS do
        if C.RESOLVE_REASONS[i] == reason then return true end
    end
    return false
end

function C.ResolveCustody(profile, actor, holder, itemId, reason, opts)
    actor = Norm(actor)
    holder = Norm(holder)
    itemId = tonumber(itemId)
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can resolve custody."
    end
    local entry = C.CustodyFor(profile, holder, itemId)
    if not entry then
        return false, "That custody entry is not outstanding."
    end
    if not ReasonOk(reason) then
        reason = "Other"
    end
    local ok, err = C.AppendEvent(profile, {
        type = C.EVENT.RESOLVE,
        actor = actor,
        holder = holder,
        itemId = itemId,
        quantity = entry.quantity,
        reason = reason,
        generation = C.Ensure(profile).generation,
        timestamp = Now(),
    })
    if not ok then return false, err end
    Debug("Info", "%s resolved custody for %s item %s", actor, holder, tostring(itemId))
    return true
end

function C.ItemName(itemId, itemName)
    if type(itemName) == "string" and itemName ~= "" then return itemName end
    return "item " .. tostring(itemId or "")
end

function C.FormatEvent(event, itemName)
    if type(event) ~= "table" then return "" end
    local name = C.ItemName(event.itemId, itemName)
    local qty = tonumber(event.quantity) or 0
    if event.type == C.EVENT.DONATION then
        local where = event.source == "guildbank" and "the guild bank" or (event.crafter or "a Crafter")
        return string.format("%s donated %d %s to %s.", tostring(event.actor or "Someone"), qty, name, tostring(where))
    elseif event.type == C.EVENT.RECEIPT then
        return string.format("%s received %d %s.", tostring(event.crafter or "A Crafter"), qty, name)
    elseif event.type == C.EVENT.CUSTODY then
        if event.action == C.ACTION.WITHDRAW then
            return string.format("%s withdrew %d %s into custody.", tostring(event.holder), qty, name)
        elseif event.action == C.ACTION.TRANSFER then
            return string.format("%s transferred custody of %d %s to %s.", tostring(event.fromHolder), qty, name, tostring(event.toHolder))
        elseif event.action == C.ACTION.RETURN then
            return string.format("%s returned %d %s from custody to the guild bank.", tostring(event.holder or event.fromHolder), qty, name)
        elseif event.action == C.ACTION.DELIVER then
            return string.format("%s delivered %d %s from custody to %s.", tostring(event.fromHolder or event.holder), qty, name, tostring(event.crafter or event.toHolder))
        end
    elseif event.type == C.EVENT.RESOLVE then
        return string.format("%s resolved %s's custody of %d %s (%s).", tostring(event.actor), tostring(event.holder), qty, name, tostring(event.reason or "Other"))
    elseif event.type == C.EVENT.RESET then
        return string.format("%s cleared the Raid Consumables configuration.", tostring(event.actor or "An admin"))
    end
    return ""
end

function C.HistoryRows(profile, nameForItem, limit, offset)
    C.Ensure(profile)
    local ordered = {}
    local archive = profile._consumableEventArchive
    if type(archive) == "table" then
        for i = 1, #archive do
            ordered[#ordered + 1] = archive[i]
        end
    end
    for i = 1, #profile._consumableEvents do
        ordered[#ordered + 1] = profile._consumableEvents[i]
    end
    table.sort(ordered, function(a, b) return EventLess(b, a) end)
    local total = #ordered
    offset = math.floor(tonumber(offset) or 0)
    if offset < 0 then offset = 0 end
    if offset > total then offset = total end
    local last = total
    limit = tonumber(limit)
    if limit and limit >= 0 then
        last = offset + math.floor(limit)
        if last > total then last = total end
    end
    local rows = {}
    for i = offset + 1, last do
        local event = ordered[i]
        local itemName = nil
        if type(nameForItem) == "function" then
            itemName = nameForItem(event.itemId)
        end
        local text = C.FormatEvent(event, itemName)
        if text ~= "" then
            rows[#rows + 1] = {
                text = text,
                timestamp = event.timestamp,
                generation = event.generation,
            }
        end
    end
    return rows, total
end

function C.ClearConfirmation(profile)
    local custody = C.Project(profile).custody
    if #custody > 0 then
        return "Clear Raid Consumables configuration? Outstanding custody (" .. tostring(#custody) .. " entries) will be removed from current tracking. Historical Raid Consumable Logs are kept."
    end
    return "Clear Raid Consumables configuration? Guild, Crafters, assignments, and current tracking will be removed. Historical Raid Consumable Logs are kept."
end

local function CopyGuild(guild)
    if type(guild) ~= "table" or type(guild.guid) ~= "string" or guild.guid == "" then
        return nil
    end
    return {
        guid = guild.guid,
        name = type(guild.name) == "string" and guild.name or "",
        realm = type(guild.realm) == "string" and guild.realm or "",
    }
end

function C.ExportSnapshot(profile, opts)
    local cfg = C.Ensure(profile)
    opts = opts or {}
    local assignments = {}
    for key, row in pairs(cfg.assignments) do
        if type(row) == "table" then
            assignments[key] = {
                itemId = tonumber(row.itemId),
                epoch = tonumber(row.epoch) or 1,
                crafters = SortedCopy(row.crafters),
                history = CopyHistory(row.history),
            }
        end
    end
    local events = nil
    if not opts.omitEvents then
        events = {}
        local archive = profile._consumableEventArchive
        if type(archive) == "table" then
            for i = 1, #archive do
                events[#events + 1] = CopyEvent(archive[i])
            end
        end
        for i = 1, #profile._consumableEvents do
            events[#events + 1] = CopyEvent(profile._consumableEvents[i])
        end
    end
    return {
        generation = cfg.generation,
        configSeq = cfg.configSeq,
        eventSeq = cfg.eventSeq,
        ledgerSeq = tonumber(cfg.ledgerSeq) or 0,
        guild = CopyGuild(cfg.guild),
        bankTab = cfg.bankTab,
        crafters = CopyCrafterRoster(cfg.crafters),
        assignments = assignments,
        events = events,
    }
end

function C.ValidateSnapshot(data)
    if data == nil then return true end
    if type(data) ~= "table" then
        return false, "snapshot.consumables must be a table or nil"
    end
    if data.generation ~= nil and type(data.generation) ~= "number" then
        return false, "snapshot.consumables.generation must be a number"
    end
    if data.configSeq ~= nil and type(data.configSeq) ~= "number" then
        return false, "snapshot.consumables.configSeq must be a number"
    end
    if data.crafters ~= nil and type(data.crafters) ~= "table" then
        return false, "snapshot.consumables.crafters must be a table"
    end
    if data.assignments ~= nil and type(data.assignments) ~= "table" then
        return false, "snapshot.consumables.assignments must be a table"
    end
    if data.events ~= nil and type(data.events) ~= "table" then
        return false, "snapshot.consumables.events must be a table"
    end
    if type(data.events) == "table" then
        for i = 1, #data.events do
            local event = data.events[i]
            if type(event) ~= "table" or type(event.id) ~= "string" or type(event.type) ~= "string" then
                return false, "snapshot.consumables.events contains an invalid event"
            end
        end
    end
    return true
end

function C.ReplaceConfig(profile, payload)
    local cfg = C.Ensure(profile)
    cfg.generation = tonumber(payload.generation) or cfg.generation or 1
    cfg.configSeq = tonumber(payload.configSeq) or cfg.configSeq or 0
    local remoteEventSeq = tonumber(payload.eventSeq)
    if remoteEventSeq and remoteEventSeq == math.floor(remoteEventSeq)
        and remoteEventSeq > (tonumber(cfg.eventSeq) or 0) and remoteEventSeq <= C.MAX_EVENT_SEQ then
        cfg.eventSeq = remoteEventSeq
    end
    cfg.ledgerSeq = math.max(tonumber(cfg.ledgerSeq) or 0, tonumber(payload.ledgerSeq) or 0)
    cfg.guild = CopyGuild(payload.guild)
    cfg.bankTab = tonumber(payload.bankTab)
    if not IsBankTab(cfg.bankTab) then cfg.bankTab = nil end
    cfg.crafters = CopyCrafterRoster(payload.crafters)
    cfg.assignments = {}
    if type(payload.assignments) == "table" then
        for key, row in pairs(payload.assignments) do
            if type(row) == "table" then
                local itemId = tonumber(row.itemId) or tonumber(key)
                if IsItemId(itemId) then
                    cfg.assignments[ItemKey(itemId)] = {
                        itemId = itemId,
                        epoch = tonumber(row.epoch) or 1,
                        crafters = SortedCopy(row.crafters),
                        history = CopyHistory(row.history),
                    }
                end
            end
        end
    end
    PruneRetiredAssignments(cfg)
    Invalidate(profile)
    RestoreAdoptedGeneration(profile)
    C.RetainCurrentGeneration(profile)
    Notify()
    return true
end

local function ReconcileAuthoritativeEvents(profile, events)
    local keep = {}
    local limit = #events
    local maxEvents = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
    if limit > maxEvents then limit = maxEvents end
    for i = 1, limit do
        local event = events[i]
        if type(event) == "table" and type(event.id) == "string" and event.id ~= "" then
            keep[event.id] = true
        end
    end
    local unsent = {}
    local queue = profile._consumablesUnsent
    if type(queue) == "table" then
        local queued = #queue
        if queued > maxEvents then queued = maxEvents end
        for i = 1, queued do
            if type(queue[i]) == "string" then
                unsent[queue[i]] = true
            end
        end
    end
    local function keepEvent(event)
        if type(event) ~= "table" or type(event.id) ~= "string" then return false end
        return keep[event.id] or unsent[event.id] or false
    end
    local function filterList(list)
        local keptRows = {}
        local removed = false
        if type(list) ~= "table" then return keptRows, false end
        for i = 1, #list do
            if keepEvent(list[i]) then
                keptRows[#keptRows + 1] = list[i]
            else
                removed = true
            end
        end
        return keptRows, removed
    end
    local live, liveRemoved = filterList(profile._consumableEvents)
    local archive, archiveRemoved = filterList(profile._consumableEventArchive)
    if not liveRemoved and not archiveRemoved then return false end
    profile._consumableEvents = live
    profile._consumableEventArchive = archive
    RebuildIndex(profile)
    Invalidate(profile)
    Notify()
    return true
end

function C.MergeSnapshot(profile, data, opts)
    C.Ensure(profile)
    if data == nil then return true end
    local ok, err = C.ValidateSnapshot(data)
    if not ok then return false, err end
    local localDesc = C.Descriptor(profile)
    local remoteGen = tonumber(data.generation) or 1
    local remoteSeq = tonumber(data.configSeq) or 0
    opts = type(opts) == "table" and opts or {}
    local fromCoordinator = opts.consumablesFromCoordinator == true
    local adoptSession = profile._consumablesAdoptNextSnapshot
    local epoch = 0
    local syncState = SF.LootHelperSync and SF.LootHelperSync.state
    local sessionActive = type(syncState) == "table" and syncState.active == true
    if opts.consumablesFromCoordinator == false then
        if type(data.events) == "table" then
            for i = 1, #data.events do
                C.AppendEvent(profile, data.events[i], { silent = true })
            end
        end
        Notify()
        return true
    end
    if fromCoordinator and sessionActive then
        epoch = tonumber(syncState.coordEpoch) or 0
    end
    local snapshotCurrent = true
    if SF.ConsumablesSync and SF.ConsumablesSync.WatermarkAdmits then
        snapshotCurrent = SF.ConsumablesSync.WatermarkAdmits(profile, remoteGen, remoteSeq, epoch)
    end
    local replace
    if fromCoordinator then
        replace = snapshotCurrent
    else
        replace = remoteGen > localDesc.generation
            or (remoteGen == localDesc.generation and remoteSeq >= localDesc.configSeq)
            or (adoptSession and remoteGen >= localDesc.generation and snapshotCurrent)
    end
    if replace and remoteGen ~= (tonumber(profile._consumables.generation) or 1) then
        profile._consumables.generation = remoteGen
    end
    if type(data.events) == "table" then
        for i = 1, #data.events do
            C.AppendEvent(profile, data.events[i], { silent = true })
        end
    end
    profile._consumablesAdoptNextSnapshot = nil
    if replace then
        C.ReplaceConfig(profile, data)
        if fromCoordinator and type(data.events) == "table" then
            ReconcileAuthoritativeEvents(profile, data.events)
        end
        if adoptSession then
            profile._consumablesConfigAdoptedSession = adoptSession
        end
        if SF.ConsumablesSync and SF.ConsumablesSync.NoteCoordinatorWatermark then
            SF.ConsumablesSync.NoteCoordinatorWatermark(profile, remoteGen, remoteSeq, epoch)
        end
    else
        Notify()
    end
    return true
end

function C.CopyConfiguration(source, dest)
    local src = C.Ensure(source)
    C.Ensure(dest)
    dest._consumableEvents = {}
    dest._consumableEventArchive = {}
    dest._consumableEventIds = nil
    dest._consumableIndexCount = nil
    C.InvalidateEventIndex(dest)
    local assignments = {}
    for key, row in pairs(src.assignments) do
        if type(row) == "table" and type(row.crafters) == "table" and #row.crafters > 0 then
            assignments[key] = {
                itemId = tonumber(row.itemId),
                epoch = 1,
                crafters = SortedCopy(row.crafters),
            }
        end
    end
    dest._consumables = {
        generation = 1,
        configSeq = 0,
        eventSeq = 0,
        ledgerSeq = 0,
        guild = CopyGuild(src.guild),
        bankTab = src.bankTab,
        crafters = SortedCopy(src.crafters),
        assignments = assignments,
    }
    Invalidate(dest)
    Invalidate(source)
    return true
end

function C.ApplyOp(profile, op, actor, opts)
    if type(op) ~= "table" or type(op.name) ~= "string" then
        return false, "Unknown configuration change."
    end
    if op.name == "add_crafter" then
        return C.AddCrafter(profile, actor, op.crafter, opts)
    elseif op.name == "remove_crafter" then
        return C.RemoveCrafter(profile, actor, op.crafter, opts)
    elseif op.name == "add_assignment" then
        return C.AddAssignment(profile, actor, op.itemId, op.crafter, opts)
    elseif op.name == "remove_assignment" then
        return C.RemoveAssignment(profile, actor, op.itemId, op.crafter, opts)
    elseif op.name == "set_guild" then
        return C.SetGuild(profile, actor, op.guild, op.bankTab, opts)
    elseif op.name == "set_bank_tab" then
        return C.SetBankTab(profile, actor, op.bankTab, opts)
    elseif op.name == "clear" then
        return C.Clear(profile, actor, opts)
    end
    return false, "Unknown configuration change."
end

function C.CommitEvents(profile, token, events, opts)
    if type(token) ~= "string" or token == "" then
        return false, "Missing transaction id."
    end
    opts = type(opts) == "table" and opts or {}
    local writer = opts.writer
    local Rules = SF.ConsumablesSync
    local wrote = false
    local failed = nil
    for i = 1, #(events or {}) do
        local event = events[i]
        if type(event) == "table" then
            event.id = string.format("ce:%s:%s:%d", tostring(profile._profileId or "profile"), token, i)
            if type(writer) == "string" and writer ~= "" and type(event.writer) ~= "string" then
                if Rules and Rules.RemoteEventIdOk and Rules.RemoteEventIdOk(event.id, writer) then
                    event.writer = writer
                end
            end
            local ok, status = C.AppendEvent(profile, event, { silent = true })
            if not ok then
                failed = status or "Could not record that raid supplies change."
                break
            elseif status ~= "duplicate" then
                wrote = true
            end
        end
    end
    if wrote then
        Debug("Info", "Committed transaction %s", token)
        Notify()
    end
    if failed == "full" then
        return false, "The raid supplies ledger is full. Older entries stay in the log."
    end
    if failed == "quota" then
        return false, "That character has reached the raid-supply event limit for this configuration."
    end
    if failed then
        return false, failed
    end
    return true
end

function C.SettingsModel(profile, actor, asAdmin)
    local cfg = C.Ensure(profile)
    local crafter = C.IsCrafter(profile, actor)
    local rows = {}
    for _, row in pairs(cfg.assignments) do
        if type(row) == "table" and type(row.crafters) == "table" then
            for i = 1, #row.crafters do
                local name = row.crafters[i]
                if asAdmin or Same(name, actor) then
                    rows[#rows + 1] = {
                        itemId = tonumber(row.itemId),
                        crafter = name,
                        epoch = tonumber(row.epoch) or 0,
                        text = string.format("%s → %s", tostring(row.itemId), name),
                        canRemove = asAdmin or Same(name, actor),
                    }
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.itemId ~= b.itemId then return a.itemId < b.itemId end
        return tostring(a.crafter) < tostring(b.crafter)
    end)
    local crafterRows = {}
    for i = 1, #cfg.crafters do
        crafterRows[i] = {
            crafter = cfg.crafters[i],
            text = cfg.crafters[i],
            canRemove = asAdmin and true or false,
        }
    end
    local custody = {}
    if asAdmin then
        local projected = C.Project(profile).custody
        for i = 1, #projected do
            local entry = projected[i]
            custody[i] = {
                holder = entry.holder,
                itemId = entry.itemId,
                quantity = entry.quantity,
                retired = entry.retired,
                text = string.format("%s · item %s · %d%s", entry.holder, tostring(entry.itemId), entry.quantity, entry.retired and " · retired" or ""),
                canRemove = false,
            }
        end
    end
    local guildText = "No guild configured."
    if cfg.guild and cfg.guild.guid then
        guildText = string.format("%s (%s) · tab %s", cfg.guild.name ~= "" and cfg.guild.name or cfg.guild.guid, cfg.guild.guid, tostring(cfg.bankTab or ""))
    end
    return {
        isAdmin = asAdmin and true or false,
        isCrafter = crafter,
        canEditGuild = asAdmin and true or false,
        guildLocked = cfg.guild ~= nil and cfg.guild.guid ~= nil,
        canClear = asAdmin and true or false,
        canManageCrafters = asAdmin and true or false,
        guildText = guildText,
        bankTab = cfg.bankTab,
        crafters = crafterRows,
        assignments = rows,
        custody = custody,
        clearWarning = C.ClearConfirmation(profile),
        selfCrafter = crafter and Norm(actor) or nil,
    }
end

function C.BuildDonationPlan(profile, carried, ctx)
    local Routing = SF.ConsumablesRouting
    ctx = ctx or {}
    local cfg = C.Ensure(profile)
    local lines = {}
    for i = 1, #(carried or {}) do
        local row = carried[i]
        local itemId = tonumber(row.itemId)
        local quantity = math.floor(tonumber(row.quantity) or 0)
        if C.IsRequested(profile, itemId) and quantity > 0 then
            local crafters = C.AssignedCrafters(profile, itemId)
            local totals = {}
            for c = 1, #crafters do
                totals[crafters[c]] = C.ReceiptTotal(profile, itemId, crafters[c])
            end
            local recipient = Routing.RouteItem(crafters, totals, ctx.inGroup or {}, ctx.compatible or {})
            local assignment = cfg.assignments[tostring(itemId)]
            lines[#lines + 1] = {
                itemId = itemId,
                quantity = quantity,
                quality = row.quality,
                name = row.name,
                recipient = recipient,
                inRange = recipient and Routing.Flag(ctx.inRange, recipient) or false,
                epoch = assignment and tonumber(assignment.epoch) or 0,
                generation = cfg.generation,
                guildBank = ctx.guildBankUsable and true or false,
            }
        end
    end
    local groups = {}
    local order = {}
    for i = 1, #lines do
        local line = lines[i]
        local key = line.recipient
        if not key and line.guildBank then
            key = "Guild Bank"
        end
        if key then
            if not groups[key] then
                groups[key] = { key = key, lines = {} }
                order[#order + 1] = key
            end
            groups[key].lines[#groups[key].lines + 1] = line
        end
    end
    local grouped = {}
    for i = 1, #order do
        grouped[i] = groups[order[i]]
    end
    return { lines = lines, groups = grouped }
end

function C.RevalidateDonation(profile, line, ctx, inventoryQty)
    if type(line) ~= "table" then
        return false, "Review the donation again."
    end
    local cfg = C.Ensure(profile)
    if tonumber(line.generation) ~= cfg.generation then
        return false, "The active profile configuration changed. Review the donation again."
    end
    if not C.IsRequested(profile, line.itemId) then
        return false, "That item is no longer requested."
    end
    local assignment = cfg.assignments[tostring(line.itemId)]
    if not assignment or tonumber(assignment.epoch) ~= tonumber(line.epoch) then
        return false, "Routing changed. Review the donation again."
    end
    inventoryQty = math.floor(tonumber(inventoryQty) or 0)
    if inventoryQty < math.floor(tonumber(line.quantity) or 0) then
        return false, "You no longer have that many."
    end
    if line.recipient then
        local Routing = SF.ConsumablesRouting
        local totals = {}
        local crafters = C.AssignedCrafters(profile, line.itemId)
        for i = 1, #crafters do
            totals[crafters[i]] = C.ReceiptTotal(profile, line.itemId, crafters[i])
        end
        local recipient = Routing.RouteItem(crafters, totals, (ctx and ctx.inGroup) or {}, (ctx and ctx.compatible) or {})
        if recipient ~= line.recipient then
            return false, "The recipient changed. Review the donation again."
        end
        if not (ctx and Routing and Routing.Flag(ctx.inRange, line.recipient)) then
            return false, "That Crafter is out of trade range."
        end
        if not (ctx and Routing and Routing.Flag(ctx.compatible, line.recipient)) then
            return false, "That Crafter is not running a compatible client."
        end
    elseif not (ctx and ctx.guildBankUsable) then
        return false, "No donation path is available."
    end
    return true
end

function C.ItemIdFromText(text)
    local id = nil
    if type(text) == "number" then
        id = text
    elseif type(text) == "string" then
        id = tonumber(text)
        if not IsItemId(id) then
            id = tonumber(text:match("item:(%d+)"))
        end
    end
    if not IsItemId(id) then return nil end
    return id
end

function C.FreezeTrade(profile, donor, receiver, lines, token)
    donor = Norm(donor)
    receiver = Norm(receiver)
    local cfg = C.Ensure(profile)
    local custody = C.Project(profile).custody
    local wanted = {}
    local function mark(itemId)
        itemId = tonumber(itemId)
        if IsItemId(itemId) then
            wanted[itemId] = true
        end
    end
    local requested = C.RequestedItemIds(profile)
    for i = 1, #requested do
        mark(requested[i])
    end
    for c = 1, #custody do
        local entry = custody[c]
        if Same(entry.holder, donor) then
            mark(entry.itemId)
        end
    end
    for i = 1, #(lines or {}) do
        local line = lines[i]
        if type(line) == "table" then
            mark(line.itemId)
        end
    end
    local items = {}
    for itemId in pairs(wanted) do
        local custodyQty = 0
        for c = 1, #custody do
            local entry = custody[c]
            if entry.itemId == itemId and Same(entry.holder, donor) then
                custodyQty = entry.quantity
            end
        end
        local assignment = cfg.assignments[tostring(itemId)]
        items[itemId] = {
            assignedToReceiver = C.CrafterHasItem(profile, receiver, itemId),
            donorAssigned = C.CrafterHasItem(profile, donor, itemId),
            epoch = assignment and tonumber(assignment.epoch) or 0,
            custodyQty = custodyQty,
        }
    end
    return {
        profileId = profile._profileId,
        generation = cfg.generation,
        donor = donor,
        receiver = receiver,
        donorIsAdmin = C.IsCanonicalAdmin(profile, donor),
        receiverIsAdmin = C.IsCanonicalAdmin(profile, receiver),
        items = items,
        token = token,
        timestamp = Now(),
    }
end

if SF.LootProfile then
    function SF.LootProfile:EnsureConsumables()
        return C.Ensure(self)
    end
end
