-- Guild-wide officer rank policy (#405).
-- One guild-owned threshold per verified club:<id>. Not a Loot Helper profile
-- setting, not Guild Supplies dataset authority, and not Guild Info history.
--
-- Contract:
--   Authority: this module. Empty storage is unknown, not "never configured".
--   Guarantee: rankOrder <= effective threshold. Same-revision concurrent edits
--     keep the lower threshold. A self-restricting edit is authorized against
--     the previous threshold. A verified Guild Master may bootstrap or recover
--     a missing/invalid policy and must not overwrite a valid one.
--   Dependencies: native guild identity, roster rank, and the rank-name list.
--     A shorter rank list caps the effective threshold; it does not widen it
--     and does not rewrite the stored value.
--   Lifecycle: SavedVariables plus one current Guild Gossip record. Reload
--     restores the stored policy. No timers and no roster polling.
--   Evidence: tests/lua/guild_officer_tests.lua.
local addonName, SF = ...

SF.GuildOfficer = SF.GuildOfficer or {}
local GO = SF.GuildOfficer

GO.SCHEMA_VERSION = 1
GO.PROVIDER_ID = "sf.guildofficer.policy"
GO.PROVIDER_SCHEMA = 1
GO.RECORD_ID = "go-p:current"
GO.DEFAULT_THRESHOLD = 3
GO.BOOTSTRAP_BASE = 0
GO.MAX_THRESHOLD = 20
GO.MAX_REV = 9007199254740990
-- Ordinary remote catch-up may skip missed revisions, but not leap to a
-- terminal or implausibly forward revision that strands future edits.
GO.MAX_REV_CATCHUP = 10000

GO._db = nil
GO._root = nil
GO._rootValid = false
GO._rootReason = "not_initialized"
GO._handleGeneration = 0
GO._lastGuildKey = nil
GO._applyingRemote = false

local function DebugInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Info("GUILD_OFFICER", fmt, ...)
    end
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("GUILD_OFFICER", fmt, ...)
    end
end

local function Hex8()
    local n = math.random(0, 0xfffffff)
    local s = string.format("%08x", n)
    if #s > 8 then
        s = s:sub(-8)
    elseif #s < 8 then
        s = string.rep("0", 8 - #s) .. s
    end
    return s
end

local function NewNonce()
    return Hex8() .. Hex8() .. Hex8()
end

local function IsNonce(nonce)
    return type(nonce) == "string" and #nonce == 24 and nonce:match("^[0-9a-fA-F]+$") ~= nil
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

local function IsFinitePosInt(n, maxN)
    n = tonumber(n)
    if not n or n ~= n or n < 1 or n == math.huge then
        return nil
    end
    if math.floor(n) ~= n then
        return nil
    end
    if maxN and n > maxN then
        return nil
    end
    return n
end

function GO.ParseGuildKey(guildKey)
    if type(guildKey) ~= "string" or guildKey == "" then
        return nil, nil
    end
    local clubId = guildKey:match("^club:(.+)$")
    if not clubId or clubId == "" or clubId == "0" then
        return nil, nil
    end
    if clubId:match("^%s") or clubId:match("%s$") then
        return nil, nil
    end
    return guildKey, clubId
end

local function PreviewNonAdminActive()
    local Imp = SF.LootHelperImpersonation
    if Imp and type(Imp.IsActive) == "function" and Imp:IsActive() then
        return true
    end
    return false
end

local function SnapshotLocalActor()
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildMember) ~= "function" or type(GG.SelfId) ~= "function" then
        return nil, "identity_unavailable"
    end
    local selfName = GG.SelfId()
    if type(selfName) ~= "string" or selfName == "" then
        return nil, "self_unavailable"
    end
    local member, reason = GG.GetGuildMember(selfName)
    if not member then
        return nil, reason or "not_a_member"
    end
    if type(member.guid) ~= "string" or member.guid == "" then
        if UnitGUID then
            local guid = UnitGUID("player")
            if type(guid) == "string" and guid ~= "" then
                member.guid = guid
            end
        end
    end
    if type(member.guid) ~= "string" or member.guid == "" then
        return nil, "guid_unavailable"
    end
    return member
end

function GO.GetHandleGeneration()
    return tonumber(GO._handleGeneration) or 0
end

function GO:_TrackGuildKey(guildKey)
    if guildKey ~= GO._lastGuildKey then
        GO._lastGuildKey = guildKey
        GO._handleGeneration = (tonumber(GO._handleGeneration) or 0) + 1
    end
end

function GO:IsRootReady()
    return GO._rootValid and type(GO._root) == "table"
end

function GO:GetRootReason()
    return GO._rootReason
end

--- Normalize a policy body. Does not consult the roster.
-- @return table|nil policy, string|nil reason
function GO.NormalizePolicy(body)
    if type(body) ~= "table" then
        return nil, "malformed"
    end
    local guildKey = select(1, GO.ParseGuildKey(body.guildKey))
    if not guildKey then
        return nil, "invalid_guild_key"
    end
    local threshold = IsFinitePosInt(body.threshold, GO.MAX_THRESHOLD)
    if not threshold then
        return nil, "invalid_threshold"
    end
    local base = tonumber(body.baseThreshold)
    if base == nil or base ~= math.floor(base) or base < 0 or base > GO.MAX_THRESHOLD then
        return nil, "invalid_base"
    end
    if base ~= GO.BOOTSTRAP_BASE and base < 1 then
        return nil, "invalid_base"
    end
    local revN = IsFinitePosInt(body.revN, GO.MAX_REV)
    if not revN then
        return nil, "invalid_revision"
    end
    if not IsNonce(body.revW) then
        return nil, "invalid_revision"
    end
    return {
        schemaVersion = GO.SCHEMA_VERSION,
        guildKey = guildKey,
        threshold = threshold,
        baseThreshold = base,
        revN = revN,
        revW = string.lower(body.revW),
        at = tonumber(body.at) or 0,
    }
end

--- Same-revision concurrent edits: lower threshold wins. Higher revision replaces.
-- A lower revision is stale. Equal threshold breaks ties on writer nonce.
-- @return string status, table|nil policy, string|nil detail
function GO.MergePolicies(localPolicy, remotePolicy)
    local remote, remoteErr = GO.NormalizePolicy(remotePolicy)
    if not remote then
        return "rejected", nil, remoteErr or "malformed"
    end
    if localPolicy == nil then
        return "accepted", remote, "catchup"
    end
    local localNorm, localErr = GO.NormalizePolicy(localPolicy)
    if not localNorm then
        return "accepted", remote, localErr or "replaced_invalid"
    end
    if localNorm.guildKey ~= remote.guildKey then
        return "rejected", nil, "wrong_guild"
    end
    if remote.revN == localNorm.revN and remote.revW == localNorm.revW
        and remote.threshold == localNorm.threshold
        and remote.baseThreshold == localNorm.baseThreshold then
        return "duplicate", localNorm, "duplicate"
    end
    if remote.revN < localNorm.revN then
        return "duplicate", localNorm, "stale"
    end
    if remote.revN > localNorm.revN then
        return "accepted", remote, "newer"
    end
    -- Equal revision: simultaneous edits against a shared prior.
    if remote.threshold < localNorm.threshold then
        return "accepted", remote, "restrictive"
    end
    if remote.threshold > localNorm.threshold then
        return "duplicate", localNorm, "restrictive"
    end
    if remote.revW < localNorm.revW then
        return "accepted", remote, "tiebreak"
    end
    return "duplicate", localNorm, "tiebreak"
end

function GO:Initialize(db)
    db = db or (type(SpectrumFederationDB) == "table" and SpectrumFederationDB) or nil
    if type(db) ~= "table" then
        GO._db = nil
        GO._root = nil
        GO._rootValid = false
        GO._rootReason = "not_initialized"
        return false, "not_initialized"
    end
    GO._db = db
    if db.guildOfficer == nil then
        db.guildOfficer = {
            schemaVersion = GO.SCHEMA_VERSION,
            localWriter = { nonce = NewNonce(), nextSeq = 1 },
            guilds = {},
        }
        DebugInfo("created empty guildOfficer root")
    end
    local root = db.guildOfficer
    if type(root) ~= "table" then
        GO._root = nil
        GO._rootValid = false
        GO._rootReason = "invalid_root"
        DebugWarn("guildOfficer root is not a table")
        return false, "invalid_root"
    end
    local ver = tonumber(root.schemaVersion)
    if ver and ver > GO.SCHEMA_VERSION then
        GO._root = root
        GO._rootValid = false
        GO._rootReason = "unsupported_schema"
        DebugWarn("guildOfficer schema %s is newer than %s", tostring(ver), tostring(GO.SCHEMA_VERSION))
        return false, "unsupported_schema"
    end
    if type(root.guilds) ~= "table" then
        root.guilds = {}
    end
    if type(root.localWriter) ~= "table" or not IsNonce(root.localWriter.nonce) then
        root.localWriter = { nonce = NewNonce(), nextSeq = 1 }
    end
    root.schemaVersion = GO.SCHEMA_VERSION
    GO._root = root
    GO._rootValid = true
    GO._rootReason = nil
    if GO.EnsureGossipProvider then
        GO:EnsureGossipProvider()
    end
    return true
end

function GO:_WriterNonce()
    if not GO:IsRootReady() then
        return nil
    end
    local writer = GO._root.localWriter
    if type(writer) ~= "table" or not IsNonce(writer.nonce) then
        GO._root.localWriter = { nonce = NewNonce(), nextSeq = 1 }
        writer = GO._root.localWriter
    end
    return string.lower(writer.nonce)
end

function GO:GetStoredPolicy(guildKey)
    if not GO:IsRootReady() then
        return nil, GO:GetRootReason() or "not_ready"
    end
    local key = select(1, GO.ParseGuildKey(guildKey))
    if not key then
        return nil, "invalid_guild_key"
    end
    local raw = GO._root.guilds[key]
    if raw == nil then
        return nil, "policy_unknown"
    end
    local policy, err = GO.NormalizePolicy(raw)
    if not policy then
        return nil, err or "policy_invalid"
    end
    if policy.guildKey ~= key then
        return nil, "policy_invalid"
    end
    -- A terminal revision cannot accept further commits; treat it as unusable so
    -- a verified Guild Master can recover through Bootstrap.
    if policy.revN >= GO.MAX_REV then
        return nil, "policy_invalid"
    end
    return policy, nil
end

local function RemoteRevisionPlausible(localPolicy, remoteRev)
    remoteRev = tonumber(remoteRev)
    if not remoteRev then
        return false, "invalid_revision"
    end
    if remoteRev >= GO.MAX_REV then
        return false, "implausible_revision"
    end
    local localRev = 0
    if localPolicy and tonumber(localPolicy.revN) then
        localRev = tonumber(localPolicy.revN)
    end
    local gap = tonumber(GO.MAX_REV_CATCHUP) or 10000
    if remoteRev > localRev + gap then
        return false, "implausible_revision"
    end
    return true
end

--- Current guild context. Missing ranks are unknown, not permission.
function GO:GetContext()
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildIdentity) ~= "function" then
        return {
            ready = false,
            reason = "identity_unavailable",
            handleGeneration = GO.GetHandleGeneration(),
        }
    end
    local identity, idReason = GG.GetGuildIdentity()
    if not identity or not select(1, GO.ParseGuildKey(identity.guildKey)) then
        GO:_TrackGuildKey(nil)
        return {
            ready = false,
            reason = idReason or "not_in_guild",
            handleGeneration = GO.GetHandleGeneration(),
        }
    end
    GO:_TrackGuildKey(identity.guildKey)
    local ranks, rankReason = nil, nil
    if type(GG.GetGuildRanks) == "function" then
        ranks, rankReason = GG.GetGuildRanks()
    end
    local member, memberReason = SnapshotLocalActor()
    local rankCount = type(ranks) == "table" and tonumber(ranks.count) or nil
    local rankReady = type(ranks) == "table" and rankCount and rankCount >= 1
        and type(member) == "table" and type(member.rankOrder) == "number"
        and type(member.guid) == "string"
    local ctx = {
        ready = rankReady and true or false,
        membershipReady = type(member) == "table",
        guildKey = identity.guildKey,
        clubId = identity.clubId,
        actorName = member and member.name or nil,
        actorGuid = member and member.guid or nil,
        rankOrder = member and member.rankOrder or nil,
        ranks = ranks,
        rankCount = rankCount,
        handleGeneration = GO.GetHandleGeneration(),
        previewNonAdmin = PreviewNonAdminActive(),
        reason = nil,
    }
    if not ctx.membershipReady then
        ctx.reason = memberReason or "not_ready"
    elseif not rankReady then
        ctx.reason = rankReason or memberReason or "rank_unavailable"
    end
    return ctx
end

local function EffectiveThreshold(policy, rankCount)
    if type(policy) ~= "table" then
        return nil
    end
    local threshold = tonumber(policy.threshold)
    if not threshold then
        return nil
    end
    rankCount = tonumber(rankCount)
    if rankCount and rankCount >= 1 and threshold > rankCount then
        return rankCount
    end
    return threshold
end

--- Established effective threshold for the current guild, or nil when unknown.
-- A shorter rank list caps the value used for checks. The stored record stays.
function GO:GetEstablishedThreshold(guildKey)
    local ctx = GO:GetContext()
    local key = guildKey or ctx.guildKey
    if type(key) ~= "string" then
        return nil, ctx.reason or "not_ready"
    end
    if ctx.guildKey and key ~= ctx.guildKey then
        return nil, "wrong_guild"
    end
    if not ctx.ready then
        return nil, ctx.reason or "rank_unavailable"
    end
    local policy, reason = GO:GetStoredPolicy(key)
    if not policy then
        if reason == "policy_unknown" or reason == "invalid_threshold"
            or reason == "invalid_base" or reason == "invalid_revision"
            or reason == "malformed" then
            if reason == "policy_unknown" then
                return nil, "policy_unknown"
            end
            return nil, "policy_invalid"
        end
        return nil, reason or "policy_unknown"
    end
    return EffectiveThreshold(policy, ctx.rankCount), nil
end

--- @return boolean meets, string|nil reason
function GO:RankMeetsThreshold(rankOrder, rankCount)
    rankOrder = tonumber(rankOrder)
    rankCount = tonumber(rankCount)
    if not rankOrder or rankOrder ~= math.floor(rankOrder) or rankOrder < 1 then
        return false, "unauthorized"
    end
    if not rankCount or rankCount < 1 or rankOrder > rankCount then
        return false, "rank_unavailable"
    end
    local threshold, reason = GO:GetEstablishedThreshold()
    if not threshold then
        return false, reason or "policy_unknown"
    end
    if rankOrder <= threshold then
        return true, nil
    end
    return false, "unauthorized"
end

local function RankName(ranks, position)
    if type(ranks) ~= "table" or type(position) ~= "number" then
        return nil
    end
    local name = ranks[position]
    if type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

local function RankOptions(ranks, rankCount)
    local opts = {}
    if type(ranks) ~= "table" or not rankCount then
        return opts
    end
    for i = 1, rankCount do
        local name = ranks[i]
        if type(name) == "string" and name ~= "" then
            opts[#opts + 1] = { value = i, label = name }
        end
    end
    return opts
end

--- Settings view. Viewing does not create or repair a policy.
function GO:GetView()
    local ctx = GO:GetContext()
    local view = {
        status = "unavailable",
        canRead = ctx.membershipReady and true or false,
        canEdit = false,
        canBootstrap = false,
        threshold = nil,
        effectiveThreshold = nil,
        thresholdName = nil,
        capped = false,
        rankOptions = RankOptions(ctx.ranks, ctx.rankCount),
        rankOrder = ctx.rankOrder,
        guildKey = ctx.guildKey,
        actorGuid = ctx.actorGuid,
        handleGeneration = ctx.handleGeneration,
        revN = nil,
        previewNonAdmin = ctx.previewNonAdmin and true or false,
        reason = ctx.reason,
    }
    if not ctx.guildKey then
        view.canRead = false
        return view
    end
    local policy, policyReason = GO:GetStoredPolicy(ctx.guildKey)
    if not ctx.ready then
        view.status = "unavailable"
        view.reason = ctx.reason or "rank_unavailable"
        if policy then
            view.threshold = policy.threshold
            view.revN = policy.revN
        end
        return view
    end
    if not policy then
        local invalid = policyReason == "policy_invalid" or policyReason == "invalid_threshold"
            or policyReason == "invalid_base" or policyReason == "invalid_revision"
            or policyReason == "malformed"
        view.status = invalid and "invalid" or "unknown"
        view.reason = invalid and "policy_invalid" or "policy_unknown"
        if ctx.rankOrder == 1 and not ctx.previewNonAdmin then
            view.canBootstrap = true
        end
        return view
    end
    view.threshold = policy.threshold
    view.revN = policy.revN
    view.policyFp = GO.PolicyVersionFp and GO.PolicyVersionFp(policy) or nil
    view.effectiveThreshold = EffectiveThreshold(policy, ctx.rankCount)
    view.capped = view.effectiveThreshold ~= policy.threshold
    view.thresholdName = RankName(ctx.ranks, view.effectiveThreshold)
    view.status = "established"
    view.reason = nil
    if ctx.previewNonAdmin then
        view.canEdit = false
        view.reason = "preview_non_admin"
        return view
    end
    if type(ctx.rankOrder) == "number" and view.effectiveThreshold
        and ctx.rankOrder <= view.effectiveThreshold then
        view.canEdit = true
    else
        view.canEdit = false
        view.reason = "unauthorized"
    end
    return view
end

local function SavePolicy(policy)
    if not GO:IsRootReady() then
        return false, GO:GetRootReason() or "not_ready"
    end
    local norm, err = GO.NormalizePolicy(policy)
    if not norm then
        return false, err or "malformed"
    end
    GO._root.guilds[norm.guildKey] = norm
    return true, norm
end

local function BindCommitOpts(ctx, opts)
    opts = opts or {}
    if opts.expectedGuildKey and opts.expectedGuildKey ~= ctx.guildKey then
        return false, "wrong_guild"
    end
    if opts.expectedHandleGeneration ~= nil
        and tonumber(opts.expectedHandleGeneration) ~= tonumber(ctx.handleGeneration) then
        return false, "stale_handle"
    end
    if opts.expectedActorGuid and opts.expectedActorGuid ~= ctx.actorGuid then
        return false, "actor_changed"
    end
    return true
end

--- Verified Guild Master bootstrap or recovery. Refuses a valid established policy.
function GO:Bootstrap(opts)
    opts = opts or {}
    if not GO:IsRootReady() then
        return "rejected", GO:GetRootReason() or "not_ready"
    end
    local ctx = GO:GetContext()
    if not ctx.ready then
        return "rejected", ctx.reason or "not_ready"
    end
    if ctx.previewNonAdmin then
        return "rejected", "preview_non_admin"
    end
    local okBind, bindErr = BindCommitOpts(ctx, opts)
    if not okBind then
        return "rejected", bindErr
    end
    if ctx.rankOrder ~= 1 then
        return "rejected", "policy_requires_gm"
    end
    local existing, existingReason = GO:GetStoredPolicy(ctx.guildKey)
    if existing and existing.threshold >= 1 and existing.threshold <= GO.MAX_THRESHOLD then
        -- In-range stored policy is valid even when the current rank list is shorter.
        return "rejected", "already_established"
    end
    if existingReason and existingReason ~= "policy_unknown"
        and existingReason ~= "policy_invalid"
        and existingReason ~= "invalid_threshold"
        and existingReason ~= "invalid_base"
        and existingReason ~= "invalid_revision"
        and existingReason ~= "malformed" then
        return "rejected", existingReason
    end
    local position = tonumber(opts.threshold)
    if position == nil then
        position = math.min(GO.DEFAULT_THRESHOLD, ctx.rankCount)
    end
    position = IsFinitePosInt(position, ctx.rankCount)
    if not position then
        return "rejected", "invalid_threshold"
    end
    local revN = 1
    local raw = GO._root.guilds[ctx.guildKey]
    if type(raw) == "table" and tonumber(raw.revN) and tonumber(raw.revN) >= 1 then
        local prior = math.floor(tonumber(raw.revN))
        if prior >= GO.MAX_REV then
            -- Terminal/unusable stored revision: verified GM recovery restarts.
            revN = 1
        else
            revN = prior + 1
            if revN > GO.MAX_REV then
                return "rejected", "revision_exhausted"
            end
        end
    end
    local policy = {
        schemaVersion = GO.SCHEMA_VERSION,
        guildKey = ctx.guildKey,
        threshold = position,
        baseThreshold = GO.BOOTSTRAP_BASE,
        revN = revN,
        revW = GO:_WriterNonce(),
        at = Now(),
    }
    local saved, saveErr = SavePolicy(policy)
    if not saved then
        return "rejected", saveErr or "not_ready"
    end
    DebugInfo("bootstrapped officer policy guild=%s threshold=%s rev=%s",
        ctx.guildKey, tostring(position), tostring(revN))
    if GO.NotifyLocalChange then
        GO.NotifyLocalChange("bootstrap")
    end
    return "accepted", nil
end

--- Commit a new threshold. Authorized against the previous effective threshold.
function GO:CommitThreshold(position, opts)
    opts = opts or {}
    if not GO:IsRootReady() then
        return "rejected", GO:GetRootReason() or "not_ready"
    end
    local ctx = GO:GetContext()
    if not ctx.ready then
        return "rejected", ctx.reason or "not_ready"
    end
    if ctx.previewNonAdmin then
        return "rejected", "preview_non_admin"
    end
    local okBind, bindErr = BindCommitOpts(ctx, opts)
    if not okBind then
        return "rejected", bindErr
    end
    position = IsFinitePosInt(position, ctx.rankCount)
    if not position then
        return "rejected", "invalid_threshold"
    end
    local existing, existingReason = GO:GetStoredPolicy(ctx.guildKey)
    if not existing then
        return "rejected", existingReason or "policy_unknown"
    end
    if opts.expectedPolicyFp ~= nil then
        local fp = GO.PolicyVersionFp and GO.PolicyVersionFp(existing) or nil
        if type(opts.expectedPolicyFp) ~= "string" or opts.expectedPolicyFp == ""
            or opts.expectedPolicyFp ~= fp then
            return "rejected", "stale_policy"
        end
    elseif opts.expectedRevN ~= nil and tonumber(opts.expectedRevN) ~= tonumber(existing.revN) then
        return "rejected", "stale_policy"
    end
    local effective = EffectiveThreshold(existing, ctx.rankCount)
    if not effective or ctx.rankOrder > effective then
        return "rejected", "unauthorized"
    end
    if position == existing.threshold then
        return "accepted", "noop"
    end
    local revN = existing.revN + 1
    if revN > GO.MAX_REV then
        return "rejected", "revision_exhausted"
    end
    local policy = {
        schemaVersion = GO.SCHEMA_VERSION,
        guildKey = ctx.guildKey,
        threshold = position,
        baseThreshold = existing.threshold,
        revN = revN,
        revW = GO:_WriterNonce(),
        at = Now(),
    }
    local saved, saveErr = SavePolicy(policy)
    if not saved then
        return "rejected", saveErr or "not_ready"
    end
    DebugInfo("officer threshold guild=%s %s -> %s by rank %s",
        ctx.guildKey, tostring(existing.threshold), tostring(position), tostring(ctx.rankOrder))
    if GO.NotifyLocalChange then
        GO.NotifyLocalChange("commit")
    end
    return "accepted", nil
end

-- Approved default officer cap for first-record catch-up. Local bootstrap and
-- recovery still require a verified Guild Master through Bootstrap().
local function DefaultOfficerCap(rankCount)
    rankCount = tonumber(rankCount)
    if not rankCount or rankCount < 1 then
        return nil
    end
    return math.min(GO.DEFAULT_THRESHOLD, rankCount)
end

-- Remote admission. The transport sender is a relay, not the original author.
-- A known local policy authorizes the sender against that policy. Same-revision
-- edits still authorize against the shared predecessor so a more restrictive
-- concurrent edit is admitted. An empty client authorizes the sender against
-- the approved default officer cap so a GM-created record can be relayed by an
-- eligible officer after the GM logs off, while a non-officer cannot install a
-- first policy by claiming a permissive predecessor. Ordinary Gossip fields
-- cannot prove original authorship; an eligible-by-default officer can still
-- install any valid first-record content.
local function RemoteSenderAuthorized(remote, member, localPolicy, rankCount)
    if localPolicy then
        local sameGeneration = remote.revN == localPolicy.revN
            and remote.baseThreshold == localPolicy.baseThreshold
        if sameGeneration then
            local pred = localPolicy.baseThreshold
            if pred == GO.BOOTSTRAP_BASE then
                if member.rankOrder ~= 1 then
                    return false, "unauthorized"
                end
                return true
            end
            if rankCount and pred > rankCount then
                pred = rankCount
            end
            if member.rankOrder > pred then
                return false, "unauthorized"
            end
            return true
        end
        if remote.baseThreshold == GO.BOOTSTRAP_BASE then
            -- Verified Guild Master recovery writes baseThreshold=0 with a newer
            -- revision. Established peers must accept that authenticated recovery
            -- so a corrupt local SV entry can converge again. Non-GM forgery and
            -- non-newer recovery records stay rejected.
            if member.rankOrder == 1
                and tonumber(remote.revN)
                and tonumber(localPolicy.revN)
                and remote.revN > localPolicy.revN then
                return true
            end
            return false, "already_established"
        end
        local effective = EffectiveThreshold(localPolicy, rankCount)
        if not effective or member.rankOrder > effective then
            return false, "unauthorized"
        end
        return true
    end
    local defaultCap = DefaultOfficerCap(rankCount)
    if not defaultCap then
        return false, "rank_unavailable"
    end
    if member.rankOrder > defaultCap then
        return false, "unauthorized"
    end
    return true
end

--- Apply one authenticated remote policy record.
function GO:ApplyRemotePolicy(body, member)
    if GO._applyingRemote then
        return "rejected", "reentrant"
    end
    if type(member) ~= "table" or type(member.rankOrder) ~= "number" then
        return "rejected", "unauthorized"
    end
    if type(member.guildKey) ~= "string" or not select(1, GO.ParseGuildKey(member.guildKey)) then
        return "rejected", "wrong_guild"
    end
    local remote, remoteErr = GO.NormalizePolicy(body)
    if not remote then
        return "rejected", remoteErr or "malformed"
    end
    if remote.guildKey ~= member.guildKey then
        return "rejected", "wrong_guild"
    end
    local GG = SF.GuildGossip
    local identity = GG and GG.GetGuildIdentity and GG.GetGuildIdentity()
    if not identity or identity.guildKey ~= member.guildKey then
        return "rejected", "wrong_guild"
    end
    local ranks = GG and GG.GetGuildRanks and GG.GetGuildRanks()
    local rankCount = type(ranks) == "table" and tonumber(ranks.count) or nil
    if not rankCount or rankCount < 1 or type(member.rankOrder) ~= "number" then
        return "rejected", "rank_unavailable"
    end
    if member.rankOrder < 1 or member.rankOrder > rankCount then
        return "rejected", "unauthorized"
    end
    if not GO:IsRootReady() then
        return "rejected", GO:GetRootReason() or "not_ready"
    end
    local localPolicy = select(1, GO:GetStoredPolicy(remote.guildKey))
    local allowed, authReason = RemoteSenderAuthorized(remote, member, localPolicy, rankCount)
    if not allowed then
        return "rejected", authReason or "unauthorized"
    end
    local revOk, revReason = RemoteRevisionPlausible(localPolicy, remote.revN)
    if not revOk then
        return "rejected", revReason or "implausible_revision"
    end
    -- A stored threshold above this client's rank count is kept. Authorization
    -- above already capped a known policy. The shorter list does not rewrite it.
    local status, merged, detail = GO.MergePolicies(localPolicy, remote)
    if status ~= "accepted" then
        return status, detail
    end
    GO._applyingRemote = true
    local saved, saveErr = SavePolicy(merged)
    GO._applyingRemote = false
    if not saved then
        return "rejected", saveErr or "not_ready"
    end
    DebugInfo("applied remote officer policy guild=%s threshold=%s rev=%s (%s)",
        merged.guildKey, tostring(merged.threshold), tostring(merged.revN), tostring(detail))
    if GO.NotifyLocalChange then
        GO.NotifyLocalChange("remote")
    end
    return "accepted", detail
end

--- One-character eligibility for a Loot Helper grant. Unknown stays nil.
-- @return boolean|nil eligible, string|nil reason
function GO:EvaluateCharacter(name)
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildMember) ~= "function" or type(GG.NormalizePlayer) ~= "function" then
        return nil, "identity_unavailable"
    end
    local identity = GG.GetGuildIdentity and GG.GetGuildIdentity()
    if not identity then
        return nil, "not_in_guild"
    end
    local want = GG.NormalizePlayer(name)
    if not want then
        return nil, "invalid_name"
    end
    if not GetNumGuildMembers or not GetGuildRosterInfo then
        return nil, "roster_unavailable"
    end
    -- GetNumGuildMembers returns several numbers. Keep only the first before tonumber;
    -- passing the rest makes Lua treat the second value as a conversion base.
    local total = GetNumGuildMembers()
    total = tonumber(total) or 0
    if total <= 0 then
        return nil, "roster_incomplete"
    end
    local wantLower = string.lower(want)
    local matches = 0
    local matchedGuid = nil
    for i = 1, total do
        local rosterName, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
        local norm = GG.NormalizePlayer(rosterName)
        if norm and string.lower(norm) == wantLower then
            matches = matches + 1
            if type(guid) == "string" and guid ~= "" then
                matchedGuid = guid
            end
        end
    end
    if matches > 1 then
        return nil, "ambiguous_name"
    end
    if matches == 0 then
        return false, "not_a_member"
    end
    local member, reason = GG.GetGuildMember(want)
    if not member then
        if reason == "not_a_member" then
            return false, reason
        end
        return nil, reason or "not_ready"
    end
    if type(member.guid) ~= "string" or member.guid == "" then
        return nil, "guid_unavailable"
    end
    if matchedGuid and matchedGuid ~= member.guid then
        return nil, "ambiguous_name"
    end
    if member.guildKey ~= identity.guildKey then
        return nil, "wrong_guild"
    end
    local threshold, polReason = GO:GetEstablishedThreshold(identity.guildKey)
    if not threshold then
        return nil, polReason or "policy_unknown"
    end
    if type(member.rankOrder) ~= "number" then
        return nil, "rank_unavailable"
    end
    if member.rankOrder <= threshold then
        return true, nil
    end
    return false, "ineligible"
end

--- Settings banner text for officer-policy commits. Not game Chat.
function GO.FormatFeedback(status, reason)
    local function Loc(key, default)
        if SF.LocaleText then
            return SF.LocaleText(key, default)
        end
        return default
    end
    if status == "accepted" and reason == "noop" then
        return Loc("GUILD_OFFICER_STATUS_NOOP", "Officer rank is already set to that rank."), "info"
    end
    if status == "accepted" then
        return Loc("GUILD_OFFICER_STATUS_ACCEPTED", "Officer rank updated."), "success"
    end
    if status == "duplicate" then
        return Loc("GUILD_OFFICER_STATUS_DUPLICATE", "Officer rank is already up to date."), "info"
    end
    local map = {
        unauthorized = Loc("GUILD_OFFICER_ERR_UNAUTHORIZED", "Your guild rank cannot change the officer rank."),
        preview_non_admin = Loc("GUILD_OFFICER_ERR_PREVIEW", "Preview as Non-Admin is active; officer rank edits are disabled."),
        policy_unknown = Loc("GUILD_OFFICER_ERR_UNKNOWN", "Officer rank is not available yet."),
        policy_invalid = Loc("GUILD_OFFICER_ERR_INVALID", "Officer rank needs Guild Master recovery."),
        policy_requires_gm = Loc("GUILD_OFFICER_ERR_GM", "Only the Guild Master can establish or recover the officer rank."),
        already_established = Loc("GUILD_OFFICER_ERR_EXISTS", "This guild already has an officer rank."),
        stale_policy = Loc("GUILD_OFFICER_ERR_STALE", "Officer rank changed before this confirmation. Review it and try again."),
        stale_handle = Loc("GUILD_OFFICER_ERR_STALE_HANDLE", "Guild context changed; the officer rank was not changed."),
        wrong_guild = Loc("GUILD_OFFICER_ERR_WRONG_GUILD", "Guild context changed; the officer rank was not changed."),
        actor_changed = Loc("GUILD_OFFICER_ERR_ACTOR", "Your character changed; the officer rank was not changed."),
        invalid_threshold = Loc("GUILD_OFFICER_ERR_THRESHOLD", "That rank is not in the current guild rank list."),
        rank_unavailable = Loc("GUILD_OFFICER_ERR_RANKS", "Guild rank information is unavailable."),
        not_ready = Loc("GUILD_OFFICER_ERR_NOT_READY", "Guild membership or rank information is not ready yet."),
        not_in_guild = Loc("GUILD_OFFICER_ERR_NOT_IN_GUILD", "You are not currently in a guild."),
        implausible_revision = Loc("GUILD_OFFICER_ERR_REVISION", "That officer-rank update is too far ahead to apply safely."),
        revision_exhausted = Loc("GUILD_OFFICER_ERR_REVISION", "That officer-rank update is too far ahead to apply safely."),
    }
    return map[reason] or Loc("GUILD_OFFICER_ERR_GENERIC", "The officer rank could not be changed."), "error"
end
