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

--- Format mutation feedback for Settings banners (never Chat).
function GI.FormatMutationFeedback(status, reason)
    status = tostring(status or "rejected")
    reason = reason and tostring(reason) or ""
    if status == "accepted" and reason == "noop" then
        return Loc("GUILD_INFO_STATUS_DUPLICATE", "No change — that relationship was already recorded."), "info"
    end
    if status == "accepted" and reason == "cleanup_done" then
        return Loc("GUILD_INFO_STATUS_CLEANUP_DONE", "Obsolete Guild Info history was cleaned up. Active relationships were preserved."), "success"
    end
    if status == "accepted" and reason == "cleanup_noop" then
        return Loc("GUILD_INFO_STATUS_CLEANUP_NOOP", "No obsolete Guild Info history to remove."), "info"
    end
    if status == "accepted" then
        return Loc("GUILD_INFO_STATUS_ACCEPTED", "Assignment updated."), "success"
    end
    if status == "duplicate" then
        return Loc("GUILD_INFO_STATUS_DUPLICATE", "No change — that relationship was already recorded."), "info"
    end
    if status == "pending" then
        return Loc("GUILD_INFO_STATUS_PENDING", "Change is pending (%s)."):format(reason ~= "" and reason or "wait"), "warn"
    end

    local map = {
        unauthorized = Loc("GUILD_INFO_ERR_UNAUTHORIZED", "Your guild rank cannot change main/alt assignments."),
        policy_unknown = Loc("GUILD_INFO_ERR_POLICY_UNKNOWN", "Officer rank is not available yet, so Guild Info edits are disabled."),
        policy_invalid = Loc("GUILD_INFO_ERR_POLICY_INVALID", "Officer rank needs Guild Master recovery before Guild Info can be edited."),
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
        members_overflow = Loc("GUILD_INFO_ERR_MEMBERS_OVERFLOW", "Guild Info has reached its retained-character limit (active assignments plus unassigned history). New characters cannot be added until an existing retained identity is reused; unassigned history is not deleted automatically."),
        groups_overflow = Loc("GUILD_INFO_ERR_GROUPS_OVERFLOW", "Guild Info could not create another relationship group after reclaiming unused groups. Remove unused assignments and try again."),
        ops_overflow = Loc("GUILD_INFO_ERR_OPS_OVERFLOW", "Too many pending relationship operations."),
        stale_generation = Loc("GUILD_INFO_ERR_STALE_GENERATION", "That change belongs to an older Guild Info history generation and was discarded."),
        generation_syncing = Loc("GUILD_INFO_ERR_GENERATION_SYNCING", "Guild Info is synchronizing a newer history generation. Try again when sync finishes."),
        generation_pending = Loc("GUILD_INFO_ERR_GENERATION_PENDING", "A newer Guild Info history generation was announced; wait for its baseline to arrive."),
        cleanup_no_capacity = Loc("GUILD_INFO_ERR_CLEANUP_NO_CAPACITY", "Cleanup cannot free capacity because every retained slot is part of an active relationship. Unassign unused alts first."),
        cleanup_failed = Loc("GUILD_INFO_ERR_CLEANUP_FAILED", "Cleanup could not rebuild a valid baseline."),
        cleanup_invalid = Loc("GUILD_INFO_ERR_CLEANUP_INVALID", "Cleanup produced an invalid relationship baseline and was aborted."),
        cleanup_serialize = Loc("GUILD_INFO_ERR_CLEANUP_SERIALIZE", "Cleanup could not serialize the new baseline for Guild Gossip and was aborted."),
        cleanup_active_overflow = Loc("GUILD_INFO_ERR_CLEANUP_ACTIVE_OVERFLOW", "Active relationships alone exceed Guild Info capacity; cleanup cannot proceed."),
        cleanup_incomplete_member = Loc("GUILD_INFO_ERR_CLEANUP_INCOMPLETE", "Cleanup could not faithfully represent every active relationship and was aborted."),
        cleanup_relationship_mismatch = Loc("GUILD_INFO_ERR_CLEANUP_MISMATCH", "Cleanup would omit an active relationship and was aborted."),
        cleanup_forward_cycle = Loc("GUILD_INFO_ERR_CLEANUP_FORWARD_CYCLE", "Cleanup aborted: concurrent forwarding aliases still conflict. Resolve the overlapping assignments first."),
        generation_exhausted = Loc("GUILD_INFO_ERR_GENERATION_EXHAUSTED", "Guild Info cannot advance its history generation further on this client."),
        invalid_generation = Loc("GUILD_INFO_ERR_INVALID_GENERATION", "That Guild Info history generation is invalid and was rejected."),
        unsupported_schema = Loc("GUILD_INFO_ERR_UNSUPPORTED_SCHEMA", "Saved Guild Info data uses a newer schema this version cannot safely read."),
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

--- Assign alt under main. Requires verified roster targets for new links.
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
        return "rejected", mainErr or "not_a_member"
    end
    local altRow, altErr = ResolveRosterTarget(altRef, roster)
    if not altRow then
        return "rejected", altErr or "not_a_member"
    end
    if mainRow.guid == altRow.guid then
        return "rejected", "same_character"
    end
    if not mainRow.inGuild or not altRow.inGuild then
        return "rejected", "target_not_rostered"
    end

    local record = select(1, GI:EnsureGuildRecord(ctx.guildKey))
    local altInfo = record and record.graph and record.graph.byGuid and record.graph.byGuid[altRow.guid]
    local requireMove = altInfo and altInfo.role == "alt" and altInfo.mainGuid ~= mainRow.guid
    local status, detail, meta = GI:ApplyAssign(mainRow.guid, altRow.guid, {
        guildKey = ctx.guildKey,
        mainName = mainRow.nameRealm,
        mainClass = mainRow.classFile,
        altName = altRow.nameRealm,
        altClass = altRow.classFile,
        requireMoveConfirm = requireMove and not opts.moveConfirmed,
        moveConfirmed = opts.moveConfirmed,
        expectedOldMain = opts.expectedOldMain,
    })
    if status == "rejected" and detail == "move_confirmation_required" then
        return status, detail, meta or { oldMainGuid = altInfo and altInfo.mainGuid }
    end
    return status, detail, meta
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
    return GI:ApplyUnassign(altGuid, {
        guildKey = ctx.guildKey,
        expectedMainGuid = opts.expectedMainGuid,
    })
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

    return GI:ApplyChangeMain(oldMainGuid, newMainGuid, { guildKey = ctx.guildKey })
end

--- Officer-controlled history cleanup (Option B). Preserves active relationships.
function GI:CleanupHistory(opts)
    opts = opts or {}
    local okAuth, authReason, ctx = GI:_AuthorizeCommit({
        expectedGuildKey = opts.expectedGuildKey,
        expectedHandleGeneration = opts.expectedHandleGeneration,
        expectedActorGuid = opts.expectedActorGuid,
    })
    if not okAuth then
        return "rejected", authReason
    end
    local status, detail, meta = GI:ApplyCleanupHistory({ guildKey = ctx.guildKey })
    if status == "accepted" and detail == nil then
        return "accepted", "cleanup_done", meta
    end
    return status, detail, meta
end

function GI:PreviewCleanup(opts)
    opts = opts or {}
    local record
    if opts.guildKey then
        record = select(1, GI:EnsureGuildRecord(opts.guildKey))
    else
        record = select(1, GI:GetCurrentRecord())
    end
    return GI.PreviewCleanupHistory(record)
end
