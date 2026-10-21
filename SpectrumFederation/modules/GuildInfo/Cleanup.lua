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

local function MaxAdvancableN()
    -- Exclusive ceiling: n must stay strictly below this so n+1 remains a
    -- finite, exact Lua number and ordinary cleanup can still advance.
    return tonumber(GI.MAX_SYNC_GEN_N) or 9007199254740990
end

--- Bound, canonical sync-generation tuple (bootstrap or 24-hex writer).
-- Rejects terminal counters that cannot be advanced by _NextSyncGen.
local function ValidGen(gen)
    if type(gen) ~= "table" or not GI.IsFiniteNonnegInt(gen.n) then
        return false
    end
    if gen.n >= MaxAdvancableN() then
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

--- Seal revisions use the same writer canon and exclusive numeric ceiling as syncGen.
local function ValidSealRev(rev)
    if type(rev) ~= "table" or not GI.IsFiniteNonnegInt(rev.n) then
        return false
    end
    if rev.n >= MaxAdvancableN() then
        return false
    end
    return IsCanonicalGenWriter(rev.w)
end

function GI.ValidSealRev(rev)
    return ValidSealRev(rev)
end

local function CompareSealRev(a, b)
    return GI.CompareVer(a, b)
end

--- Bump baseline.sealRev using the local writable writer (complete peers / cleanup).
function GI._BumpSealRev(record)
    if type(record) ~= "table" then
        return nil, "not_ready"
    end
    record.baseline = record.baseline or {}
    local writer, reason = GI:_EnsureWritableWriter()
    if not writer then
        return nil, reason
    end
    local prev = record.baseline.sealRev
    local prevN = 0
    if type(prev) == "table" and GI.IsFiniteNonnegInt(prev.n) then
        prevN = tonumber(prev.n) or 0
    end
    local maxN = MaxAdvancableN()
    if prevN + 1 >= maxN then
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
-- Tests may read GI._fpEvalCount for work-bound evidence (reset via ResetFpEvalCount).
GI._fpEvalCount = 0
function GI.ResetFpEvalCount()
    GI._fpEvalCount = 0
end

function GI.ComputeBaselineContentFp(members, groups)
    GI._fpEvalCount = (GI._fpEvalCount or 0) + 1
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
    local maxN = MaxAdvancableN()
    local nextN = prevN + 1
    -- nextN must itself be ValidGen (strictly below the exclusive ceiling).
    if nextN >= maxN or nextN <= prevN then
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
-- instead of last-arrival fingerprint replacement. If the revision cannot
-- advance, leave the prior advertised tip untouched (no stale-rev content swap).
function GI.RefreshBaselineSeal(record)
    if type(record) ~= "table" then
        return false
    end
    if not GI.IsBaselineComplete(record) then
        return false
    end
    record.baseline = record.baseline or {}
    local bumped, bumpErr = GI._BumpSealRev(record)
    if not bumped then
        return false, bumpErr or "generation_exhausted"
    end
    record.baseline.complete = true
    record.baseline.memberCount = CountKeys(record.members)
    record.baseline.groupCount = CountKeys(record.groups)
    record.baseline.contentFp = GI.ComputeBaselineContentFp(record.members, record.groups)
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
    -- Empty writer is only for this synthetic sort key, never admitted on wire.
    return { n = 0, w = "bootstrap" }
end

local function CompareVerSafe(a, b)
    if GI.CompareVer then
        return GI.CompareVer(a, b)
    end
    return 0
end

-- Max distinct Gossip senders whose admit streams are retained for tip windows.
local MAX_HOLD_SENDERS = 8

local function EnsureSameGenHold(record)
    record._sameGenHold = record._sameGenHold or {
        members = {},
        groups = {},
        characters = {},
        order = {}, -- chronological admit ids (all senders)
        bySender = {}, -- sender -> { order = {..} } contiguous per-peer export streams
        senderOrder = {}, -- recent sender names for bounded per-sender trials
    }
    local hold = record._sameGenHold
    if type(hold.order) ~= "table" then
        hold.order = {}
    end
    if type(hold.bySender) ~= "table" then
        hold.bySender = {}
    end
    if type(hold.senderOrder) ~= "table" then
        hold.senderOrder = {}
    end
    return hold
end

local function TrimOrder(order, maxOrder)
    while #order > maxOrder do
        table.remove(order, 1)
    end
end

local function HoldOrderAppend(hold, kind, id, sender, body)
    -- Bound chronological buffer: tip reconstruction only needs the trailing
    -- tip-sized unique ids, but keep a small headroom for concurrent extras.
    -- Each entry carries the admitted body so a tip window can rebuild the
    -- advertised snapshot versions, not only the eventual merge winners.
    local maxOrder = (GI.MAX_MEMBERS or 256) + (GI.MAX_GROUPS or 128) + 8
    hold.order[#hold.order + 1] = { k = kind, id = id, body = body }
    TrimOrder(hold.order, maxOrder)
    if type(sender) == "string" and sender ~= "" then
        local slot = hold.bySender[sender]
        if not slot then
            slot = { order = {} }
            hold.bySender[sender] = slot
            hold.senderOrder[#hold.senderOrder + 1] = sender
            while #hold.senderOrder > MAX_HOLD_SENDERS do
                local drop = table.remove(hold.senderOrder, 1)
                hold.bySender[drop] = nil
            end
        end
        slot.order[#slot.order + 1] = { k = kind, id = id, body = body }
        TrimOrder(slot.order, maxOrder)
    end
end

--- Park already-accepted same-gen rows before restarting tip catch-up.
-- Bounded by MAX_MEMBERS / MAX_GROUPS; version merge keeps the winning row.
local function HoldSameGenRows(record)
    local hold = EnsureSameGenHold(record)
    for guid, m in pairs(record.members or {}) do
        local prev = hold.members[guid]
        if not prev or CompareVerSafe(m.ver, prev.ver) > 0 then
            hold.members[guid] = m
        end
    end
    for gid, g in pairs(record.groups or {}) do
        local prev = hold.groups[gid]
        if not prev or CompareVerSafe(g.ver, prev.ver) > 0 then
            hold.groups[gid] = g
        end
    end
    for guid, c in pairs(record.characters or {}) do
        if type(c) == "table" then
            hold.characters[guid] = c
        end
    end
end

local function HoldOneMember(record, member, sender)
    if type(member) ~= "table" or type(member.guid) ~= "string" then
        return
    end
    local hold = EnsureSameGenHold(record)
    -- Winning body for post-seal reapply (eventual merge authority).
    local prev = hold.members[member.guid]
    if not prev or CompareVerSafe(member.ver, prev.ver) > 0 then
        hold.members[member.guid] = member
    end
    -- Snapshot witness: order entry keeps *this admit's* body for tip FP match.
    HoldOrderAppend(hold, "m", member.guid, sender, member)
end

local function HoldOneGroup(record, group, sender)
    if type(group) ~= "table" or type(group.groupId) ~= "string" then
        return
    end
    local hold = EnsureSameGenHold(record)
    local prev = hold.groups[group.groupId]
    if not prev or CompareVerSafe(group.ver, prev.ver) > 0 then
        hold.groups[group.groupId] = group
    end
    HoldOrderAppend(hold, "g", group.groupId, sender, group)
end

local function ClearDurableRows(record)
    record.members = {}
    record.groups = {}
    record.characters = {}
    record.revision = 0
end

--- Re-merge held same-gen rows after an exact tip seal so concurrent officer
-- edits survive without requiring Gossip retransmission.
function GI.ReapplySameGenHold(record)
    if type(record) ~= "table" then
        return false
    end
    local hold = record._sameGenHold
    if type(hold) ~= "table" then
        return false
    end
    record._sameGenHold = nil
    local gen = record.syncGen
    local applied = false
    for _, m in pairs(hold.members or {}) do
        local st = GI.MergeMember(record, m, { remote = true, gen = gen, skipReconcile = true })
        if st == "accepted" then
            applied = true
        end
    end
    for _, g in pairs(hold.groups or {}) do
        local st = GI.MergeGroup(record, g, { remote = true, gen = gen })
        if st == "accepted" then
            applied = true
        end
    end
    if type(hold.characters) == "table" and GI._RememberCharacter then
        for guid, c in pairs(hold.characters) do
            if type(c) == "table" then
                GI._RememberCharacter(record.characters, guid, c.nameRealm, c.classFile)
            end
        end
    end
    if GI.RebuildDerived then
        GI.RebuildDerived(record)
    end
    if applied and GI.IsBaselineComplete(record) and GI.RefreshBaselineSeal then
        GI.RefreshBaselineSeal(record)
    end
    return applied
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
    if epochBody.sealRev ~= nil and not ValidSealRev(epochBody.sealRev) then
        return false, "invalid_generation"
    end
    local incomingSeal = SealRevFromEpoch(epochBody)

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
            or { n = 0, w = "bootstrap" }
        local sealCmp = CompareSealRev(incomingSeal, localSeal)
        if sealCmp < 0 then
            return true, "duplicate"
        end
        if sealCmp == 0 then
            GI.TrySealBaseline(record)
            return true, "duplicate"
        end
        -- Higher same-gen tip: restart tip catch-up but park already-accepted
        -- rows so concurrent officer edits are not silently discarded.
        HoldSameGenRows(record)
        ClearDurableRows(record)
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
        GI.TrySealBaseline(record)
        return true, "accepted"
    end

    -- Newer generation wins: discard previous-generation durable relationship state.
    record._sameGenHold = nil
    ClearDurableRows(record)
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
    GI.TrySealBaseline(record)
    return true, "accepted"
end

--- Build a tip-sized member/group set from the most recent unique ids in `order`.
-- Prefer each order entry's admitted body (snapshot witness) so an older tip
-- author's versions are not replaced by a later higher-version merge winner.
-- One O(#order) scan; caller performs at most one fingerprint compare.
local function TipSetFromOrder(hold, order, tipMc, tipGc)
    if type(order) ~= "table" then
        return nil
    end
    local members, groups = {}, {}
    local mc, gc = 0, 0
    for i = #order, 1, -1 do
        local e = order[i]
        if type(e) == "table" then
            if e.k == "m" and mc < tipMc and not members[e.id] then
                -- Tests may set GI._sameGenTipUseWinningBodiesOnly to reproduce the
                -- pre-fix "latest hold body only" fingerprint mismatch.
                local body = (not GI._sameGenTipUseWinningBodiesOnly) and e.body or nil
                if type(body) ~= "table" then
                    body = hold.members and hold.members[e.id]
                end
                if type(body) == "table" then
                    members[e.id] = body
                    mc = mc + 1
                end
            elseif e.k == "g" and gc < tipGc and not groups[e.id] then
                local body = (not GI._sameGenTipUseWinningBodiesOnly) and e.body or nil
                if type(body) ~= "table" then
                    body = hold.groups and hold.groups[e.id]
                end
                if type(body) == "table" then
                    groups[e.id] = body
                    gc = gc + 1
                end
            end
        end
        if mc >= tipMc and gc >= tipGc then
            break
        end
    end
    if mc ~= tipMc or gc ~= tipGc then
        return nil
    end
    return members, groups
end

--- Seal from a chronological tip window: global trailing batch, then each recent
-- sender's contiguous export stream (≤ MAX_HOLD_SENDERS fingerprint trials).
-- No combinatorial subset search across extras.
local function TrySealFromRecentHoldWindow(record)
    local hold = record._sameGenHold
    if type(hold) ~= "table" then
        return false
    end
    local tipMc = tonumber(record.baseline.memberCount) or -1
    local tipGc = tonumber(record.baseline.groupCount) or -1
    local tipFp = tostring(record.baseline.contentFp or "")
    if tipMc < 0 or tipGc < 0 or tipFp == "" then
        return false
    end

    local function tryOrder(order)
        local members, groups = TipSetFromOrder(hold, order, tipMc, tipGc)
        if not members then
            return false
        end
        if GI.ComputeBaselineContentFp(members, groups) ~= tipFp then
            return false
        end
        ClearDurableRows(record)
        record.members = members
        record.groups = groups
        if GI.RebuildDerived then
            GI.RebuildDerived(record)
        end
        return GI.TrySealBaseline(record)
    end

    if tryOrder(hold.order) then
        return true
    end
    local senderOrder = hold.senderOrder
    if type(senderOrder) == "table" then
        -- Newest senders first (most likely tip author).
        for i = #senderOrder, 1, -1 do
            local slot = hold.bySender and hold.bySender[senderOrder[i]]
            if slot and tryOrder(slot.order) then
                return true
            end
        end
    end
    return false
end

--- After a remote admit while incomplete: park the row, try exact durable seal,
-- then bounded tip windows (global + per-sender). Polluted durable tip buffers
-- are cleared (rows remain in hold) so a complete tip batch can seal without search.
function GI.NoteIncompleteAdmit(record, keep)
    if type(record) ~= "table" or type(record.baseline) ~= "table" then
        return false
    end
    if record.baseline.complete then
        return true
    end
    keep = keep or {}
    local sender = keep.sender
    -- Prefer the incoming wire body when provided so tip-author versions land in
    -- hold even when durable already has an equal/winning duplicate row.
    if type(keep.member) == "table" and type(keep.member.guid) == "string" then
        HoldOneMember(record, keep.member, sender)
    elseif type(keep.group) == "table" and type(keep.group.groupId) == "string" then
        HoldOneGroup(record, keep.group, sender)
    elseif type(keep.memberGuid) == "string" and record.members[keep.memberGuid] then
        HoldOneMember(record, record.members[keep.memberGuid], sender)
    elseif type(keep.groupId) == "string" and record.groups[keep.groupId] then
        HoldOneGroup(record, record.groups[keep.groupId], sender)
    else
        HoldSameGenRows(record)
    end
    -- Always keep a full park of current durable rows as well.
    HoldSameGenRows(record)

    if GI.TrySealBaseline(record) then
        return true
    end
    -- Tip windows rebuild from hold without wiping a still-incomplete durable
    -- buffer (count supersets must remain visible and incomplete).
    return TrySealFromRecentHoldWindow(record)
end

--- Seal only on exact tip counts + contentFp. Concurrent edits live in
-- _sameGenHold and are re-merged after seal (see NoteIncompleteAdmit).
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
    local tipFp = tostring(record.baseline.contentFp or "")
    local fp = GI.ComputeBaselineContentFp(record.members, record.groups)
    if not (mc == tipMc and gc == tipGc and fp == tipFp) then
        return false
    end
    record.baseline.complete = true
    if GI.RebuildDerived then
        GI.RebuildDerived(record)
    end
    if record._sameGenHold then
        GI.ReapplySameGenHold(record)
    end
    if GI.RefreshBaselineSeal then
        GI.RefreshBaselineSeal(record)
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
