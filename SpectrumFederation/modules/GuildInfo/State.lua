-- Guild Info durable guild-keyed state (#402).
-- Independent of Loot Helper profiles and Guild Supplies witness links.
local addonName, SF = ...

SF.GuildInfo = SF.GuildInfo or {}
local GI = SF.GuildInfo

GI.SCHEMA_VERSION = 1
GI.PROVIDER_ID = "sf.guildinfo.relationships"
GI.PROVIDER_SCHEMA = 1
GI.EDITOR_RANK_MAX = 3
GI.MAX_OPERATION_ID = 192
GI.MAX_EVENT_SEQ = 2147483647
GI.MAX_ACCEPTED_OPS = 512
GI.MAX_GROUPS = 128
GI.MAX_ALTS_PER_MAIN = 32
GI.MAX_CHARACTERS = 256
GI.MAX_NAME_REALM = 96
GI.MAX_GUID = 64
GI.MAX_CLASS = 32

GI.KIND = {
    ASSIGN = "assign",
    UNASSIGN = "unassign",
    CHANGE_MAIN = "change_main",
    SNAPSHOT = "snapshot",
}

GI._db = nil
GI._root = nil
GI._rootValid = false
GI._rootReason = "not_initialized"
GI._handleGeneration = 0
GI._lastGuildKey = nil

local function DebugInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Info("GUILD_INFO", fmt, ...)
    end
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("GUILD_INFO", fmt, ...)
    end
end

local function Rand31()
    local n = math.random(0, 0x7fffffff)
    if n < 0 then
        n = -n
    end
    return n % 0x80000000
end

local function NewWriterState()
    return {
        nonce = string.format("%08x%08x%08x", Rand31(), Rand31(), Rand31()),
        nextSeq = 1,
    }
end

local function IsValidWriterNonce(nonce)
    return type(nonce) == "string" and #nonce == 24 and nonce:match("^[0-9a-fA-F]+$") ~= nil
end

local function IsValidWriterState(writer)
    if type(writer) ~= "table" or not IsValidWriterNonce(writer.nonce) then
        return false
    end
    local seq = tonumber(writer.nextSeq)
    return seq and seq == math.floor(seq) and seq >= 1 and seq <= GI.MAX_EVENT_SEQ
end

local function IsFiniteNonnegInt(value)
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= 0 and n == n and n ~= math.huge
end

function GI.IsFiniteNonnegInt(value)
    return IsFiniteNonnegInt(value)
end

--- Parse durable guild key. Rejects name: transport fallbacks.
-- @return string|nil guildKey, string|nil clubId, string|nil reason
function GI.ParseGuildKey(guildKey)
    if type(guildKey) ~= "string" or guildKey == "" then
        return nil, nil, "invalid_guild_key"
    end
    local clubId = guildKey:match("^club:(.+)$")
    if not clubId or clubId == "" or clubId == "0" then
        return nil, nil, "unsupported_guild_key"
    end
    if clubId:match("^%s") or clubId:match("%s$") then
        return nil, nil, "unsupported_guild_key"
    end
    return guildKey, clubId, nil
end

function GI._BumpHandleGeneration(reason)
    GI._handleGeneration = (tonumber(GI._handleGeneration) or 0) + 1
    DebugInfo("handle generation=%d reason=%s", GI._handleGeneration, tostring(reason or "unknown"))
end

function GI.GetHandleGeneration()
    return tonumber(GI._handleGeneration) or 0
end

function GI:_TrackGuildKey(guildKey)
    if guildKey ~= GI._lastGuildKey then
        GI._lastGuildKey = guildKey
        GI._BumpHandleGeneration("guild_key_changed")
    end
end

local function ValidGuid(guid)
    return type(guid) == "string" and guid ~= "" and #guid <= GI.MAX_GUID
end

local function ValidNameRealm(name)
    return type(name) == "string" and name ~= "" and #name <= GI.MAX_NAME_REALM
end

local function ValidClass(classFile)
    if classFile == nil then
        return true
    end
    return type(classFile) == "string" and classFile ~= "" and #classFile <= GI.MAX_CLASS
end

local function EmptyGraph()
    return {
        mains = {}, -- [mainGuid] = { mainGuid, altGuids = {ordered}, altSet = {} }
        byGuid = {}, -- [guid] = { role = "main"|"alt", mainGuid = <guid> }
    }
end

local function RememberCharacter(characters, guid, nameRealm, classFile)
    if not ValidGuid(guid) then
        return
    end
    characters = characters or {}
    local row = characters[guid]
    if type(row) ~= "table" then
        row = { guid = guid }
        characters[guid] = row
    end
    if ValidNameRealm(nameRealm) then
        row.nameRealm = nameRealm
    end
    if ValidClass(classFile) and classFile then
        row.classFile = classFile
    end
    return characters
end

local function EnsureMain(graph, mainGuid)
    local group = graph.mains[mainGuid]
    if not group then
        group = { mainGuid = mainGuid, altGuids = {}, altSet = {} }
        graph.mains[mainGuid] = group
        graph.byGuid[mainGuid] = { role = "main", mainGuid = mainGuid }
    end
    return group
end

local function RemoveAltFromGroup(graph, altGuid)
    local info = graph.byGuid[altGuid]
    if not info or info.role ~= "alt" then
        return false
    end
    local mainGuid = info.mainGuid
    local group = graph.mains[mainGuid]
    if group then
        group.altSet[altGuid] = nil
        local nextAlts = {}
        for i = 1, #group.altGuids do
            if group.altGuids[i] ~= altGuid then
                nextAlts[#nextAlts + 1] = group.altGuids[i]
            end
        end
        group.altGuids = nextAlts
        if #group.altGuids == 0 then
            graph.mains[mainGuid] = nil
            graph.byGuid[mainGuid] = nil
        end
    end
    graph.byGuid[altGuid] = nil
    return true
end

--- Apply one op onto a fold graph. Invalid ops are skipped (deterministic no-op).
-- @return boolean applied
local function FoldApplyOp(graph, characters, op)
    if type(op) ~= "table" or type(op.kind) ~= "string" then
        return false
    end
    local kind = op.kind

    if kind == GI.KIND.SNAPSHOT then
        local snap = op.groups
        if type(snap) ~= "table" then
            return false
        end
        local fresh = EmptyGraph()
        for i = 1, math.min(#snap, GI.MAX_GROUPS) do
            local g = snap[i]
            if type(g) == "table" and ValidGuid(g.mainGuid) then
                local mainGuid = g.mainGuid
                if not fresh.byGuid[mainGuid] then
                    EnsureMain(fresh, mainGuid)
                    RememberCharacter(characters, mainGuid, g.mainName, g.mainClass)
                    local alts = g.altGuids
                    if type(alts) == "table" then
                        for j = 1, math.min(#alts, GI.MAX_ALTS_PER_MAIN) do
                            local altGuid = alts[j]
                            if ValidGuid(altGuid) and altGuid ~= mainGuid and not fresh.byGuid[altGuid] then
                                local group = EnsureMain(fresh, mainGuid)
                                group.altSet[altGuid] = true
                                group.altGuids[#group.altGuids + 1] = altGuid
                                fresh.byGuid[altGuid] = { role = "alt", mainGuid = mainGuid }
                                local altNames = g.altNames
                                local altClasses = g.altClasses
                                RememberCharacter(
                                    characters,
                                    altGuid,
                                    type(altNames) == "table" and altNames[j] or nil,
                                    type(altClasses) == "table" and altClasses[j] or nil
                                )
                            end
                        end
                    end
                end
            end
        end
        -- Replace graph contents in place.
        for k in pairs(graph.mains) do
            graph.mains[k] = nil
        end
        for k in pairs(graph.byGuid) do
            graph.byGuid[k] = nil
        end
        for k, v in pairs(fresh.mains) do
            graph.mains[k] = v
        end
        for k, v in pairs(fresh.byGuid) do
            graph.byGuid[k] = v
        end
        return true
    end

    if kind == GI.KIND.ASSIGN then
        local mainGuid, altGuid = op.mainGuid, op.altGuid
        if not ValidGuid(mainGuid) or not ValidGuid(altGuid) or mainGuid == altGuid then
            return false
        end
        RememberCharacter(characters, mainGuid, op.mainName, op.mainClass)
        RememberCharacter(characters, altGuid, op.altName, op.altClass)

        local altInfo = graph.byGuid[altGuid]
        local mainInfo = graph.byGuid[mainGuid]

        -- Reject: alt is currently a main with dependents.
        if altInfo and altInfo.role == "main" then
            local group = graph.mains[altGuid]
            if group and #group.altGuids > 0 then
                return false
            end
            -- Lone main with no alts can become an alt: dissolve empty main first.
            if group then
                graph.mains[altGuid] = nil
                graph.byGuid[altGuid] = nil
                altInfo = nil
            end
        end

        -- Reject: target main is itself an alt.
        if mainInfo and mainInfo.role == "alt" then
            return false
        end

        -- Idempotent: already under this main (no mutation).
        if altInfo and altInfo.role == "alt" and altInfo.mainGuid == mainGuid then
            return true
        end

        -- Capacity checks BEFORE mutating the old relationship (D).
        local wouldDissolveOld = false
        if altInfo and altInfo.role == "alt" then
            local oldGroup = graph.mains[altInfo.mainGuid]
            if oldGroup and #oldGroup.altGuids == 1 and oldGroup.altGuids[1] == altGuid then
                wouldDissolveOld = true
            end
        end
        local groupCount = 0
        for _ in pairs(graph.mains) do
            groupCount = groupCount + 1
        end
        local effectiveGroupCount = groupCount - (wouldDissolveOld and 1 or 0)
        if not graph.mains[mainGuid] and effectiveGroupCount >= GI.MAX_GROUPS then
            return false
        end
        local destGroup = graph.mains[mainGuid]
        if destGroup and #destGroup.altGuids >= GI.MAX_ALTS_PER_MAIN then
            return false
        end

        -- All checks passed — mutate.
        if altInfo and altInfo.role == "alt" then
            RemoveAltFromGroup(graph, altGuid)
        end
        local group = EnsureMain(graph, mainGuid)
        if #group.altGuids >= GI.MAX_ALTS_PER_MAIN then
            -- Defensive: should be unreachable after pre-check.
            return false
        end
        group.altSet[altGuid] = true
        group.altGuids[#group.altGuids + 1] = altGuid
        graph.byGuid[altGuid] = { role = "alt", mainGuid = mainGuid }
        return true
    end

    if kind == GI.KIND.UNASSIGN then
        local altGuid = op.altGuid
        if not ValidGuid(altGuid) then
            return false
        end
        local info = graph.byGuid[altGuid]
        if not info or info.role ~= "alt" then
            return false
        end
        if type(op.mainGuid) == "string" and op.mainGuid ~= "" and info.mainGuid ~= op.mainGuid then
            return false
        end
        return RemoveAltFromGroup(graph, altGuid)
    end

    if kind == GI.KIND.CHANGE_MAIN then
        local oldMain = op.mainGuid
        local newMain = op.newMainGuid
        if not ValidGuid(oldMain) or not ValidGuid(newMain) or oldMain == newMain then
            return false
        end
        local group = graph.mains[oldMain]
        if not group or not group.altSet[newMain] then
            return false
        end
        RememberCharacter(characters, oldMain, op.mainName, op.mainClass)
        RememberCharacter(characters, newMain, op.newMainName, op.newMainClass)

        local alts = {}
        for i = 1, #group.altGuids do
            local g = group.altGuids[i]
            if g ~= newMain then
                alts[#alts + 1] = g
            end
        end
        alts[#alts + 1] = oldMain

        graph.mains[oldMain] = nil
        graph.byGuid[oldMain] = nil
        graph.byGuid[newMain] = nil

        local newGroup = {
            mainGuid = newMain,
            altGuids = alts,
            altSet = {},
        }
        for i = 1, #alts do
            newGroup.altSet[alts[i]] = true
            graph.byGuid[alts[i]] = { role = "alt", mainGuid = newMain }
        end
        graph.mains[newMain] = newGroup
        graph.byGuid[newMain] = { role = "main", mainGuid = newMain }
        return true
    end

    return false
end

--- Deterministic fold of accepted ops → relationship graph.
-- @return table graph, table characters
function GI.FoldOperations(opsById, order)
    local graph = EmptyGraph()
    local characters = {}
    if type(opsById) ~= "table" or type(order) ~= "table" then
        return graph, characters
    end

    local list = {}
    for i = 1, #order do
        local id = order[i]
        local op = opsById[id]
        if type(op) == "table" and type(op.id) == "string" then
            list[#list + 1] = op
            if type(op.mainGuid) == "string" then
                RememberCharacter(characters, op.mainGuid, op.mainName, op.mainClass)
            end
            if type(op.altGuid) == "string" then
                RememberCharacter(characters, op.altGuid, op.altName, op.altClass)
            end
            if type(op.newMainGuid) == "string" then
                RememberCharacter(characters, op.newMainGuid, op.newMainName, op.newMainClass)
            end
            if type(op.characters) == "table" then
                for guid, row in pairs(op.characters) do
                    if type(row) == "table" then
                        RememberCharacter(characters, guid, row.nameRealm, row.classFile)
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b)
        local atA = tonumber(a.at) or 0
        local atB = tonumber(b.at) or 0
        if atA ~= atB then
            return atA < atB
        end
        return tostring(a.id) < tostring(b.id)
    end)

    for i = 1, #list do
        FoldApplyOp(graph, characters, list[i])
    end
    return graph, characters
end

GI._FoldApplyOp = FoldApplyOp
GI._RememberCharacter = RememberCharacter

local function RebuildDerived(record)
    local graph, foldedChars = GI.FoldOperations(record.ops, record.order)
    record.graph = {
        mains = {},
        byGuid = {},
    }
    for mainGuid, group in pairs(graph.mains) do
        local altGuids = {}
        for i = 1, #group.altGuids do
            altGuids[i] = group.altGuids[i]
        end
        record.graph.mains[mainGuid] = {
            mainGuid = mainGuid,
            altGuids = altGuids,
        }
    end
    for guid, info in pairs(graph.byGuid) do
        record.graph.byGuid[guid] = {
            role = info.role,
            mainGuid = info.mainGuid,
        }
    end
    record.characters = record.characters or {}
    for guid, row in pairs(foldedChars) do
        RememberCharacter(record.characters, guid, row.nameRealm, row.classFile)
    end
    record.revision = #(record.order or {})
    return record
end

function GI.RebuildDerived(record)
    return RebuildDerived(record)
end

local function ValidateOpBody(op)
    if type(op) ~= "table" then
        return false, "invalid_op"
    end
    if type(op.id) ~= "string" or op.id == "" or #op.id > GI.MAX_OPERATION_ID then
        return false, "invalid_op_id"
    end
    if type(op.kind) ~= "string" or op.kind == "" then
        return false, "invalid_op_kind"
    end
    if not IsFiniteNonnegInt(op.at) then
        return false, "invalid_op_at"
    end
    if not ValidGuid(op.actorGuid) then
        return false, "invalid_actor_guid"
    end
    if type(op.guildKey) ~= "string" or not GI.ParseGuildKey(op.guildKey) then
        return false, "invalid_guild_key"
    end
    local kind = op.kind
    if kind == GI.KIND.ASSIGN or kind == GI.KIND.UNASSIGN then
        if not ValidGuid(op.altGuid) then
            return false, "invalid_alt_guid"
        end
        if kind == GI.KIND.ASSIGN and not ValidGuid(op.mainGuid) then
            return false, "invalid_main_guid"
        end
    elseif kind == GI.KIND.CHANGE_MAIN then
        if not ValidGuid(op.mainGuid) or not ValidGuid(op.newMainGuid) then
            return false, "invalid_main_guid"
        end
    elseif kind == GI.KIND.SNAPSHOT then
        if type(op.groups) ~= "table" then
            return false, "invalid_snapshot"
        end
    else
        return false, "unsupported_op_kind"
    end
    return true
end

function GI.ValidateOpBody(op)
    return ValidateOpBody(op)
end

local function ValidateGuildRecord(guildKey, record)
    local key, clubId, keyErr = GI.ParseGuildKey(guildKey)
    if not key then
        return false, keyErr
    end
    if type(record) ~= "table" then
        return false, "invalid_record"
    end
    if tonumber(record.schemaVersion) ~= GI.SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if record.guildKey ~= key then
        return false, "guild_key_mismatch"
    end
    if tostring(record.clubId) ~= tostring(clubId) then
        return false, "club_id_mismatch"
    end
    if type(record.ops) ~= "table" or type(record.order) ~= "table" then
        return false, "invalid_ops"
    end
    if #record.order > GI.MAX_ACCEPTED_OPS then
        return false, "ops_overflow"
    end
    for i = 1, #record.order do
        local id = record.order[i]
        if type(id) ~= "string" or type(record.ops[id]) ~= "table" then
            return false, "invalid_ops"
        end
        local ok, err = ValidateOpBody(record.ops[id])
        if not ok then
            return false, err
        end
        if record.ops[id].id ~= id then
            return false, "invalid_ops"
        end
        if record.ops[id].guildKey ~= key then
            return false, "op_guild_mismatch"
        end
    end
    if type(record.characters) ~= "table" then
        return false, "invalid_characters"
    end
    return true
end

function GI.ValidateGuildRecord(guildKey, record)
    return ValidateGuildRecord(guildKey, record)
end

local function ValidateRootBase(root)
    if type(root) ~= "table" then
        return false, "invalid_root"
    end
    if tonumber(root.schemaVersion) ~= GI.SCHEMA_VERSION then
        return false, "unsupported_schema"
    end
    if type(root.guilds) ~= "table" then
        return false, "invalid_guilds"
    end
    return true
end

local function ValidateRoot(root)
    local ok, reason = ValidateRootBase(root)
    if not ok then
        return false, reason
    end
    if not IsValidWriterState(root.localWriter) then
        return false, "invalid_local_writer"
    end
    return true
end

local function EnsureEmptyRoot(db)
    if type(db.guildInfo) ~= "table" then
        db.guildInfo = {
            schemaVersion = GI.SCHEMA_VERSION,
            localWriter = NewWriterState(),
            guilds = {},
        }
        DebugInfo("created empty guildInfo root")
    end
    return db.guildInfo
end

function GI:Initialize(db)
    db = db or (type(SpectrumFederationDB) == "table" and SpectrumFederationDB) or nil
    if type(db) ~= "table" then
        GI._db = nil
        GI._root = nil
        GI._rootValid = false
        GI._rootReason = "db_unavailable"
        return false, GI._rootReason
    end
    GI._db = db

    local existing = db.guildInfo
    if existing == nil then
        GI._root = EnsureEmptyRoot(db)
        GI._rootValid = true
        GI._rootReason = nil
        return true
    end

    local ok, reason = ValidateRoot(existing)
    if not ok then
        if reason == "invalid_local_writer" then
            local baseOk = ValidateRootBase(existing)
            if baseOk then
                existing.localWriter = NewWriterState()
                GI._root = existing
                GI._rootValid = true
                GI._rootReason = nil
                DebugWarn("reestablished localWriter nonce on initialize")
                return true
            end
        end
        GI._root = existing
        GI._rootValid = false
        GI._rootReason = reason or "unsupported_schema"
        DebugWarn("guildInfo root unavailable: %s", tostring(GI._rootReason))
        return false, GI._rootReason
    end

    GI._root = existing
    GI._rootValid = true
    GI._rootReason = nil
    return true
end

function GI:IsRootReady()
    return GI._rootValid == true and type(GI._root) == "table"
end

function GI:GetRootReason()
    if GI._rootValid then
        return nil
    end
    return GI._rootReason or "not_ready"
end

function GI:_GetRoot()
    if not GI._rootValid then
        return nil, GI:GetRootReason()
    end
    return GI._root
end

function GI:_EnsureWritableWriter()
    local root, reason = GI:_GetRoot()
    if not root then
        return nil, reason
    end
    local writer = root.localWriter
    if not IsValidWriterState(writer) then
        root.localWriter = NewWriterState()
        DebugWarn("reestablished localWriter nonce")
        return root.localWriter
    end
    return writer
end

function GI:_AllocateOperationId(actorGuid)
    if type(actorGuid) ~= "string" or actorGuid == "" then
        return nil, "missing_actor"
    end
    local writer, reason = GI:_EnsureWritableWriter()
    if not writer then
        return nil, reason
    end
    local seq = tonumber(writer.nextSeq)
    if seq > GI.MAX_EVENT_SEQ then
        writer = NewWriterState()
        GI._root.localWriter = writer
        seq = 1
    end
    local id = string.format("gi1:%s:%s:%d", actorGuid, writer.nonce, seq)
    if #id > GI.MAX_OPERATION_ID then
        return nil, "id_too_long"
    end
    writer.nextSeq = seq + 1
    if writer.nextSeq > GI.MAX_EVENT_SEQ then
        GI._root.localWriter = NewWriterState()
    end
    return id
end

local function EmptyRecord(guildKey, clubId)
    return {
        schemaVersion = GI.SCHEMA_VERSION,
        guildKey = guildKey,
        clubId = clubId,
        ops = {},
        order = {},
        characters = {},
        graph = { mains = {}, byGuid = {} },
        revision = 0,
        openConflicts = {},
        compactedIds = {}, -- op ids removed by compaction (duplicate detection)
    }
end

--- Ensure a durable guild record exists (empty relationship set). Never imports other systems.
function GI:EnsureGuildRecord(guildKey)
    if not GI:IsRootReady() then
        return nil, GI:GetRootReason()
    end
    local key, clubId, err = GI.ParseGuildKey(guildKey)
    if not key then
        return nil, err
    end
    local root = GI._root
    local record = root.guilds[key]
    if record == nil then
        record = EmptyRecord(key, clubId)
        root.guilds[key] = record
        DebugInfo("created empty guildInfo record key=%s", key)
        return record
    end
    local ok, reason = ValidateGuildRecord(key, record)
    if not ok then
        return nil, reason
    end
    if type(record.graph) ~= "table" or type(record.graph.mains) ~= "table" then
        RebuildDerived(record)
    end
    return record
end

function GI:GetRecordForGuildKey(guildKey)
    if not GI:IsRootReady() then
        return nil, GI:GetRootReason()
    end
    local key = select(1, GI.ParseGuildKey(guildKey))
    if not key then
        return nil, "invalid_guild_key"
    end
    local record = GI._root.guilds[key]
    if record == nil then
        return nil, "not_configured"
    end
    local ok, err = ValidateGuildRecord(key, record)
    if not ok then
        return nil, err or "unsupported_schema"
    end
    if type(record.graph) ~= "table" or type(record.graph.mains) ~= "table" then
        RebuildDerived(record)
    end
    return record
end

function GI:GetCurrentRecord()
    if not GI:IsRootReady() then
        return nil, GI:GetRootReason()
    end
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildIdentity) ~= "function" then
        return nil, "identity_unavailable"
    end
    local identity, reason = GG.GetGuildIdentity()
    if not identity then
        GI:_TrackGuildKey(nil)
        return nil, reason or "not_ready"
    end
    GI:_TrackGuildKey(identity.guildKey)
    local record = GI._root.guilds[identity.guildKey]
    if record == nil then
        return nil, "not_configured", identity
    end
    local ok, err = ValidateGuildRecord(identity.guildKey, record)
    if not ok then
        return nil, err or "unsupported_schema", identity
    end
    if type(record.graph) ~= "table" or type(record.graph.mains) ~= "table" then
        RebuildDerived(record)
    end
    return record, nil, identity
end

local function SnapshotGroupsFromRecord(record)
    local graph = record.graph
    if type(graph) ~= "table" then
        RebuildDerived(record)
        graph = record.graph
    end
    local groups = {}
    for mainGuid, group in pairs(graph.mains or {}) do
        local altGuids, altNames, altClasses = {}, {}, {}
        for i = 1, #(group.altGuids or {}) do
            local ag = group.altGuids[i]
            altGuids[#altGuids + 1] = ag
            local crow = record.characters and record.characters[ag]
            altNames[#altNames + 1] = crow and crow.nameRealm or nil
            altClasses[#altClasses + 1] = crow and crow.classFile or nil
        end
        local mrow = record.characters and record.characters[mainGuid]
        groups[#groups + 1] = {
            mainGuid = mainGuid,
            mainName = mrow and mrow.nameRealm or nil,
            mainClass = mrow and mrow.classFile or nil,
            altGuids = altGuids,
            altNames = altNames,
            altClasses = altClasses,
        }
    end
    table.sort(groups, function(a, b)
        return tostring(a.mainGuid) < tostring(b.mainGuid)
    end)
    return groups
end

local function MaxOpAt(record)
    local maxAt = 0
    for i = 1, #(record.order or {}) do
        local op = record.ops[record.order[i]]
        local at = op and tonumber(op.at) or 0
        if at > maxAt then
            maxAt = at
        end
    end
    return maxAt
end

--- Compact the op log into an officer-authored snapshot when full.
-- actorGuid/actorName must be a verified editor identity (never a synthetic marker).
-- Compacted op IDs are retained for duplicate detection so late redelivery cannot resurrect.
local function CompactIfNeeded(record, actorGuid, actorName)
    if #record.order < GI.MAX_ACCEPTED_OPS then
        return false
    end
    if type(actorGuid) ~= "string" or actorGuid == "" or actorGuid == "compact" then
        return false
    end
    local groups = SnapshotGroupsFromRecord(record)
    local maxAt = MaxOpAt(record)
    local compacted = record.compactedIds
    if type(compacted) ~= "table" then
        compacted = {}
        record.compactedIds = compacted
    end
    for i = 1, #record.order do
        compacted[record.order[i]] = true
    end
    -- Bound compacted-id retention to one full log window.
    local count = 0
    for _ in pairs(compacted) do
        count = count + 1
    end
    if count > GI.MAX_ACCEPTED_OPS * 2 then
        record.compactedIds = {}
        compacted = record.compactedIds
        for i = 1, #record.order do
            compacted[record.order[i]] = true
        end
    end

    local parts = { tostring(record.guildKey), tostring(maxAt), tostring(record.revision or 0) }
    for i = 1, #groups do
        parts[#parts + 1] = groups[i].mainGuid
        for j = 1, #groups[i].altGuids do
            parts[#parts + 1] = groups[i].altGuids[j]
        end
    end
    local digest = table.concat(parts, "\0")
    local mix = 5381
    for i = 1, #digest do
        mix = (mix * 33 + digest:byte(i)) % 4294967296
    end
    local snapId = string.format("gi1:%s:snap:%08x:%d", actorGuid, mix, tonumber(record.revision) or 0)
    if #snapId > GI.MAX_OPERATION_ID then
        snapId = string.format("gi1:snap:%08x:%d", mix, tonumber(record.revision) or 0)
    end
    local snap = {
        id = snapId,
        kind = GI.KIND.SNAPSHOT,
        at = maxAt,
        actorGuid = actorGuid,
        actorName = type(actorName) == "string" and actorName or "",
        guildKey = record.guildKey,
        groups = groups,
    }
    record.ops = { [snapId] = snap }
    record.order = { snapId }
    compacted[snapId] = nil -- snapshot itself remains live
    RebuildDerived(record)
    DebugInfo("compacted guildInfo ops into snapshot id=%s actor=%s", snapId, actorGuid)
    return true
end

--- Whether admitting `op` into `record` would produce the intended assign effect.
function GI.WouldAssignTakeEffect(record, op)
    if type(record) ~= "table" or type(op) ~= "table" then
        return false
    end
    local ops = {}
    for id, body in pairs(record.ops or {}) do
        ops[id] = body
    end
    ops[op.id] = op
    local order = {}
    for i = 1, #(record.order or {}) do
        order[i] = record.order[i]
    end
    order[#order + 1] = op.id
    local graph = GI.FoldOperations(ops, order)
    local info = graph.byGuid and graph.byGuid[op.altGuid]
    return info and info.role == "alt" and info.mainGuid == op.mainGuid
end

--- Admit an authenticated operation into durable storage.
-- Remote path: store well-formed ops without racing on the local derived graph; effect
-- is determined solely by deterministic fold so peers converge (B).
-- Local path: UX preconditions (move confirm / stale confirm) still apply before store.
-- @return string status, string|nil detail
function GI:AdmitOperation(op, opts)
    opts = opts or {}
    local ok, err = ValidateOpBody(op)
    if not ok then
        return "rejected", err
    end
    local record, recErr = GI:EnsureGuildRecord(op.guildKey)
    if not record then
        return "rejected", recErr or "not_ready"
    end
    if record.ops[op.id] then
        return "duplicate", nil
    end
    if type(record.compactedIds) == "table" and record.compactedIds[op.id] then
        return "duplicate", "compacted"
    end

    -- Ops strictly older than the latest durable snapshot are superseded (C).
    if op.kind ~= GI.KIND.SNAPSHOT then
        local latestSnapAt = nil
        for i = 1, #(record.order or {}) do
            local existing = record.ops[record.order[i]]
            if existing and existing.kind == GI.KIND.SNAPSHOT then
                local at = tonumber(existing.at) or 0
                if not latestSnapAt or at > latestSnapAt then
                    latestSnapAt = at
                end
            end
        end
        if latestSnapAt and (tonumber(op.at) or 0) < latestSnapAt then
            return "duplicate", "superseded"
        end
    end

    -- Local-only confirmation / staleness gates (not used for remote sync admission).
    if not opts.remote and op.kind ~= GI.KIND.SNAPSHOT and type(record.graph) == "table" then
        local byGuid = record.graph.byGuid or {}
        if op.kind == GI.KIND.ASSIGN then
            local altInfo = byGuid[op.altGuid]
            if opts.moveConfirmed and type(opts.expectedOldMain) == "string" and opts.expectedOldMain ~= "" then
                if not altInfo or altInfo.role ~= "alt" or altInfo.mainGuid ~= opts.expectedOldMain then
                    return "rejected", "stale_move_confirmation"
                end
            elseif opts.requireMoveConfirm then
                if not altInfo or altInfo.role ~= "alt" then
                    return "rejected", "stale_move_confirmation"
                end
                if not opts.moveConfirmed then
                    return "rejected", "move_confirmation_required"
                end
            end
        elseif op.kind == GI.KIND.UNASSIGN then
            local altInfo = byGuid[op.altGuid]
            if not altInfo or altInfo.role ~= "alt" then
                return "rejected", "alt_not_assigned"
            end
            if type(op.mainGuid) == "string" and op.mainGuid ~= "" and altInfo.mainGuid ~= op.mainGuid then
                return "rejected", "stale_unassign"
            end
        elseif op.kind == GI.KIND.CHANGE_MAIN then
            local group = record.graph.mains and record.graph.mains[op.mainGuid]
            if not group then
                return "rejected", "group_missing"
            end
            local found = false
            for i = 1, #(group.altGuids or {}) do
                if group.altGuids[i] == op.newMainGuid then
                    found = true
                    break
                end
            end
            if not found then
                return "rejected", "stale_change_main"
            end
        end
    end

    local compacted = false
    if #record.order >= GI.MAX_ACCEPTED_OPS then
        compacted = CompactIfNeeded(record, op.actorGuid, op.actorName) and true or false
    end
    if #record.order >= GI.MAX_ACCEPTED_OPS then
        return "rejected", "ops_overflow"
    end

    record.ops[op.id] = op
    record.order[#record.order + 1] = op.id
    RebuildDerived(record)

    if GI._NotifyLocalDurableChange then
        GI._NotifyLocalDurableChange(compacted and "compact" or (opts.remote and "remote" or "local"))
    end
    return "accepted", nil
end

--- Public read: relationship groups for a guild key (or current guild).
-- @return table|nil groups, string|nil reason
function GI:GetRelationshipGroups(guildKey)
    local record, reason
    if guildKey then
        record, reason = GI:GetRecordForGuildKey(guildKey)
    else
        record, reason = GI:GetCurrentRecord()
        if reason == "not_configured" then
            return {}, nil
        end
    end
    if not record then
        if reason == "not_configured" then
            return {}, nil
        end
        return nil, reason
    end
    local groups = {}
    local mains = record.graph and record.graph.mains or {}
    for mainGuid, group in pairs(mains) do
        local alts = {}
        for i = 1, #(group.altGuids or {}) do
            alts[#alts + 1] = group.altGuids[i]
        end
        groups[#groups + 1] = {
            mainGuid = mainGuid,
            altGuids = alts,
        }
    end
    return groups, nil, record
end

--- Public read: role for a character GUID.
-- @return string|nil role ("main"|"alt"|nil), string|nil mainGuid
function GI:GetCharacterRole(guid, guildKey)
    if not ValidGuid(guid) then
        return nil
    end
    local record
    if guildKey then
        record = select(1, GI:GetRecordForGuildKey(guildKey))
    else
        record = select(1, GI:GetCurrentRecord())
    end
    if not record or type(record.graph) ~= "table" or type(record.graph.byGuid) ~= "table" then
        return nil
    end
    local info = record.graph.byGuid[guid]
    if not info then
        return nil
    end
    return info.role, info.mainGuid
end

function GI.UpdateCharacterDisplay(record, guid, nameRealm, classFile)
    if type(record) ~= "table" then
        return
    end
    RememberCharacter(record.characters, guid, nameRealm, classFile)
end
