-- Guild Supplies rank/capability authority (#385 Part 2A, #405).
-- Current edits use the shared guild officer threshold. Historical
-- permission.editorRankPosition remains for dataset validation only.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

local function L(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default
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
    if not GG then
        return nil, "identity_unavailable"
    end
    local selfName = nil
    if type(GG.SelfId) == "function" then
        selfName = GG.SelfId()
    end
    if type(selfName) ~= "string" or selfName == "" then
        return nil, "self_unavailable"
    end
    local member, reason = GG.GetGuildMember(selfName)
    if not member then
        return nil, reason or "not_a_member"
    end
    if type(member.guid) ~= "string" or member.guid == "" then
        -- Prefer UnitGUID when roster GUID is missing.
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

--- Current native-derived context or machine-readable waiting reason.
function GS:GetCurrentContext()
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildIdentity) ~= "function" then
        return {
            ready = false,
            reason = "identity_unavailable",
            handleGeneration = GS.GetHandleGeneration(),
        }
    end

    local identity, idReason = GG.GetGuildIdentity()
    if not identity then
        GS:_TrackGuildKey(nil)
        return {
            ready = false,
            reason = idReason or "not_ready",
            handleGeneration = GS.GetHandleGeneration(),
        }
    end
    GS:_TrackGuildKey(identity.guildKey)

    local ranks, rankReason = GG.GetGuildRanks()
    local member, memberReason = SnapshotLocalActor()

    local rankReady = type(ranks) == "table" and type(member) == "table"
        and type(member.rankOrder) == "number" and type(member.guid) == "string"
    local membershipReady = type(member) == "table" -- name/membership known

    local ctx = {
        ready = rankReady and true or false,
        membershipReady = membershipReady and true or false,
        guildKey = identity.guildKey,
        clubId = identity.clubId,
        guildName = identity.guildName,
        guildRealm = identity.guildRealm,
        transportScopeId = identity.transportScopeId,
        actorName = member and member.name or nil,
        actorGuid = member and member.guid or nil,
        rankOrder = member and member.rankOrder or nil,
        ranks = ranks,
        rankCount = ranks and ranks.count or nil,
        handleGeneration = GS.GetHandleGeneration(),
        previewNonAdmin = PreviewNonAdminActive(),
        reason = nil,
    }
    if not membershipReady then
        ctx.reason = memberReason or "not_ready"
    elseif not rankReady then
        ctx.reason = rankReason or memberReason or "rank_unavailable"
    end
    return ctx
end

--- Effective officer threshold. Nil when the shared policy is unknown or unusable.
function GS.SharedOfficerThreshold()
    local GO = SF.GuildOfficer
    if not GO or type(GO.GetEstablishedThreshold) ~= "function" then
        return nil, "policy_unknown"
    end
    return GO:GetEstablishedThreshold()
end

local function PolicyPosition(record)
    if type(record) ~= "table" or type(record.permission) ~= "table" then
        return nil, "invalid_permission"
    end
    local pos = tonumber(record.permission.editorRankPosition)
    if not pos or pos ~= math.floor(pos) or pos < 1 then
        return nil, "invalid_editor_rank_position"
    end
    return pos, record.permission.revisionId
end

local function ResolveThresholdName(ranks, position)
    if type(ranks) ~= "table" or type(position) ~= "number" then
        return nil
    end
    local name = ranks[position]
    if type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

--- Current capabilities. UI visibility is not security; recheck at commit.
function GS:GetCapabilities()
    local ctx = GS:GetCurrentContext()
    local result = {
        canRead = false,
        canEdit = false,
        canRecoverPolicy = false,
        editorRankPosition = nil,
        editorRankName = nil,
        editorRankLabel = nil,
        reason = ctx.reason or "not_ready",
        previewNonAdmin = ctx.previewNonAdmin and true or false,
        guildKey = ctx.guildKey,
        rankOrder = ctx.rankOrder,
        handleGeneration = ctx.handleGeneration,
    }

    if not ctx.guildKey then
        return result
    end

    -- Member-readable accepted caches require verifiable current guild membership.
    if ctx.membershipReady then
        result.canRead = true
        if not ctx.ready then
            result.reason = ctx.reason or "rank_unavailable"
        else
            result.reason = nil
        end
    else
        result.reason = ctx.reason or "not_ready"
        return result
    end

    local record, recordReason = GS:GetCurrentRecord()
    local policyPos = nil
    local policyValid = false
    local policyInRange = false

    if record then
        local pos, revErr = PolicyPosition(record)
        if pos then
            policyPos = pos
            result.editorRankPosition = pos
            if ctx.ranks and ctx.rankCount and pos <= ctx.rankCount then
                policyValid = true
                policyInRange = true
            elseif ctx.ranks and ctx.rankCount then
                policyValid = false -- out of range after reorder/delete
            else
                policyValid = false
            end
        else
            result.reason = revErr or "invalid_permission"
        end
    elseif recordReason == "not_configured" then
        -- Fresh initialization uses default threshold when ranks exist.
        if ctx.ready and ctx.rankCount and ctx.rankCount >= GS.DEFAULT_EDITOR_RANK_POSITION then
            policyPos = GS.DEFAULT_EDITOR_RANK_POSITION
            policyValid = true
            policyInRange = true
            result.editorRankPosition = policyPos
        elseif ctx.ready and ctx.rankCount and ctx.rankCount > 0
            and ctx.rankCount < GS.DEFAULT_EDITOR_RANK_POSITION then
            -- Fewer than three ranks: only verified GM may select a threshold later.
            policyPos = nil
            policyValid = false
            result.editorRankPosition = nil
        end
    elseif GS._IsPermissionOnlyFailure and GS._IsPermissionOnlyFailure(recordReason) then
        -- Permission-only failure: structure must still be recoverable.
        local raw = GS:_GetPolicyRecoveryRecord(ctx.guildKey)
        if not raw then
            result.canRead = false
            result.reason = recordReason
            return result
        end
        policyValid = false
        result.reason = recordReason
    elseif recordReason and recordReason ~= "not_configured" then
        -- Malformed/unsupported record: fail closed for edits; reads of accepted
        -- public history remain available only when record validates. Here record
        -- failed validation, so do not expose it as readable domain data.
        -- Unrelated corruption is not GM policy recovery.
        result.canRead = false
        result.canRecoverPolicy = false
        result.reason = recordReason
        return result
    end

    if ctx.ready and type(ctx.rankOrder) == "number" then
        local isGM = (ctx.rankOrder == 1)
        -- Historical permission repair is GM-only and only when that record is
        -- actually corrupt. It must not authorize ordinary edits, initialization,
        -- or adoption while the shared officer policy is unknown.
        result.canRecoverPolicy = false
        local sharedPos, sharedReason = GS.SharedOfficerThreshold()
        local permissionBroken = recordReason
            and GS._IsPermissionOnlyFailure
            and GS._IsPermissionOnlyFailure(recordReason)

        if PreviewNonAdminActive() then
            result.canEdit = false
            result.reason = "preview_non_admin"
        elseif GS.IsBootstrapEditLocked and GS.IsBootstrapEditLocked(ctx.guildKey) then
            -- Descriptor-first install: replication continues, local edits blocked
            -- until the advertised dataset revision is reconstructed.
            result.canEdit = false
            result.reason = "awaiting_policy"
        elseif permissionBroken then
            result.canEdit = false
            result.canRecoverPolicy = isGM and true or false
            result.reason = isGM and "policy_requires_gm" or "unauthorized"
        elseif not sharedPos then
            result.canEdit = false
            result.reason = sharedReason or "policy_unknown"
            result.editorRankPosition = nil
        elseif ctx.rankOrder <= sharedPos
            and (recordReason == "not_configured" or record ~= nil) then
            result.canEdit = true
            result.reason = nil
            result.editorRankPosition = sharedPos
        else
            result.canEdit = false
            result.reason = "unauthorized"
            result.editorRankPosition = sharedPos
        end
    else
        result.canEdit = false
        result.canRecoverPolicy = false
        if not result.reason then
            result.reason = "rank_unavailable"
        end
    end

    local thresholdName = ResolveThresholdName(ctx.ranks, result.editorRankPosition)
    if thresholdName then
        result.editorRankName = thresholdName
        result.editorRankLabel = L(
            "GUILD_SUPPLIES_EDITOR_RANK_LABEL",
            "%s and higher"
        ):format(thresholdName)
    else
        result.editorRankName = nil
        result.editorRankLabel = L(
            "GUILD_SUPPLIES_RANK_WAITING",
            "Guild rank information is unavailable."
        )
        if result.canEdit or result.canRecoverPolicy then
            -- Names unavailable: disable editing controls presentation; authority
            -- still fails closed when ranks are missing (handled above).
        end
    end

    return result
end

--- Recheck authority for a prepared context at commit time.
-- @return boolean ok, string|nil reason, table|nil freshContext
function GS:_AuthorizeCommit(prepared, opts)
    opts = opts or {}
    local fresh = GS:GetCurrentContext()
    if not fresh or not fresh.ready then
        return false, (fresh and fresh.reason) or "not_ready", fresh
    end
    if prepared then
        if prepared.guildKey and prepared.guildKey ~= fresh.guildKey then
            return false, "wrong_guild", fresh
        end
        if prepared.handleGeneration ~= nil
            and prepared.handleGeneration ~= fresh.handleGeneration then
            return false, "stale_handle", fresh
        end
        if prepared.actorGuid and prepared.actorGuid ~= fresh.actorGuid then
            return false, "actor_changed", fresh
        end
    end
    local caps = GS:GetCapabilities()
    if opts.requireRecoverPolicy then
        if not caps.canRecoverPolicy then
            return false, caps.reason or "unauthorized", fresh
        end
        return true, nil, fresh
    end
    if opts.allowRecoverPolicy and caps.canRecoverPolicy and not caps.canEdit then
        return true, nil, fresh
    end
    if not caps.canEdit then
        return false, caps.reason or "unauthorized", fresh
    end
    return true, nil, fresh
end
