-- Raid Signup authority (#404).
-- Officers manage plans and may edit any entry. Members edit only their own.
-- Nickname is never used for authorization.
local addonName, SF = ...

SF.RaidSignup = SF.RaidSignup or {}
local RS = SF.RaidSignup

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

function RS:GetCurrentContext()
    local GG = SF.GuildGossip
    if not GG or type(GG.GetGuildIdentity) ~= "function" then
        return {
            ready = false,
            reason = "identity_unavailable",
            handleGeneration = RS.GetHandleGeneration(),
        }
    end

    local identity, idReason = GG.GetGuildIdentity()
    if not identity then
        RS:_TrackGuildKey(nil)
        return {
            ready = false,
            reason = idReason or "not_ready",
            handleGeneration = RS.GetHandleGeneration(),
        }
    end
    RS:_TrackGuildKey(identity.guildKey)

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
        handleGeneration = RS.GetHandleGeneration(),
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

function RS.RankIsOfficer(rankOrder, rankCount)
    local GO = SF.GuildOfficer
    if not GO or type(GO.RankMeetsThreshold) ~= "function" then
        return false, "policy_unknown"
    end
    return GO:RankMeetsThreshold(rankOrder, rankCount)
end

function RS:GetCapabilities()
    local ctx = RS:GetCurrentContext()
    local result = {
        canRead = false,
        canCreateEntry = false,
        canManagePlans = false,
        canEditAnyEntry = false,
        reason = ctx.reason or "not_ready",
        previewNonAdmin = ctx.previewNonAdmin and true or false,
        guildKey = ctx.guildKey,
        actorGuid = ctx.actorGuid,
        rankOrder = ctx.rankOrder,
        handleGeneration = ctx.handleGeneration,
    }

    if not ctx.guildKey then
        return result
    end

    if ctx.membershipReady then
        result.canRead = true
        result.canCreateEntry = true
        if not ctx.ready then
            result.reason = ctx.reason or "rank_unavailable"
        else
            result.reason = nil
        end
    else
        result.reason = ctx.reason or "not_ready"
        return result
    end

    if ctx.previewNonAdmin then
        result.canCreateEntry = true
        result.canManagePlans = false
        result.canEditAnyEntry = false
        result.reason = "preview_non_admin"
        return result
    end

    if not ctx.ready then
        return result
    end

    local isOfficer, officerReason = RS.RankIsOfficer(ctx.rankOrder, ctx.rankCount)
    if isOfficer then
        result.canManagePlans = true
        result.canEditAnyEntry = true
        result.reason = nil
    else
        result.canManagePlans = false
        result.canEditAnyEntry = false
        if officerReason == "policy_unknown" or officerReason == "policy_invalid" then
            result.reason = officerReason
        end
    end
    return result
end

function RS.CanEditEntry(caps, actorGuid, entry)
    if type(entry) ~= "table" then
        return false, "missing_entry"
    end
    if type(caps) ~= "table" then
        return false, "unauthorized"
    end
    if caps.canEditAnyEntry then
        return true
    end
    if type(actorGuid) == "string" and actorGuid ~= "" and entry.creatorGuid == actorGuid then
        return true
    end
    return false, "unauthorized"
end

function RS:_AuthorizeMembership(opts)
    opts = opts or {}
    local ctx = RS:GetCurrentContext()
    if not ctx.membershipReady then
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
    if ctx.previewNonAdmin and opts.requireOfficer then
        return false, "preview_non_admin", ctx
    end
    return true, nil, ctx
end

function RS:_AuthorizeOfficer(opts)
    local ok, reason, ctx = RS:_AuthorizeMembership(opts)
    if not ok then
        return false, reason, ctx
    end
    if not ctx.ready then
        return false, ctx.reason or "rank_unavailable", ctx
    end
    if ctx.previewNonAdmin then
        return false, "preview_non_admin", ctx
    end
    local isOfficer, officerReason = RS.RankIsOfficer(ctx.rankOrder, ctx.rankCount)
    if not isOfficer then
        return false, officerReason or "unauthorized", ctx
    end
    return true, nil, ctx
end

function RS.AuthenticateTransportSender(senderName)
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
    if type(member.guildKey) ~= "string" or not RS.ParseGuildKey(member.guildKey) then
        return nil, "wrong_guild"
    end
    return member, nil
end

function RS.SenderHasOfficerAuthority(member)
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
    return RS.RankIsOfficer(member.rankOrder, rankCount)
end

function RS.SenderMayMutateEntry(member, entryCreatorGuid)
    local officer, officerReason = RS.SenderHasOfficerAuthority(member)
    if officer then
        return true, nil
    end
    if type(member) == "table"
        and type(member.guid) == "string"
        and member.guid ~= ""
        and member.guid == entryCreatorGuid then
        return true, nil
    end
    if officerReason == "policy_unknown" or officerReason == "policy_invalid" or officerReason == "rank_unavailable" then
        -- Still allow creator self-mutations when officer policy is unknown,
        -- matching local member create rights.
        if type(member) == "table" and member.guid == entryCreatorGuid then
            return true, nil
        end
    end
    return false, "relay_lacks_authority"
end
