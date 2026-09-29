-- Raid Consumables domain, ledger, and projections.
-- Configuration lives on the LootProfile. Accounting is append-only events.
local _, SF = ...

SF.Consumables = SF.Consumables or {}
local C = SF.Consumables

C.EVENT = {
    DONATION = "CONSUMABLE_DONATION",
    RESET = "CONSUMABLE_CONFIG_RESET",
    -- Legacy event type strings may still appear in archived development data.
    RECEIPT = "CONSUMABLE_CRAFTER_RECEIPT",
    CUSTODY = "CONSUMABLE_CUSTODY",
    RESOLVE = "CONSUMABLE_CUSTODY_RESOLVE",
}

C.MAX_REQUESTED_ITEMS = 256
C.MAX_ASSIGNMENT_PAIRS = C.MAX_REQUESTED_ITEMS -- alias for older callers/tests
C.MAX_LEDGER_EVENTS = 4096
C.MAX_ARCHIVED_EVENTS = 4096
C.MAX_VISIBLE_HISTORY = 200
C.MAX_EVENTS_PER_ACTOR = 512
C.MAX_EVENT_SEQ = 2147483647
C.MAX_EVENT_ID = 192
C.MAX_EVENT_NAME = 64

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
local BODY_HASH_BYTES = 1024
local CopyEvent

local function HashText(text, limit)
    if type(text) ~= "string" or text == "" then return 0 end
    local hash = 2166136261 % FINGERPRINT_MOD
    local size = #text
    if size > limit then size = limit end
    for i = 1, size do
        hash = (hash * 131 + string.byte(text, i)) % FINGERPRINT_MOD
    end
    return hash
end

local function IdHash(id)
    return HashText(id, HASH_BYTES)
end

local function FingerprintToken(id, order)
    if type(id) ~= "string" or id == "" then return nil end
    order = tonumber(order)
    if order and order > 0 then
        return id .. "\0" .. tostring(math.floor(order))
    end
    return id
end

local function BodyText(value)
    if value == nil then return "" end
    return tostring(value)
end

local function BodyNumber(value)
    local number = tonumber(value)
    if not number then return "" end
    return tostring(number)
end

-- Accounting fields only. Order and timestamp stay out so a stamp or a clock
-- does not look like a different event, and a changed quantity does.
local function BodyToken(event)
    if type(event) ~= "table" then return nil end
    local copy = CopyEvent(event)
    return table.concat({
        BodyText(copy.type),
        BodyNumber(copy.generation),
        BodyText(copy.actor),
        BodyNumber(copy.itemId),
        BodyNumber(copy.quantity),
        BodyText(copy.source),
        BodyText(copy.crafter),
        BodyNumber(copy.epoch),
        BodyText(copy.action),
        BodyText(copy.holder),
        BodyText(copy.fromHolder),
        BodyText(copy.toHolder),
        BodyText(copy.writer),
        BodyText(copy.tradeToken),
        BodyText(copy.withdrawToken),
        BodyText(copy.reason),
    }, "\0")
end

local function MixFingerprint(current, id, order, event)
    local token = FingerprintToken(id, order)
    if not token then return tonumber(current) or 0 end
    local mixed = Xor32(current or 0, IdHash(token))
    local body = BodyToken(event)
    if body then
        mixed = Xor32(mixed, HashText(body, BODY_HASH_BYTES))
    end
    return mixed
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
                fingerprint = MixFingerprint(fingerprint, archived.id, archived.order, archived)
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
            fingerprint = MixFingerprint(fingerprint, event.id, event.order, event)
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

local function CopyRequestedMap(source)
    local out = {}
    if type(source) ~= "table" then return out end
    local count = 0
    local keys = {}
    for key, row in pairs(source) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for i = 1, #keys do
        if count >= C.MAX_REQUESTED_ITEMS then break end
        local key = keys[i]
        local row = source[key]
        local itemId = nil
        if type(row) == "table" then
            itemId = tonumber(row.itemId) or tonumber(key)
        else
            itemId = tonumber(key) or tonumber(row)
        end
        if IsItemId(itemId) then
            out[ItemKey(itemId)] = { itemId = itemId }
            count = count + 1
        end
    end
    return out
end

local function NormalizeRequestedItems(cfg)
    if type(cfg.requestedItems) == "table" then
        cfg.requestedItems = CopyRequestedMap(cfg.requestedItems)
    else
        local migrated = {}
        -- Development-era Crafter assignments: union of assigned exact items.
        if type(cfg.assignments) == "table" then
            for key, row in pairs(cfg.assignments) do
                if type(row) == "table" then
                    local crafters = row.crafters
                    local itemId = tonumber(row.itemId) or tonumber(key)
                    if IsItemId(itemId) and type(crafters) == "table" and #crafters > 0 then
                        migrated[ItemKey(itemId)] = { itemId = itemId }
                    elseif IsItemId(itemId) and crafters == nil and row.itemId then
                        -- Already a flat requested row under the old key name.
                        migrated[ItemKey(itemId)] = { itemId = itemId }
                    end
                end
            end
        end
        cfg.requestedItems = CopyRequestedMap(migrated)
    end
    -- Discard obsolete Crafter-era persisted fields.
    cfg.crafters = nil
    cfg.assignments = nil
    cfg.itemEpochs = nil
    -- Also drop development-era freeze grants persisted beside the profile.
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
            requestedItems = {},
        }
    end
    local cfg = profile._consumables
    if type(cfg.generation) ~= "number" or cfg.generation < 1
        or cfg.generation ~= math.floor(cfg.generation) or cfg.generation > C.MAX_EVENT_SEQ then
        cfg.generation = 1
    end
    do
        local seq = tonumber(cfg.configSeq)
        if not seq or seq ~= seq or seq ~= math.floor(seq) or seq < 0 or seq > C.MAX_EVENT_SEQ then
            cfg.configSeq = 0
        else
            cfg.configSeq = seq
        end
    end
    if type(cfg.eventSeq) ~= "number" or cfg.eventSeq < 0 or cfg.eventSeq ~= math.floor(cfg.eventSeq) then
        cfg.eventSeq = 0
    elseif cfg.eventSeq >= 9007199254740992 then
        cfg.eventSeq = C.MAX_EVENT_SEQ
    end
    if type(cfg.ledgerSeq) ~= "number" or cfg.ledgerSeq < 0 then cfg.ledgerSeq = 0 end
    NormalizeRequestedItems(cfg)
    if type(profile._consumablesPendingFreezes) == "table" then
        profile._consumablesPendingFreezes = nil
    end
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

-- XOR is its own inverse, so mixing a stored row again removes it.
local function ReleaseArchivedRecord(profile, evicted)
    if type(evicted) ~= "table" then return end
    local cfg = profile._consumables
    if type(cfg) == "table" then
        cfg.archiveFingerprint = MixFingerprint(cfg.archiveFingerprint, evicted.id, evicted.order, evicted)
    end
    local bound = EventIds(profile)
    if type(evicted.id) == "string" and bound.ids[evicted.id] == evicted then
        bound.ids[evicted.id] = nil
    end
    if not ArchiveQuotaExempt(evicted) and type(bound.archiveCounts) == "table" then
        local key = QuotaBucket(evicted)
        bound.archiveCounts[key] = math.max(0, (bound.archiveCounts[key] or 1) - 1)
    end
end

local function EvictArchivedAt(profile, index)
    local archive = ArchiveList(profile)
    if type(index) ~= "number" or index < 1 or index > #archive then return nil end
    local evicted = table.remove(archive, index)
    ReleaseArchivedRecord(profile, evicted)
    return evicted
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
    local ids = {}
    for key, row in pairs(cfg.requestedItems or {}) do
        local itemId = type(row) == "table" and tonumber(row.itemId) or tonumber(key)
        if IsItemId(itemId) then
            ids[#ids + 1] = itemId
        end
    end
    table.sort(ids)
    local limit = #ids
    if limit > C.MAX_REQUESTED_ITEMS then limit = C.MAX_REQUESTED_ITEMS end
    hash = MixConfigText(hash, "r:" .. tostring(#ids))
    for i = 1, limit do
        hash = MixConfigText(hash, "i:" .. tostring(ids[i]))
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

function C.IsRequested(profile, itemId)
    itemId = tonumber(itemId)
    if not IsItemId(itemId) then return false end
    local row = C.Ensure(profile).requestedItems[ItemKey(itemId)]
    return type(row) == "table" and IsItemId(tonumber(row.itemId))
end

function C.RequestedItemIds(profile)
    local cfg = C.Ensure(profile)
    local ids = {}
    for _, row in pairs(cfg.requestedItems or {}) do
        local itemId = type(row) == "table" and tonumber(row.itemId) or nil
        if IsItemId(itemId) then
            ids[#ids + 1] = itemId
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

function C.AddRequestedItem(profile, actor, itemId, opts)
    opts = opts or {}
    itemId = tonumber(itemId)
    actor = Norm(actor)
    if not IsItemId(itemId) then
        return false, "Enter a valid item ID."
    end
    if not actor then
        return false, "Only a profile admin can add requested items."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can add requested items."
    end
    if opts.transferable == false or (opts.requireTransferable and opts.transferable ~= true) then
        return false, "That item cannot be deposited into the guild bank."
    end
    local cfg = C.Ensure(profile)
    if C.IsRequested(profile, itemId) then
        return false, "That exact item is already requested."
    end
    local count = 0
    for _ in pairs(cfg.requestedItems) do
        count = count + 1
        if count >= C.MAX_REQUESTED_ITEMS then
            return false, "Raid Consumables already has the maximum number of requested items."
        end
    end
    cfg.requestedItems[ItemKey(itemId)] = { itemId = itemId }
    BumpConfig(profile)
    Debug("Info", "Requested item %s", tostring(itemId))
    Notify()
    return true
end

function C.RemoveRequestedItem(profile, actor, itemId, opts)
    opts = opts or {}
    itemId = tonumber(itemId)
    actor = Norm(actor)
    if not IsItemId(itemId) or not actor then
        return false, "Choose a requested material."
    end
    if not AllowAdmin(profile, actor, opts) then
        return false, "Only a profile admin can remove requested items."
    end
    if not C.IsRequested(profile, itemId) then
        return false, "That material is not currently requested."
    end
    local cfg = C.Ensure(profile)
    cfg.requestedItems[ItemKey(itemId)] = nil
    BumpConfig(profile)
    Debug("Info", "Removed requested item %s", tostring(itemId))
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

function CopyEvent(event)
    local source = event.source
    if source ~= "guildbank" then
        -- Preserve archived development-era trade donations without new writers.
        if source ~= "trade" then
            source = nil
        end
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
        order = tonumber(event.order),
        writer = type(event.writer) == "string" and event.writer ~= "" and #event.writer <= C.MAX_EVENT_NAME and event.writer or nil,
    }
end

function C.AppendArchivedEvent(profile, event, opts)
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
    local cfg = profile._consumables
    cfg.archiveFingerprint = MixFingerprint(cfg.archiveFingerprint, record.id, record.order, record)
    if not exempt then
        bound.archiveCounts[quotaKey] = (bound.archiveCounts[quotaKey] or 0) + 1
    end
    local evicted = nil
    while #archive > C.MAX_ARCHIVED_EVENTS do
        local dropped = EvictArchivedAt(profile, 1)
        if not dropped then break end
        if opts and opts.collectEvicted then
            evicted = evicted or {}
            evicted[#evicted + 1] = dropped
        end
    end
    cfg.archiveCount = #archive
    if not (opts and opts.silent) then
        Notify()
    end
    return true, "archived", evicted
end

local function RestoreArchivedFront(profile, record)
    if type(record) ~= "table" or type(record.id) ~= "string" or record.id == "" then
        return false
    end
    local bound = EventIds(profile)
    if bound.ids[record.id] then
        return false
    end
    local archive = ArchiveList(profile)
    table.insert(archive, 1, record)
    bound.ids[record.id] = record
    local cfg = profile._consumables
    if type(cfg) == "table" then
        cfg.archiveFingerprint = MixFingerprint(cfg.archiveFingerprint, record.id, record.order, record)
        cfg.archiveCount = #archive
    end
    if not ArchiveQuotaExempt(record) then
        bound.archiveCounts = bound.archiveCounts or {}
        local key = QuotaBucket(record)
        bound.archiveCounts[key] = (bound.archiveCounts[key] or 0) + 1
    end
    return true
end

local function NoteCollectedEvictions(into, dropped)
    if type(dropped) ~= "table" or type(into) ~= "table" then return end
    for i = 1, #dropped do
        into[#into + 1] = dropped[i]
    end
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

function C.NoteStoredWriter(profile, event, writer)
    if type(profile) ~= "table" or type(event) ~= "table" then return false end
    if type(writer) ~= "string" or writer == "" or #writer > C.MAX_EVENT_NAME then return false end
    if type(event.writer) == "string" and event.writer ~= "" then return false end
    local before = BodyToken(event)
    event.writer = writer
    local after = BodyToken(event)
    if before == after then return true end
    local cfg = profile._consumables
    if type(cfg) ~= "table" then return true end
    local oldHash = before and HashText(before, BODY_HASH_BYTES) or 0
    local newHash = after and HashText(after, BODY_HASH_BYTES) or 0
    local function remix(field)
        cfg[field] = Xor32(Xor32(tonumber(cfg[field]) or 0, oldHash), newHash)
    end
    if IsLiveRecord(profile, event) then
        remix("eventFingerprint")
    elseif IsArchivedRecord(profile, event) then
        remix("archiveFingerprint")
    end
    return true
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

local function AssignStoredBody(stored, event)
    if type(stored) ~= "table" or type(event) ~= "table" then return false end
    if BodyToken(stored) == BodyToken(event) then return false end
    local incoming = CopyEvent(event)
    stored.type = incoming.type
    stored.generation = incoming.generation
    stored.timestamp = incoming.timestamp
    stored.actor = incoming.actor
    stored.itemId = incoming.itemId
    stored.quantity = incoming.quantity
    stored.source = incoming.source
    stored.crafter = incoming.crafter
    stored.epoch = incoming.epoch
    stored.action = incoming.action
    stored.holder = incoming.holder
    stored.fromHolder = incoming.fromHolder
    stored.toHolder = incoming.toHolder
    stored.reason = incoming.reason
    stored.tradeToken = incoming.tradeToken
    stored.withdrawToken = incoming.withdrawToken
    stored.writer = incoming.writer
    if incoming.order ~= nil then
        stored.order = incoming.order
    end
    return true
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
        if opts.replaceBody and type(stored) == "table" and AssignStoredBody(stored, event) then
            Invalidate(profile)
            return true, "replaced"
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
        return C.AppendArchivedEvent(profile, event, opts)
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
    cfg.eventFingerprint = MixFingerprint(cfg.eventFingerprint, event.id, record.order, record)
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
    cfg.requestedItems = {}
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

local function BuildProjection(profile, cfg)
    local ordered = {}
    for i = 1, #profile._consumableEvents do
        ordered[i] = profile._consumableEvents[i]
    end
    table.sort(ordered, EventLess)

    local contributions = {}
    for i = 1, #ordered do
        local event = ordered[i]
        if tonumber(event.generation) == cfg.generation then
            local itemId = tonumber(event.itemId)
            local qty = tonumber(event.quantity) or 0
            if event.type == C.EVENT.DONATION and event.actor and itemId and qty > 0 then
                contributions[event.actor] = contributions[event.actor] or {}
                contributions[event.actor][itemId] = (contributions[event.actor][itemId] or 0) + qty
            end
        end
    end

    return {
        contributions = contributions,
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

function C.ItemName(itemId, itemName)
    if type(itemName) == "string" and itemName ~= "" then return itemName end
    return "item " .. tostring(itemId or "")
end

function C.FormatEvent(event, itemName)
    if type(event) ~= "table" then return "" end
    local name = C.ItemName(event.itemId, itemName)
    local qty = tonumber(event.quantity) or 0
    if event.type == C.EVENT.DONATION then
        if event.source ~= "guildbank" then
            return ""
        end
        return string.format("%s donated %d %s to the guild bank.", tostring(event.actor or "Someone"), qty, name)
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
    return "Clear Raid Consumables configuration? Guild, Guild Bank tab, and requested items will be removed. Historical Raid Consumable Logs are kept."
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
    local requestedItems = CopyRequestedMap(cfg.requestedItems)
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
        requestedItems = requestedItems,
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
    if data.requestedItems ~= nil and type(data.requestedItems) ~= "table" then
        return false, "snapshot.consumables.requestedItems must be a table"
    end
    -- Legacy development snapshots may still carry crafters/assignments.
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

function C.ValidGeneration(value)
    local generation = tonumber(value)
    if not generation or generation ~= math.floor(generation) or generation < 1 or generation > C.MAX_EVENT_SEQ then
        return nil
    end
    return generation
end

function C.ValidConfigSeq(value)
    local seq = tonumber(value)
    if not seq or seq ~= seq or seq == math.huge or seq == -math.huge then
        return nil
    end
    if seq ~= math.floor(seq) or seq < 0 or seq > C.MAX_EVENT_SEQ then
        return nil
    end
    return seq
end

local function RequestedFromPayload(payload)
    if type(payload) ~= "table" then return {} end
    if type(payload.requestedItems) == "table" then
        return CopyRequestedMap(payload.requestedItems)
    end
    -- Migrate legacy assignment snapshots into a flat requested-item list.
    local migrated = {}
    if type(payload.assignments) == "table" then
        for key, row in pairs(payload.assignments) do
            if type(row) == "table" then
                local itemId = tonumber(row.itemId) or tonumber(key)
                local crafters = row.crafters
                if IsItemId(itemId) and (crafters == nil or (type(crafters) == "table" and #crafters > 0)) then
                    migrated[ItemKey(itemId)] = { itemId = itemId }
                end
            end
        end
    end
    return CopyRequestedMap(migrated)
end

function C.ReplaceConfig(profile, payload)
    local cfg = C.Ensure(profile)
    local generation = C.ValidGeneration(payload.generation)
    if generation then
        cfg.generation = generation
    end
    local configSeq = C.ValidConfigSeq(payload.configSeq)
    if configSeq then
        cfg.configSeq = configSeq
    end
    local remoteEventSeq = tonumber(payload.eventSeq)
    if remoteEventSeq and remoteEventSeq == math.floor(remoteEventSeq)
        and remoteEventSeq > (tonumber(cfg.eventSeq) or 0) and remoteEventSeq <= C.MAX_EVENT_SEQ then
        cfg.eventSeq = remoteEventSeq
    end
    cfg.ledgerSeq = math.max(tonumber(cfg.ledgerSeq) or 0, tonumber(payload.ledgerSeq) or 0)
    cfg.guild = CopyGuild(payload.guild)
    cfg.bankTab = tonumber(payload.bankTab)
    if not IsBankTab(cfg.bankTab) then cfg.bankTab = nil end
    cfg.requestedItems = RequestedFromPayload(payload)
    cfg.crafters = nil
    cfg.assignments = nil
    cfg.itemEpochs = nil
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
    local selfId = SF.NameUtil and SF.NameUtil.GetSelfId and SF.NameUtil.GetSelfId() or nil
    local Rules = SF.ConsumablesSync
    local function authoredUnacked(event)
        if type(event) ~= "table" or type(event.id) ~= "string" then return false end
        if tonumber(event.order) ~= nil then return false end
        if keep[event.id] or unsent[event.id] then return false end
        if type(selfId) ~= "string" or selfId == "" then return false end
        return Rules and Rules.RemoteEventIdOk and Rules.RemoteEventIdOk(event.id, selfId) and true or false
    end
    local function keepEvent(event)
        if type(event) ~= "table" or type(event.id) ~= "string" then return false end
        if keep[event.id] or unsent[event.id] then return true end
        -- Sent, then dropped before the coordinator stamped it. The id still names this client.
        return authoredUnacked(event)
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
    local requeued = false
    for i = 1, #live do
        local event = live[i]
        if authoredUnacked(event) then
            if type(queue) ~= "table" then
                queue = {}
                profile._consumablesUnsent = queue
            end
            if #queue >= maxEvents then break end
            queue[#queue + 1] = event.id
            unsent[event.id] = true
            requeued = true
        end
    end
    if not liveRemoved and not archiveRemoved then return requeued end
    profile._consumableEvents = live
    profile._consumableEventArchive = archive
    RebuildIndex(profile)
    Invalidate(profile)
    Notify()
    return true
end

local function PreferEvictableArchiveRows(profile, preserveIds)
    if type(preserveIds) ~= "table" then return end
    local archive = ArchiveList(profile)
    local count = #archive
    if count == 0 then return end
    local maxScan = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
    local limit = count
    if limit > maxScan then limit = maxScan end
    local evictable = {}
    local kept = {}
    for i = 1, limit do
        local row = archive[i]
        local id = type(row) == "table" and row.id or nil
        if type(id) == "string" and preserveIds[id] then
            kept[#kept + 1] = row
        else
            evictable[#evictable + 1] = row
        end
    end
    if #evictable == 0 then return end
    local ordered = {}
    for i = 1, #evictable do
        ordered[#ordered + 1] = evictable[i]
    end
    for i = 1, #kept do
        ordered[#ordered + 1] = kept[i]
    end
    for i = limit + 1, count do
        ordered[#ordered + 1] = archive[i]
    end
    profile._consumableEventArchive = ordered
end

function C.MergeSnapshot(profile, data, opts)
    C.Ensure(profile)
    if data == nil then return true end
    local ok, err = C.ValidateSnapshot(data)
    if not ok then return false, err end
    local localDesc = C.Descriptor(profile)
    local remoteGen = C.ValidGeneration(data.generation)
    if not remoteGen then
        if data.generation == nil then
            remoteGen = 1
        else
            remoteGen = tonumber(profile._consumables.generation) or 1
        end
    end
    local remoteSeq = C.ValidConfigSeq(data.configSeq) or 0
    opts = type(opts) == "table" and opts or {}
    local fromCoordinator = opts.consumablesFromCoordinator == true
    local adoptSession = profile._consumablesAdoptNextSnapshot
    local epoch = 0
    local syncState = SF.LootHelperSync and SF.LootHelperSync.state
    local sessionActive = type(syncState) == "table" and syncState.active == true
    if opts.consumablesFromCoordinator == false then
        local Rules = SF.ConsumablesSync
        if type(data.events) == "table" and Rules and Rules.ApplyRemoteEvent and Rules.RelayWriter then
            local limit = #data.events
            local maxEvents = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
            if limit > maxEvents then limit = maxEvents end
            for i = 1, limit do
                local event = data.events[i]
                local order = type(event) == "table" and tonumber(event.order) or nil
                if order and order > 0 and order == math.floor(order) and Rules.RelayWriter(event) then
                    Rules.ApplyRemoteEvent(profile, event, nil, {
                        coordinatorRelay = true,
                        silent = true,
                        skipGrantUse = true,
                    })
                end
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
        C.RetainCurrentGeneration(profile)
    end
    local replacedBody = false
    if fromCoordinator and replace and type(data.events) == "table" then
        local preserveIds = {}
        local preserveLimit = #data.events
        local maxEvents = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
        if preserveLimit > maxEvents then preserveLimit = maxEvents end
        for i = 1, preserveLimit do
            local event = data.events[i]
            if type(event) == "table" and type(event.id) == "string" and event.id ~= "" then
                preserveIds[event.id] = true
            end
        end
        PreferEvictableArchiveRows(profile, preserveIds)
    end
    local deferred = nil
    if type(data.events) == "table" then
        local limit = #data.events
        local maxEvents = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
        if limit > maxEvents then limit = maxEvents end
        for i = 1, limit do
            local _, status = C.AppendEvent(profile, data.events[i], {
                silent = true,
                replaceBody = fromCoordinator and replace,
            })
            if status == "replaced" then replacedBody = true end
            if fromCoordinator and replace and (status == "full" or status == "quota") then
                deferred = deferred or {}
                local deferredCap = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
                if #deferred < deferredCap then
                    deferred[#deferred + 1] = data.events[i]
                end
            end
        end
    end
    if replacedBody then RebuildIndex(profile) end
    profile._consumablesAdoptNextSnapshot = nil
    if replace then
        C.ReplaceConfig(profile, data)
        if fromCoordinator and type(data.events) == "table" then
            ReconcileAuthoritativeEvents(profile, data.events)
        end
        if fromCoordinator and type(deferred) == "table" then
            local retryLimit = #deferred
            local deferredCap = C.MAX_LEDGER_EVENTS + C.MAX_ARCHIVED_EVENTS
            if retryLimit > deferredCap then retryLimit = deferredCap end
            for i = 1, retryLimit do
                local _, status = C.AppendEvent(profile, deferred[i], {
                    silent = true,
                    replaceBody = true,
                })
                if status == "replaced" then replacedBody = true end
            end
            if replacedBody then RebuildIndex(profile) end
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
    dest._consumablesPendingFreezes = nil
    C.InvalidateEventIndex(dest)
    dest._consumables = {
        generation = 1,
        configSeq = 0,
        eventSeq = 0,
        ledgerSeq = 0,
        guild = CopyGuild(src.guild),
        bankTab = src.bankTab,
        requestedItems = CopyRequestedMap(src.requestedItems),
    }
    Invalidate(dest)
    Invalidate(source)
    return true
end

function C.ApplyOp(profile, op, actor, opts)
    if type(op) ~= "table" or type(op.name) ~= "string" then
        return false, "Unknown configuration change."
    end
    if op.name == "add_item" then
        return C.AddRequestedItem(profile, actor, op.itemId, opts)
    elseif op.name == "remove_item" then
        return C.RemoveRequestedItem(profile, actor, op.itemId, opts)
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
    local added = {}
    local evicted = {}
    for i = 1, #(events or {}) do
        local event = events[i]
        if type(event) == "table" then
            event.id = string.format("ce:%s:%s:%d", tostring(profile._profileId or "profile"), token, i)
            if type(writer) == "string" and writer ~= "" and type(event.writer) ~= "string" then
                if Rules and Rules.RemoteEventIdOk and Rules.RemoteEventIdOk(event.id, writer) then
                    event.writer = writer
                end
            end
            local ok, status, dropped = C.AppendEvent(profile, event, {
                silent = true,
                collectEvicted = true,
            })
            NoteCollectedEvictions(evicted, dropped)
            if not ok then
                failed = status or "Could not record that raid supplies change."
                break
            elseif status ~= "duplicate" then
                wrote = true
                added[#added + 1] = event.id
            end
        end
    end
    if failed and (#added > 0 or #evicted > 0) then
        local drop = {}
        for i = 1, #added do
            drop[added[i]] = true
        end
        local function keepRows(list)
            local kept = {}
            if type(list) ~= "table" then return kept end
            for i = 1, #list do
                local row = list[i]
                if not (type(row) == "table" and drop[row.id]) then
                    kept[#kept + 1] = row
                end
            end
            return kept
        end
        profile._consumableEvents = keepRows(profile._consumableEvents)
        profile._consumableEventArchive = keepRows(profile._consumableEventArchive)
        for i = #evicted, 1, -1 do
            RestoreArchivedFront(profile, evicted[i])
        end
        RebuildIndex(profile)
        Invalidate(profile)
        wrote = false
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
    local rows = {}
    for _, row in pairs(cfg.requestedItems or {}) do
        local itemId = type(row) == "table" and tonumber(row.itemId) or nil
        if IsItemId(itemId) then
            rows[#rows + 1] = {
                itemId = itemId,
                text = tostring(itemId),
                canRemove = asAdmin and true or false,
            }
        end
    end
    table.sort(rows, function(a, b) return a.itemId < b.itemId end)
    local guildText = "No guild configured."
    if cfg.guild and cfg.guild.guid then
        guildText = string.format("%s (%s) · tab %s", cfg.guild.name ~= "" and cfg.guild.name or cfg.guild.guid, cfg.guild.guid, tostring(cfg.bankTab or ""))
    end
    return {
        isAdmin = asAdmin and true or false,
        canEditGuild = asAdmin and true or false,
        guildLocked = cfg.guild ~= nil and cfg.guild.guid ~= nil,
        canClear = asAdmin and true or false,
        canManageItems = asAdmin and true or false,
        guildText = guildText,
        bankTab = cfg.bankTab,
        requestedItems = rows,
        clearWarning = C.ClearConfirmation(profile),
    }
end

function C.BuildDonationPlan(profile, carried, ctx)
    ctx = ctx or {}
    local cfg = C.Ensure(profile)
    local lines = {}
    for i = 1, #(carried or {}) do
        local row = carried[i]
        local itemId = tonumber(row.itemId)
        local quantity = math.floor(tonumber(row.quantity) or 0)
        if C.IsRequested(profile, itemId) and quantity > 0 and ctx.guildBankUsable then
            lines[#lines + 1] = {
                itemId = itemId,
                quantity = quantity,
                quality = row.quality,
                name = row.name,
                generation = cfg.generation,
                guildBank = true,
            }
        end
    end
    table.sort(lines, function(a, b) return a.itemId < b.itemId end)
    return { lines = lines, groups = { { key = "Guild Bank", lines = lines } } }
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
    inventoryQty = math.floor(tonumber(inventoryQty) or 0)
    if inventoryQty < math.floor(tonumber(line.quantity) or 0) then
        return false, "You no longer have that many."
    end
    if not (ctx and ctx.guildBankUsable) then
        return false, "No Guild Bank donation path is available."
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

if SF.LootProfile then
    function SF.LootProfile:EnsureConsumables()
        return C.Ensure(self)
    end
end
