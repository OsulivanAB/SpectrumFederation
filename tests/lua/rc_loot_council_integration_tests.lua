-- Production-Lua tests for RC Loot Council Integration.
-- Run from the repository root: lua5.1 tests/lua/rc_loot_council_integration_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. message .. "\n")
end

local function assertTrue(cond, message)
    if cond then
        pass(message)
    else
        fail(message)
    end
end

local function assertFalse(cond, message)
    assertTrue(not cond, message)
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local PLAYER = "Tester-Garona"
local WINNER = "Winner-Garona"
local AWARDER = "RCMaster-Garona"
local ITEM_LINK = "|cffa335ee|Hitem:12345::::::::80:259:::::::::|h[Test Item]|h|r"
local HISTORY_ID = "1700000000-7"

function strtrim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

function string.trim(s)
    return strtrim(s)
end

function GetRealmName()
    return "Garona"
end

function UnitName(unit)
    if unit == "player" then
        return PLAYER:match("^([^%-]+)")
    end
    return "Unknown"
end

function UnitFullName(unit)
    if unit == "player" then
        return PLAYER:match("^([^%-]+)"), "Garona"
    end
    return "Unknown", "Garona"
end

function UnitClass()
    return "Warrior", "WARRIOR"
end

function GetServerTime()
    return 1700000999
end

function GetTime()
    return 0
end

CreateFrame = CreateFrame or function()
    local f = { scripts = {} }
    function f:SetScript(ev, fn) self.scripts[ev] = fn end
    function f:RegisterEvent() end
    function f:Show() end
    function f:Hide() end
    return f
end

hooksecurefunc = hooksecurefunc or function(tbl, name, hook)
    local original = tbl[name]
    tbl[name] = function(...)
        if original then
            original(...)
        end
        hook(...)
    end
end

SpectrumFederationDB = { lootHelper = { profiles = {}, syncSession = {}, window = {} } }
SpectrumFederationDebugDB = { enabled = false, logs = {} }

local SF = {}
local printed = {}

local function loadModule(relative)
    local chunk = assert(loadfile(relative))
    chunk("SpectrumFederation", SF)
end

loadModule("SpectrumFederation/modules/NameUtil.lua")
loadModule("SpectrumFederation/modules/core.lua")
loadModule("SpectrumFederation/modules/LootHelper/Members.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogValidators.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootLogs.lua")
loadModule("SpectrumFederation/modules/LootHelper/Profiles.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootHelper.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/02_State.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/05_Scheduling.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/12_LiveUpdates.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/16_ProfileIntegration.lua")

function SF:GetPlayerFullIdentifier()
    return PLAYER
end

function SF:GetPlayerClass()
    return "WARRIOR"
end

function SF:PrintWarning(message)
    printed[#printed + 1] = { "warn", tostring(message) }
end

function SF:PrintInfo(message)
    printed[#printed + 1] = { "info", tostring(message) }
end

function SF:SetActiveProfileById(profileId)
    local profile = SF.lootHelperDB.profiles[profileId]
    SF.lootHelperDB.activeProfileId = profileId
    SF.lootHelperDB.activeProfile = profile
    return profile
end

local Sync = SF.LootHelperSync

function Sync:FindLocalProfileById(profileId)
    return SF.lootHelperDB and SF.lootHelperDB.profiles and SF.lootHelperDB.profiles[profileId]
end

function Sync:_SelfId()
    return PLAYER
end

function Sync:LogSessionPointsSummary() end
function Sync:EnsureRepairConvergence() end
function Sync:_KickRepairConvergence() end
function Sync:RequestProfileSnapshot() end
function Sync:IsBulkTransferAllowed()
    return true
end
function Sync:IsSenderAuthorized()
    return true
end

local ns = {}
local integrationChunk = assert(loadfile("SpectrumFederation_RCLootCouncilIntegration/Integration.lua"))
integrationChunk("SpectrumFederation_RCLootCouncilIntegration", ns)
local Integration = ns.RCLootCouncilIntegration
_G.SpectrumFederation = SF

local function resetEnv()
    printed = {}
    PLAYER = "Tester-Garona"
    SF.lootHelperDB = {
        enabled = true,
        profiles = {},
        activeProfileId = nil,
        activeProfile = nil,
        window = {},
        syncSession = {},
    }
    SpectrumFederationDB.lootHelper = SF.lootHelperDB
    Sync.state = {
        active = false,
        sessionId = "SES1",
        profileId = nil,
        coordinator = PLAYER,
        isCoordinator = true,
        requests = {},
        helpers = {},
        repairQueue = { order = {}, items = {} },
        convergence = {},
    }
    Integration.ClearSessionMemory()
end

local function makeProfile(name)
    local profile = SF.LootProfile.new(name)
    assert(profile, "failed to create profile " .. tostring(name))
    SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
    return profile
end

local function addMember(profile, memberId)
    local member = SF.Member.new(memberId, "member", "WARRIOR")
    assert(member, "failed to create member " .. tostring(memberId))
    assert(profile:AddMember(member), "failed to add member " .. tostring(memberId))
    return member
end

local function setActive(profile)
    SF:SetActiveProfileById(profile:GetProfileId())
    Sync.state.profileId = profile:GetProfileId()
end

local function historyTable(overrides)
    local history = {
        id = HISTORY_ID,
        lootWon = ITEM_LINK,
        response = "Need",
        owner = "Owner-Garona",
        responseID = 1,
        isAwardReason = false,
    }
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            history[key] = value
        end
    end
    return history
end

local function countRCLogs(profile)
    local count = 0
    for _, log in ipairs(profile:GetLootLogs() or {}) do
        if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL then
            count = count + 1
        end
    end
    return count
end

local function queuedRepairCount()
    local queue = Sync.state and Sync.state.repairQueue
    if type(queue) ~= "table" or type(queue.order) ~= "table" then
        return 0
    end
    return #queue.order
end

-- ---------------------------------------------------------------------------
-- Identity helpers
-- ---------------------------------------------------------------------------
resetEnv()

local expectedKey = table.concat({
    "RCLootCouncil",
    AWARDER,
    HISTORY_ID,
    WINNER,
    "item:12345::::::::80:259:::::::::",
    "Owner-Garona",
}, "|")

assertEq(
    SF.LootLog.MakeRCAwardExternalId(AWARDER, HISTORY_ID, WINNER, ITEM_LINK, "Owner-Garona"),
    expectedKey,
    "canonical award key includes awarder, history id, winner, item string, and owner"
)
assertEq(
    SF.LootLog.MakeRCAwardExternalId(AWARDER, HISTORY_ID, WINNER, ITEM_LINK, "Owner-Garona"),
    SF.LootLog.MakeRCAwardExternalId(AWARDER, HISTORY_ID, WINNER, ITEM_LINK, "Owner-Garona"),
    "identity helper is deterministic for the same inputs"
)
assertTrue(
    SF.LootLog.MakeRCAwardExternalId(AWARDER, HISTORY_ID, WINNER, ITEM_LINK, "Owner-Garona")
        ~= SF.LootLog.MakeRCAwardExternalId(AWARDER, HISTORY_ID, WINNER, ITEM_LINK, "Other-Garona"),
    "owner participates in identity"
)
assertEq(
    SF.LootLog.ExtractItemString(ITEM_LINK),
    "item:12345::::::::80:259:::::::::",
    "item string is extracted from a colored item link"
)
assertEq(
    SF.LootLog.ExtractItemHyperlink(ITEM_LINK),
    ITEM_LINK,
    "colored item hyperlink is recovered for tooltip hover"
)
assertEq(
    SF.LootLog.ExtractItemHyperlink("Awarded " .. ITEM_LINK),
    ITEM_LINK,
    "item hyperlink can be recovered from surrounding Action text"
)
assertEq(SF.LootLog.ParseHistoryTimestamp(HISTORY_ID), 1700000000, "history.id prefix is the award timestamp")
assertEq(SF.LootLog.ParseHistoryTimestamp("nope"), nil, "non-numeric history ids do not invent a timestamp")

local localCanonical = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable())
local remoteCanonical = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable())
assertTrue(localCanonical ~= nil, "local history path builds a canonical award")
assertEq(localCanonical.awardKey, remoteCanonical.awardKey, "local ML and remote history share the same external identity")
assertEq(localCanonical.timestamp, 1700000000, "canonical timestamp comes from history.id, not GetServerTime")
assertEq(localCanonical.response, "Need", "original RC response casing is preserved")
assertEq(
    SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({ response = "Need" })).awardKey,
    SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({ response = "Greed" })).awardKey,
    "response label is audit data and is not part of identity"
)
assertEq(
    SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({ id = "bad-id" })),
    nil,
    "history.id without a numeric timestamp prefix is rejected"
)

-- ---------------------------------------------------------------------------
-- Profile recording, filters, permissions
-- ---------------------------------------------------------------------------
resetEnv()
local profile = makeProfile("RC Profile")
addMember(profile, WINNER)
setActive(profile)

local cfg = profile:GetRCLootCouncilIntegrationConfig()
assertTrue(cfg.recordAwards, "old/new profiles default to recording RC awards")
assertTrue(cfg.recordAllAwardTypes, "old/new profiles default to recording all award types")
assertEq(#cfg.allowedResponses, 0, "old/new profiles default to an empty allow-list")

local logCountBeforeSettings = #(profile:GetLootLogs() or {})
assertTrue(profile:SetRCLootCouncilRecordAwards(true), "admin can edit record-awards")
assertTrue(profile:SetRCLootCouncilRecordAllAwardTypes(true), "admin can edit record-all")
assertEq(#(profile:GetLootLogs() or {}), logCountBeforeSettings, "RC setting changes do not create Loot Log rows")

local ok, err = profile:TryAddRCLootCouncilAward(localCanonical)
assertTrue(ok, "admin writer records an eligible RC award")
assertEq(err, nil, "successful record has no error")
assertEq(countRCLogs(profile), 1, "one RC log is stored")

local stored = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL then
        stored = log
    end
end
assertTrue(stored ~= nil, "stored RC log exists")
assertEq(stored:GetID(), expectedKey, "external log id is the canonical award key")
assertEq(stored:GetCounter(), 0, "external logs use sentinel counter 0")
assertEq(stored:GetAuthor(), AWARDER, "Author is the RC awarder, not the Spectrum writer")
assertEq(stored:GetTimestamp(), 1700000000, "stored timestamp is the history.id prefix")
assertEq(stored:GetEventData().member, WINNER, "Member is the loot recipient")
assertEq(stored:GetEventData().itemLink, ITEM_LINK, "Action source is the item link")
assertEq(stored:GetEventData().response, "Need", "original response is persisted")
assertEq(stored._externalId, expectedKey, "wire table keeps _externalId")

local wire = stored:ToTable()
assertEq(wire._id, wire._externalId, "ToTable keeps _id equal to _externalId")
assertEq(wire._counter, 0, "ToTable keeps sentinel counter 0")
local okWire, wireErr = SF.LootLog.ValidateTable(wire)
assertTrue(okWire, "current validator accepts an external RC log")
assertEq(wireErr, nil, "valid external log has no validation error")

local oldClientShape = {}
for key, value in pairs(wire) do
    oldClientShape[key] = value
end
oldClientShape._externalId = nil
local oldOk, oldErr = SF.LootLog.ValidateTable(oldClientShape)
assertFalse(oldOk, "old clients without _externalId reject counter-0 logs")
assertTrue(type(oldErr) == "string" and oldErr:find("positive integer", 1, true) ~= nil, "old-client rejection names the sequential counter rule")

assertFalse(select(1, profile:TryAddRCLootCouncilAward(localCanonical)), "replay of the same award is a duplicate")
assertEq(countRCLogs(profile), 1, "replay does not duplicate the RC log")

profile:SetRCLootCouncilRecordAwards(false)
assertFalse(profile:ShouldRecordRCResponse("Need"), "logging disabled filters every response")
assertEq(select(2, profile:TryAddRCLootCouncilAward(SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({ id = "1700000100-1" })))), "filtered", "disabled recording rejects a new award")

profile:SetRCLootCouncilRecordAwards(true)
profile:SetRCLootCouncilRecordAllAwardTypes(false)
assertFalse(profile:ShouldRecordRCResponse("Need"), "empty allow-list records nothing when record-all is off")
assertTrue(profile:AddRCLootCouncilAllowedResponse("need"), "allow-list stores the trimmed value")
assertFalse(profile:AddRCLootCouncilAllowedResponse("Need"), "duplicate allow-list entries are rejected case-insensitively")
assertTrue(profile:ShouldRecordRCResponse("Need"), "allow-list matching is case-insensitive")
assertTrue(profile:ShouldRecordRCResponse(" need "), "allow-list matching trims RC labels")
assertFalse(profile:ShouldRecordRCResponse("Greed"), "non-matching allow-list values are filtered")
assertTrue(profile:AddRCLootCouncilAllowedResponse("BiS"), "custom RC labels can be allow-listed")
assertTrue(profile:ShouldRecordRCResponse("bis"), "custom labels match case-insensitively")

local greedCanonical = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
    id = "1700000200-2",
    response = "Greed",
}))
assertEq(select(2, profile:TryAddRCLootCouncilAward(greedCanonical)), "filtered", "non-matching allow-list award is not logged")

local needAgain = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
    id = "1700000300-3",
    response = "NEED",
}))
assertTrue(profile:TryAddRCLootCouncilAward(needAgain), "matching allow-list award is recorded")
local storedNeed = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL and log:GetEventData().rcAwardId == "1700000300-3" then
        storedNeed = log
    end
end
assertEq(storedNeed:GetEventData().response, "NEED", "original RC response casing is stored, not the allow-list casing")

local outsider = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, "Stranger-Garona", historyTable({ id = "1700000400-4" }))
assertEq(select(2, profile:TryAddRCLootCouncilAward(outsider)), "not_member", "non-profile recipients are not logged")

PLAYER = "NotAdmin-Garona"
local adminOnly = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({ id = "1700000500-5" }))
assertEq(select(2, profile:TryAddRCLootCouncilAward(adminOnly)), "not_admin", "non-admin Spectrum writers cannot create the log")
PLAYER = "Tester-Garona"

-- Awarder remains a non-Spectrum-admin; the writer is still the profile admin.
assertFalse(profile:IsCurrentUserAdmin and profile:IsCurrentUserAdmin() and AWARDER == PLAYER, "awarder is not the local Spectrum admin")
local awarderIsAdmin = false
for _, adminId in ipairs(profile:getAdminMemberIds()) do
    if adminId == AWARDER then
        awarderIsAdmin = true
    end
end
assertFalse(awarderIsAdmin, "RC awarder does not need to be a Spectrum admin")

-- ---------------------------------------------------------------------------
-- Two-admin race: same award before either receives the other's mutation
-- ---------------------------------------------------------------------------
resetEnv()
local adminA = makeProfile("Race A")
addMember(adminA, WINNER)
setActive(adminA)
local adminB = makeProfile("Race B")
addMember(adminB, WINNER)
-- Keep both profiles on the same id/logs by cloning the same award independently.
SF.lootHelperDB.profiles[adminB:GetProfileId()] = adminB

local raceCanonical = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable())
SF.lootHelperDB.activeProfile = adminA
assertTrue(adminA:TryAddRCLootCouncilAward(raceCanonical), "admin A records the award locally")
SF.lootHelperDB.activeProfile = adminB
assertTrue(adminB:TryAddRCLootCouncilAward(raceCanonical), "admin B records the same award locally before sync")

assertEq(adminA:GetLootLogs()[#adminA:GetLootLogs()]:GetID(), adminB:GetLootLogs()[#adminB:GetLootLogs()]:GetID(), "both admins produce the same external id")
assertEq(adminA:GetLootLogs()[#adminA:GetLootLogs()]:GetFingerprint(), adminB:GetLootLogs()[#adminB:GetLootLogs()]:GetFingerprint(), "both admins produce the same fingerprint")

local merged = adminA:MergeLogTables({ adminB:GetLootLogs()[#adminB:GetLootLogs()]:ToTable() })
assertEq(merged, 0, "merging the peer's identical RC log inserts nothing")
assertEq(countRCLogs(adminA), 1, "final synchronized profile has exactly one RC log")

-- ---------------------------------------------------------------------------
-- Snapshot / old-profile compatibility
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("Snapshot")
addMember(profile, WINNER)
setActive(profile)
assertTrue(profile:SetRCLootCouncilRecordAllAwardTypes(false), "admin can turn off record-all")
assertTrue(profile:AddRCLootCouncilAllowedResponse("Major Upgrade"), "allow-list value is exported")
assertTrue(profile:TryAddRCLootCouncilAward(SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({ response = "Major Upgrade" }))), "custom label is recorded")

local snapshot = profile:ExportSnapshot()
assertTrue(type(snapshot.rcLootCouncilIntegration) == "table", "snapshot exports rcLootCouncilIntegration")
assertFalse(snapshot.rcLootCouncilIntegration.recordAllAwardTypes, "snapshot carries record-all=false")
assertEq(snapshot.rcLootCouncilIntegration.allowedResponses[1], "Major Upgrade", "snapshot carries the allow-list")

local okSnap, snapErr = SF.LootProfile.ValidateSnapshot(snapshot)
assertTrue(okSnap, "current snapshot with RC integration validates")
assertEq(snapErr, nil, "valid snapshot has no error")

local legacy = {}
for key, value in pairs(snapshot) do
    legacy[key] = value
end
legacy.rcLootCouncilIntegration = nil
legacy.rcLootCouncil = { rollType = "Need" }
assertTrue(select(1, SF.LootProfile.ValidateSnapshot(legacy)), "legacy snapshot.rcLootCouncil remains valid compatibility-only metadata")

assertTrue(profile:SetRCLootCouncilRecordAllAwardTypes(true), "local settings can diverge before snapshot import")
assertTrue(profile:RemoveRCLootCouncilAllowedResponse("Major Upgrade"), "local allow-list can be cleared before snapshot import")
assertTrue(profile:ImportSnapshot(snapshot), "snapshot import reapplies RC integration settings")
local importedCfg = profile:GetRCLootCouncilIntegrationConfig()
assertFalse(importedCfg.recordAllAwardTypes, "imported profile restores record-all")
assertEq(importedCfg.allowedResponses[1], "Major Upgrade", "imported profile restores allow-list")

local oldProfile = makeProfile("Old Defaults")
local oldCfg = oldProfile:GetRCLootCouncilIntegrationConfig()
assertTrue(oldCfg.recordAwards and oldCfg.recordAllAwardTypes and #oldCfg.allowedResponses == 0, "profiles without stored RC config fill defaults")

-- ---------------------------------------------------------------------------
-- Sequential isolation (required regression boundary)
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("Isolation")
addMember(profile, WINNER)
setActive(profile)
assertTrue(profile:TryAddRCLootCouncilAward(SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable())), "isolation profile has one RC log")

local authorMax = profile:ComputeAuthorMax()
assertEq(authorMax[AWARDER], nil, "external logs do not advance ComputeAuthorMax")
assertEq(profile._authorCounters[AWARDER], nil, "external logs do not populate authorCounters")

local nextSequential = profile:AllocateNextCounter(AWARDER)
assertEq(nextSequential, 1, "next ordinary counter for the RC awarder starts at 1")

local window = profile:ComputeAuthorWindowSummary(25)
assertEq(window[AWARDER], nil, "external logs do not poison author-window summaries")

local sequentialLog = SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
    member = WINNER,
    change = SF.LootLogPointChangeTypes.INCREMENT,
}, {
    author = PLAYER,
    counter = 2,
    skipPermission = true,
})
assertTrue(profile:AddLootLog(sequentialLog, { skipBroadcast = true }), "ordinary sequential logs still insert")
assertEq(profile:ComputeAuthorMax()[PLAYER], 2, "ordinary author max still tracks sequential counters")

Sync.state.active = true
Sync.state.sessionId = "SES1"
Sync.state.profileId = profile:GetProfileId()
Sync:_EnsureRepairQueueState()

local rcTable = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL then
        rcTable = log:ToTable()
    end
end
assertTrue(rcTable ~= nil, "isolation test has an RC wire table")

assertFalse(Sync:DetectGap(profile:GetProfileId(), rcTable), "external logs do not trigger missing-log gap repair")
assertFalse(Sync:QueueRepairRanges(profile:GetProfileId(), {
    { author = AWARDER, fromCounter = 0, toCounter = 0, mode = "integrity" },
}, { mode = "integrity", reason = "external-zero" }), "0-0 ranges are not queued")
assertEq(queuedRepairCount(), 0, "queue stays empty after a 0-0 external range")

assertFalse(Sync:RequestIntegrityRepairRanges(profile:GetProfileId(), {
    { author = AWARDER, fromCounter = 0, toCounter = 0 },
}, "external-auth"), "AUTH_LOGS repair is not requested for counter 0")

local mismatch = {}
for key, value in pairs(rcTable) do
    mismatch[key] = value
end
mismatch._data = {}
for key, value in pairs(rcTable._data) do
    mismatch._data[key] = value
end
mismatch._data.response = "Different"
mismatch._fingerprint = SF.LootLog.ComputeFingerprintFromTable(mismatch)
assertTrue(mismatch._fingerprint ~= rcTable._fingerprint, "same-id different-fingerprint fixture is ready")

Sync:HandleNewLog(PLAYER, {
    sessionId = "SES1",
    profileId = profile:GetProfileId(),
    log = mismatch,
})
assertEq(queuedRepairCount(), 0, "same-id/different-fingerprint RC logs do not enqueue integrity repair")
assertEq(countRCLogs(profile), 1, "mismatch keeps the first RC log and does not duplicate")
assertEq(profile:GetLogFingerprintById(rcTable._id), rcTable._fingerprint, "first-writer fingerprint is retained")

-- Ordinary sequential gap/integrity behavior is unchanged.
local gapLog = SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
    member = WINNER,
    change = SF.LootLogPointChangeTypes.INCREMENT,
}, {
    author = PLAYER,
    counter = 5,
    skipPermission = true,
}):ToTable()
local hasGap, gapFrom, gapTo = Sync:DetectGap(profile:GetProfileId(), gapLog)
assertTrue(hasGap, "ordinary sequential logs still detect gaps")
assertEq(gapFrom, 3, "ordinary gap starts after the last contiguous sequential counter")
assertEq(gapTo, 4, "ordinary gap ends before the received sequential counter")

assertTrue(Sync:QueueRepairRanges(profile:GetProfileId(), {
    { author = PLAYER, fromCounter = 3, toCounter = 4, mode = "missing" },
}, { mode = "missing", reason = "ordinary-gap" }), "ordinary sequential ranges still enqueue")
assertTrue(queuedRepairCount() >= 1, "ordinary sequential repair remains available")

-- ---------------------------------------------------------------------------
-- Child addon: session gate, local/remote identity, non-member warning, decode
-- ---------------------------------------------------------------------------
resetEnv()
profile = makeProfile("Child")
addMember(profile, WINNER)
setActive(profile)

assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable(), "acecomm"), "no_session", "no Spectrum session means no log")
assertEq(countRCLogs(profile), 0, "inactive session does not persist an RC log")

Sync.state.active = true
function Sync:IsSessionActive()
    return self.state and self.state.active == true
end

assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable(), "acecomm"), "recorded", "remote history records during an active session")
assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable(), "local"), "seen", "local ML replay of the same award is suppressed")
assertEq(countRCLogs(profile), 1, "local and remote observations converge to one log")

local childLog = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL then
        childLog = log
    end
end
assertEq(childLog:GetID(), expectedKey, "child-recorded log uses the same external identity")
assertEq(childLog:GetAuthor(), AWARDER, "child-recorded Author is the RC awarder")

Integration.ClearSessionMemory()
assertEq(Integration.HandleHistory(AWARDER, "Stranger-Garona", historyTable({ id = "1700000600-6" }), "acecomm"), "not_member", "child skips non-profile recipients")
assertEq(countRCLogs(profile), 1, "non-member award does not create a log")
assertEq(#printed, 1, "admin receives exactly one local warning")
assertTrue(printed[1][2]:find("not a member of the active profile", 1, true) ~= nil, "warning names the missing-member reason")
assertTrue(printed[1][2]:find("Stranger-Garona", 1, true) ~= nil, "warning names the recipient")
assertEq(Integration.HandleHistory(AWARDER, "Stranger-Garona", historyTable({ id = "1700000600-6" }), "acecomm"), "seen", "replay does not warn again")
assertEq(#printed, 1, "replay of a non-member award does not spam the warning")

PLAYER = "NotAdmin-Garona"
printed = {}
Integration.ClearSessionMemory()
assertEq(Integration.HandleHistory(AWARDER, "Stranger-Garona", historyTable({ id = "1700000700-7" }), "acecomm"), "not_member", "non-admin still skips outsiders")
assertEq(#printed, 0, "non-admins do not receive the local outsider warning")
PLAYER = "Tester-Garona"

local libs = {
    LibDeflate = {
        DecodeForWoWAddonChannel = function(_self, raw)
            return raw
        end,
        DecompressDeflate = function(_self, bytes)
            return bytes
        end,
    },
    AceSerializer = {
        Deserialize = function(_self)
            return true, "history", WINNER, historyTable()
        end,
    },
}
local decoded = Integration.DecodeHistoryPayload("payload", libs)
assertTrue(decoded.ok, "history payloads decode to a winner and history table")
assertEq(decoded.winner, WINNER, "decoded winner is preserved")
assertEq(decoded.history.id, HISTORY_ID, "decoded history id is preserved")

libs.AceSerializer.Deserialize = function(_self)
    return true, "xrealm", { "unused", "history", WINNER, historyTable() }
end
local xrealm = Integration.DecodeHistoryPayload("payload", libs)
assertTrue(xrealm.ok, "xrealm envelopes unwrap to the inner history command")
assertEq(xrealm.winner, WINNER, "xrealm winner is the inner winner")

libs.AceSerializer.Deserialize = function(_self)
    return true, "awarded", WINNER
end
assertFalse(Integration.DecodeHistoryPayload("payload", libs).ok, "awarded-only traffic is ignored")

local registeredPages = {}
SF.SettingsUI = {
    RegisterPage = function(_self, page)
        registeredPages[#registeredPages + 1] = page
    end,
    DefinitionRenderer = {},
}
assertTrue(Integration.RegisterSettingsPage(), "child registers the Loot Helper RC page")
assertEq(registeredPages[1].id, "lootHelperRCLootCouncil", "page id is lootHelperRCLootCouncil")
assertEq(registeredPages[1].categoryId, "lootHelper", "page is hosted under Loot Helper")
assertFalse(Integration.RegisterSettingsPage(), "settings page is registered once")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
