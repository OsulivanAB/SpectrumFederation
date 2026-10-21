-- Guild Info rank/capability authority (#402, #405).
-- Editing uses the shared guild officer threshold, not a Guild Info-local rank.
local addonName, SF = ...

SF.GuildInfo = SF.GuildInfo or {}
local GI = SF.GuildInfo

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
function GI:GetCurrentContext()
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildIdentity) ~= "function" then
        return {
            ready = false,
            reason = "identity_unavailable",
            handleGeneration = GI.GetHandleGeneration(),
        }
    end

    local identity, idReason = GG.GetGuildIdentity()
    if not identity then
        GI:_TrackGuildKey(nil)
        return {
            ready = false,
            reason = idReason or "not_ready",
            handleGeneration = GI.GetHandleGeneration(),
        }
    end
    GI:_TrackGuildKey(identity.guildKey)

    local ranks, rankReason = GG.GetGuildRanks()
    local member, memberReason = SnapshotLocalActor()

    local rankReady = type(ranks) == "table" and type(member) == "table"
        and type(member.rankOrder) == "number" and type(member.guid) == "string"
    local membershipReady = type(member) == "table"

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
        handleGeneration = GI.GetHandleGeneration(),
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

--- Whether a verified rank order may edit Guild Info under the shared officer policy.
-- @return boolean ok, string|nil reason
function GI.RankMayEdit(rankOrder, rankCount)
    local GO = SF.GuildOfficer
    if not GO or type(GO.RankMeetsThreshold) ~= "function" then
        return false, "policy_unknown"
    end
    return GO:RankMeetsThreshold(rankOrder, rankCount)
end

--- Current capabilities. UI visibility is not security; recheck at commit.
function GI:GetCapabilities()
    local ctx = GI:GetCurrentContext()
    local result = {
        canRead = false,
        canEdit = false,
        editorRankMax = GI.EDITOR_RANK_MAX,
        reason = ctx.reason or "not_ready",
        previewNonAdmin = ctx.previewNonAdmin and true or false,
        guildKey = ctx.guildKey,
        rankOrder = ctx.rankOrder,
        handleGeneration = ctx.handleGeneration,
    }

    if not ctx.guildKey then
        return result
    end

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

    if not ctx.ready then
        return result
    end

    if ctx.previewNonAdmin then
        result.canEdit = false
        result.reason = "preview_non_admin"
        return result
    end

    local mayEdit, editReason = GI.RankMayEdit(ctx.rankOrder, ctx.rankCount)
    if mayEdit then
        result.canEdit = true
        result.reason = nil
    else
        result.canEdit = false
        result.reason = editReason or "unauthorized"
    end
    return result
end

--- Recheck authority at mutation commit time.
-- @return boolean ok, string|nil reason, table|nil context
function GI:_AuthorizeCommit(opts)
    opts = opts or {}
    local ctx = GI:GetCurrentContext()
    if not ctx.ready then
        return false, ctx.reason or "not_ready", ctx
    end
    if opts.expectedGuildKey and ctx.guildKey ~= opts.expectedGuildKey then
        return false, "wrong_guild", ctx
    end
    if opts.expectedHandleGeneration
        and tonumber(opts.expectedHandleGeneration) ~= tonumber(ctx.handleGeneration) then
        return false, "stale_handle", ctx
    end
    if opts.expectedActorGuid and ctx.actorGuid ~= opts.expectedActorGuid then
        return false, "actor_changed", ctx
    end
    local caps = GI:GetCapabilities()
    if not caps.canEdit then
        return false, caps.reason or "unauthorized", ctx
    end
    return true, nil, ctx
end

--- Resolve transport sender to verified guild member (never trusts payload claims).
-- @return table|nil member, string|nil reason
function GI.AuthenticateTransportSender(senderName)
    local GG = SF.GuildGossip
    if not GG or not GG.GetGuildMember then
        return nil, "not_ready"
    end
    if type(senderName) ~= "string" or senderName == "" then
        return nil, "invalid_sender"
    end
    local member, reason = GG.GetGuildMember(senderName)
    if not member then
        return nil, reason or "unknown_sender"
    end
    if type(member.guid) ~= "string" or member.guid == "" then
        return nil, "sender_guid_unavailable"
    end
    if type(member.rankOrder) ~= "number" then
        return nil, "rank_unavailable"
    end
    if type(member.guildKey) ~= "string" or not GI.ParseGuildKey(member.guildKey) then
        return nil, "wrong_guild"
    end
    return member, nil
end

--- Whether a verified member currently meets Guild Info editor authority.
function GI.SenderHasEditorAuthority(member)
    if type(member) ~= "table" or type(member.rankOrder) ~= "number" then
        return false, "unauthorized"
    end
    local GG = SF.GuildGossip
    local identity = GG and GG.GetGuildIdentity and GG.GetGuildIdentity()
    if not identity or member.guildKey ~= identity.guildKey then
        return false, "wrong_guild"
    end
    local ranks = GG and GG.GetGuildRanks and GG.GetGuildRanks()
    local rankCount = type(ranks) == "table" and tonumber(ranks.count) or nil
    if not rankCount or rankCount < 1 then
        return false, "rank_unavailable"
    end
    local mayEdit, editReason = GI.RankMayEdit(member.rankOrder, rankCount)
    if mayEdit then
        return true, nil
    end
    return false, editReason or "unauthorized"
end
