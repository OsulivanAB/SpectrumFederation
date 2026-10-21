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

local function IsCanonicalGenWriter(w)
    if type(w) ~= "string" or w == "" then
        return false
    end
    if w == "bootstrap" then
        return true
    end
    -- Local writers use 24-char lowercase/uppercase hex nonces.
    return #w == 24 and w:match("^[0-9a-fA-F]+$") ~= nil
end

--- Bound, canonical sync-generation tuple (bootstrap or 24-hex writer).
local function ValidGen(gen)
    if type(gen) ~= "table" or not GI.IsFiniteNonnegInt(gen.n) then
        return false
    end
    local maxN = tonumber(GI.MAX_SYNC_GEN_N) or 9007199254740990
    if gen.n > maxN then
        return false
    end
    return IsCanonicalGenWriter(gen.w)
end

function GI.ValidSyncGen(gen)
    return ValidGen(gen)
end

function GI.CompareGen(a, b)
    return GI.CompareVer(a, b)
end

function GI.DefaultSyncGen()
    return { n = 1, w = "bootstrap" }
end

local function ValidSealRev(rev)
    return type(rev) == "table"
        and GI.IsFiniteNonnegInt(rev.n)
        and type(rev.w) == "string"
        and rev.w ~= ""
        and #rev.w <= 64
end

local function CompareSealRev(a, b)
    return GI.CompareVer(a, b)
end

--- Bump baseline.sealRev using the local writable writer (complete peers / cleanup).
function GI._BumpSealRev(record)
    if type(record) ~= "table" then
        return nil
    end
    record.baseline = record.baseline or {}
    local writer, reason = GI:_EnsureWritableWriter()
    if not writer then
        return nil, reason
    end
    local prev = record.baseline.sealRev
    local prevN = (ValidSealRev(prev) and tonumber(prev.n)) or 0
    local maxN = tonumber(GI.MAX_SYNC_GEN_N) or 9007199254740990
    if prevN >= maxN then
        return nil, "generation_exhausted"
    end
    record.baseline.sealRev = { n = prevN + 1, w = writer.nonce }
    return record.baseline.sealRev
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
    local maxN = tonumber(GI.MAX_SYNC_GEN_N) or 9007199254740990
    if prevN >= maxN then
        return nil, "generation_exhausted"
    end
    local nextN = prevN + 1
    if nextN > maxN or nextN <= prevN then
        return nil, "generation_exhausted"
    end
    return { n = nextN, w = writer.nonce }
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

--- Snapshot of visible active relationships: mainGuid -> sorted altGuid list.
function GI.LogicalRelationshipSnapshot(record)
    local snap = {}
    if type(record) ~= "table" then
        return snap
    end
    RebuildIfNeeded(record)
    local mains = record.graph and record.graph.mains or {}
    for mainGuid, ginfo in pairs(mains) do
        local alts = {}
        for i = 1, #(ginfo.altGuids or {}) do
            alts[#alts + 1] = ginfo.altGuids[i]
        end
        if #alts > 0 then
            table.sort(alts)
            snap[mainGuid] = {
                groupId = ginfo.groupId,
                alts = alts,
            }
        end
    end
    return snap
end

local function SnapshotsEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    local nA, nB = 0, 0
    for mainGuid, infoA in pairs(a) do
        nA = nA + 1
        local infoB = b[mainGuid]
        if type(infoB) ~= "table" then
            return false
        end
        if #(infoA.alts or {}) ~= #(infoB.alts or {}) then
            return false
        end
        for i = 1, #(infoA.alts or {}) do
            if infoA.alts[i] ~= infoB.alts[i] then
                return false
            end
        end
    end
    for _ in pairs(b) do
        nB = nB + 1
    end
    return nA == nB
end

--- Classify current record for cleanup preview / rebuild.
-- Also returns:
--   keepMember[guid] = true
--   keepGroup[canonicalGroupId] = mainGuid
--   memberGroup[guid] = canonicalGroupId (logical home for every retained character)
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

    local keepGroup = {} -- [canonicalGid] = mainGuid
    local keepMember = {}
    local memberGroup = {} -- [guid] = canonicalGid
    local mains = record.graph and record.graph.mains or {}
    for mainGuid, ginfo in pairs(mains) do
        local alts = ginfo.altGuids or {}
        if #alts > 0 then
            out.relationships = out.relationships + 1
            local gid = ginfo.groupId
            if type(gid) == "string" then
                keepGroup[gid] = mainGuid
                keepMember[mainGuid] = true
                memberGroup[mainGuid] = gid
                for i = 1, #alts do
                    keepMember[alts[i]] = true
                    memberGroup[alts[i]] = gid
                end
            end
        end
    end

    out.retainedMembers = CountKeys(keepMember)
    for guid, m in pairs(record.members or {}) do
        if not keepMember[guid] and not MemberIsAssigned(m) then
            out.tombstones = out.tombstones + 1
        end
    end
    -- Count retained groups from the logical set (canonical ids only).
    out.retainedGroups = CountKeys(keepGroup)
    for gid, g in pairs(record.groups or {}) do
        if keepGroup[gid] then
            -- counted above
        elseif type(g) == "table" and g.dissolved and type(g.forwardTo) == "string" and g.forwardTo ~= "" then
            out.aliases = out.aliases + 1
        elseif type(g) == "table" and not g.dissolved then
            -- Live group with no visible alts (solo-main shell or empty).
            out.soloShells = out.soloShells + 1
        else
            out.otherLiveEmpty = out.otherLiveEmpty + 1
        end
    end
    return out, keepMember, keepGroup, memberGroup
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

--- Build compact baseline from *logical* derived relationships (not raw physical ids).
-- Absorbed / forwarded alts are rewritten onto their canonical groupId.
local function BuildCleanupBaseline(record)
    local expectedSnap = GI.LogicalRelationshipSnapshot(record)
    local c, keepMember, keepGroup, memberGroup = GI.ClassifyRetainedState(record)
    local writer, wErr = GI:_EnsureWritableWriter()
    if not writer then
        return nil, wErr or "not_ready"
    end
    local at = Now()
    local newMembers = {}
    local newGroups = {}
    local newCharacters = {}

    -- Canonical live groups from the derived graph (mainGuid is authoritative).
    for gid, mainGuid in pairs(keepGroup) do
        newGroups[gid] = {
            groupId = gid,
            mainGuid = mainGuid,
            ver = { n = 1, w = writer.nonce },
            at = at,
        }
    end

    for guid in pairs(keepMember) do
        local canonicalGid = memberGroup and memberGroup[guid]
        if type(canonicalGid) ~= "string" or not newGroups[canonicalGid] then
            return nil, "cleanup_incomplete_member"
        end
        local old = record.members and record.members[guid]
        local char = record.characters and record.characters[guid]
        local nameRealm = (old and old.nameRealm) or (char and char.nameRealm)
        local classFile = (old and old.classFile) or (char and char.classFile)
        if not old and not nameRealm then
            -- Visible active assignment without any durable identity row — abort.
            return nil, "cleanup_incomplete_member"
        end
        newMembers[guid] = {
            guid = guid,
            groupId = canonicalGid,
            ver = { n = 1, w = writer.nonce },
            at = at,
            nameRealm = nameRealm,
            classFile = classFile,
        }
        if nameRealm or classFile then
            newCharacters[guid] = {
                nameRealm = nameRealm,
                classFile = classFile,
            }
        end
    end

    -- Every canonical group must retain its main membership.
    for gid, g in pairs(newGroups) do
        if not newMembers[g.mainGuid] then
            return nil, "cleanup_incomplete_member"
        end
    end

    if CountKeys(newMembers) > GI.MAX_MEMBERS or CountKeys(newGroups) > GI.MAX_GROUPS then
        return nil, "cleanup_active_overflow"
    end
    if CountKeys(newMembers) ~= c.retainedMembers then
        -- Preview promised these identities; refuse silent omission.
        return nil, "cleanup_relationship_mismatch"
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
        expectedSnap = expectedSnap,
        discarded = {
            soloShells = c.soloShells,
            tombstones = c.tombstones,
            aliases = c.aliases,
        },
    }
end

--- Refresh advertised current-generation seal from durable rows.
-- Only valid for a completed baseline writer/follower. Incomplete sync keeps
-- epoch-expected counts/fingerprint until TrySealBaseline succeeds.
-- Each refresh bumps sealRev so same-generation catch-up follows a tip order
-- instead of last-arrival fingerprint replacement.
function GI.RefreshBaselineSeal(record)
    if type(record) ~= "table" then
        return false
    end
    if not GI.IsBaselineComplete(record) then
        return false
    end
    record.baseline = record.baseline or {}
    record.baseline.complete = true
    record.baseline.memberCount = CountKeys(record.members)
    record.baseline.groupCount = CountKeys(record.groups)
    record.baseline.contentFp = GI.ComputeBaselineContentFp(record.members, record.groups)
    if not GI._BumpSealRev(record) then
        -- Keep prior sealRev if the writer cannot advance; still refresh content.
        if not ValidSealRev(record.baseline.sealRev) then
            record.baseline.sealRev = { n = 1, w = "bootstrap" }
        end
    end
    record.revision = record.baseline.memberCount + record.baseline.groupCount
    return true
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

    if GI.HasForwardAliasCycle and GI.HasForwardAliasCycle(record) then
        return "rejected", "cleanup_forward_cycle"
    end
    if GI.CountHiddenAssignedMembers and GI.CountHiddenAssignedMembers(record) > 0 then
        return "rejected", "cleanup_forward_cycle"
    end

    local preview = GI.PreviewCleanupHistory(record)
    -- Capacity blockage must win over the ordinary nothing-to-do success path.
    if preview.blockedByActive then
        return "rejected", "cleanup_no_capacity", preview
    end
    if preview.nothingToDo then
        return "accepted", "cleanup_noop", preview
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
    -- Semantic gate: every confirmed visible relationship must survive unchanged.
    local probeSnap = GI.LogicalRelationshipSnapshot(probe)
    if not SnapshotsEqual(built.expectedSnap, probeSnap) then
        return "rejected", "cleanup_relationship_mismatch"
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
        sealRev = { n = 1, w = newGen.w },
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

local function SealRevFromEpoch(epochBody)
    local rev = epochBody and epochBody.sealRev
    if ValidSealRev(rev) then
        return { n = rev.n, w = rev.w }
    end
    -- Legacy epochs without sealRev sort as the generation-entry tip.
    return { n = 0, w = "" }
end

--- Adopt a newer remote sync generation (wipe old baseline; await sealed content).
function GI.AdoptSyncGeneration(record, epochBody)
    if type(record) ~= "table" or type(epochBody) ~= "table" then
        return false, "malformed"
    end
    -- Validate before any wipe/mutation.
    if not ValidGen(epochBody.gen) then
        return false, "invalid_generation"
    end
    local memberCount = tonumber(epochBody.memberCount) or 0
    local groupCount = tonumber(epochBody.groupCount) or 0
    if memberCount < 0 or groupCount < 0 or memberCount > GI.MAX_MEMBERS or groupCount > GI.MAX_GROUPS then
        return false, "invalid_generation"
    end
    if not GI.IsFiniteNonnegInt(memberCount) or not GI.IsFiniteNonnegInt(groupCount) then
        return false, "invalid_generation"
    end
    local contentFp = tostring(epochBody.contentFp or "")
    if #contentFp > 128 then
        return false, "invalid_generation"
    end
    local incomingSeal = SealRevFromEpoch(epochBody)
    if epochBody.sealRev ~= nil and not ValidSealRev(epochBody.sealRev) then
        return false, "invalid_generation"
    end

    local localGen = GI.GetSyncGen(record) or { n = 0, w = "" }
    local cmp = GI.CompareGen(epochBody.gen, localGen)
    if cmp < 0 then
        return false, "stale_generation"
    end
    if cmp == 0 then
        if GI.IsBaselineComplete(record) then
            -- Complete peers keep durable state; ordinary member/group merges
            -- converge concurrent edits. Do not wipe on a higher remote tip.
            return true, "duplicate"
        end
        record.baseline = record.baseline or {}
        local localSeal = ValidSealRev(record.baseline.sealRev) and record.baseline.sealRev
            or { n = 0, w = "" }
        local sealCmp = CompareSealRev(incomingSeal, localSeal)
        if sealCmp < 0 then
            return true, "duplicate"
        end
        if sealCmp == 0 then
            -- Same tip: keep expected seal; try seal / merged finalize.
            GI.TrySealBaseline(record)
            return true, "duplicate"
        end
        -- Higher same-gen tip: follow it. Wipe so an interleaved union cannot
        -- permanently mismatch every single-writer fingerprint, then refill
        -- from the winning writer's snapshot (loser edits merge afterward).
        record.members = {}
        record.groups = {}
        record.characters = {}
        record.baseline = {
            complete = false,
            memberCount = memberCount,
            groupCount = groupCount,
            contentFp = contentFp,
            sealRev = { n = incomingSeal.n, w = incomingSeal.w },
        }
        record.pendingByGen = nil
        if GI.RebuildDerived then
            GI.RebuildDerived(record)
        end
        record.revision = 0
        GI.TrySealBaseline(record)
        return true, "accepted"
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
        sealRev = { n = incomingSeal.n, w = incomingSeal.w },
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
-- Also finalizes a concurrent same-generation merge when durable rows form a
-- strict superset of the adopted tip (independent partitioned edits).
function GI.TrySealBaseline(record)
    if type(record) ~= "table" or type(record.baseline) ~= "table" then
        return false
    end
    if record.baseline.complete then
        return true
    end
    local mc = CountKeys(record.members)
    local gc = CountKeys(record.groups)
    local tipMc = tonumber(record.baseline.memberCount) or -1
    local tipGc = tonumber(record.baseline.groupCount) or -1
    local fp = GI.ComputeBaselineContentFp(record.members, record.groups)
    if mc == tipMc and gc == tipGc and fp == tostring(record.baseline.contentFp or "") then
        record.baseline.complete = true
        if GI.RebuildDerived then
            GI.RebuildDerived(record)
        end
        return true
    end
    -- Concurrent same-gen catch-up: local durable state exceeded the adopted
    -- single-writer tip (merged independent edits). Seal the merged snapshot
    -- so a fresh peer can relay after source writers go offline.
    if (mc > tipMc or gc > tipGc) and mc > 0 and gc > 0 and tipMc >= 0 and tipGc >= 0 then
        record.baseline.complete = true
        record.baseline.memberCount = mc
        record.baseline.groupCount = gc
        record.baseline.contentFp = fp
        if not ValidSealRev(record.baseline.sealRev) then
            record.baseline.sealRev = { n = 1, w = "bootstrap" }
        end
        if GI.RebuildDerived then
            GI.RebuildDerived(record)
        end
        return true
    end
    return false
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
    if record.syncGen == nil then
        record.syncGen = GI.DefaultSyncGen()
    elseif not ValidGen(record.syncGen) then
        -- Noncanonical / exhausted persisted generations are not rewritten here;
        -- ValidateGuildRecord / AdoptSyncGeneration fail closed instead.
        return
    end
    if type(record.baseline) ~= "table" then
        record.baseline = {
            complete = true,
            memberCount = CountKeys(record.members),
            groupCount = CountKeys(record.groups),
            contentFp = GI.ComputeBaselineContentFp(record.members, record.groups),
            sealRev = { n = 1, w = record.syncGen.w },
        }
    else
        if record.baseline.complete == nil then
            record.baseline.complete = true
        end
        if not ValidSealRev(record.baseline.sealRev) then
            record.baseline.sealRev = {
                n = record.baseline.complete and 1 or 0,
                w = (type(record.syncGen) == "table" and record.syncGen.w) or "bootstrap",
            }
        end
    end
end
