-- Guild Info durable guild-keyed state (#402).
-- Versioned current-state membership + group records (no append-only op log).
local addonName, SF = ...

SF.GuildInfo = SF.GuildInfo or {}
local GI = SF.GuildInfo

GI.SCHEMA_VERSION = 2
GI.PROVIDER_ID = "sf.guildinfo.relationships"
GI.PROVIDER_SCHEMA = 2
GI.EDITOR_RANK_MAX = 3
GI.MAX_OPERATION_ID = 192
GI.MAX_EVENT_SEQ = 2147483647
GI.MAX_MEMBERS = 256 -- active + tombstone memberships (identity churn cap)
GI.MAX_GROUPS = 128 -- live + dissolved group records
GI.MAX_ALTS_PER_MAIN = 32
GI.MAX_CHARACTERS = 256 -- alias for callers/tests
GI.MAX_NAME_REALM = 96
GI.MAX_GUID = 64
GI.MAX_CLASS = 32
GI.MAX_GROUP_ID = 128
GI.UNASSIGNED = false -- membership.groupId sentinel for tombstones

-- Legacy KIND table kept only so older tests/docs references fail closed cleanly.
GI.KIND = {
    MEMBER = "member",
    GROUP = "group",
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

--- Portable 8-digit lowercase hex (avoid %x sign-extension producing 16 chars on some Lua 5.1 builds).
local function Hex8()
    local n = math.random(0, 0xfffffff) -- 28-bit fits %08x without sign-extension blowups
    local s = string.format("%08x", n)
    if #s > 8 then
        s = s:sub(-8)
    elseif #s < 8 then
        s = string.rep("0", 8 - #s) .. s
    end
    return s
end

local function Rand31()
    return math.random(0, 0xfffffff)
end

local function NewWriterState()
    return {
        nonce = Hex8() .. Hex8() .. Hex8(),
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
    return seq and seq >= 1 and seq <= GI.MAX_EVENT_SEQ + 1
end

function GI.IsFiniteNonnegInt(n)
    n = tonumber(n)
    if not n or n ~= n or n < 0 or n == math.huge then
        return false
    end
    return math.floor(n) == n
end

local function IsFiniteNonnegInt(n)
    return GI.IsFiniteNonnegInt(n)
end

local function ValidGuid(guid)
    return type(guid) == "string" and guid ~= "" and #guid <= GI.MAX_GUID
end

local function ClampName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if #name > GI.MAX_NAME_REALM then
        return name:sub(1, GI.MAX_NAME_REALM)
    end
    return name
end

local function ClampClass(classFile)
    if type(classFile) ~= "string" or classFile == "" then
        return nil
    end
    if #classFile > GI.MAX_CLASS then
        return classFile:sub(1, GI.MAX_CLASS)
    end
    return classFile
end

local function Now()
    if GetServerTime then
        local t = GetServerTime()
        if type(t) == "number" then
            return t
        end
    end
    if time then
        return time()
    end
    return 0
end

--- Compare version tuples. Higher n wins; tie-break on writer nonce string.
-- @return number -1 if a<b, 0 if equal, 1 if a>b
function GI.CompareVer(a, b)
    local an = (type(a) == "table" and tonumber(a.n)) or 0
    local bn = (type(b) == "table" and tonumber(b.n)) or 0
    if an < bn then
        return -1
    end
    if an > bn then
        return 1
    end
    local aw = (type(a) == "table" and tostring(a.w or "")) or ""
    local bw = (type(b) == "table" and tostring(b.w or "")) or ""
    if aw < bw then
        return -1
    end
    if aw > bw then
        return 1
    end
    return 0
end

local function ValidVer(ver)
    return type(ver) == "table"
        and IsFiniteNonnegInt(ver.n)
        and type(ver.w) == "string"
        and ver.w ~= ""
        and #ver.w <= 64
end

function GI.ParseGuildKey(guildKey)
    if type(guildKey) ~= "string" or guildKey == "" then
        return nil, nil, "invalid_guild_key"
    end
    local clubId = guildKey:match("^club:(%d+)$")
    if not clubId then
        return nil, nil, "invalid_guild_key"
    end
    return guildKey, clubId, nil
end

function GI.GetHandleGeneration()
    return GI._handleGeneration or 0
end

function GI:_TrackGuildKey(guildKey)
    local prev = GI._lastGuildKey
    if prev ~= guildKey then
        GI._lastGuildKey = guildKey
        GI._handleGeneration = (GI._handleGeneration or 0) + 1
    end
end

local function EmptyGraph()
    return { mains = {}, byGuid = {} }
end

local function EmptyRecord(guildKey, clubId)
    return {
        schemaVersion = GI.SCHEMA_VERSION,
        guildKey = guildKey,
        clubId = clubId,
        members = {}, -- [guid] = membership
        groups = {}, -- [groupId] = group
        characters = {}, -- last-known display (subset; also mirrored on membership)
        graph = EmptyGraph(),
        revision = 0,
        openConflicts = {},
    }
end

local function CountKeys(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do
            n = n + 1
        end
    end
    return n
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
    local n = ClampName(nameRealm)
    local c = ClampClass(classFile)
    if n then
        row.nameRealm = n
    end
    if c then
        row.classFile = c
    end
    return row
end

--- Derive mains/alts from membership + group records.
--- Canonical live group among several that claim the same designated main.
-- Prefer the main's durable membership group when it is a claimant; otherwise
-- highest group version (CompareVer), with gid sort as the stable seed order.
local function PickCanonicalClaimGroup(record, mainGuid, claimantGids)
    local mainMem = record.members and record.members[mainGuid]
    if mainMem and type(mainMem.groupId) == "string" and mainMem.groupId ~= "" then
        for i = 1, #claimantGids do
            if claimantGids[i] == mainMem.groupId then
                return mainMem.groupId
            end
        end
    end
    local winner = claimantGids[1]
    for i = 2, #claimantGids do
        local gid = claimantGids[i]
        if GI.CompareVer(record.groups[gid].ver, record.groups[winner].ver) > 0 then
            winner = gid
        end
    end
    return winner
end

--- Resolve membership groupId through a bounded dissolved forwardTo chain.
-- Incomplete concurrent shells retired by Change Main keep late members visible.
local function ResolveEffectiveGroupId(groups, gid)
    local seen = {}
    local cur = gid
    for _ = 1, 8 do
        if type(cur) ~= "string" or cur == "" then
            return nil
        end
        if seen[cur] then
            return nil
        end
        seen[cur] = true
        local g = groups and groups[cur]
        if type(g) ~= "table" then
            return nil
        end
        if type(g.forwardTo) == "string" and g.forwardTo ~= "" then
            cur = g.forwardTo
        elseif g.dissolved then
            return nil
        else
            return cur
        end
    end
    return nil
end

--- Build derived display graph. Concurrent groups that claim the same main are
-- absorbed into one canonical view without rewriting durable membership/group
-- versions (no BeatVers / dissolve). Loser shells stay stored until genuine
-- user edits move their members away. Dissolved groups may carry forwardTo so
-- late memberships remain resolvable after Change Main consolidation.
local function RebuildDerived(record)
    local graph = EmptyGraph()
    local members = record.members or {}
    local groups = record.groups or {}

    -- Deterministic absorb map: loser live groupId → canonical live groupId
    -- when multiple live groups claim the same mainGuid.
    local absorbTo = {}
    local mainsClaimed = {}
    for _, g in pairs(groups) do
        if type(g) == "table" and not g.dissolved and ValidGuid(g.mainGuid) then
            mainsClaimed[g.mainGuid] = true
        end
    end
    for mainGuid in pairs(mainsClaimed) do
        local gids = {}
        for gid, g in pairs(groups) do
            if type(g) == "table" and not g.dissolved and g.mainGuid == mainGuid then
                gids[#gids + 1] = gid
            end
        end
        table.sort(gids)
        if #gids > 1 then
            local canon = PickCanonicalClaimGroup(record, mainGuid, gids)
            for i = 1, #gids do
                if gids[i] ~= canon then
                    absorbTo[gids[i]] = canon
                end
            end
        end
    end

    -- Collect members per effective (forward + absorb) groupId.
    local byGroup = {}
    for guid, m in pairs(members) do
        if type(m) == "table" and ValidGuid(guid) then
            local gid = m.groupId
            if type(gid) == "string" and gid ~= "" then
                local resolved = ResolveEffectiveGroupId(groups, gid)
                if resolved then
                    local effective = absorbTo[resolved] or resolved
                    local g = groups[effective]
                    if type(g) == "table" and not g.dissolved then
                        byGroup[effective] = byGroup[effective] or {}
                        byGroup[effective][#byGroup[effective] + 1] = guid
                    end
                end
            end
        end
    end

    for gid, guids in pairs(byGroup) do
        table.sort(guids)
        local g = groups[gid]
        local mainGuid = nil
        local mainMovedAway = false
        if type(g.mainGuid) == "string" then
            local mm = members[g.mainGuid]
            local mmResolved = mm and ResolveEffectiveGroupId(groups, mm.groupId) or nil
            local mmEffective = mmResolved and (absorbTo[mmResolved] or mmResolved) or nil
            if mm and mmEffective == gid then
                mainGuid = g.mainGuid
            elseif mm and mmResolved and mmEffective ~= gid then
                -- Designated main lives in another non-absorbed live group.
                mainMovedAway = true
            end
        end
        if not mainGuid and not mainMovedAway then
            -- Designated main missing/unassigned: deterministic fallback among members.
            mainGuid = guids[1]
        end
        if mainGuid then
            local altGuids = {}
            for i = 1, #guids do
                local guid = guids[i]
                if guid == mainGuid then
                    graph.byGuid[guid] = { role = "main", mainGuid = mainGuid, groupId = gid }
                else
                    altGuids[#altGuids + 1] = guid
                    graph.byGuid[guid] = { role = "alt", mainGuid = mainGuid, groupId = gid }
                end
            end
            graph.mains[mainGuid] = {
                mainGuid = mainGuid,
                groupId = gid,
                altGuids = altGuids,
            }
        end
    end

    -- Bound display cache to membership GUIDs only (no lifetime roster accumulation).
    if type(record.characters) == "table" then
        for guid in pairs(record.characters) do
            if members[guid] == nil then
                record.characters[guid] = nil
            end
        end
    end

    record.graph = graph
    record.revision = CountKeys(members) + CountKeys(groups)
    return record
end

function GI.RebuildDerived(record)
    return RebuildDerived(record)
end

local function ValidateMemberBody(m)
    if type(m) ~= "table" then
        return false, "invalid_member"
    end
    if not ValidGuid(m.guid) then
        return false, "invalid_member_guid"
    end
    if not ValidVer(m.ver) then
        return false, "invalid_member_ver"
    end
    if not IsFiniteNonnegInt(m.at) then
        return false, "invalid_member_at"
    end
    local gid = m.groupId
    if gid ~= GI.UNASSIGNED and gid ~= nil then
        if type(gid) ~= "string" or gid == "" or #gid > GI.MAX_GROUP_ID then
            return false, "invalid_member_group"
        end
    end
    return true
end

local function ValidateGroupBody(g)
    if type(g) ~= "table" then
        return false, "invalid_group"
    end
    if type(g.groupId) ~= "string" or g.groupId == "" or #g.groupId > GI.MAX_GROUP_ID then
        return false, "invalid_group_id"
    end
    if not ValidVer(g.ver) then
        return false, "invalid_group_ver"
    end
    if not IsFiniteNonnegInt(g.at) then
        return false, "invalid_group_at"
    end
    local fwd = g.forwardTo
    if fwd ~= nil then
        if type(fwd) ~= "string" or fwd == "" or #fwd > GI.MAX_GROUP_ID then
            return false, "invalid_group_forward"
        end
        if fwd == g.groupId then
            return false, "invalid_group_forward"
        end
    end
    if g.dissolved then
        return true
    end
    if fwd ~= nil then
        -- Live groups do not carry forward aliases.
        return false, "invalid_group_forward"
    end
    if not ValidGuid(g.mainGuid) then
        return false, "invalid_group_main"
    end
    return true
end

function GI.ValidateMemberBody(m)
    return ValidateMemberBody(m)
end

function GI.ValidateGroupBody(g)
    return ValidateGroupBody(g)
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
    if type(record.members) ~= "table" or type(record.groups) ~= "table" then
        return false, "invalid_state"
    end
    if CountKeys(record.members) > GI.MAX_MEMBERS then
        return false, "members_overflow"
    end
    if CountKeys(record.groups) > GI.MAX_GROUPS then
        return false, "groups_overflow"
    end
    for guid, m in pairs(record.members) do
        local ok, err = ValidateMemberBody(m)
        if not ok then
            return false, err
        end
        if m.guid ~= guid then
            return false, "invalid_member"
        end
    end
    for gid, g in pairs(record.groups) do
        local ok, err = ValidateGroupBody(g)
        if not ok then
            return false, err
        end
        if g.groupId ~= gid then
            return false, "invalid_group"
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

--- Hard-reset Guild Info only (feature unmerged; no published data to migrate).
local function ResetGuildInfoRoot(db, reason)
    db.guildInfo = {
        schemaVersion = GI.SCHEMA_VERSION,
        localWriter = NewWriterState(),
        guilds = {},
    }
    DebugWarn("reset guildInfo root (%s) to schema %s", tostring(reason), tostring(GI.SCHEMA_VERSION))
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

    -- Schema 1 was the unmerged op-log prototype; replace with empty state-based root.
    if tonumber(existing.schemaVersion) ~= GI.SCHEMA_VERSION then
        GI._root = ResetGuildInfoRoot(db, "schema_upgrade")
        GI._rootValid = true
        GI._rootReason = nil
        return true
    end

    local ok, reason = ValidateRoot(existing)
    if not ok then
        if reason == "invalid_local_writer" then
            -- Repair writer only; do not wipe guild relationship state.
            existing.localWriter = NewWriterState()
            ok, reason = ValidateRoot(existing)
            if not ok and reason == "invalid_local_writer" then
                existing.localWriter = {
                    nonce = "0123456789abcdef01234567",
                    nextSeq = 1,
                }
                ok, reason = ValidateRoot(existing)
            end
            if ok then
                DebugWarn("repaired invalid localWriter nonce; guild records preserved")
            end
        end
    end
    if not ok then
        GI._root = ResetGuildInfoRoot(db, reason or "invalid_root")
        GI._rootValid = true
        GI._rootReason = nil
        return true
    end

    -- Drop any leftover op-log fields from partial upgrades.
    if type(existing.guilds) == "table" then
        for _, rec in pairs(existing.guilds) do
            if type(rec) == "table" then
                rec.ops = nil
                rec.order = nil
                rec.compactedIds = nil
                rec.compactWatermarkAt = nil
                if type(rec.members) ~= "table" then
                    rec.members = {}
                end
                if type(rec.groups) ~= "table" then
                    rec.groups = {}
                end
                RebuildDerived(rec)
            end
        end
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

function GI:_NextVer(prevVer)
    local writer, reason = GI:_EnsureWritableWriter()
    if not writer then
        return nil, reason
    end
    local prevN = (type(prevVer) == "table" and tonumber(prevVer.n)) or 0
    return { n = prevN + 1, w = writer.nonce }
end

function GI:_AllocateGroupId()
    local writer, reason = GI:_EnsureWritableWriter()
    if not writer then
        return nil, reason
    end
    local seq = tonumber(writer.nextSeq) or 1
    if seq > GI.MAX_EVENT_SEQ then
        writer = NewWriterState()
        GI._root.localWriter = writer
        seq = 1
    end
    local id = string.format("gig:%s:%d", writer.nonce, seq)
    if #id > GI.MAX_GROUP_ID then
        id = string.format("gig:%08x:%d", Rand31(), seq)
    end
    writer.nextSeq = seq + 1
    if writer.nextSeq > GI.MAX_EVENT_SEQ then
        GI._root.localWriter = NewWriterState()
    end
    return id
end

function GI:EnsureGuildRecord(guildKey)
    if not GI:IsRootReady() then
        return nil, GI:GetRootReason()
    end
    local key, clubId, err = GI.ParseGuildKey(guildKey)
    if not key then
        return nil, err
    end
    local record = GI._root.guilds[key]
    if record == nil then
        record = EmptyRecord(key, clubId)
        GI._root.guilds[key] = record
        DebugInfo("created empty guildInfo record key=%s", key)
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

local function MemberIsAssigned(m)
    return type(m) == "table" and type(m.groupId) == "string" and m.groupId ~= ""
end

local function GroupIsLive(g)
    return type(g) == "table" and not g.dissolved and ValidGuid(g.mainGuid)
end

local function GroupIsReferenced(record, groupId)
    for _, m in pairs(record.members or {}) do
        if m.groupId == groupId then
            return true
        end
    end
    return false
end

--- Build a version that strictly beats all provided version tuples (deterministic).
local function BeatVers(...)
    local bestN, bestW = 0, ""
    local nArgs = select("#", ...)
    for i = 1, nArgs do
        local v = select(i, ...)
        if type(v) == "table" then
            local n = tonumber(v.n) or 0
            local w = tostring(v.w or "")
            if n > bestN or (n == bestN and w > bestW) then
                bestN = n
                bestW = w
            end
        end
    end
    if bestW == "" then
        bestW = "0"
    end
    return { n = bestN + 1, w = bestW }
end

local function StoreMemberDirect(record, guid, groupId, ver, at, nameRealm, classFile)
    local prev = record.members[guid]
    local stored = {
        guid = guid,
        groupId = groupId == nil and GI.UNASSIGNED or groupId,
        ver = { n = ver.n, w = ver.w },
        at = tonumber(at) or 0,
        nameRealm = ClampName(nameRealm) or (prev and prev.nameRealm) or nil,
        classFile = ClampClass(classFile) or (prev and prev.classFile) or nil,
    }
    record.members[guid] = stored
    RememberCharacter(record.characters, stored.guid, stored.nameRealm, stored.classFile)
    return stored
end

local function StoreGroupDirect(record, groupId, mainGuid, ver, at, dissolved, forwardTo)
    local fwd = nil
    if dissolved and type(forwardTo) == "string" and forwardTo ~= "" and forwardTo ~= groupId then
        fwd = forwardTo
    end
    local stored = {
        groupId = groupId,
        mainGuid = dissolved and nil or mainGuid,
        ver = { n = ver.n, w = ver.w },
        at = tonumber(at) or 0,
        dissolved = dissolved and true or nil,
        forwardTo = fwd,
    }
    record.groups[groupId] = stored
    return stored
end

--- Reclaim unreferenced dissolved groups (safe: no membership points at them).
-- Membership tombstones are NOT auto-deleted; they remain until MAX_MEMBERS
-- fail-closed so stale peers cannot resurrect deleted relationships.
function GI.ReclaimUnreferencedDissolved(record)
    if type(record) ~= "table" or type(record.groups) ~= "table" then
        return 0, {}
    end
    local removed = 0
    local victims = {}
    for gid, g in pairs(record.groups) do
        if g.dissolved and not GroupIsReferenced(record, gid) then
            victims[#victims + 1] = gid
        end
    end
    for i = 1, #victims do
        record.groups[victims[i]] = nil
        removed = removed + 1
    end
    if removed > 0 then
        RebuildDerived(record)
    end
    return removed, victims
end

--- Ensure room for one new group id by reclaiming unreferenced dissolved slots.
-- Never deletes live empty shells: group-first Gossip can admit a shell before
-- its memberships arrive; discarding it loses the incomplete relationship.
-- Fail closed with groups_overflow when only live groups fill the cap.
function GI.EnsureGroupCapacity(record)
    if type(record) ~= "table" then
        return false, "not_ready"
    end
    if CountKeys(record.groups) < GI.MAX_GROUPS then
        return true
    end
    GI.ReclaimUnreferencedDissolved(record)
    if CountKeys(record.groups) < GI.MAX_GROUPS then
        return true
    end
    return false, "groups_overflow"
end

--- Legacy entry point kept for callers/tests. Concurrent same-main groups are
-- resolved only in RebuildDerived (derived-view absorption). Never invents
-- membership/group versions or dissolves loser shells.
local function ReconcileSplitMains(record)
    if type(record) == "table" then
        RebuildDerived(record)
    end
    return false
end

function GI.ReconcileSplitMains(record)
    return ReconcileSplitMains(record)
end

--- Merge a membership record if its version wins. Returns status, detail.
function GI.MergeMember(record, member, opts)
    opts = opts or {}
    if type(record) ~= "table" or type(record.members) ~= "table" then
        return "rejected", "not_ready"
    end
    local ok, err = ValidateMemberBody(member)
    if not ok then
        return "rejected", err
    end
    local existing = record.members[member.guid]
    local incomingGid = member.groupId == nil and GI.UNASSIGNED or member.groupId
    if existing then
        local inN = tonumber(member.ver and member.ver.n) or 0
        local exN = tonumber(existing.ver and existing.ver.n) or 0
        -- A string groupId is a positive assignment (group shell may arrive later).
        local incomingAssigned = type(incomingGid) == "string" and incomingGid ~= ""
        local existingAssigned = type(existing.groupId) == "string" and existing.groupId ~= ""
        local incomingUn = incomingGid == GI.UNASSIGNED or incomingGid == nil
        local existingUn = existing.groupId == GI.UNASSIGNED or existing.groupId == nil

        -- At equal logical revision, a live-group membership beats an unassign
        -- tombstone regardless of writer nonce. Concurrent dissolve of a solo-main
        -- shell on one peer must not hide another peer's still-populated group.
        if inN == exN and incomingAssigned and existingUn then
            -- accept (fall through)
        elseif inN == exN and incomingUn and existingAssigned then
            return "duplicate", "stale"
        else
            local cmp = GI.CompareVer(member.ver, existing.ver)
            if cmp <= 0 then
                if cmp == 0 then
                    return "duplicate", nil
                end
                return "duplicate", "stale"
            end
        end
    end

    -- Capacity: new GUID only when under MAX_MEMBERS.
    if not existing and CountKeys(record.members) >= GI.MAX_MEMBERS then
        return "rejected", "members_overflow"
    end

    StoreMemberDirect(
        record,
        member.guid,
        incomingGid,
        member.ver,
        member.at,
        member.nameRealm,
        member.classFile
    )
    if not opts.skipReconcile then
        ReconcileSplitMains(record)
    end
    RebuildDerived(record)
    return "accepted", nil
end

--- Merge a group record if its version wins.
-- Does not run split-main reconcile: an empty new group must not be dissolved
-- before its memberships arrive.
function GI.MergeGroup(record, group, opts)
    opts = opts or {}
    if type(record) ~= "table" or type(record.groups) ~= "table" then
        return "rejected", "not_ready"
    end
    local ok, err = ValidateGroupBody(group)
    if not ok then
        return "rejected", err
    end
    local existing = record.groups[group.groupId]
    if existing and GI.CompareVer(group.ver, existing.ver) <= 0 then
        if GI.CompareVer(group.ver, existing.ver) == 0 then
            return "duplicate", nil
        end
        return "duplicate", "stale"
    end
    if not existing then
        local room, roomErr = GI.EnsureGroupCapacity(record)
        if not room then
            return "rejected", roomErr or "groups_overflow"
        end
        existing = record.groups[group.groupId]
        if existing and GI.CompareVer(group.ver, existing.ver) <= 0 then
            return "duplicate", "stale"
        end
    end

    StoreGroupDirect(
        record,
        group.groupId,
        group.mainGuid,
        group.ver,
        group.at,
        group.dissolved and true or false,
        group.forwardTo
    )
    RebuildDerived(record)
    return "accepted", nil
end

local function NotifyDurable(reason)
    if GI._NotifyLocalDurableChange then
        GI._NotifyLocalDurableChange(reason or "local")
    end
end

local function CountAltsInGroup(record, groupId)
    local n = 0
    for _, m in pairs(record.members) do
        if m.groupId == groupId then
            n = n + 1
        end
    end
    return math.max(0, n - 1)
end

--- True when a live group has no durable alts left (empty or solo designated main).
-- A loser concurrent shell that still holds only alts (main lives elsewhere) must
-- NOT dissolve — those alts remain authoritative until a genuine edit moves them.
local function GroupHasNoDurableAlts(record, groupId)
    local g = record.groups and record.groups[groupId]
    if type(g) ~= "table" or g.dissolved then
        return false
    end
    local any = false
    for guid, m in pairs(record.members or {}) do
        if m.groupId == groupId then
            any = true
            if guid ~= g.mainGuid then
                return false
            end
        end
    end
    return true -- empty or solo main only
end

local function ClaimantGroupIds(record, mainGuid)
    local gids = {}
    for gid, g in pairs(record.groups or {}) do
        if GroupIsLive(g) and g.mainGuid == mainGuid then
            gids[#gids + 1] = gid
        end
    end
    table.sort(gids)
    return gids
end

--- True when any durable alt remains across all physical groups that claim mainGuid.
local function LogicalMainHasOtherAlts(record, mainGuid, excludeGuid)
    if not ValidGuid(mainGuid) then
        return false
    end
    local gids = ClaimantGroupIds(record, mainGuid)
    for i = 1, #gids do
        for guid, m in pairs(record.members or {}) do
            if m.groupId == gids[i] and guid ~= mainGuid and guid ~= excludeGuid then
                return true
            end
        end
    end
    return false
end

--- Dissolve a physical group only when doing so cannot hide logical-group alts.
-- Empty live shells are NOT dissolved here: absence of memberships means
-- incomplete Gossip, not proof the group is empty. Solo designated main: keep
-- while any sibling live claimant exists (shell or populated).
local function ShouldDissolvePhysicalGroup(record, groupId)
    local g = record.groups and record.groups[groupId]
    if not GroupIsLive(g) then
        return false
    end
    local n = 0
    local hasAlt = false
    for guid, m in pairs(record.members or {}) do
        if m.groupId == groupId then
            n = n + 1
            if guid ~= g.mainGuid then
                hasAlt = true
            end
        end
    end
    if n == 0 then
        return false
    end
    if hasAlt then
        return false
    end
    -- Solo main: keep while a sibling claimant shell/group may still deliver alts.
    if ValidGuid(g.mainGuid) then
        local siblings = ClaimantGroupIds(record, g.mainGuid)
        for i = 1, #siblings do
            if siblings[i] ~= groupId then
                return false
            end
        end
        if LogicalMainHasOtherAlts(record, g.mainGuid, nil) then
            return false
        end
    end
    return true
end

local function FindGroupIdForMain(record, mainGuid)
    local info = record.graph and record.graph.byGuid and record.graph.byGuid[mainGuid]
    if info and info.role == "main" and type(info.groupId) == "string" then
        return info.groupId
    end
    -- Fallback: group record whose mainGuid matches and membership confirms.
    for gid, g in pairs(record.groups) do
        if GroupIsLive(g) and g.mainGuid == mainGuid then
            local m = record.members[mainGuid]
            if m and m.groupId == gid then
                return gid
            end
        end
    end
    return nil
end

--- Dissolve a group with no remaining alts: tombstone members + mark group dissolved.
-- Dissolved group records are retained so peers can observe the tombstone via Gossip.
-- Unreferenced dissolved slots are reclaimed automatically when EnsureGroupCapacity
-- needs room (assign/unassign churn cannot permanently exhaust MAX_GROUPS).
local function DissolveEmptyGroup(record, groupId)
    if type(groupId) ~= "string" or groupId == "" then
        return
    end
    local oldG = record.groups[groupId]
    if not oldG or oldG.dissolved then
        return
    end
    local remaining = {}
    for guid, m in pairs(record.members) do
        if m.groupId == groupId then
            remaining[#remaining + 1] = guid
        end
    end
    for i = 1, #remaining do
        local guid = remaining[i]
        local mm = record.members[guid]
        local mver = GI:_NextVer(mm and mm.ver)
        if mver then
            GI.MergeMember(record, {
                guid = guid,
                groupId = GI.UNASSIGNED,
                ver = mver,
                at = Now(),
                nameRealm = mm and mm.nameRealm,
                classFile = mm and mm.classFile,
            }, { skipReconcile = true })
        end
    end
    oldG = record.groups[groupId]
    if oldG and not oldG.dissolved then
        local dVer = GI:_NextVer(oldG.ver)
        if dVer then
            GI.MergeGroup(record, {
                groupId = groupId,
                ver = dVer,
                at = Now(),
                dissolved = true,
            }, { skipReconcile = true })
        end
    end
end

--- Officer-authorized: retire a concurrent physical group as a dissolved forward
-- alias to the canonical group so late memberships remain resolvable.
local function RetireGroupAsForward(record, fromGid, toGid)
    if type(fromGid) ~= "string" or fromGid == "" or fromGid == toGid then
        return true
    end
    local g = record.groups and record.groups[fromGid]
    if not g then
        return true
    end
    if g.dissolved and g.forwardTo == toGid then
        return true
    end
    local ver, vErr = GI:_NextVer(g.ver)
    if not ver then
        return false, vErr or "no_effect"
    end
    local st = GI.MergeGroup(record, {
        groupId = fromGid,
        ver = ver,
        at = Now(),
        dissolved = true,
        forwardTo = toGid,
    }, { skipReconcile = true })
    if st ~= "accepted" and st ~= "duplicate" then
        return false, st
    end
    return true
end

--- Officer-authorized consolidate: move every currently known durable member of
-- groups claiming mainGuid into targetGroupId, then retire emptied/sibling
-- claimants as forward aliases (not hard-delete). Incomplete shells must keep
-- late-arriving members resolvable after Change Main.
local function ConsolidateLogicalGroupTo(record, mainGuid, targetGroupId)
    if type(targetGroupId) ~= "string" or targetGroupId == "" then
        return false, "group_missing"
    end
    local claimants = ClaimantGroupIds(record, mainGuid)
    for i = 1, #claimants do
        local gid = claimants[i]
        if gid ~= targetGroupId then
            local moveGuids = {}
            for guid, m in pairs(record.members or {}) do
                if m.groupId == gid then
                    moveGuids[#moveGuids + 1] = guid
                end
            end
            for j = 1, #moveGuids do
                local guid = moveGuids[j]
                local mm = record.members[guid]
                local ver, vErr = GI:_NextVer(mm and mm.ver)
                if not ver then
                    return false, vErr or "no_effect"
                end
                local st = GI.MergeMember(record, {
                    guid = guid,
                    groupId = targetGroupId,
                    ver = ver,
                    at = Now(),
                    nameRealm = mm and mm.nameRealm,
                    classFile = mm and mm.classFile,
                }, { skipReconcile = true })
                if st ~= "accepted" and st ~= "duplicate" then
                    return false, st
                end
            end
            local okFwd, fwdErr = RetireGroupAsForward(record, gid, targetGroupId)
            if not okFwd then
                return false, fwdErr or "no_effect"
            end
        end
    end
    RebuildDerived(record)
    return true
end

--- Local assign/move implementation. Returns status, detail[, meta].
function GI:ApplyAssign(mainGuid, altGuid, opts)
    opts = opts or {}
    if not ValidGuid(mainGuid) or not ValidGuid(altGuid) or mainGuid == altGuid then
        return "rejected", "same_character"
    end
    local record, recErr = GI:EnsureGuildRecord(opts.guildKey)
    if not record then
        return "rejected", recErr or "not_ready"
    end

    local mainMem = record.members[mainGuid]
    local altMem = record.members[altGuid]
    local mainInfo = record.graph.byGuid and record.graph.byGuid[mainGuid]
    local altInfo = record.graph.byGuid and record.graph.byGuid[altGuid]
    -- Durable home before mutation (derived groupId may differ under absorb).
    local durablePrevGid = altMem and type(altMem.groupId) == "string" and altMem.groupId or nil

    -- Hierarchy gates (local).
    if altInfo and altInfo.role == "main" then
        local g = record.graph.mains[altGuid]
        if g and #(g.altGuids or {}) > 0 then
            return "rejected", "alt_is_main_with_alts"
        end
    end
    if mainInfo and mainInfo.role == "alt" then
        return "rejected", "main_is_alt"
    end

    local targetGroupId = FindGroupIdForMain(record, mainGuid)
    if altInfo and altInfo.role == "alt" and altInfo.mainGuid == mainGuid then
        return "accepted", "noop"
    end
    if altInfo and altInfo.role == "alt" and altInfo.mainGuid ~= mainGuid then
        if opts.requireMoveConfirm and not opts.moveConfirmed then
            return "rejected", "move_confirmation_required", { oldMainGuid = altInfo.mainGuid }
        end
        if opts.moveConfirmed and type(opts.expectedOldMain) == "string" and opts.expectedOldMain ~= "" then
            if altInfo.mainGuid ~= opts.expectedOldMain then
                return "rejected", "stale_move_confirmation"
            end
        elseif opts.requireMoveConfirm then
            return "rejected", "move_confirmation_required", { oldMainGuid = altInfo.mainGuid }
        end
    end

    if not targetGroupId then
        -- Creating a new group: reclaim dissolved slots first, then allocate.
        local room, roomErr = GI.EnsureGroupCapacity(record)
        if not room then
            return "rejected", roomErr or "groups_overflow"
        end
        if not mainMem and CountKeys(record.members) >= GI.MAX_MEMBERS then
            return "rejected", "members_overflow"
        end
        if not altMem and CountKeys(record.members) >= GI.MAX_MEMBERS - (mainMem and 0 or 1) then
            return "rejected", "members_overflow"
        end
        local gid, gErr = GI:_AllocateGroupId()
        if not gid then
            return "rejected", gErr
        end
        targetGroupId = gid
        local gVer, gvErr = GI:_NextVer(nil)
        if not gVer then
            return "rejected", gvErr
        end
        local st = GI.MergeGroup(record, {
            groupId = gid,
            mainGuid = mainGuid,
            ver = gVer,
            at = Now(),
        })
        if st ~= "accepted" and st ~= "duplicate" then
            return "rejected", st
        end
    else
        local derivedAlts = record.graph.mains and record.graph.mains[mainGuid]
        local altCount = derivedAlts and #(derivedAlts.altGuids or {}) or CountAltsInGroup(record, targetGroupId)
        if altCount >= GI.MAX_ALTS_PER_MAIN then
            -- Moving within same group doesn't add; moving in from outside does.
            if not (altInfo and altInfo.groupId == targetGroupId) then
                if not (altInfo and altInfo.role == "alt" and altInfo.mainGuid == mainGuid) then
                    local already = altMem and altMem.groupId == targetGroupId
                    if not already then
                        return "rejected", "group_full"
                    end
                end
            end
        end
        -- Re-check capacity for brand-new alt identity.
        if not altMem and CountKeys(record.members) >= GI.MAX_MEMBERS then
            return "rejected", "members_overflow"
        end
    end

    -- Ensure main membership points at the group.
    local mainVer, mvErr = GI:_NextVer(mainMem and mainMem.ver)
    if not mainVer then
        return "rejected", mvErr
    end
    local stMain = GI.MergeMember(record, {
        guid = mainGuid,
        groupId = targetGroupId,
        ver = mainVer,
        at = Now(),
        nameRealm = opts.mainName,
        classFile = opts.mainClass,
    })
    if stMain ~= "accepted" and stMain ~= "duplicate" then
        return "rejected", stMain
    end

    local altVer, avErr = GI:_NextVer(altMem and altMem.ver)
    if not altVer then
        return "rejected", avErr
    end
    local stAlt = GI.MergeMember(record, {
        guid = altGuid,
        groupId = targetGroupId,
        ver = altVer,
        at = Now(),
        nameRealm = opts.altName,
        classFile = opts.altClass,
    })
    if stAlt ~= "accepted" and stAlt ~= "duplicate" then
        return "rejected", stAlt
    end

    -- Dissolve previous durable home when safe for the logical group.
    if durablePrevGid and durablePrevGid ~= targetGroupId then
        RebuildDerived(record)
        if ShouldDissolvePhysicalGroup(record, durablePrevGid) then
            DissolveEmptyGroup(record, durablePrevGid)
        end
    end

    NotifyDurable("local")
    return "accepted", nil
end

function GI:ApplyUnassign(altGuid, opts)
    opts = opts or {}
    if not ValidGuid(altGuid) then
        return "rejected", "identity_unavailable"
    end
    local record, recErr = GI:EnsureGuildRecord(opts.guildKey)
    if not record then
        return "rejected", recErr or "not_ready"
    end
    local info = record.graph.byGuid and record.graph.byGuid[altGuid]
    if not info or info.role ~= "alt" then
        return "rejected", "alt_not_assigned"
    end
    if type(opts.expectedMainGuid) == "string" and opts.expectedMainGuid ~= "" then
        if info.mainGuid ~= opts.expectedMainGuid then
            return "rejected", "stale_unassign"
        end
    end

    local logicalMain = info.mainGuid
    local mem = record.members[altGuid]
    local ver, vErr = GI:_NextVer(mem and mem.ver)
    if not ver then
        return "rejected", vErr
    end
    -- Prefer durable membership home; derived absorb groupId may differ.
    local oldGid = (mem and type(mem.groupId) == "string" and mem.groupId) or info.groupId
    local st = GI.MergeMember(record, {
        guid = altGuid,
        groupId = GI.UNASSIGNED,
        ver = ver,
        at = Now(),
        nameRealm = mem and mem.nameRealm or nil,
        classFile = mem and mem.classFile or nil,
    })
    if st ~= "accepted" and st ~= "duplicate" then
        return "rejected", st
    end

    if type(oldGid) == "string" and ShouldDissolvePhysicalGroup(record, oldGid) then
        DissolveEmptyGroup(record, oldGid)
    end

    -- When the logical main has no remaining alts, dissolve leftover solo-main
    -- claimant shells (same outcome as unassigning the last alt of a single group).
    RebuildDerived(record)
    if ValidGuid(logicalMain) then
        local ginfo = record.graph.mains and record.graph.mains[logicalMain]
        if not ginfo or #(ginfo.altGuids or {}) == 0 then
            local claimants = ClaimantGroupIds(record, logicalMain)
            for i = 1, #claimants do
                if ShouldDissolvePhysicalGroup(record, claimants[i]) then
                    DissolveEmptyGroup(record, claimants[i])
                end
            end
            RebuildDerived(record)
        end
    end

    NotifyDurable("local")
    return "accepted", nil
end

function GI:ApplyChangeMain(oldMainGuid, newMainGuid, opts)
    opts = opts or {}
    if not ValidGuid(oldMainGuid) or not ValidGuid(newMainGuid) or oldMainGuid == newMainGuid then
        return "rejected", "same_character"
    end
    local record, recErr = GI:EnsureGuildRecord(opts.guildKey)
    if not record then
        return "rejected", recErr or "not_ready"
    end
    local groupId = FindGroupIdForMain(record, oldMainGuid)
    if not groupId then
        return "rejected", "group_missing"
    end
    local newInfo = record.graph.byGuid and record.graph.byGuid[newMainGuid]
    if not newInfo or newInfo.role ~= "alt" or newInfo.mainGuid ~= oldMainGuid or newInfo.groupId ~= groupId then
        return "rejected", "stale_change_main"
    end

    -- Bring absorbed concurrent shells into the canonical physical group with
    -- genuine officer versions before flipping mainGuid.
    local okConsol, consolErr = ConsolidateLogicalGroupTo(record, oldMainGuid, groupId)
    if not okConsol then
        return "rejected", consolErr or "no_effect"
    end
    groupId = FindGroupIdForMain(record, oldMainGuid)
    if not groupId then
        return "rejected", "group_missing"
    end
    newInfo = record.graph.byGuid and record.graph.byGuid[newMainGuid]
    if not newInfo or newInfo.role ~= "alt" or newInfo.mainGuid ~= oldMainGuid or newInfo.groupId ~= groupId then
        return "rejected", "stale_change_main"
    end
    local newMem = record.members[newMainGuid]
    if not newMem or newMem.groupId ~= groupId then
        return "rejected", "stale_change_main"
    end

    local g = record.groups[groupId]
    local gVer, gErr = GI:_NextVer(g and g.ver)
    if not gVer then
        return "rejected", gErr
    end
    local st = GI.MergeGroup(record, {
        groupId = groupId,
        mainGuid = newMainGuid,
        ver = gVer,
        at = Now(),
    })
    if st ~= "accepted" and st ~= "duplicate" then
        return "rejected", st
    end
    NotifyDurable("local")
    return "accepted", nil
end

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
        -- Hide mains-only (no alts) from the relationship list.
        if #alts > 0 then
            groups[#groups + 1] = {
                mainGuid = mainGuid,
                groupId = group.groupId,
                altGuids = alts,
            }
        end
    end
    return groups, nil, record
end

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
    -- Solo main (no alts) is not a displayed relationship role.
    if info.role == "main" then
        local g = record.graph.mains[guid]
        if not g or #(g.altGuids or {}) == 0 then
            return nil
        end
    end
    return info.role, info.mainGuid
end

function GI.UpdateCharacterDisplay(record, guid, nameRealm, classFile)
    if type(record) ~= "table" then
        return
    end
    RememberCharacter(record.characters, guid, nameRealm, classFile)
    local m = record.members and record.members[guid]
    if m then
        local n = ClampName(nameRealm)
        local c = ClampClass(classFile)
        if n then
            m.nameRealm = n
        end
        if c then
            m.classFile = c
        end
    end
end

--- Enumerate exportable state bodies for Gossip.
function GI.ListStateBodies(record)
    local bodies = {}
    if type(record) ~= "table" then
        return bodies
    end
    for guid, m in pairs(record.members or {}) do
        bodies[#bodies + 1] = {
            kind = "guildinfo-member",
            member = m,
            _sort = "m:" .. guid,
        }
    end
    for gid, g in pairs(record.groups or {}) do
        bodies[#bodies + 1] = {
            kind = "guildinfo-group",
            group = g,
            _sort = "g:" .. gid,
        }
    end
    table.sort(bodies, function(a, b)
        return a._sort < b._sort
    end)
    for i = 1, #bodies do
        bodies[i]._sort = nil
    end
    return bodies
end

--- Count retained durable rows for bound checks / tests.
function GI.CountRetainedState(record)
    record = record or select(1, GI:GetCurrentRecord())
    if type(record) ~= "table" then
        return {
            members = 0,
            groups = 0,
            assigned = 0,
            unassigned = 0,
            dissolved = 0,
            liveGroups = 0,
            characters = 0,
        }
    end
    local assigned, unassigned, dissolved, live = 0, 0, 0, 0
    for _, m in pairs(record.members or {}) do
        if MemberIsAssigned(m) then
            assigned = assigned + 1
        else
            unassigned = unassigned + 1
        end
    end
    for _, g in pairs(record.groups or {}) do
        if g.dissolved then
            dissolved = dissolved + 1
        elseif GroupIsLive(g) then
            live = live + 1
        end
    end
    return {
        members = CountKeys(record.members),
        groups = CountKeys(record.groups),
        assigned = assigned,
        unassigned = unassigned,
        dissolved = dissolved,
        liveGroups = live,
        characters = CountKeys(record.characters),
    }
end

GI._RememberCharacter = RememberCharacter
GI._DissolveEmptyGroup = DissolveEmptyGroup
GI._BeatVers = BeatVers
