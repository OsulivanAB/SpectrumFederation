-- Guild Info history cleanup + sync generation (#402 Option B).
-- Officer-controlled rebuild of obsolete retained state under a new guild-scoped epoch.
local addonName, SF = ...

SF.GuildInfo = SF.GuildInfo or {}
local GI = SF.GuildInfo

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

local function CountKeys(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do
            n = n + 1
        end
    end
    return n
end

local function ValidGen(gen)
    return type(gen) == "table"
        and GI.IsFiniteNonnegInt(gen.n)
        and type(gen.w) == "string"
        and gen.w ~= ""
        and #gen.w <= 64
end

function GI.CompareGen(a, b)
    return GI.CompareVer(a, b)
end

function GI.DefaultSyncGen()
    return { n = 1, w = "bootstrap" }
end

function GI.EpochRecordId()
    return "gi-e:current"
end

function GI.IsBaselineComplete(record)
    if type(record) ~= "table" then
        return false
    end
    local b = record.baseline
    return type(b) == "table" and b.complete == true
end

function GI.GetSyncGen(record)
    if type(record) ~= "table" then
        return nil
    end
    if ValidGen(record.syncGen) then
        return record.syncGen
    end
    return nil
end

--- Deterministic fingerprint of retained member/group identity set for baseline sealing.
function GI.ComputeBaselineContentFp(members, groups)
    local parts = {}
    local mids = {}
    for guid in pairs(members or {}) do
        mids[#mids + 1] = guid
    end
    table.sort(mids)
    for i = 1, #mids do
        local m = members[mids[i]]
        parts[#parts + 1] = "m:"
            .. tostring(mids[i])
            .. ":"
            .. tostring(m.groupId == false and "U" or m.groupId or "")
            .. ":"
            .. tostring(m.ver and m.ver.n or 0)
            .. ":"
            .. tostring(m.ver and m.ver.w or "")
    end
    local gids = {}
    for gid in pairs(groups or {}) do
        gids[#gids + 1] = gid
    end
    table.sort(gids)
    for i = 1, #gids do
        local g = groups[gids[i]]
        parts[#parts + 1] = "g:"
            .. tostring(gids[i])
            .. ":"
            .. tostring(g.mainGuid or "")
            .. ":"
            .. tostring(g.ver and g.ver.n or 0)
            .. ":"
            .. tostring(g.ver and g.ver.w or "")
    end
    local joined = table.concat(parts, "|")
    local gg = SF.GuildGossip
    if gg and gg.Hash32 then
        return string.format("%08x", gg.Hash32(joined))
    end
    return tostring(#joined) .. ":" .. joined:sub(1, 32)
end

function GI:_NextSyncGen(prevGen)
    local writer, reason = GI:_EnsureWritableWriter()
    if not writer then
        return nil, reason
    end
    local prevN = (type(prevGen) == "table" and tonumber(prevGen.n)) or 0
    return { n = prevN + 1, w = writer.nonce }
end

local function MemberIsAssigned(m)
    return type(m) == "table" and type(m.groupId) == "string" and m.groupId ~= ""
end

local function RebuildIfNeeded(record)
    if type(record) ~= "table" then
        return
    end
    if type(record.graph) ~= "table" or type(record.graph.mains) ~= "table" then
        if GI.RebuildDerived then
            GI.RebuildDerived(record)
        end
    end
end

--- Classify current record for cleanup preview / rebuild.
function GI.ClassifyRetainedState(record)
    record = record or select(1, GI:GetCurrentRecord())
    local out = {
        relationships = 0,
        retainedMembers = 0,
        retainedGroups = 0,
        soloShells = 0,
        tombstones = 0,
        aliases = 0,
        otherLiveEmpty = 0,
        totalMembers = 0,
        totalGroups = 0,
    }
    if type(record) ~= "table" then
        return out
    end
    RebuildIfNeeded(record)
    out.totalMembers = CountKeys(record.members)
    out.totalGroups = CountKeys(record.groups)

    local keepGroup = {}
    local keepMember = {}
    local mains = record.graph and record.graph.mains or {}
    for mainGuid, ginfo in pairs(mains) do
        local alts = ginfo.altGuids or {}
        if #alts > 0 then
            out.relationships = out.relationships + 1
            local gid = ginfo.groupId
            if type(gid) == "string" then
                keepGroup[gid] = true
            end
            keepMember[mainGuid] = true
            for i = 1, #alts do
                keepMember[alts[i]] = true
            end
        end
    end

    for guid, m in pairs(record.members or {}) do
        if keepMember[guid] then
            out.retainedMembers = out.retainedMembers + 1
        elseif not MemberIsAssigned(m) then
            out.tombstones = out.tombstones + 1
        end
    end
    for gid, g in pairs(record.groups or {}) do
        if keepGroup[gid] then
            out.retainedGroups = out.retainedGroups + 1
        elseif type(g) == "table" and g.dissolved and type(g.forwardTo) == "string" and g.forwardTo ~= "" then
            out.aliases = out.aliases + 1
        elseif type(g) == "table" and not g.dissolved then
            -- Live group with no visible alts (solo-main shell or empty).
            out.soloShells = out.soloShells + 1
        else
            out.otherLiveEmpty = out.otherLiveEmpty + 1
        end
    end
    return out, keepMember, keepGroup
end

function GI.PreviewCleanupHistory(record)
    record = record or select(1, GI:GetCurrentRecord())
    local c = GI.ClassifyRetainedState(record)
    local discardGroups = c.soloShells + c.aliases + c.otherLiveEmpty
    local discardMembers = c.tombstones
    local recoverGroups = discardGroups
    local recoverMembers = discardMembers
    local nothingToDo = discardGroups == 0 and discardMembers == 0
    local capacityRecovered = recoverGroups > 0 or recoverMembers > 0
    -- If every slot is an active relationship, cleanup cannot free capacity.
    local blockedByActive = (not capacityRecovered)
        and (c.retainedGroups >= GI.MAX_GROUPS or c.retainedMembers >= GI.MAX_MEMBERS)
    return {
        relationships = c.relationships,
        retainedMembers = c.retainedMembers,
        retainedGroups = c.retainedGroups,
        discardSoloShells = c.soloShells,
        discardTombstones = c.tombstones,
        discardAliases = c.aliases,
        discardGroups = discardGroups,
        discardMembers = discardMembers,
        capacityRecovered = capacityRecovered,
        nothingToDo = nothingToDo,
        blockedByActive = blockedByActive and true or false,
        syncing = not GI.IsBaselineComplete(record),
    }
end

--- Build compact baseline tables from currently known active relationships.
local function BuildCleanupBaseline(record)
    local c, keepMember, keepGroup = GI.ClassifyRetainedState(record)
    local writer, wErr = GI:_EnsureWritableWriter()
    if not writer then
        return nil, wErr or "not_ready"
    end
    local at = Now()
    local newMembers = {}
    local newGroups = {}
    local newCharacters = {}

    for guid in pairs(keepMember) do
        local old = record.members[guid]
        if type(old) == "table" then
            local ver = { n = 1, w = writer.nonce }
            newMembers[guid] = {
                guid = guid,
                groupId = old.groupId,
                ver = ver,
                at = at,
                nameRealm = old.nameRealm,
                classFile = old.classFile,
            }
            if old.nameRealm or old.classFile then
                newCharacters[guid] = {
                    nameRealm = old.nameRealm,
                    classFile = old.classFile,
                }
            end
        end
    end
    for gid in pairs(keepGroup) do
        local old = record.groups[gid]
        if type(old) == "table" and not old.dissolved and type(old.mainGuid) == "string" then
            newGroups[gid] = {
                groupId = gid,
                mainGuid = old.mainGuid,
                ver = { n = 1, w = writer.nonce },
                at = at,
            }
        end
    end

    -- Ensure every retained member's group exists and mains are members.
    for guid, m in pairs(newMembers) do
        local gid = m.groupId
        if type(gid) == "string" and not newGroups[gid] then
            -- Drop orphan membership that lost its group during classify race.
            newMembers[guid] = nil
            newCharacters[guid] = nil
        end
    end
    for gid, g in pairs(newGroups) do
        if not newMembers[g.mainGuid] then
            -- Main missing: drop the group and its alts.
            for guid, m in pairs(newMembers) do
                if m.groupId == gid then
                    newMembers[guid] = nil
                    newCharacters[guid] = nil
                end
            end
            newGroups[gid] = nil
        end
    end

    if CountKeys(newMembers) > GI.MAX_MEMBERS or CountKeys(newGroups) > GI.MAX_GROUPS then
        return nil, "cleanup_active_overflow"
    end

    local contentFp = GI.ComputeBaselineContentFp(newMembers, newGroups)
    return {
        members = newMembers,
        groups = newGroups,
        characters = newCharacters,
        memberCount = CountKeys(newMembers),
        groupCount = CountKeys(newGroups),
        contentFp = contentFp,
        relationships = c.relationships,
        discarded = {
            soloShells = c.soloShells,
            tombstones = c.tombstones,
            aliases = c.aliases,
        },
    }
end

--- Install a fully built baseline under a new sync generation (local cleanup).
function GI:ApplyCleanupHistory(opts)
    opts = opts or {}
    local record, recErr = GI:EnsureGuildRecord(opts.guildKey)
    if not record then
        return "rejected", recErr or "not_ready"
    end
    if not GI.IsBaselineComplete(record) then
        return "rejected", "generation_syncing"
    end

    local preview = GI.PreviewCleanupHistory(record)
    if preview.nothingToDo then
        return "accepted", "cleanup_noop", preview
    end
    if preview.blockedByActive then
        return "rejected", "cleanup_no_capacity", preview
    end

    local built, buildErr = BuildCleanupBaseline(record)
    if not built then
        return "rejected", buildErr or "cleanup_failed"
    end

    local newGen, genErr = GI:_NextSyncGen(record.syncGen)
    if not newGen then
        return "rejected", genErr or "not_ready"
    end

    -- Validate constructed graph before mutating durable state.
    local probe = {
        schemaVersion = GI.SCHEMA_VERSION,
        guildKey = record.guildKey,
        clubId = record.clubId,
        members = built.members,
        groups = built.groups,
        characters = built.characters,
        syncGen = newGen,
        baseline = {
            complete = true,
            memberCount = built.memberCount,
            groupCount = built.groupCount,
            contentFp = built.contentFp,
        },
        graph = { mains = {}, byGuid = {} },
        revision = 0,
        openConflicts = {},
    }
    if GI.RebuildDerived then
        GI.RebuildDerived(probe)
    end
    local okVal, valErr = GI.ValidateGuildRecord(record.guildKey, probe)
    if not okVal then
        return "rejected", valErr or "cleanup_invalid"
    end

    -- Serialization gate: epoch + every retained wire must fit Gossip CBOR cap.
    if type(GI.RecordWithinGossipCap) == "function" then
        local epochWire = {
            id = GI.EpochRecordId(),
            versionFp = "probe",
            body = {
                kind = "guildinfo-epoch",
                schema = GI.PROVIDER_SCHEMA,
                gen = newGen,
                memberCount = built.memberCount,
                groupCount = built.groupCount,
                contentFp = built.contentFp,
            },
        }
        if not GI.RecordWithinGossipCap(epochWire) then
            return "rejected", "cleanup_serialize"
        end
        for guid, m in pairs(built.members) do
            local wire = {
                id = "gi-m:" .. guid,
                versionFp = "probe",
                body = {
                    kind = "guildinfo-member",
                    schema = GI.PROVIDER_SCHEMA,
                    gen = newGen,
                    member = m,
                },
            }
            if not GI.RecordWithinGossipCap(wire) then
                return "rejected", "cleanup_serialize"
            end
        end
        for gid, g in pairs(built.groups) do
            local wire = {
                id = "gi-g:" .. gid,
                versionFp = "probe",
                body = {
                    kind = "guildinfo-group",
                    schema = GI.PROVIDER_SCHEMA,
                    gen = newGen,
                    group = g,
                },
            }
            if not GI.RecordWithinGossipCap(wire) then
                return "rejected", "cleanup_serialize"
            end
        end
    end

    -- Atomic install.
    record.members = built.members
    record.groups = built.groups
    record.characters = built.characters
    record.syncGen = newGen
    record.baseline = {
        complete = true,
        memberCount = built.memberCount,
        groupCount = built.groupCount,
        contentFp = built.contentFp,
    }
    record.pendingByGen = nil
    if GI.RebuildDerived then
        GI.RebuildDerived(record)
    end
    record.revision = CountKeys(record.members) + CountKeys(record.groups)

    if GI._NotifyLocalDurableChange then
        GI._NotifyLocalDurableChange("local")
    end
    return "accepted", nil, {
        relationships = built.relationships,
        retainedMembers = built.memberCount,
        retainedGroups = built.groupCount,
        discardSoloShells = built.discarded.soloShells,
        discardTombstones = built.discarded.tombstones,
        discardAliases = built.discarded.aliases,
        syncGen = newGen,
    }
end

--- Adopt a newer remote sync generation (wipe old baseline; await sealed content).
function GI.AdoptSyncGeneration(record, epochBody)
    if type(record) ~= "table" or type(epochBody) ~= "table" then
        return false, "malformed"
    end
    if not ValidGen(epochBody.gen) then
        return false, "invalid_generation"
    end
    local memberCount = tonumber(epochBody.memberCount) or 0
    local groupCount = tonumber(epochBody.groupCount) or 0
    if memberCount < 0 or groupCount < 0 or memberCount > GI.MAX_MEMBERS or groupCount > GI.MAX_GROUPS then
        return false, "invalid_generation"
    end
    local contentFp = tostring(epochBody.contentFp or "")
    if #contentFp > 128 then
        return false, "invalid_generation"
    end

    local localGen = GI.GetSyncGen(record) or { n = 0, w = "" }
    local cmp = GI.CompareGen(epochBody.gen, localGen)
    if cmp < 0 then
        return false, "stale_generation"
    end
    if cmp == 0 then
        -- Same generation identity: ignore duplicate epoch.
        if GI.IsBaselineComplete(record) then
            return true, "duplicate"
        end
        -- Refresh expected seal metadata while still syncing.
        record.baseline = record.baseline or {}
        record.baseline.memberCount = memberCount
        record.baseline.groupCount = groupCount
        record.baseline.contentFp = contentFp
        return true, "duplicate"
    end

    -- Newer generation wins: discard previous-generation durable relationship state.
    record.members = {}
    record.groups = {}
    record.characters = {}
    record.syncGen = { n = epochBody.gen.n, w = epochBody.gen.w }
    record.baseline = {
        complete = false,
        memberCount = memberCount,
        groupCount = groupCount,
        contentFp = contentFp,
    }
    record.pendingByGen = nil
    if GI.RebuildDerived then
        GI.RebuildDerived(record)
    end
    record.revision = 0
    GI.TrySealBaseline(record)
    return true, "accepted"
end

--- After admitting new-gen member/group rows, seal when counts + contentFp match.
function GI.TrySealBaseline(record)
    if type(record) ~= "table" or type(record.baseline) ~= "table" then
        return false
    end
    if record.baseline.complete then
        return true
    end
    local mc = CountKeys(record.members)
    local gc = CountKeys(record.groups)
    if mc ~= (tonumber(record.baseline.memberCount) or -1) then
        return false
    end
    if gc ~= (tonumber(record.baseline.groupCount) or -1) then
        return false
    end
    local fp = GI.ComputeBaselineContentFp(record.members, record.groups)
    if fp ~= tostring(record.baseline.contentFp or "") then
        return false
    end
    record.baseline.complete = true
    if GI.RebuildDerived then
        GI.RebuildDerived(record)
    end
    return true
end

--- Gate remote/local merge against the active sync generation.
-- @return "ok"|"stale"|"newer_without_epoch"
function GI.EvaluateRecordGeneration(record, wireGen)
    local localGen = GI.GetSyncGen(record) or { n = 0, w = "" }
    if not ValidGen(wireGen) then
        -- Epochless / pre-schema-3: treat as generation 0.
        wireGen = { n = 0, w = "" }
    end
    local cmp = GI.CompareGen(wireGen, localGen)
    if cmp < 0 then
        return "stale"
    end
    if cmp > 0 then
        -- Member/group from a newer gen cannot apply before its epoch meta.
        return "newer_without_epoch"
    end
    return "ok"
end

function GI.EnsureSyncGenerationFields(record)
    if type(record) ~= "table" then
        return
    end
    if not ValidGen(record.syncGen) then
        record.syncGen = GI.DefaultSyncGen()
    end
    if type(record.baseline) ~= "table" then
        record.baseline = {
            complete = true,
            memberCount = CountKeys(record.members),
            groupCount = CountKeys(record.groups),
            contentFp = GI.ComputeBaselineContentFp(record.members, record.groups),
        }
    elseif record.baseline.complete == nil then
        record.baseline.complete = true
    end
end
