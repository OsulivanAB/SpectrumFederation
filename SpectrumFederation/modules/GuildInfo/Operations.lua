-- Guild Info local mutation APIs (#402).
local addonName, SF = ...

SF.GuildInfo = SF.GuildInfo or {}
local GI = SF.GuildInfo

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default or key
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

local function CharacterSnapshot(guid, nameRealm, classFile)
    return {
        guid = guid,
        nameRealm = nameRealm,
        classFile = classFile,
    }
end

--- Format mutation feedback for Settings banners (never Chat).
function GI.FormatMutationFeedback(status, reason)
    status = tostring(status or "rejected")
    reason = reason and tostring(reason) or ""
    if status == "accepted" then
        return Loc("GUILD_INFO_STATUS_ACCEPTED", "Assignment updated."), "success"
    end
    if status == "duplicate" then
        return Loc("GUILD_INFO_STATUS_DUPLICATE", "No change — that relationship was already recorded."), "info"
    end
    if status == "pending" then
        return Loc("GUILD_INFO_STATUS_PENDING", "Change is pending (%s)."):format(reason ~= "" and reason or "wait"), "warn"
    end

    if status == "accepted" and reason == "noop" then
        return Loc("GUILD_INFO_STATUS_DUPLICATE", "No change — that relationship was already recorded."), "info"
    end
    local map = {
        unauthorized = Loc("GUILD_INFO_ERR_UNAUTHORIZED", "Only guild ranks 1–3 may change main/alt assignments."),
        preview_non_admin = Loc("GUILD_INFO_ERR_PREVIEW", "Preview as Non-Admin is active; edits are disabled."),
        not_ready = Loc("GUILD_INFO_ERR_NOT_READY", "Guild membership or rank information is not ready yet."),
        roster_incomplete = Loc("GUILD_INFO_ERR_ROSTER_INCOMPLETE", "Guild roster is incomplete. Try again when the roster finishes loading."),
        roster_unavailable = Loc("GUILD_INFO_ERR_ROSTER_UNAVAILABLE", "Guild roster is unavailable."),
        not_a_member = Loc("GUILD_INFO_ERR_NOT_MEMBER", "That character is not a current guild member."),
        ambiguous_name = Loc("GUILD_INFO_ERR_AMBIGUOUS", "That name matches more than one guild member. Select a suggestion or use Name-Realm."),
        same_character = Loc("GUILD_INFO_ERR_SAME_CHARACTER", "Main and alt must be different characters."),
        identity_unavailable = Loc("GUILD_INFO_ERR_IDENTITY", "A stable character identity could not be established."),
        guid_unavailable = Loc("GUILD_INFO_ERR_GUID", "Character GUID is unavailable; cannot assign safely."),
        alt_is_main_with_alts = Loc("GUILD_INFO_ERR_ALT_IS_MAIN", "That character is already a main with alts. Use Change Main or unassign its alts first."),
        main_is_alt = Loc("GUILD_INFO_ERR_MAIN_IS_ALT", "That character is already an alt of another main. Choose a different main or use Change Main."),
        move_confirmation_required = Loc("GUILD_INFO_ERR_MOVE_CONFIRM", "Moving an alt to a different main requires confirmation."),
        stale_move_confirmation = Loc("GUILD_INFO_ERR_STALE_MOVE", "That move is no longer valid — the relationship changed. Review and try again."),
        stale_unassign = Loc("GUILD_INFO_ERR_STALE_UNASSIGN", "That alt is no longer under the expected main."),
        stale_change_main = Loc("GUILD_INFO_ERR_STALE_CHANGE_MAIN", "That Change Main candidate is no longer eligible."),
        alt_not_assigned = Loc("GUILD_INFO_ERR_ALT_NOT_ASSIGNED", "That character is not currently an assigned alt."),
        group_missing = Loc("GUILD_INFO_ERR_GROUP_MISSING", "That main/alt group no longer exists."),
        group_full = Loc("GUILD_INFO_ERR_GROUP_FULL", "That main already has the maximum number of alts."),
        no_effect = Loc("GUILD_INFO_ERR_NO_EFFECT", "That change could not be applied to the current relationships."),
        wrong_guild = Loc("GUILD_INFO_ERR_WRONG_GUILD", "Guild context changed; the action was not applied."),
        stale_handle = Loc("GUILD_INFO_ERR_STALE_HANDLE", "Guild context changed; the action was not applied."),
        actor_changed = Loc("GUILD_INFO_ERR_ACTOR_CHANGED", "Your character identity changed; the action was not applied."),
        not_in_guild = Loc("GUILD_INFO_ERR_NOT_IN_GUILD", "You are not currently in a guild."),
        target_not_rostered = Loc("GUILD_INFO_ERR_TARGET_NOT_ROSTERED", "New assignments require currently rostered guild members."),
        ops_overflow = Loc("GUILD_INFO_ERR_OPS_OVERFLOW", "Too many pending relationship operations."),
    }
    local msg = map[reason]
    if msg then
        return msg, "error"
    end
    if reason ~= "" then
        return Loc("GUILD_INFO_STATUS_REJECTED", "Change was not applied (%s)."):format(reason), "error"
    end
    return Loc("GUILD_INFO_STATUS_REJECTED_GENERIC", "Change was not applied."), "error"
end

local function ResolveRosterTarget(nameOrGuid, roster)
    if type(roster) ~= "table" or type(roster.Resolve) ~= "function" then
        return nil, "roster_unavailable"
    end
    return roster:Resolve(nameOrGuid)
end

local function BuildAssignOp(ctx, mainRow, altRow)
    local id, idErr = GI:_AllocateOperationId(ctx.actorGuid)
    if not id then
        return nil, idErr
    end
    return {
        id = id,
        kind = GI.KIND.ASSIGN,
        at = Now(),
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        guildKey = ctx.guildKey,
        mainGuid = mainRow.guid,
        mainName = mainRow.nameRealm,
        mainClass = mainRow.classFile,
        altGuid = altRow.guid,
        altName = altRow.nameRealm,
        altClass = altRow.classFile,
    }
end

--- Assign alt under main. Requires verified roster targets for new links.
-- opts.moveConfirmed / opts.expectedOldMain for confirmed moves.
-- opts.roster = Guild Info roster snapshot helper.
function GI:AssignAlt(mainRef, altRef, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = GI:_AuthorizeCommit({
        expectedGuildKey = opts.expectedGuildKey,
        expectedHandleGeneration = opts.expectedHandleGeneration,
        expectedActorGuid = opts.expectedActorGuid,
    })
    if not okAuth then
        return "rejected", authReason
    end

    local roster = opts.roster
    if not roster and GI.GetRosterSnapshot then
        roster = GI.GetRosterSnapshot()
    end
    if not roster or not roster.complete then
        return "rejected", roster and roster.reason or "roster_incomplete"
    end

    local mainRow, mainErr = ResolveRosterTarget(mainRef, roster)
    if not mainRow then
        return "rejected", mainErr or "identity_unavailable"
    end
    local altRow, altErr = ResolveRosterTarget(altRef, roster)
    if not altRow then
        return "rejected", altErr or "identity_unavailable"
    end
    if mainRow.guid == altRow.guid then
        return "rejected", "same_character"
    end
    if not mainRow.inGuild or not altRow.inGuild then
        return "rejected", "target_not_rostered"
    end

    -- Ensure record exists.
    local record, recErr = GI:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", recErr
    end

    local byGuid = record.graph and record.graph.byGuid or {}
    local altInfo = byGuid[altRow.guid]
    local mainInfo = byGuid[mainRow.guid]

    -- Confirmed reassignment: verify expected previous main before noop/success (D.3).
    if opts.moveConfirmed and type(opts.expectedOldMain) == "string" and opts.expectedOldMain ~= "" then
        if not altInfo or altInfo.role ~= "alt" or altInfo.mainGuid ~= opts.expectedOldMain then
            return "rejected", "stale_move_confirmation"
        end
    end

    -- Genuine no-op: already under this main — do not append a durable op (D.4).
    if altInfo and altInfo.role == "alt" and altInfo.mainGuid == mainRow.guid then
        return "accepted", "noop"
    end

    if altInfo and altInfo.role == "main" then
        local g = record.graph.mains and record.graph.mains[altRow.guid]
        if g and type(g.altGuids) == "table" and #g.altGuids > 0 then
            return "rejected", "alt_is_main_with_alts"
        end
    end
    if mainInfo and mainInfo.role == "alt" then
        return "rejected", "main_is_alt"
    end

    local isMove = altInfo and altInfo.role == "alt" and altInfo.mainGuid ~= mainRow.guid
    if isMove and not opts.moveConfirmed then
        return "rejected", "move_confirmation_required", {
            oldMainGuid = altInfo.mainGuid,
            newMainGuid = mainRow.guid,
            altGuid = altRow.guid,
        }
    end

    local op, opErr = BuildAssignOp(ctx, mainRow, altRow)
    if not op then
        return "rejected", opErr
    end

    -- Refuse local writes that the deterministic fold would ignore (capacity / hierarchy).
    if GI.WouldAssignTakeEffect and not GI.WouldAssignTakeEffect(record, op) then
        local dest = record.graph.mains and record.graph.mains[mainRow.guid]
        if dest and #(dest.altGuids or {}) >= (GI.MAX_ALTS_PER_MAIN or 32) then
            return "rejected", "group_full"
        end
        return "rejected", "no_effect"
    end

    return GI:AdmitOperation(op, {
        requireMoveConfirm = isMove and true or false,
        moveConfirmed = opts.moveConfirmed and true or false,
        expectedOldMain = opts.expectedOldMain or (altInfo and altInfo.mainGuid) or nil,
        remote = false,
    })
end

function GI:UnassignAlt(altGuid, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = GI:_AuthorizeCommit({
        expectedGuildKey = opts.expectedGuildKey,
        expectedHandleGeneration = opts.expectedHandleGeneration,
        expectedActorGuid = opts.expectedActorGuid,
    })
    if not okAuth then
        return "rejected", authReason
    end
    if type(altGuid) ~= "string" or altGuid == "" then
        return "rejected", "identity_unavailable"
    end

    local record, recErr = GI:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", recErr
    end
    local info = record.graph and record.graph.byGuid and record.graph.byGuid[altGuid]
    if not info or info.role ~= "alt" then
        return "rejected", "alt_not_assigned"
    end

    local crow = record.characters and record.characters[altGuid]
    local mrow = record.characters and record.characters[info.mainGuid]
    local id, idErr = GI:_AllocateOperationId(ctx.actorGuid)
    if not id then
        return "rejected", idErr
    end
    local op = {
        id = id,
        kind = GI.KIND.UNASSIGN,
        at = Now(),
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        guildKey = ctx.guildKey,
        mainGuid = info.mainGuid,
        mainName = mrow and mrow.nameRealm or nil,
        mainClass = mrow and mrow.classFile or nil,
        altGuid = altGuid,
        altName = crow and crow.nameRealm or nil,
        altClass = crow and crow.classFile or nil,
    }
    return GI:AdmitOperation(op, { remote = false })
end

function GI:ChangeMain(oldMainGuid, newMainGuid, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = GI:_AuthorizeCommit({
        expectedGuildKey = opts.expectedGuildKey,
        expectedHandleGeneration = opts.expectedHandleGeneration,
        expectedActorGuid = opts.expectedActorGuid,
    })
    if not okAuth then
        return "rejected", authReason
    end
    if type(oldMainGuid) ~= "string" or type(newMainGuid) ~= "string" then
        return "rejected", "identity_unavailable"
    end
    if oldMainGuid == newMainGuid then
        return "rejected", "same_character"
    end

    -- New main must be currently rostered (ticket: Change Main candidates are rostered alts).
    local roster = opts.roster
    if not roster and GI.GetRosterSnapshot then
        roster = GI.GetRosterSnapshot()
    end
    if not roster or not roster.complete then
        return "rejected", roster and roster.reason or "roster_incomplete"
    end
    local newRow = roster.byGuid and roster.byGuid[newMainGuid]
    if not newRow or not newRow.inGuild then
        return "rejected", "target_not_rostered"
    end

    local record, recErr = GI:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", recErr
    end

    local mrow = record.characters and record.characters[oldMainGuid]
    local id, idErr = GI:_AllocateOperationId(ctx.actorGuid)
    if not id then
        return "rejected", idErr
    end
    local op = {
        id = id,
        kind = GI.KIND.CHANGE_MAIN,
        at = Now(),
        actorGuid = ctx.actorGuid,
        actorName = ctx.actorName,
        guildKey = ctx.guildKey,
        mainGuid = oldMainGuid,
        mainName = mrow and mrow.nameRealm or nil,
        mainClass = mrow and mrow.classFile or nil,
        newMainGuid = newMainGuid,
        newMainName = newRow.nameRealm,
        newMainClass = newRow.classFile,
    }
    return GI:AdmitOperation(op, { remote = false })
end
