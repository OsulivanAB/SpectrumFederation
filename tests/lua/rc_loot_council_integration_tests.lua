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
loadModule("SpectrumFederation/modules/LootHelper/Impersonation.lua")
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

function Sync:IsSessionActive()
    return self.state and self.state.active == true
end

function Sync:GetSessionProfileId()
    return self:IsSessionActive() and self.state.profileId or nil
end

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
function Sync:_Now()
    return 1
end
function Sync:GetIntegrityWindowSize()
    return 25
end
function Sync:IsBulkTransferAllowed()
    return true
end
function Sync:IsSenderAuthorized()
    return true
end
function Sync:BroadcastNewLog()
    return true
end
function Sync:_EnforceGroupedSessionActive()
    return "RAID"
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

local function selectProfile(profile)
    SF:SetActiveProfileById(profile:GetProfileId())
end

local function startSessionOn(profile)
    Sync.state.active = true
    Sync.state.sessionId = "SES1"
    Sync.state.profileId = profile and profile.GetProfileId and profile:GetProfileId() or profile
end

local function makeProfileOwnedBy(name, ownerId)
    local previous = PLAYER
    PLAYER = ownerId
    local profile = makeProfile(name)
    PLAYER = previous
    return profile
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
assertEq(
    SF.LootLog.ExtractItemRef(ITEM_LINK),
    "item:12345::::::::80:259:::::::::",
    "SetItemRef receives the inner item token, not the colored display string"
)
assertEq(
    SF.LootLog.ExtractItemRef("Awarded " .. ITEM_LINK),
    "item:12345::::::::80:259:::::::::",
    "SetItemRef token can be recovered from surrounding Action text"
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
assertTrue(type(oldErr) == "string" and oldErr:find("external id", 1, true) ~= nil, "RC rows without _externalId are rejected")

local ordinary = SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
    member = WINNER,
    change = SF.LootLogPointChangeTypes.INCREMENT,
}, {
    author = PLAYER,
    counter = 2,
    skipPermission = true,
})
assertTrue(ordinary ~= nil, "ordinary sequential logs still create")
assertEq(SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
    member = WINNER,
    change = SF.LootLogPointChangeTypes.INCREMENT,
}, {
    author = PLAYER,
    externalId = expectedKey,
    skipPermission = true,
}), nil, "ordinary event + externalId is rejected")
assertEq(SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
    member = WINNER,
    change = SF.LootLogPointChangeTypes.INCREMENT,
}, {
    author = PLAYER,
    counter = 0,
    skipPermission = true,
}), nil, "ordinary event + counter 0 is rejected")

local ordinaryWire = ordinary:ToTable()
ordinaryWire._externalId = expectedKey
ordinaryWire._id = expectedKey
ordinaryWire._counter = 0
ordinaryWire._fingerprint = nil
assertFalse(select(1, SF.LootLog.ValidateTable(ordinaryWire)), "ordinary wire table cannot use an external id")

local zeroCounter = ordinary:ToTable()
zeroCounter._counter = 0
zeroCounter._id = PLAYER .. ":0"
zeroCounter._fingerprint = nil
assertFalse(select(1, SF.LootLog.ValidateTable(zeroCounter)), "ordinary wire table cannot use counter 0")

local mismatchId = {}
for key, value in pairs(wire) do
    mismatchId[key] = value
end
mismatchId._id = "RCLootCouncil|other"
mismatchId._fingerprint = nil
assertFalse(select(1, SF.LootLog.ValidateTable(mismatchId)), "RC row with mismatched _id is rejected")

local mismatchKey = {}
for key, value in pairs(wire) do
    mismatchKey[key] = value
end
mismatchKey._data = {}
for key, value in pairs(wire._data) do
    mismatchKey._data[key] = value
end
mismatchKey._data.awardKey = "RCLootCouncil|other"
mismatchKey._fingerprint = nil
assertFalse(select(1, SF.LootLog.ValidateTable(mismatchKey)), "RC row with mismatched data.awardKey is rejected")

local mismatchExternal = {}
for key, value in pairs(wire) do
    mismatchExternal[key] = value
end
mismatchExternal._externalId = "RCLootCouncil|other"
mismatchExternal._fingerprint = nil
assertFalse(select(1, SF.LootLog.ValidateTable(mismatchExternal)), "RC row with mismatched _externalId is rejected")

for _, eventType in ipairs({
    SF.LootLogEventTypes.POINT_CHANGE,
    SF.LootLogEventTypes.ARMOR_CHANGE,
    SF.LootLogEventTypes.ADMIN_ADDED,
    SF.LootLogEventTypes.ROLE_CHANGE,
    SF.LootLogEventTypes.LOOT_MODE_CHANGE,
    SF.LootLogEventTypes.REWARD_POT_CHANGE,
    SF.LootLogEventTypes.ATTENDANCE_CHANGE,
}) do
    local ordinaryExternal = ordinary:ToTable()
    ordinaryExternal._eventType = eventType
    ordinaryExternal._externalId = expectedKey
    ordinaryExternal._id = expectedKey
    ordinaryExternal._counter = 0
    ordinaryExternal._fingerprint = nil
    assertFalse(
        select(1, SF.LootLog.ValidateTable(ordinaryExternal)),
        eventType .. " cannot use a counter-zero external representation"
    )
end

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

assertTrue(profile:SetRCLootCouncilRecordAllAwardTypes(true), "admin can re-enable record-all")
assertTrue(profile:ShouldRecordRCResponse("Want"), "record-all ignores a Need-only allow-list")
assertTrue(profile:ShouldRecordRCResponse("Need"), "record-all still records allow-listed labels")
local wantCanonical = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
    id = "1700000310-31",
    response = "Want",
}))
assertTrue(profile:TryAddRCLootCouncilAward(wantCanonical), "record-all records a Want award despite Need-only allow-list")
assertTrue(profile:SetRCLootCouncilRecordAllAwardTypes(false), "admin can disable record-all again")
assertFalse(profile:ShouldRecordRCResponse("Want"), "record-all off restores allow-list filtering")

local outsider = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, "Stranger-Garona", historyTable({ id = "1700000400-4" }))
assertEq(select(2, profile:TryAddRCLootCouncilAward(outsider)), "not_member", "non-profile recipients are not logged")

PLAYER = "NotAdmin-Garona"
local adminOnly = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({ id = "1700000500-5" }))
assertEq(select(2, profile:TryAddRCLootCouncilAward(adminOnly)), "not_admin", "non-admin Spectrum writers cannot create the log")
PLAYER = "Tester-Garona"

-- Awarder remains a non-Spectrum-admin; the writer is still the profile admin.
assertTrue(profile:IsCurrentUserAdmin(), "Spectrum writer remains a profile admin")
assertFalse(AWARDER == PLAYER, "RC awarder is not the local Spectrum writer")
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

local function findRCLog(profile)
    for _, log in ipairs(profile:GetLootLogs() or {}) do
        if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL then
            return log
        end
    end
    return nil
end

local raceA = findRCLog(adminA)
local raceB = findRCLog(adminB)
assertTrue(raceA ~= nil and raceB ~= nil, "both admins stored an RC log")
assertEq(raceA:GetID(), raceB:GetID(), "both admins produce the same external id")
assertEq(raceA:GetFingerprint(), raceB:GetFingerprint(), "both admins produce the same fingerprint")

local merged = adminA:MergeLogTables({ raceB:ToTable() })
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

-- Main Swap must not rewrite isolated RC recipients.
resetEnv()
local swapProfile = makeProfile("Swap")
local sourceAlt = "Alt-Garona"
addMember(swapProfile, sourceAlt)
addMember(swapProfile, WINNER)
setActive(swapProfile)
local sourceCanonical = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, sourceAlt, historyTable({ id = "1700000800-8" }))
assertTrue(swapProfile:TryAddRCLootCouncilAward(sourceCanonical), "RC award is recorded on the source alt")
local pointLog = SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
    member = sourceAlt,
    change = SF.LootLogPointChangeTypes.INCREMENT,
}, {
    author = PLAYER,
    counter = 2,
    skipPermission = true,
})
assertTrue(swapProfile:AddLootLog(pointLog, { skipBroadcast = true }), "sequential point log is recorded on the source alt")
assertTrue(swapProfile:TransferMemberHistory(sourceAlt, WINNER), "Main Swap transfers sequential history")
local swappedRC = nil
local swappedPoint = nil
for _, log in ipairs(swapProfile:GetLootLogs() or {}) do
    if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL then
        swappedRC = log
    elseif log:GetEventType() == SF.LootLogEventTypes.POINT_CHANGE then
        swappedPoint = log
    end
end
assertTrue(swappedRC ~= nil, "RC log remains after Main Swap")
assertEq(swappedRC:GetEventData().member, sourceAlt, "Main Swap does not rewrite the RC recipient")
assertEq(swappedRC:GetID(), sourceCanonical.awardKey, "Main Swap does not change the external RC identity")
assertTrue(swappedPoint ~= nil, "sequential point log remains after Main Swap")
assertEq(swappedPoint:GetEventData().member, WINNER, "Main Swap still rewrites ordinary sequential member references")

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
assertTrue(printed[1][2]:find("Spectrum Federation:", 1, true) == nil, "warning payload does not include a doubled Spectrum prefix")
assertTrue(printed[1][2]:find(ITEM_LINK, 1, true) ~= nil, "warning preserves the real item link")
assertEq(Integration.HandleHistory(AWARDER, "Stranger-Garona", historyTable({ id = "1700000600-6" }), "acecomm"), "seen", "replay does not warn again")
assertEq(#printed, 1, "replay of a non-member award does not spam the warning")

PLAYER = "NotAdmin-Garona"
printed = {}
Integration.ClearSessionMemory()
assertEq(Integration.HandleHistory(AWARDER, "Stranger-Garona", historyTable({ id = "1700000700-7" }), "acecomm"), "not_member", "non-admin still skips outsiders")
assertEq(#printed, 0, "non-admins do not receive the local outsider warning")
PLAYER = "Tester-Garona"

local function passthroughLibs(deserialize)
    return {
        LibDeflate = {
            DecodeForWoWAddonChannel = function(_self, raw)
                return raw
            end,
            DecompressDeflate = function(_self, bytes)
                return bytes
            end,
        },
        AceSerializer = {
            Deserialize = deserialize,
        },
    }
end

local realHistory = historyTable()
local libs = passthroughLibs(function(_self)
    return true, "history", { WINNER, realHistory }
end)
local decoded = Integration.DecodeHistoryPayload("payload", libs)
assertTrue(decoded.ok, "real-shape history decodes winner/history correctly")
assertEq(decoded.winner, WINNER, "decoded winner is preserved")
assertEq(decoded.history.id, HISTORY_ID, "decoded history id is preserved")

libs = passthroughLibs(function(_self)
    return true, "xrealm", { PLAYER, "history", WINNER, realHistory }
end)
local xrealm = Integration.DecodeHistoryPayload("payload", libs, { localPlayer = PLAYER })
assertTrue(xrealm.ok, "xrealm addressed to the local player decodes correctly")
assertEq(xrealm.winner, WINNER, "xrealm winner is the inner winner")

libs = passthroughLibs(function(_self)
    return true, "xrealm", { "Other-Garona", "history", WINNER, realHistory }
end)
local foreign = Integration.DecodeHistoryPayload("payload", libs, { localPlayer = PLAYER })
assertFalse(foreign.ok, "xrealm addressed to another player is ignored")
assertEq(foreign.command, "xrealm", "foreign xrealm keeps the outer command")

libs = passthroughLibs(function(_self)
    return false, "deserialize failed"
end)
assertFalse(Integration.DecodeHistoryPayload("payload", libs).ok, "malformed decode is ignored")
assertFalse(Integration.DecodeHistoryPayload(nil, libs).ok, "non-string payload is ignored")

libs = passthroughLibs(function(_self)
    return true, "awarded", { WINNER }
end)
assertFalse(Integration.DecodeHistoryPayload("payload", libs).ok, "unrelated awarded command remains ignored")

libs = passthroughLibs(function(_self)
    return true, "history", WINNER, realHistory
end)
assertFalse(Integration.DecodeHistoryPayload("payload", libs).ok, "flattened AceSerializer history shape is ignored")

_G.RCLootCouncil = {
    masterLooter = AWARDER,
    GetML = function()
        return false, AWARDER
    end,
    IsMasterLooter = function(_, unit)
        return SF.NameUtil.SamePlayer(unit, AWARDER)
    end,
}
assertTrue(Integration.SenderIsCurrentMasterLooter(AWARDER), "current RC ML group sender is accepted")
assertFalse(Integration.SenderIsCurrentMasterLooter("Other-Garona"), "non-ML group sender is rejected")
assertFalse(Integration.SenderIsCurrentMasterLooter("Guildie-OtherRealm"), "unrelated guild history sender is rejected")

_G.RCLootCouncil = {
    masterLooter = PLAYER,
    GetML = function()
        return true, PLAYER
    end,
    IsMasterLooter = function()
        return true
    end,
}
assertTrue(Integration.SenderIsCurrentMasterLooter(PLAYER), "local player is accepted when they are the current RC ML")
assertFalse(Integration.SenderIsCurrentMasterLooter("Guildie-OtherRealm"), "local-only IsMasterLooter must not accept a different sender")
assertFalse(Integration.SenderIsCurrentMasterLooter("Other-Garona"), "non-ML sender is rejected even when the local client is ML")
_G.RCLootCouncil = {
    masterLooter = AWARDER,
    GetML = function()
        return false, AWARDER
    end,
    IsMasterLooter = function()
        return true
    end,
}

function Integration.ResolveLibraries()
    return passthroughLibs(function(_self)
        return true, "history", { WINNER, historyTable({ id = "1700000900-9" }) }
    end)
end
Sync.state.active = true
function Sync:IsSessionActive()
    return true
end
Integration.ClearSessionMemory()
assertEq(Integration.HandleIncomingMessage("RCLC", "payload", "RAID", AWARDER), "recorded", "remote history from the current ML is recorded")
assertEq(Integration.HandleIncomingMessage("RCLC", "payload", "RAID", "Other-Garona"), "not_ml", "remote history from a non-ML is rejected")
assertEq(Integration.HandleIncomingMessage("RCLC", "payload", "GUILD", "Guildie-OtherRealm"), "not_ml", "guild-distributed history from a non-ML is rejected")

local localHistory = historyTable({ id = "1700000900-9" })
local remoteCanonical = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, localHistory)
PLAYER = AWARDER
local localResult = Integration.HandleLocalHistory(localHistory, WINNER)
PLAYER = "Tester-Garona"
assertEq(localResult, "seen", "local RCMLLootHistorySend of the same award is accepted then deduped")
assertEq(remoteCanonical.awardKey, SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, localHistory).awardKey, "accepted local and remote observations share the same award key")
assertEq(countRCLogs(profile), 2, "the ML-authorized remote award created exactly one additional RC log")

local localOnlyHistory = historyTable({ id = "1700001000-10" })
local localOnlyKey = SF.LootLog.BuildRCLootCouncilCanonical(PLAYER, WINNER, localOnlyHistory).awardKey
_G.RCLootCouncil = {
    masterLooter = PLAYER,
    GetML = function()
        return true, PLAYER
    end,
    IsMasterLooter = function(_, unit)
        return SF.NameUtil.SamePlayer(unit, PLAYER)
    end,
}
Integration.ClearSessionMemory()
assertEq(Integration.HandleLocalHistory(localOnlyHistory, WINNER), "recorded", "local RCMLLootHistorySend is accepted")
local storedLocalId = nil
for _, log in ipairs(profile:GetLootLogs()) do
    if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL and log:GetEventData().rcAwardId == "1700001000-10" then
        storedLocalId = log:GetID()
    end
end
assertEq(storedLocalId, localOnlyKey, "local RCMLLootHistorySend stores the same deterministic award key")
function Integration.ResolveLibraries()
    return passthroughLibs(function(_self)
        return true, "history", { WINNER, historyTable({ id = "1700001000-10" }) }
    end)
end
Integration.ClearSessionMemory()
assertEq(Integration.HandleIncomingMessage("RCLC", "payload", "RAID", PLAYER), "duplicate", "remote observation of the same local award converges without a second log")
assertEq(countRCLogs(profile), 3, "local and remote observations of the same award share one stored row")

-- ---------------------------------------------------------------------------
-- Session profile vs selected profile (A vs B)
-- ---------------------------------------------------------------------------
function Sync:IsSessionActive()
    return self.state and self.state.active == true
end
resetEnv()
local sessionA = makeProfile("Session A")
local selectedB = makeProfile("Selected B")
addMember(sessionA, WINNER)
startSessionOn(sessionA)
selectProfile(selectedB)
assertEq(Integration.GetSessionProfile(), sessionA, "runtime resolver uses the session profile")
assertEq(Integration.GetSelectedProfile(), selectedB, "selected profile remains B")
assertEq(Integration.GetSettingsProfile(), sessionA, "Settings follow the session profile while a session is active")
assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable({ id = "1700002000-20" }), "acecomm"), "recorded", "member-only-in-session-profile award is recorded in A")
assertEq(countRCLogs(sessionA), 1, "Case A records into the session profile")
assertEq(countRCLogs(selectedB), 0, "Case A does not write the selected profile")
assertEq(#printed, 0, "Case A does not emit a false non-member warning")

resetEnv()
sessionA = makeProfile("Session A Admin")
addMember(sessionA, WINNER)
selectedB = makeProfileOwnedBy("Selected B Other", "OtherOwner-Garona")
startSessionOn(sessionA)
selectProfile(selectedB)
assertTrue(sessionA:IsCurrentUserAdmin(), "writer is admin of the session profile")
assertFalse(selectedB:IsCurrentUserAdmin(), "writer is not admin of the selected profile")
assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable({ id = "1700002100-21" }), "acecomm"), "recorded", "admin-only-in-session-profile can still record into A")
assertEq(countRCLogs(sessionA), 1, "Case B records into A despite B permission denial")
assertEq(countRCLogs(selectedB), 0, "Case B does not write B")

resetEnv()
sessionA = makeProfile("Session A Empty")
selectedB = makeProfile("Selected B Member")
addMember(selectedB, WINNER)
startSessionOn(sessionA)
selectProfile(selectedB)
assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable({ id = "1700002200-22" }), "acecomm"), "not_member", "recipient only in selected profile is not recorded")
assertEq(countRCLogs(sessionA), 0, "Case C writes nothing to the session profile")
assertEq(countRCLogs(selectedB), 0, "Case C does not write the selected profile")
assertEq(#printed, 1, "Case C warns the session-profile admin")
assertTrue(printed[1][2]:find("not a member of the active profile", 1, true) ~= nil, "Case C warning names the session-profile membership miss")

resetEnv()
sessionA = makeProfile("Session A Both")
selectedB = makeProfile("Selected B Both")
addMember(sessionA, WINNER)
addMember(selectedB, WINNER)
startSessionOn(sessionA)
selectProfile(selectedB)
assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable({ id = "1700002300-23" }), "acecomm"), "recorded", "shared recipient still routes to the session profile")
assertEq(countRCLogs(sessionA), 1, "Case D records only into A")
assertEq(countRCLogs(selectedB), 0, "Case D does not copy the award into B")

resetEnv()
sessionA = makeProfile("Session A Settings")
selectedB = makeProfile("Selected B Settings")
addMember(sessionA, WINNER)
addMember(selectedB, WINNER)
assertTrue(sessionA:SetRCLootCouncilRecordAwards(true), "A can enable RC recording")
assertTrue(selectedB:SetRCLootCouncilRecordAwards(false), "B can disable RC recording")
startSessionOn(sessionA)
selectProfile(selectedB)
assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable({ id = "1700002400-24" }), "acecomm"), "recorded", "enabled session-profile settings allow the award")
assertEq(countRCLogs(sessionA), 1, "Case E records when A logging is on")
assertEq(countRCLogs(selectedB), 0, "Case E ignores B's disabled setting for insertion")
assertTrue(sessionA:SetRCLootCouncilRecordAwards(false), "A can disable RC recording")
assertTrue(selectedB:SetRCLootCouncilRecordAwards(true), "B can enable RC recording")
Integration.ClearSessionMemory()
printed = {}
assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable({ id = "1700002500-25" }), "acecomm"), "filtered", "disabled session-profile settings reject the award")
assertEq(countRCLogs(sessionA), 1, "Case E does not add a second A log after A is disabled")
assertEq(countRCLogs(selectedB), 0, "Case E still does not write B after B is enabled")

resetEnv()
selectedB = makeProfile("Selected B Orphan")
addMember(selectedB, WINNER)
startSessionOn(nil)
Sync.state.active = true
Sync.state.profileId = "missing-session-profile"
selectProfile(selectedB)
assertEq(Integration.GetSessionProfile(), nil, "missing local session profile does not resolve")
assertEq(Integration.GetSettingsProfile(), nil, "Settings do not fall back to B during an unresolved session")
assertEq(Integration.HandleHistory(AWARDER, WINNER, historyTable({ id = "1700002600-26" }), "acecomm"), "no_profile", "unresolved session profile fails safely")
assertEq(countRCLogs(selectedB), 0, "Case F does not write the selected profile")

Sync.state.active = false
assertEq(Integration.GetSettingsProfile(), selectedB, "Settings use the selected profile when no session is active")

local registeredPages = {}
local capturedDef = nil
local refreshCount = 0
local lastAllowCondition = nil
local lastRecordAllVisible = nil
SF.SettingsUI = {
    RegisterPage = function(_self, page)
        registeredPages[#registeredPages + 1] = page
    end,
    DefinitionRenderer = {},
}

local function findSection(pageDef, id)
    for _, sec in ipairs((pageDef and pageDef.sections) or {}) do
        if sec.id == id then
            return sec
        end
    end
    return nil
end

local function findItem(section, label)
    for _, item in ipairs((section and section.items) or {}) do
        if item.label == label then
            return item
        end
    end
    return nil
end

local function evaluateAllowCondition()
    local allow = findSection(capturedDef, "allowList")
    if allow and type(allow.condition) == "function" then
        lastAllowCondition = allow.condition() and true or false
    else
        lastAllowCondition = nil
    end
    local recording = findSection(capturedDef, "recording")
    local recordAll = findItem(recording, "Record all award types")
    if recordAll and type(recordAll.visible) == "function" then
        lastRecordAllVisible = recordAll.visible() and true or false
    else
        lastRecordAllVisible = nil
    end
end

function SF.SettingsUI.DefinitionRenderer:Build(panel, pageDef)
    capturedDef = pageDef
    panel.__sfPageDef = pageDef
    panel.__sfPageBuilder = {
        Refresh = function() end,
        Reflow = function() end,
    }
    panel.__sfSections = {}
    evaluateAllowCondition()
end

function SF.SettingsUI.DefinitionRenderer:Refresh(panel)
    refreshCount = refreshCount + 1
    capturedDef = (panel and panel.__sfPageDef) or capturedDef
    evaluateAllowCondition()
end

assertTrue(Integration.RegisterSettingsPage(), "child registers the Loot Helper RC page")
assertEq(registeredPages[1].id, "lootHelperRCLootCouncil", "page id is lootHelperRCLootCouncil")
assertEq(registeredPages[1].categoryId, "lootHelper", "page is hosted under Loot Helper")
assertFalse(Integration.RegisterSettingsPage(), "settings page is registered once")

resetEnv()
local settingsProfile = makeProfile("RC Settings UX")
addMember(settingsProfile, WINNER)
selectProfile(settingsProfile)
local settingsPanel = {}
registeredPages[1].Build(registeredPages[1], settingsPanel)
assertTrue(capturedDef ~= nil, "Page.Build passes a definition to DefinitionRenderer")
assertTrue(type(capturedDef.isAdmin) == "function", "RC page supplies the renderer isAdmin predicate")
assertEq(capturedDef.visible, nil, "RC page does not use an unused page-level visible flag")

local recordingSec = findSection(capturedDef, "recording")
local allowSec = findSection(capturedDef, "allowList")
local recordAwardsItem = findItem(recordingSec, "Record RC Loot Council Awards in Loot Logs")
local recordAllItem = findItem(recordingSec, "Record all award types")
local addItem = findItem(allowSec, "Add award type")
local listItem = findItem(allowSec, "Allowed types")
assertTrue(recordingSec ~= nil and allowSec ~= nil, "recording and allow-list sections exist")
assertTrue(recordAwardsItem ~= nil and recordAllItem ~= nil, "both recording checkboxes exist")
assertTrue(addItem ~= nil and listItem ~= nil, "allow-list add and scroll-list controls exist")
assertTrue(type(allowSec.condition) == "function", "Allowed Award Types uses section condition")
assertEq(allowSec.visible, nil, "Allowed Award Types does not use unused section visible")
assertTrue(recordAwardsItem.adminOnly and recordAllItem.adminOnly, "recording checkboxes are adminOnly")
assertTrue(addItem.adminOnly and listItem.adminOnly, "allow-list add/remove controls are adminOnly")
assertTrue(type(recordAllItem.visible) == "function", "Record all award types uses item-level visible")

local function assertVisibility(recordAwards, recordAll, expectRecordAllShown, expectAllowShown, message)
    assertTrue(settingsProfile:SetRCLootCouncilRecordAwards(recordAwards), "admin can set recordAwards for " .. message)
    assertTrue(settingsProfile:SetRCLootCouncilRecordAllAwardTypes(recordAll), "admin can set recordAllAwardTypes for " .. message)
    evaluateAllowCondition()
    assertEq(lastRecordAllVisible, expectRecordAllShown, message .. ": Record-all checkbox visibility")
    assertEq(lastAllowCondition, expectAllowShown, message .. ": Allowed Award Types visibility")
end

assertVisibility(false, true, false, false, "recordAwards=false recordAll=true")
assertVisibility(false, false, false, false, "recordAwards=false recordAll=false")
assertVisibility(true, true, true, false, "recordAwards=true recordAll=true")
assertVisibility(true, false, true, true, "recordAwards=true recordAll=false")

assertTrue(settingsProfile:AddRCLootCouncilAllowedResponse("Need"), "admin can seed an allowed type")
refreshCount = 0
recordAllItem.set(true)
assertTrue(refreshCount >= 1, "toggling record-all calls DefinitionRenderer:Refresh")
assertFalse(lastAllowCondition, "record-all false→true immediately hides Allowed Award Types")
assertEq(
    settingsProfile:GetRCLootCouncilIntegrationConfig().allowedResponses[1],
    "Need",
    "hidden allow-list keeps stored values"
)
assertEq(listItem.getItems()[1].label, "Need", "getItems still returns stored types while hidden")

refreshCount = 0
recordAllItem.set(false)
assertTrue(refreshCount >= 1, "toggling record-all back on calls DefinitionRenderer:Refresh")
assertTrue(lastAllowCondition, "record-all true→false immediately shows Allowed Award Types")
assertEq(listItem.getItems()[1].label, "Need", "stored allowed types reappear after the section is shown")

refreshCount = 0
recordAwardsItem.set(false)
assertTrue(refreshCount >= 1, "toggling record-awards calls DefinitionRenderer:Refresh")
assertFalse(lastRecordAllVisible, "recordAwards false hides Record all award types")
assertFalse(lastAllowCondition, "recordAwards false hides Allowed Award Types")

recordAwardsItem.set(true)
assertTrue(lastRecordAllVisible, "recordAwards true shows Record all award types")
assertTrue(lastAllowCondition, "recordAwards true shows Allowed Award Types when record-all is false")

assertTrue(capturedDef.isAdmin(), "admin user evaluates as admin for the renderer")

local Imp = SF.LootHelperImpersonation
assertTrue(Imp and Imp.Enable, "impersonation helper is available")
assertTrue(Imp:Enable(), "Preview non-admin can be enabled for the selected profile")
assertFalse(capturedDef.isAdmin(), "Preview non-admin evaluates as non-admin for the renderer")
assertFalse(settingsProfile:AddRCLootCouncilAllowedResponse("Want"), "Preview non-admin cannot add allowed types")
assertFalse(settingsProfile:RemoveRCLootCouncilAllowedResponse("Need"), "Preview non-admin cannot remove allowed types")
local previewMessages = {}
local previewCtx = {
    section = {
        ClearMessage = function() end,
        SetMessage = function(_, text, _kind)
            previewMessages[#previewMessages + 1] = tostring(text)
        end,
    },
    pageBuilder = { Refresh = function() end },
}
local previewEdit = { text = "", SetText = function(self, value) self.text = value end }
addItem.onSubmit(previewCtx, "Want", previewEdit)
assertEq(#settingsProfile:GetRCLootCouncilIntegrationConfig().allowedResponses, 1, "add control cannot mutate while previewing")
listItem.onRemove(previewCtx, { id = "Need" })
assertEq(settingsProfile:GetRCLootCouncilIntegrationConfig().allowedResponses[1], "Need", "remove control cannot mutate while previewing")
assertTrue(Imp:Disable("rc-settings-preview"), "Preview non-admin can be disabled")
assertTrue(capturedDef.isAdmin(), "disabling Preview restores renderer admin")

local nonAdminProfile = makeProfileOwnedBy("RC Non-Admin", "OtherOwner-Garona")
selectProfile(nonAdminProfile)
assertFalse(nonAdminProfile:IsCurrentUserAdmin(), "real non-admin is not a profile admin")
assertFalse(capturedDef.isAdmin(), "real non-admin evaluates as non-admin for the renderer")
assertFalse(nonAdminProfile:AddRCLootCouncilAllowedResponse("Need"), "real non-admin cannot add allowed types")
assertFalse(nonAdminProfile:RemoveRCLootCouncilAllowedResponse("Need"), "real non-admin cannot remove allowed types")

loadModule("SpectrumFederation/modules/UI/Settings/Control/Controls.lua")
local greyRow = {
    shown = true,
    alpha = 1,
    IsShown = function(self) return self.shown end,
    SetShown = function(self, shown) self.shown = shown and true or false end,
    SetAlpha = function(self, alpha) self.alpha = alpha end,
}
local greySection = {
    __sfAdminPredicate = function()
        return capturedDef.isAdmin()
    end,
}
SF.SettingsUI.Controls:_ApplyRowState(greyRow, greySection, { adminOnly = true })
assertEq(greyRow.alpha, 0.45, "non-admin adminOnly controls use the generic grey alpha")
selectProfile(settingsProfile)
SF.SettingsUI.Controls:_ApplyRowState(greyRow, greySection, { adminOnly = true })
assertEq(greyRow.alpha, 1, "admin adminOnly controls stay fully opaque")

resetEnv()
sessionA = makeProfile("Session A Settings UX")
selectedB = makeProfileOwnedBy("Selected B Settings UX", "OtherOwner-Garona")
addMember(sessionA, WINNER)
startSessionOn(sessionA)
selectProfile(selectedB)
local sessionPanel = {}
registeredPages[1].Build(registeredPages[1], sessionPanel)
assertEq(Integration.GetSettingsProfile(), sessionA, "Settings still follow the session profile while a session is active")
assertTrue(capturedDef.isAdmin(), "renderer admin follows the session profile, not the selected profile")
assertTrue(sessionA:SetRCLootCouncilRecordAwards(false), "session-profile admin can still mutate A from Settings")
assertTrue(selectedB:GetRCLootCouncilIntegrationConfig().recordAwards, "session Settings mutation does not write selected B")
assertFalse(sessionA:GetRCLootCouncilIntegrationConfig().recordAwards, "session Settings mutation writes A")
local recordAwardsDuringSession = findItem(findSection(capturedDef, "recording"), "Record RC Loot Council Awards in Loot Logs")
recordAwardsDuringSession.set(true)
assertTrue(sessionA:GetRCLootCouncilIntegrationConfig().recordAwards, "page set() writes the session profile")
assertTrue(selectedB:GetRCLootCouncilIntegrationConfig().recordAwards, "selected B keeps its own record-awards default")
Sync.state.active = false
assertEq(Integration.GetSettingsProfile(), selectedB, "Settings use the selected profile when no session is active")
assertFalse(capturedDef.isAdmin(), "renderer admin follows the selected profile outside a session")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
