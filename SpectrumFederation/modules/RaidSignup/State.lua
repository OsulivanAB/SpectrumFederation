-- Raid Signup durable guild-keyed state (#404).
-- Versioned current-state plan + entry records. Drafts are never stored here.
local addonName, SF = ...

SF.RaidSignup = SF.RaidSignup or {}
local RS = SF.RaidSignup

RS.SCHEMA_VERSION = 1
RS.PROVIDER_ID = "sf.raidsignup.roster"
RS.PROVIDER_SCHEMA = 1
RS.MAX_PLANS = 32
RS.MAX_ENTRIES_PER_PLAN = 128
RS.MAX_ENTRIES = 512
RS.MAX_NICKNAME = 48
RS.MAX_NOTES = 160
RS.MAX_PLAN_NAME = 64
RS.MAX_ID = 64
RS.MAX_GUID = 64
RS.MAX_CLASS = 32
RS.MAX_EVENT_SEQ = 2147483647
RS.MAX_REV = 9007199254740990

RS._db = nil
RS._root = nil
RS._rootValid = false
RS._rootReason = "not_initialized"
RS._handleGeneration = 0
RS._lastGuildKey = nil

local function DebugInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Info("RAID_SIGNUP", fmt, ...)
    end
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("RAID_SIGNUP", fmt, ...)
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

local function NewWriterState()
    return { nonce = Hex8() .. Hex8() .. Hex8(), nextSeq = 1 }
end

local function IsValidWriterNonce(nonce)
    return type(nonce) == "string" and #nonce == 24 and nonce:match("^[0-9a-fA-F]+$") ~= nil
end

local function IsValidWriterState(writer)
    if type(writer) ~= "table" or not IsValidWriterNonce(writer.nonce) then
        return false
    end
    local seq = tonumber(writer.nextSeq)
    return seq and seq >= 1 and seq <= RS.MAX_EVENT_SEQ + 1
end

function RS.IsFiniteNonnegInt(n)
    n = tonumber(n)
    if not n or n ~= n or n < 0 or n == math.huge then
        return false
    end
    return math.floor(n) == n
end

local function IsFiniteNonnegInt(n)
    return RS.IsFiniteNonnegInt(n)
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

function RS.CompareVer(a, b)
    local an = (type(a) == "table" and tonumber(a.n)) or 0
    local bn = (type(b) == "table" and tonumber(b.n)) or 0
    if an < bn then return -1 end
    if an > bn then return 1 end
    local aw = (type(a) == "table" and tostring(a.w or "")) or ""
    local bw = (type(b) == "table" and tostring(b.w or "")) or ""
    if aw < bw then return -1 end
    if aw > bw then return 1 end
    return 0
end

local function ValidVer(ver)
    return type(ver) == "table"
        and IsFiniteNonnegInt(ver.n)
        and type(ver.w) == "string"
        and ver.w ~= ""
        and #ver.w <= 64
end

function RS.ParseGuildKey(guildKey)
    if type(guildKey) ~= "string" or guildKey == "" then
        return nil, nil, "invalid_guild_key"
    end
    local clubId = guildKey:match("^club:(%d+)$")
    if not clubId then
        return nil, nil, "invalid_guild_key"
    end
    return guildKey, clubId, nil
end

function RS.GetHandleGeneration()
    return RS._handleGeneration or 0
end

function RS:_TrackGuildKey(guildKey)
    if guildKey ~= RS._lastGuildKey then
        RS._lastGuildKey = guildKey
        RS._handleGeneration = (RS._handleGeneration or 0) + 1
    end
end

function RS.PlanRecordId(planId)
    return "rs-p:" .. tostring(planId)
end

function RS.EntryRecordId(entryId)
    return "rs-e:" .. tostring(entryId)
end

function RS.ParsePlanRecordId(recordId)
    if type(recordId) ~= "string" then
        return nil
    end
    return recordId:match("^rs%-p:(.+)$")
end

function RS.ParseEntryRecordId(recordId)
    if type(recordId) ~= "string" then
        return nil
    end
    return recordId:match("^rs%-e:(.+)$")
end

local function ClampString(s, maxLen)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return nil
    end
    if #s > maxLen then
        s = s:sub(1, maxLen)
    end
    return s
end

function RS.NormalizeNickname(nickname)
    return ClampString(nickname, RS.MAX_NICKNAME)
end

function RS.NormalizeNotes(notes)
    if notes == nil or notes == "" then
        return ""
    end
    if type(notes) ~= "string" then
        return nil
    end
    notes = notes:gsub("^%s+", ""):gsub("%s+$", "")
    if #notes > RS.MAX_NOTES then
        notes = notes:sub(1, RS.MAX_NOTES)
    end
    return notes
end

function RS.NormalizePlanName(name)
    return ClampString(name, RS.MAX_PLAN_NAME)
end

function RS.NewId(prefix)
    prefix = tostring(prefix or "id")
    return prefix .. "-" .. Hex8() .. Hex8()
end

--- Allocate the next version for a record edit.
-- n advances from the previous record revision (not a global counter) so local
-- edits remain newer than remotely admitted peers. w is this client's writer nonce.
function RS.AllocateVer(root, prevVer)
    if not root then
        return nil, "not_initialized"
    end
    if not IsValidWriterState(root.localWriter) then
        root.localWriter = NewWriterState()
    end
    local writer = root.localWriter
    local prevN = (type(prevVer) == "table" and tonumber(prevVer.n)) or 0
    local n = prevN + 1
    if n > RS.MAX_REV then
        return nil, "revision_exhausted"
    end
    -- Keep nextSeq as a monotonic local mint counter for NewId uniqueness only.
    local seq = tonumber(writer.nextSeq) or 1
    writer.nextSeq = seq + 1
    if writer.nextSeq > RS.MAX_EVENT_SEQ then
        root.localWriter = NewWriterState()
    end
    return { n = n, w = writer.nonce }, nil
end

local function ValidGuid(guid)
    return type(guid) == "string" and guid ~= "" and #guid <= RS.MAX_GUID
end

local function NormalizeClass(classFile)
    if type(classFile) ~= "string" or classFile == "" then
        return nil
    end
    classFile = string.upper(classFile)
    if #classFile > RS.MAX_CLASS then
        return nil
    end
    if not RS.IsKnownClass or not RS.IsKnownClass(classFile) then
        return nil
    end
    return classFile
end

function RS.SelectionEqual(aClass, aSpec, bClass, bSpec)
    return NormalizeClass(aClass) == NormalizeClass(bClass)
        and tonumber(aSpec) == tonumber(bSpec)
end

function RS.ValidateMainSelection(classFile, specId)
    classFile = NormalizeClass(classFile)
    specId = tonumber(specId)
    if not classFile then
        return nil, nil, "invalid_class"
    end
    if not RS.IsValidSpecForClass(classFile, specId) then
        return nil, nil, "invalid_spec"
    end
    return classFile, specId, nil
end

function RS.ValidateAlternative(mainClass, mainSpec, altClass, altSpec)
    local aClass, aSpec, err = RS.ValidateMainSelection(altClass, altSpec)
    if err then
        return nil, nil, err
    end
    if RS.SelectionEqual(mainClass, mainSpec, aClass, aSpec) then
        return nil, nil, "duplicate_spec"
    end
    return aClass, aSpec, nil
end

function RS.IsCompleteEntryPayload(nickname, classFile, specId)
    if not RS.NormalizeNickname(nickname) then
        return false
    end
    local c, s, err = RS.ValidateMainSelection(classFile, specId)
    return err == nil and c ~= nil and s ~= nil
end

local function CountLivePlans(record)
    local n = 0
    if type(record.plans) ~= "table" then
        return 0
    end
    for _, plan in pairs(record.plans) do
        if type(plan) == "table" and type(plan.planId) == "string" then
            n = n + 1
        end
    end
    return n
end

local function CountEntries(record, planId, liveOnly)
    local n = 0
    if type(record.entries) ~= "table" then
        return 0
    end
    for _, entry in pairs(record.entries) do
        if type(entry) == "table" and type(entry.entryId) == "string" then
            if not planId or entry.planId == planId then
                if not liveOnly or not entry.deleted then
                    n = n + 1
                end
            end
        end
    end
    return n
end

local function EmptyGuildRecord(guildKey, clubId)
    return {
        schemaVersion = RS.SCHEMA_VERSION,
        guildKey = guildKey,
        clubId = clubId,
        plans = {},
        entries = {},
        selectedPlanId = nil,
    }
end

local function EmptyRoot()
    return {
        schemaVersion = RS.SCHEMA_VERSION,
        localWriter = NewWriterState(),
        guilds = {},
    }
end

local function EnsureRootShape(root)
    if type(root) ~= "table" then
        return nil, "missing_root"
    end
    if tonumber(root.schemaVersion) ~= RS.SCHEMA_VERSION then
        return nil, "unsupported_schema"
    end
    if not IsValidWriterState(root.localWriter) then
        root.localWriter = NewWriterState()
    end
    if type(root.guilds) ~= "table" then
        root.guilds = {}
    end
    return root
end

function RS:Initialize(db)
    db = db or (type(SpectrumFederationDB) == "table" and SpectrumFederationDB) or nil
    if type(db) ~= "table" then
        RS._db = nil
        RS._root = nil
        RS._rootValid = false
        RS._rootReason = "db_unavailable"
        return false, "db_unavailable"
    end
    RS._db = db
    if type(db.raidSignup) ~= "table" then
        db.raidSignup = EmptyRoot()
        DebugInfo("created empty raidSignup root")
    end
    local existing = db.raidSignup
    local schema = tonumber(existing and existing.schemaVersion)
    if schema and schema > RS.SCHEMA_VERSION then
        RS._root = existing
        RS._rootValid = false
        RS._rootReason = "unsupported_schema"
        DebugWarn("raidSignup schema %s newer than supported %s", tostring(schema), tostring(RS.SCHEMA_VERSION))
        return false, "unsupported_schema"
    end
    if not schema or schema < RS.SCHEMA_VERSION then
        db.raidSignup = EmptyRoot()
        DebugWarn("reset raidSignup root to schema %s", tostring(RS.SCHEMA_VERSION))
    end
    local root, reason = EnsureRootShape(db.raidSignup)
    if not root then
        RS._root = db.raidSignup
        RS._rootValid = false
        RS._rootReason = reason or "invalid_root"
        return false, reason
    end
    RS._root = root
    RS._rootValid = true
    RS._rootReason = nil
    return true
end

function RS.GetRoot()
    if RS._rootValid and RS._root then
        return RS._root
    end
    return nil, RS._rootReason or "not_initialized"
end

function RS:EnsureGuildRecord(guildKey)
    local root, rootReason = RS.GetRoot()
    if not root then
        return nil, rootReason or "not_initialized"
    end
    local key, clubId, err = RS.ParseGuildKey(guildKey)
    if not key then
        return nil, err or "invalid_guild_key"
    end
    RS:_TrackGuildKey(key)
    local rec = root.guilds[key]
    if type(rec) ~= "table" then
        rec = EmptyGuildRecord(key, clubId)
        root.guilds[key] = rec
        DebugInfo("created empty raidSignup record key=%s", key)
    else
        rec.schemaVersion = RS.SCHEMA_VERSION
        rec.guildKey = key
        rec.clubId = clubId
        if type(rec.plans) ~= "table" then rec.plans = {} end
        if type(rec.entries) ~= "table" then rec.entries = {} end
    end
    return rec, root, nil
end

function RS.ClonePlan(plan)
    if type(plan) ~= "table" then
        return nil
    end
    return {
        planId = plan.planId,
        name = plan.name,
        archived = plan.archived and true or false,
        createdBy = plan.createdBy,
        ver = plan.ver and { n = plan.ver.n, w = plan.ver.w } or nil,
        at = tonumber(plan.at) or 0,
    }
end

function RS.CloneEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local out = {
        entryId = entry.entryId,
        planId = entry.planId,
        nickname = entry.nickname,
        mainClass = entry.mainClass,
        mainSpec = tonumber(entry.mainSpec),
        notes = entry.notes or "",
        creatorGuid = entry.creatorGuid,
        deleted = entry.deleted and true or false,
        ver = entry.ver and { n = entry.ver.n, w = entry.ver.w } or nil,
        at = tonumber(entry.at) or 0,
    }
    if entry.altClass and entry.altSpec then
        out.altClass = entry.altClass
        out.altSpec = tonumber(entry.altSpec)
    end
    return out
end

function RS.SanitizePlan(plan)
    if type(plan) ~= "table" then
        return nil, "malformed"
    end
    local planId = ClampString(plan.planId, RS.MAX_ID)
    local name = RS.NormalizePlanName(plan.name)
    if not planId or not name or not ValidVer(plan.ver) or not ValidGuid(plan.createdBy) then
        return nil, "malformed"
    end
    return {
        planId = planId,
        name = name,
        archived = plan.archived and true or false,
        createdBy = plan.createdBy,
        ver = { n = tonumber(plan.ver.n), w = tostring(plan.ver.w) },
        at = tonumber(plan.at) or 0,
    }, nil
end

function RS.SanitizeEntry(entry)
    if type(entry) ~= "table" then
        return nil, "malformed"
    end
    local entryId = ClampString(entry.entryId, RS.MAX_ID)
    local planId = ClampString(entry.planId, RS.MAX_ID)
    if not entryId or not planId or not ValidVer(entry.ver) or not ValidGuid(entry.creatorGuid) then
        return nil, "malformed"
    end
    if entry.deleted then
        return {
            entryId = entryId,
            planId = planId,
            nickname = RS.NormalizeNickname(entry.nickname) or "?",
            mainClass = NormalizeClass(entry.mainClass) or "WARRIOR",
            mainSpec = tonumber(entry.mainSpec) or 71,
            notes = RS.NormalizeNotes(entry.notes) or "",
            creatorGuid = entry.creatorGuid,
            deleted = true,
            ver = { n = tonumber(entry.ver.n), w = tostring(entry.ver.w) },
            at = tonumber(entry.at) or 0,
        }, nil
    end
    local nickname = RS.NormalizeNickname(entry.nickname)
    local mainClass, mainSpec, err = RS.ValidateMainSelection(entry.mainClass, entry.mainSpec)
    if not nickname or err then
        return nil, err or "incomplete"
    end
    local notes = RS.NormalizeNotes(entry.notes)
    if notes == nil then
        return nil, "invalid_notes"
    end
    local out = {
        entryId = entryId,
        planId = planId,
        nickname = nickname,
        mainClass = mainClass,
        mainSpec = mainSpec,
        notes = notes,
        creatorGuid = entry.creatorGuid,
        deleted = false,
        ver = { n = tonumber(entry.ver.n), w = tostring(entry.ver.w) },
        at = tonumber(entry.at) or 0,
    }
    if entry.altClass ~= nil or entry.altSpec ~= nil then
        local altClass, altSpec, altErr = RS.ValidateAlternative(mainClass, mainSpec, entry.altClass, entry.altSpec)
        if altErr then
            return nil, altErr
        end
        out.altClass = altClass
        out.altSpec = altSpec
    end
    return out, nil
end

function RS.MergePlan(record, plan, opts)
    opts = opts or {}
    local clean, err = RS.SanitizePlan(plan)
    if not clean then
        return "rejected", err or "malformed"
    end
    local prev = record.plans[clean.planId]
    if type(prev) == "table" and ValidVer(prev.ver) then
        local cmp = RS.CompareVer(clean.ver, prev.ver)
        if cmp < 0 then
            return "duplicate", "stale"
        end
        if cmp == 0 then
            return "duplicate", "same_ver"
        end
    else
        if CountLivePlans(record) >= RS.MAX_PLANS then
            return "rejected", "plans_overflow"
        end
    end
    record.plans[clean.planId] = clean
    if not record.selectedPlanId then
        record.selectedPlanId = clean.planId
    end
    return "accepted", opts.remote and "remote" or "local"
end

function RS.MergeEntry(record, entry, opts)
    opts = opts or {}
    local clean, err = RS.SanitizeEntry(entry)
    if not clean then
        return "rejected", err or "malformed"
    end
    local plan = record.plans[clean.planId]
    if type(plan) ~= "table" then
        return "rejected", "plan_missing"
    end
    -- Archived plans are read-only for content mutations. Tombstones still
    -- apply so stale deletes converge after archive.
    if plan.archived and not clean.deleted and not opts.allowArchived then
        return "rejected", "plan_archived"
    end

    local prev = record.entries[clean.entryId]
    if type(prev) == "table" and ValidVer(prev.ver) then
        local cmp = RS.CompareVer(clean.ver, prev.ver)
        if cmp < 0 then
            return "duplicate", "stale"
        end
        if cmp == 0 then
            return "duplicate", "same_ver"
        end
        -- Creator identity is immutable once established.
        if prev.creatorGuid and clean.creatorGuid ~= prev.creatorGuid then
            return "rejected", "creator_immutable"
        end
        clean.creatorGuid = prev.creatorGuid
        -- Resist resurrection: a live record must not undo a newer tombstone.
        -- (Higher ver already required above; if prev was deleted and incoming is
        -- live with higher ver, allow — that is an intentional recreate/edit path
        -- only when ver advances from an authorized writer.)
    else
        if not clean.deleted then
            if CountEntries(record, nil, false) >= RS.MAX_ENTRIES then
                return "rejected", "entries_overflow"
            end
            if CountEntries(record, clean.planId, true) >= RS.MAX_ENTRIES_PER_PLAN then
                return "rejected", "plan_entries_overflow"
            end
        end
    end

    record.entries[clean.entryId] = clean
    return "accepted", opts.remote and "remote" or "local"
end

function RS.ListPlans(record, opts)
    opts = opts or {}
    local out = {}
    if type(record) ~= "table" or type(record.plans) ~= "table" then
        return out
    end
    for _, plan in pairs(record.plans) do
        if type(plan) == "table" and type(plan.planId) == "string" then
            local include = opts.all or opts.includeArchived or (not plan.archived)
            if include then
                out[#out + 1] = RS.ClonePlan(plan)
            end
        end
    end
    table.sort(out, function(a, b)
        local an = string.lower(a.name or "")
        local bn = string.lower(b.name or "")
        if an == bn then
            return tostring(a.planId) < tostring(b.planId)
        end
        return an < bn
    end)
    return out
end

function RS.ListEntries(record, planId)
    local out = {}
    if type(record) ~= "table" or type(record.entries) ~= "table" then
        return out
    end
    for _, entry in pairs(record.entries) do
        if type(entry) == "table"
            and entry.planId == planId
            and not entry.deleted
            and type(entry.entryId) == "string" then
            out[#out + 1] = RS.CloneEntry(entry)
        end
    end
    table.sort(out, function(a, b)
        local an = string.lower(a.nickname or "")
        local bn = string.lower(b.nickname or "")
        if an == bn then
            return tostring(a.entryId) < tostring(b.entryId)
        end
        return an < bn
    end)
    return out
end

function RS.GetPlan(record, planId)
    if type(record) ~= "table" or type(record.plans) ~= "table" then
        return nil
    end
    local plan = record.plans[planId]
    return plan and RS.ClonePlan(plan) or nil
end

function RS.GetEntry(record, entryId)
    if type(record) ~= "table" or type(record.entries) ~= "table" then
        return nil
    end
    local entry = record.entries[entryId]
    return entry and RS.CloneEntry(entry) or nil
end

function RS.SummaryForPlan(record, planId)
    local entries = RS.ListEntries(record, planId)
    return RS.BuildSummary(entries)
end
