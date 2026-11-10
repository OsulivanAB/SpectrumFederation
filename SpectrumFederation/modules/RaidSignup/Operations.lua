-- Raid Signup local mutation APIs (#404).
local addonName, SF = ...

SF.RaidSignup = SF.RaidSignup or {}
local RS = SF.RaidSignup

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default or key
end

local function Notify(reason)
    if RS.NotifyLocalDurableChange then
        RS.NotifyLocalDurableChange(reason or "local")
    end
end

local function CurrentRecord(opts)
    opts = opts or {}
    local ctx = RS:GetCurrentContext()
    if not ctx.membershipReady or not ctx.guildKey then
        return nil, nil, ctx.reason or "not_ready", ctx
    end
    local record, root, err = RS:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return nil, nil, err or "not_ready", ctx
    end
    return record, root, nil, ctx
end

--- Ephemeral draft helpers (UI/tests). Never persist incomplete drafts.
function RS.MakeDraft(planId)
    return {
        planId = planId,
        nickname = "",
        nicknameCommitted = false,
        classFile = nil,
        specId = nil,
        notes = "",
        phase = "class", -- class | spec | complete
    }
end

function RS.MakeAltDraft(entry)
    return {
        entryId = entry and entry.entryId or nil,
        planId = entry and entry.planId or nil,
        nickname = entry and entry.nickname or "",
        classFile = nil,
        specId = nil,
        mainClass = entry and entry.mainClass or nil,
        mainSpec = entry and entry.mainSpec or nil,
        phase = "class",
    }
end

function RS.DraftIsComplete(draft)
    if type(draft) ~= "table" then
        return false
    end
    return RS.IsCompleteEntryPayload(draft.nickname, draft.classFile, draft.specId)
end

--- True when nickname+class+spec are filled and the nickname input was committed
-- (Enter / focus-loss). Typing the first character after class/spec must not save.
function RS.DraftReadyToPersist(draft)
    if not RS.DraftIsComplete(draft) then
        return false
    end
    return draft.nicknameCommitted == true
end

function RS.CommitDraftNickname(draft)
    if type(draft) ~= "table" then
        return draft, false
    end
    local nick = type(draft.nickname) == "string" and draft.nickname or ""
    if strtrim then
        nick = strtrim(nick)
    else
        nick = (nick:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    draft.nickname = nick
    draft.nicknameCommitted = nick ~= ""
    return draft, draft.nicknameCommitted
end

function RS.AltDraftIsComplete(draft)
    if type(draft) ~= "table" then
        return false
    end
    if not draft.classFile or not draft.specId then
        return false
    end
    local _, _, err = RS.ValidateAlternative(draft.mainClass, draft.mainSpec, draft.classFile, draft.specId)
    return err == nil
end

--- Apply class/spec/nickname to a draft. Completeness is independent of input order.
-- Nickname text edits clear nicknameCommitted until CommitDraftNickname.
function RS.UpdateDraftField(draft, field, value)
    if type(draft) ~= "table" then
        return draft, false
    end
    if field == "nickname" then
        draft.nickname = type(value) == "string" and value or ""
        draft.nicknameCommitted = false
    elseif field == "classFile" then
        draft.classFile = value
        draft.specId = nil
        draft.phase = "spec"
    elseif field == "specId" then
        draft.specId = tonumber(value)
        if draft.classFile and draft.specId then
            draft.phase = "complete"
        end
    elseif field == "notes" then
        draft.notes = type(value) == "string" and value or ""
    end
    local complete = RS.DraftIsComplete(draft)
    if complete then
        draft.phase = "complete"
    elseif draft.classFile and not draft.specId then
        draft.phase = "spec"
    elseif not draft.classFile then
        draft.phase = "class"
    end
    return draft, complete
end

function RS.UpdateAltDraftField(draft, field, value)
    if type(draft) ~= "table" then
        return draft, false
    end
    if field == "classFile" then
        draft.classFile = value
        draft.specId = nil
        draft.phase = "spec"
    elseif field == "specId" then
        draft.specId = tonumber(value)
    end
    local complete = RS.AltDraftIsComplete(draft)
    if complete then
        draft.phase = "complete"
    elseif draft.classFile and not draft.specId then
        draft.phase = "spec"
    else
        draft.phase = "class"
    end
    return draft, complete
end

function RS.IsAltSpecDisabled(draft, specId)
    if type(draft) ~= "table" then
        return false
    end
    return draft.classFile
        and draft.mainClass
        and string.upper(tostring(draft.classFile)) == string.upper(tostring(draft.mainClass))
        and tonumber(specId) == tonumber(draft.mainSpec)
end

function RS.FormatMutationFeedback(status, reason)
    status = tostring(status or "rejected")
    reason = reason and tostring(reason) or ""
    if status == "accepted" then
        return Loc("RAID_SIGNUP_STATUS_ACCEPTED", "Raid Signup updated."), "success"
    end
    if status == "duplicate" then
        return Loc("RAID_SIGNUP_STATUS_DUPLICATE", "No change — already up to date."), "info"
    end

    local map = {
        unauthorized = Loc("RAID_SIGNUP_ERR_UNAUTHORIZED", "You are not allowed to make that change."),
        policy_unknown = Loc("RAID_SIGNUP_ERR_POLICY_UNKNOWN", "Officer rank is not available yet."),
        policy_invalid = Loc("RAID_SIGNUP_ERR_POLICY_INVALID", "Officer rank needs Guild Master recovery."),
        preview_non_admin = Loc("RAID_SIGNUP_ERR_PREVIEW", "Preview as Non-Admin is active for officer actions."),
        not_ready = Loc("RAID_SIGNUP_ERR_NOT_READY", "Guild membership is not ready yet."),
        plan_archived = Loc("RAID_SIGNUP_ERR_ARCHIVED", "That roster plan is archived and read-only."),
        plan_missing = Loc("RAID_SIGNUP_ERR_PLAN_MISSING", "That roster plan no longer exists."),
        incomplete = Loc("RAID_SIGNUP_ERR_INCOMPLETE", "Nickname, class, and spec are all required."),
        invalid_class = Loc("RAID_SIGNUP_ERR_CLASS", "Choose a valid class."),
        invalid_spec = Loc("RAID_SIGNUP_ERR_SPEC", "Choose a valid specialization for that class."),
        duplicate_spec = Loc("RAID_SIGNUP_ERR_DUP_SPEC", "The alternative cannot match the main class and spec."),
        stale_entry = Loc("RAID_SIGNUP_ERR_STALE", "That entry changed remotely. Your edit was not applied."),
        stale_plan = Loc("RAID_SIGNUP_ERR_STALE_PLAN", "That plan changed remotely. Your edit was not applied."),
        wrong_guild = Loc("RAID_SIGNUP_ERR_WRONG_GUILD", "Guild context changed; the action was not applied."),
        missing_entry = Loc("RAID_SIGNUP_ERR_MISSING_ENTRY", "That signup entry no longer exists."),
        plans_overflow = Loc("RAID_SIGNUP_ERR_PLANS_OVERFLOW", "The maximum number of roster plans has been reached."),
        entries_overflow = Loc("RAID_SIGNUP_ERR_ENTRIES_OVERFLOW", "The maximum number of signup entries has been reached."),
        empty_name = Loc("RAID_SIGNUP_ERR_EMPTY_NAME", "A non-blank name is required."),
        deleted_final = Loc("RAID_SIGNUP_ERR_DELETED_FINAL", "That signup entry was deleted and cannot be restored."),
        nickname_incomplete = Loc("RAID_SIGNUP_ERR_NICK_INCOMPLETE", "Finish typing the nickname, then press Enter."),
    }
    local msg = map[reason]
    if msg then
        return msg, "error"
    end
    if reason ~= "" then
        return Loc("RAID_SIGNUP_STATUS_REJECTED", "Change was not applied (%s)."):format(reason), "error"
    end
    return Loc("RAID_SIGNUP_STATUS_REJECTED_GENERIC", "Change was not applied."), "error"
end

function RS:CreatePlan(name, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = RS:_AuthorizeOfficer(opts)
    if not okAuth then
        return "rejected", authReason
    end
    local planName = RS.NormalizePlanName(name)
    if not planName then
        return "rejected", "empty_name"
    end
    local record, root, err = RS:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", err or "not_ready"
    end
    local ver, verErr = RS.AllocateVer(root, nil)
    if not ver then
        return "rejected", verErr or "revision_exhausted"
    end
    local plan = {
        planId = RS.NewId("plan"),
        name = planName,
        archived = false,
        createdBy = ctx.actorGuid,
        ver = ver,
        at = (GetServerTime and GetServerTime()) or (time and time()) or 0,
    }
    local status, detail = RS.MergePlan(record, plan, { remote = false })
    if status == "accepted" then
        record.selectedPlanId = plan.planId
        Notify("local")
    end
    return status, detail or plan.planId, plan.planId
end

function RS:RenamePlan(planId, name, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = RS:_AuthorizeOfficer(opts)
    if not okAuth then
        return "rejected", authReason
    end
    local planName = RS.NormalizePlanName(name)
    if not planName then
        return "rejected", "empty_name"
    end
    local record, root, err = RS:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", err or "not_ready"
    end
    local prev = record.plans[planId]
    if type(prev) ~= "table" then
        return "rejected", "plan_missing"
    end
    if prev.archived then
        return "rejected", "plan_archived"
    end
    if opts.expectedVer and RS.CompareVer(prev.ver, opts.expectedVer) ~= 0 then
        return "rejected", "stale_plan"
    end
    local ver = RS.AllocateVer(root, prev.ver)
    if not ver then
        return "rejected", "revision_exhausted"
    end
    local plan = RS.ClonePlan(prev)
    plan.name = planName
    plan.ver = ver
    plan.at = (GetServerTime and GetServerTime()) or (time and time()) or 0
    local status, detail = RS.MergePlan(record, plan, { remote = false })
    if status == "accepted" then
        Notify("local")
    end
    return status, detail
end

function RS:SetPlanArchived(planId, archived, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = RS:_AuthorizeOfficer(opts)
    if not okAuth then
        return "rejected", authReason
    end
    local record, root, err = RS:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", err or "not_ready"
    end
    local prev = record.plans[planId]
    if type(prev) ~= "table" then
        return "rejected", "plan_missing"
    end
    if opts.expectedVer and RS.CompareVer(prev.ver, opts.expectedVer) ~= 0 then
        return "rejected", "stale_plan"
    end
    local want = archived and true or false
    if (prev.archived and true or false) == want then
        return "duplicate", "noop"
    end
    local ver = RS.AllocateVer(root, prev.ver)
    if not ver then
        return "rejected", "revision_exhausted"
    end
    local plan = RS.ClonePlan(prev)
    plan.archived = want
    plan.ver = ver
    plan.at = (GetServerTime and GetServerTime()) or (time and time()) or 0
    local status, detail = RS.MergePlan(record, plan, { remote = false })
    if status == "accepted" then
        Notify("local")
    end
    return status, detail
end

function RS:SelectPlan(planId, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = RS:_AuthorizeMembership(opts)
    if not okAuth then
        return "rejected", authReason
    end
    local record, _, err = RS:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", err or "not_ready"
    end
    if planId ~= nil and type(record.plans[planId]) ~= "table" then
        return "rejected", "plan_missing"
    end
    record.selectedPlanId = planId
    -- Local UI preference only — not gossiped.
    if RS.NotifyUI then
        RS.NotifyUI("select")
    end
    return "accepted", "selected"
end

local function AssertPlanOpen(record, planId)
    local plan = record.plans[planId]
    if type(plan) ~= "table" then
        return nil, "plan_missing"
    end
    if plan.archived then
        return nil, "plan_archived"
    end
    return plan
end

function RS:UpsertEntry(fields, opts)
    opts = opts or {}
    fields = fields or {}
    local okAuth, authReason, ctx = RS:_AuthorizeMembership(opts)
    if not okAuth then
        return "rejected", authReason
    end
    local record, root, err = RS:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", err or "not_ready"
    end

    local planId = fields.planId or record.selectedPlanId
    local plan, planErr = AssertPlanOpen(record, planId)
    if not plan then
        return "rejected", planErr
    end

    local nickname = RS.NormalizeNickname(fields.nickname)
    local mainClass, mainSpec, selErr = RS.ValidateMainSelection(fields.mainClass, fields.mainSpec)
    if not nickname or selErr then
        return "rejected", selErr or "incomplete"
    end

    local notes = RS.NormalizeNotes(fields.notes)
    if notes == nil then
        return "rejected", "invalid_notes"
    end

    local altClass, altSpec = nil, nil
    if fields.clearAlt then
        altClass, altSpec = nil, nil
    elseif fields.altClass ~= nil or fields.altSpec ~= nil then
        local aClass, aSpec, altErr = RS.ValidateAlternative(mainClass, mainSpec, fields.altClass, fields.altSpec)
        if altErr then
            return "rejected", altErr
        end
        altClass, altSpec = aClass, aSpec
    end

    local entryId = fields.entryId
    local prev = entryId and record.entries[entryId] or nil
    if prev then
        if prev.deleted then
            return "rejected", "missing_entry"
        end
        local caps = RS:GetCapabilities()
        local mayEdit, mayReason = RS.CanEditEntry(caps, ctx.actorGuid, prev)
        if not mayEdit then
            return "rejected", mayReason or "unauthorized"
        end
        if opts.expectedVer and RS.CompareVer(prev.ver, opts.expectedVer) ~= 0 then
            return "rejected", "stale_entry"
        end
        -- Preserve alternative when not explicitly provided/cleared.
        if not fields.clearAlt and fields.altClass == nil and fields.altSpec == nil then
            altClass, altSpec = prev.altClass, prev.altSpec
            if altClass and altSpec and RS.SelectionEqual(mainClass, mainSpec, altClass, altSpec) then
                return "rejected", "duplicate_spec"
            end
        end
    else
        entryId = RS.NewId("entry")
        prev = nil
    end

    local ver = RS.AllocateVer(root, prev and prev.ver or nil)
    if not ver then
        return "rejected", "revision_exhausted"
    end

    local entry = {
        entryId = entryId,
        planId = planId,
        nickname = nickname,
        mainClass = mainClass,
        mainSpec = mainSpec,
        notes = notes,
        creatorGuid = prev and prev.creatorGuid or ctx.actorGuid,
        deleted = false,
        ver = ver,
        at = (GetServerTime and GetServerTime()) or (time and time()) or 0,
    }
    if altClass and altSpec then
        entry.altClass = altClass
        entry.altSpec = altSpec
    end

    local status, detail = RS.MergeEntry(record, entry, { remote = false })
    if status == "accepted" then
        Notify("local")
    end
    return status, detail, entryId
end

function RS:RemoveAlternative(entryId, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = RS:_AuthorizeMembership(opts)
    if not okAuth then
        return "rejected", authReason
    end
    local record, root, err = RS:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", err or "not_ready"
    end
    local prev = record.entries[entryId]
    if type(prev) ~= "table" or prev.deleted then
        return "rejected", "missing_entry"
    end
    local plan = record.plans[prev.planId]
    if type(plan) == "table" and plan.archived then
        return "rejected", "plan_archived"
    end
    local caps = RS:GetCapabilities()
    local mayEdit, mayReason = RS.CanEditEntry(caps, ctx.actorGuid, prev)
    if not mayEdit then
        return "rejected", mayReason or "unauthorized"
    end
    if not prev.altClass then
        return "duplicate", "noop"
    end
    if opts.expectedVer and RS.CompareVer(prev.ver, opts.expectedVer) ~= 0 then
        return "rejected", "stale_entry"
    end
    local ver = RS.AllocateVer(root, prev.ver)
    if not ver then
        return "rejected", "revision_exhausted"
    end
    local entry = {
        entryId = prev.entryId,
        planId = prev.planId,
        nickname = prev.nickname,
        mainClass = prev.mainClass,
        mainSpec = prev.mainSpec,
        notes = prev.notes or "",
        creatorGuid = prev.creatorGuid,
        deleted = false,
        ver = ver,
        at = (GetServerTime and GetServerTime()) or (time and time()) or 0,
    }
    local status, detail = RS.MergeEntry(record, entry, { remote = false })
    if status == "accepted" then
        Notify("local")
    end
    return status, detail
end

function RS:DeleteEntry(entryId, opts)
    opts = opts or {}
    local okAuth, authReason, ctx = RS:_AuthorizeMembership(opts)
    if not okAuth then
        return "rejected", authReason
    end
    local record, root, err = RS:EnsureGuildRecord(ctx.guildKey)
    if not record then
        return "rejected", err or "not_ready"
    end
    local prev = record.entries[entryId]
    if type(prev) ~= "table" or prev.deleted then
        return "rejected", "missing_entry"
    end
    local plan = record.plans[prev.planId]
    if type(plan) == "table" and plan.archived then
        return "rejected", "plan_archived"
    end
    local caps = RS:GetCapabilities()
    local mayEdit, mayReason = RS.CanEditEntry(caps, ctx.actorGuid, prev)
    if not mayEdit then
        return "rejected", mayReason or "unauthorized"
    end
    if opts.expectedVer and RS.CompareVer(prev.ver, opts.expectedVer) ~= 0 then
        return "rejected", "stale_entry"
    end
    local ver = RS.AllocateVer(root, prev.ver)
    if not ver then
        return "rejected", "revision_exhausted"
    end
    local tomb = RS.CloneEntry(prev)
    tomb.deleted = true
    tomb.ver = ver
    tomb.at = (GetServerTime and GetServerTime()) or (time and time()) or 0
    local status, detail = RS.MergeEntry(record, tomb, { remote = false, allowArchived = false })
    if status == "accepted" then
        Notify("local")
    end
    return status, detail
end

--- Convenience read helpers for UI/tests.
function RS:GetActiveGuildRecord()
    local ctx = RS:GetCurrentContext()
    if not ctx.guildKey then
        return nil, ctx.reason or "not_ready", ctx
    end
    local record, err = RS:EnsureGuildRecord(ctx.guildKey)
    return record, err, ctx
end

function RS:GetSelectedPlanId()
    local record = select(1, RS:GetActiveGuildRecord())
    return record and record.selectedPlanId or nil
end

function RS:GetSortedPlans(all)
    local record = select(1, RS:GetActiveGuildRecord())
    if not record then
        return {}
    end
    return RS.ListPlans(record, { all = all and true or false, includeArchived = all and true or false })
end

function RS:GetSortedEntries(planId)
    local record = select(1, RS:GetActiveGuildRecord())
    if not record then
        return {}
    end
    planId = planId or record.selectedPlanId
    if not planId then
        return {}
    end
    return RS.ListEntries(record, planId)
end

function RS:GetPlanSummary(planId)
    local record = select(1, RS:GetActiveGuildRecord())
    if not record then
        return RS.BuildSummary({})
    end
    planId = planId or record.selectedPlanId
    if not planId then
        return RS.BuildSummary({})
    end
    return RS.SummaryForPlan(record, planId)
end
