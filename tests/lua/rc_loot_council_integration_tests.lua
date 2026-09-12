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
loadModule("SpectrumFederation/modules/LootHelper/Identity.lua")
loadModule("SpectrumFederation/modules/LootHelper/SpecWeapons.lua")
loadModule("SpectrumFederation/modules/LootHelper/Bis.lua")
loadModule("SpectrumFederation/modules/LootHelper/Profiles.lua")
loadModule("SpectrumFederation/modules/LootHelper/LootHelper.lua")
loadModule("SpectrumFederation/modules/LootHelper/Impersonation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/02_State.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/05_Scheduling.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/07_Validation.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/10_Handshake.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/12_LiveUpdates.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/16_ProfileIntegration.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/14_HandlersControl.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/15_HandlersBulk.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/18_PublicAPI.lua")

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

function SF:PrintError(message)
    printed[#printed + 1] = { "error", tostring(message) }
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

function Sync:_GetAddonVersion()
    return "test"
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
function Sync:IsRequesterInGroup()
    return true
end
function Sync:RebuildProfile()
end
function Sync:CompleteRequest()
end
function Sync:_MInc()
end
function Sync:_MObserve()
end
function Sync:MetricsEnabled()
    return false
end
function Sync:BroadcastNewLog()
    return true
end
function Sync:_EnforceGroupedSessionActive()
    return "RAID"
end
function Sync:UpdatePeersFromRoster()
    self.state.peers = self.state.peers or {}
end
function Sync:TouchPeer()
end
function Sync:_GetSessionSafeModePayload()
    return { enabled = false, rev = 0 }
end
function Sync:EnsureHeartbeatSender()
    return false
end
function Sync:_MarkRosterAnnounced()
end
function Sync:StartHeartbeatSender()
    return false
end
function Sync:StopHeartbeatSender()
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
        rcConfigSeq = 0,
        coordEpoch = 1,
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

-- In-session RC setting changes publish coordinator-serialized RC_CONFIG_SET
resetEnv()
local source = makeProfile("RC Snap Source")
addMember(source, WINNER)
setActive(source)
startSessionOn(source)
local captured = {}
SF.LootHelperComm = {
    Send = function(_, channel, msgType, payload, dist, target)
        captured[#captured + 1] = {
            channel = channel,
            msgType = msgType,
            payload = payload,
            dist = dist,
            target = target,
        }
    end,
}
assertTrue(source:SetRCLootCouncilRecordAwards(true), "recordAwards change is accepted")
assertTrue(source:SetRCLootCouncilRecordAllAwardTypes(false), "recordAllAwardTypes change is accepted")
assertTrue(source:AddRCLootCouncilAllowedResponse("Need"), "allowedResponses change is accepted")
assertTrue(source:AddRCLootCouncilBisResponse({
    text = "Need",
    typeCode = "default",
    responseId = 1,
    isAwardReason = false,
}), "bisResponses change is accepted")
assertTrue(#captured >= 4, "each RC integration mutator publishes config")
local last = captured[#captured]
assertEq(last.msgType, Sync.MSG.RC_CONFIG_SET, "coordinator publishes RC_CONFIG_SET")
assertEq(last.channel, "CONTROL", "RC config uses the CONTROL prefix")
assertEq(last.dist, "RAID", "authoritative config is sent on the grouped session channel")
assertTrue(last.payload and last.payload.rcLootCouncilIntegration, "payload carries RC integration only")
assertTrue(last.payload.snapshot == nil, "RC config publish does not include a full snapshot")
assertEq(type(last.payload.seq), "number", "SET carries a monotonic seq")
assertEq(last.payload.rcLootCouncilIntegration.bisResponses[1].responseId, 1, "SET carries the new BiS response")
assertFalse(last.payload.rcLootCouncilIntegration.recordAllAwardTypes, "SET carries record-all=false")

local replica = makeProfile("RC Snap Replica")
replica._profileId = source:GetProfileId()
addMember(replica, WINNER)
local priorPlayer = PLAYER
PLAYER = "Replica-Garona"
local previousLocal = SF.lootHelperDB.profiles[source:GetProfileId()]
SF.lootHelperDB.profiles[source:GetProfileId()] = replica
Sync:HandleRCConfigSet(priorPlayer, last.payload)
PLAYER = priorPlayer
SF.lootHelperDB.profiles[source:GetProfileId()] = previousLocal
assertTrue(replica:IsBisQualifyingResponse("Need", {
    typeCode = "default",
    responseId = 1,
    isAwardReason = false,
}), "replica qualifies Need after RC_CONFIG_SET")
assertFalse(replica:GetRCLootCouncilIntegrationConfig().recordAllAwardTypes, "replica restored record-all=false")
assertTrue(source:AddRCLootCouncilBisResponse({
    text = "Greed",
    typeCode = "default",
    responseId = 2,
    isAwardReason = false,
}), "source adds Greed as BiS")
last = captured[#captured]
PLAYER = "Replica-Garona"
SF.lootHelperDB.profiles[source:GetProfileId()] = replica
Sync:HandleRCConfigSet(priorPlayer, last.payload)
PLAYER = priorPlayer
SF.lootHelperDB.profiles[source:GetProfileId()] = previousLocal
local greedCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
    id = "1700000900-9",
    response = "Greed",
    responseID = 2,
}))
assertTrue(source:TryAddRCLootCouncilAward(greedCanon), "source records the later Greed award")
assertTrue(replica:TryAddRCLootCouncilAward(greedCanon), "replica records the same later Greed award")
local function greedOutcome(profile)
    for _, log in ipairs(profile:GetLootLogs() or {}) do
        local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
        if data and data.awardKey == greedCanon.awardKey then
            return data.outcome, data.qualified
        end
    end
end
local sourceOut, sourceQual = greedOutcome(source)
local replicaOut, replicaQual = greedOutcome(replica)
assertEq(sourceQual, true, "source treats Greed as BiS")
assertEq(replicaQual, true, "replica treats Greed as BiS")
assertEq(sourceOut, replicaOut, "both admins freeze the same automatic outcome for the same award")
SF.LootHelperComm = nil

-- Live Main Swap is retired. Linking must not rewrite isolated RC recipients
-- or sequential member attribution.
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
    profile = swapProfile,
    author = PLAYER,
    skipPermission = true,
})
assertTrue(swapProfile:AddLootLog(pointLog, { skipBroadcast = true }), "sequential point log is recorded on the source alt")
local liveSwapOk, liveSwapErr = swapProfile:TransferMemberHistory(sourceAlt, WINNER)
assertFalse(liveSwapOk, "live Main Swap is retired")
assertTrue(type(liveSwapErr) == "string" and liveSwapErr:find("Linked Characters", 1, true) ~= nil, "retired Main Swap explains Linked Characters")
assertTrue(swapProfile:LinkCharacters(sourceAlt, WINNER), "characters can be linked instead of swapped")
local swappedRC = nil
local swappedPoint = nil
for _, log in ipairs(swapProfile:GetLootLogs() or {}) do
    if log:GetEventType() == SF.LootLogEventTypes.RC_LOOT_COUNCIL then
        swappedRC = log
    elseif log:GetEventType() == SF.LootLogEventTypes.POINT_CHANGE then
        swappedPoint = log
    end
end
assertTrue(swappedRC ~= nil, "RC log remains after character link")
assertEq(swappedRC:GetEventData().member, sourceAlt, "linking does not rewrite the RC recipient")
assertEq(swappedRC:GetID(), sourceCanonical.awardKey, "linking does not change the external RC identity")
assertTrue(swappedPoint ~= nil, "sequential point log remains after character link")
assertEq(swappedPoint:GetEventData().member, sourceAlt, "linking does not rewrite sequential member attribution")
local sourceMember = swapProfile:getMemberByID(sourceAlt)
local winnerMember = swapProfile:getMemberByID(WINNER)
assertTrue(sourceMember ~= nil and winnerMember ~= nil, "linked characters remain distinct members")
assertEq(sourceMember:GetPointBalance(), winnerMember:GetPointBalance(), "linked characters share identity-wide points")

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
    profile = profile,
    author = PLAYER,
    skipPermission = true,
})
assertTrue(profile:AddLootLog(sequentialLog, { skipBroadcast = true }), "ordinary sequential logs still insert")
assertTrue((profile:ComputeAuthorMax()[PLAYER] or 0) >= 2, "ordinary author max still tracks sequential counters")

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
local lastContiguous = profile:ComputeAuthorMax()[PLAYER]
local gapLog = SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
    member = WINNER,
    change = SF.LootLogPointChangeTypes.INCREMENT,
}, {
    author = PLAYER,
    counter = lastContiguous + 3,
    skipPermission = true,
}):ToTable()
local hasGap, gapFrom, gapTo = Sync:DetectGap(profile:GetProfileId(), gapLog)
assertTrue(hasGap, "ordinary sequential logs still detect gaps")
assertEq(gapFrom, lastContiguous + 1, "ordinary gap starts after the last contiguous sequential counter")
assertEq(gapTo, lastContiguous + 2, "ordinary gap ends before the received sequential counter")

assertTrue(Sync:QueueRepairRanges(profile:GetProfileId(), {
    { author = PLAYER, fromCounter = lastContiguous + 1, toCounter = lastContiguous + 2, mode = "missing" },
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

-- RCLC award-reason identity follows history sort-400, not array index or typeCode
resetEnv()
_G.RCLootCouncil = {
    Getdb = function()
        return {
            profile = {
                responses = {
                    default = {
                        [1] = { text = "Need" },
                    },
                    WEAPON = {
                        [1] = { text = "Need" },
                    },
                },
                awardReasons = {
                    { text = "Bank", sort = 401, log = true },
                    { text = "Disenchant", sort = 405, log = true },
                },
            },
        }
    end,
}
assertEq(Integration.AwardReasonHistoryResponseId({ sort = 405 }), 5, "history responseID is sort-400")
local rcOptions = Integration.GetRCResponseOptions()
local sawDefaultNeed, sawWeaponNeed, sawBank, sawDisenchant = false, false, false, false
local disenchantOption
for i = 1, #rcOptions do
    local opt = rcOptions[i]
    if opt.isAwardReason then
        assertTrue(opt.typeCode == nil, "award-reason option does not invent typeCode awardReason")
        if opt.responseId == 1 and opt.textLabel == "Bank" then
            sawBank = true
        end
        if opt.responseId == 5 and opt.textLabel == "Disenchant" then
            sawDisenchant = true
            disenchantOption = opt
        end
        assertFalse(opt.responseId == 2 and opt.textLabel == "Disenchant", "array index is not the persisted award-reason id")
    else
        if opt.typeCode == "default" and opt.responseId == 1 then
            sawDefaultNeed = true
        end
        if opt.typeCode == "WEAPON" and opt.responseId == 1 then
            sawWeaponNeed = true
        end
    end
end
assertTrue(sawDefaultNeed, "normal default Need is enumerated")
assertTrue(sawWeaponNeed, "same responseId exists in a second typeCode")
assertTrue(sawBank, "default-shaped award reason uses sort-400")
assertTrue(sawDisenchant, "reordered award reason uses sort-400 rather than ipairs index")

local awardProfile = makeProfile("AwardReasonBis")
addMember(awardProfile, WINNER)
setActive(awardProfile)
assertTrue(awardProfile:AddRCLootCouncilBisResponse({
    text = disenchantOption.textLabel,
    responseId = disenchantOption.responseId,
    isAwardReason = true,
}), "configure the real RCLC award reason")
assertTrue(awardProfile:IsBisQualifyingResponse("Disenchant", {
    typeCode = "default",
    responseId = 5,
    isAwardReason = true,
}), "real-shaped award-reason history qualifies")
assertTrue(awardProfile:IsBisQualifyingResponse("Disenchant", {
    typeCode = "WEAPON",
    responseId = 5,
    isAwardReason = true,
}), "award reason still matches when the item typeCode differs")
assertFalse(awardProfile:IsBisQualifyingResponse("Need", {
    typeCode = "default",
    responseId = 5,
    isAwardReason = false,
}), "non-award response with the same numeric id does not match")
_G.RCLootCouncil = nil

-- ---------------------------------------------------------------------------
-- RC config trust boundary and coordinator-serialized convergence
-- ---------------------------------------------------------------------------
local function cloneProfileAs(name, source)
    local copy = makeProfile(name)
    copy._profileId = source:GetProfileId()
    assertTrue((select(1, copy:ImportSnapshot(source:ExportSnapshot()))), name .. " imports source snapshot")
    return copy
end

local function withLocalProfile(profile, fn)
    local id = profile:GetProfileId()
    local previous = SF.lootHelperDB.profiles[id]
    SF.lootHelperDB.profiles[id] = profile
    Sync.state.profileId = id
    fn()
    SF.lootHelperDB.profiles[id] = previous
end

local function cfgEqual(a, b)
    if a.recordAwards ~= b.recordAwards then return false end
    if a.recordAllAwardTypes ~= b.recordAllAwardTypes then return false end
    if #a.allowedResponses ~= #b.allowedResponses then return false end
    for i = 1, #a.allowedResponses do
        if a.allowedResponses[i] ~= b.allowedResponses[i] then return false end
    end
    if #a.bisResponses ~= #b.bisResponses then return false end
    for i = 1, #a.bisResponses do
        if a.bisResponses[i].key ~= b.bisResponses[i].key then return false end
    end
    return true
end

resetEnv()
local ADMIN_A = "AdminA-Garona"
local ADMIN_B = "AdminB-Garona"
local coord = makeProfile("RC Trust Coord")
addMember(coord, WINNER)
addMember(coord, ADMIN_A)
addMember(coord, ADMIN_B)
assertTrue(coord:AddAdminMemberId(ADMIN_A, { skipPermission = true, skipBroadcast = true }), "Admin A is a legitimate admin")
assertTrue(coord:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B is a legitimate admin")
setActive(coord)
startSessionOn(coord)
assertTrue(coord:AddRCLootCouncilBisResponse({
    text = "Need",
    typeCode = "default",
    responseId = 1,
    isAwardReason = false,
}), "shared starting BiS response")
local startingOwner = coord:GetOwnerId()
local startingAdmins = {}
for i, admin in ipairs(coord:GetAdminUsers() or {}) do
    startingAdmins[i] = admin
end
local startingLootMode = coord:GetLootMode()
local startingPot = coord:GetRewardPotConfig()
local startingRaid = coord:GetRaidCheckConfig()
local startingMemberCount = #(coord._members or {})
local startingLogCount = #(coord:GetLootLogs() or {})
local startingFp
local firstLog = coord:GetLootLogs()[1]
if firstLog and firstLog.GetFingerprint then
    startingFp = firstLog:GetFingerprint()
end
local startingEquip = coord._raidCheckEquipmentSnapshots

local poisoned = coord:ExportSnapshot()
poisoned.meta._owner = ADMIN_B
poisoned.adminUsers = { ADMIN_B }
poisoned.members = {}
poisoned.lootMode = "reward_pot"
poisoned.rewardPot = { startingPotCopper = 999999, deductionType = "percent", deductionValue = 50 }
poisoned.raidCheck = coord:GetRaidCheckConfig()
poisoned.raidCheck = {
    enableWhispersPreRaid = true,
    enableWhispersRaid = true,
    enableWhispersRaidPrepared = true,
    pointsAwardPerRaidCheck = 999,
    slots = poisoned.raidCheck and poisoned.raidCheck.slots or {},
}
poisoned.equipmentSnapshots = {
    [WINNER] = { capturedAt = 1, averageItemLevel = 999, slotsByInventory = {} },
}
if type(poisoned.lootLogs) == "table" and poisoned.lootLogs[1] then
    poisoned.lootLogs[1]._fingerprint = "deadbeef-forged"
end

Sync:HandleProfileSnapshot(ADMIN_B, {
    sessionId = Sync.state.sessionId,
    profileId = coord:GetProfileId(),
    snapshot = poisoned,
    reason = "rc-integration",
})
assertEq(coord:GetOwnerId(), startingOwner, "ordinary admin PROFILE_SNAPSHOT cannot steal owner")
assertEq(#(coord:GetAdminUsers() or {}), #startingAdmins, "ordinary admin PROFILE_SNAPSHOT cannot replace admins")
assertEq(coord:GetLootMode(), startingLootMode, "ordinary admin PROFILE_SNAPSHOT cannot change loot mode")
assertEq(coord:GetRewardPotConfig().startingPotCopper, startingPot.startingPotCopper, "ordinary admin PROFILE_SNAPSHOT cannot change Reward Pot")
assertEq(coord:GetRaidCheckConfig().pointsAwardPerRaidCheck, startingRaid.pointsAwardPerRaidCheck, "ordinary admin PROFILE_SNAPSHOT cannot change Raid Check")
assertEq(#(coord._members or {}), startingMemberCount, "ordinary admin PROFILE_SNAPSHOT cannot replace members")
assertEq(#(coord:GetLootLogs() or {}), startingLogCount, "ordinary admin PROFILE_SNAPSHOT cannot replace logs")
if startingFp then
    assertEq(coord:GetLootLogs()[1]:GetFingerprint(), startingFp, "ordinary admin PROFILE_SNAPSHOT cannot rewrite fingerprints")
end
assertTrue(coord._raidCheckEquipmentSnapshots == startingEquip or not next(coord._raidCheckEquipmentSnapshots or {}), "ordinary admin PROFILE_SNAPSHOT cannot install equipment snapshots")

local capturedReq = {}
SF.LootHelperComm = {
    Send = function(_, channel, msgType, payload, dist, target)
        capturedReq[#capturedReq + 1] = {
            channel = channel,
            msgType = msgType,
            payload = payload,
            dist = dist,
            target = target,
        }
    end,
}

local adminCfg = {
    recordAwards = true,
    recordAllAwardTypes = false,
    allowedResponses = { "Need" },
    bisResponses = {
        { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false, key = "default:1" },
    },
}
Sync:HandleRCConfigRequest(ADMIN_B, {
    sessionId = Sync.state.sessionId,
    profileId = coord:GetProfileId(),
    rcLootCouncilIntegration = adminCfg,
    snapshot = poisoned,
    meta = { _owner = ADMIN_B },
    adminUsers = { ADMIN_B },
    lootLogs = poisoned.lootLogs,
})
assertEq(coord:GetOwnerId(), startingOwner, "RC_CONFIG_REQ cannot become canonical owner")
assertEq(#(coord:GetAdminUsers() or {}), #startingAdmins, "RC_CONFIG_REQ cannot replace admins")
assertEq(coord:GetLootMode(), startingLootMode, "RC_CONFIG_REQ cannot change loot mode")
assertEq(coord:GetRewardPotConfig().startingPotCopper, startingPot.startingPotCopper, "RC_CONFIG_REQ cannot change Reward Pot")
assertEq(coord:GetRaidCheckConfig().pointsAwardPerRaidCheck, startingRaid.pointsAwardPerRaidCheck, "RC_CONFIG_REQ cannot change Raid Check")
assertEq(#(coord._members or {}), startingMemberCount, "RC_CONFIG_REQ cannot replace members")
assertEq(#(coord:GetLootLogs() or {}), startingLogCount, "RC_CONFIG_REQ cannot replace logs")
local afterCfg = coord:GetRCLootCouncilIntegrationConfig()
assertFalse(afterCfg.recordAllAwardTypes, "RC_CONFIG_REQ still applies RC settings")
assertEq(afterCfg.allowedResponses[1], "Need", "RC_CONFIG_REQ applied allowed responses")
assertTrue(#capturedReq >= 1 and capturedReq[#capturedReq].msgType == Sync.MSG.RC_CONFIG_SET, "coordinator broadcasts RC_CONFIG_SET")
assertTrue(capturedReq[#capturedReq].payload.snapshot == nil, "authoritative SET has no snapshot")

Sync:HandleRCConfigSet(ADMIN_B, {
    sessionId = Sync.state.sessionId,
    profileId = coord:GetProfileId(),
    coordinator = ADMIN_B,
    seq = 99,
    rcLootCouncilIntegration = {
        recordAwards = false,
        recordAllAwardTypes = true,
        allowedResponses = {},
        bisResponses = {},
    },
    snapshot = poisoned,
})
assertTrue(coord:GetRCLootCouncilIntegrationConfig().recordAwards, "non-coordinator RC_CONFIG_SET is ignored")
assertEq(coord:GetOwnerId(), startingOwner, "spoofed RC_CONFIG_SET cannot steal owner")

-- Non-coordinator admin publishes RC_CONFIG_REQ, not a full snapshot
resetEnv()
local follower = makeProfile("RC Follower")
addMember(follower, WINNER)
setActive(follower)
startSessionOn(follower)
Sync.state.isCoordinator = false
Sync.state.coordinator = "Coord-Garona"
capturedReq = {}
SF.LootHelperComm = {
    Send = function(_, channel, msgType, payload, dist, target)
        capturedReq[#capturedReq + 1] = {
            channel = channel,
            msgType = msgType,
            payload = payload,
            dist = dist,
            target = target,
        }
    end,
}
assertTrue(follower:SetRCLootCouncilRecordAllAwardTypes(false), "follower can propose RC settings")
assertTrue(follower:GetRCLootCouncilIntegrationConfig().recordAllAwardTypes, "unaccepted follower proposal is not locally authoritative")
assertEq(capturedReq[1].msgType, Sync.MSG.RC_CONFIG_REQ, "non-coordinator proposes RC_CONFIG_REQ")
assertEq(capturedReq[1].target, "Coord-Garona", "REQ is whispered to the coordinator")
assertTrue(capturedReq[1].payload.snapshot == nil, "REQ does not include a full snapshot")
assertTrue(capturedReq[1].payload.rcLootCouncilIntegration ~= nil, "REQ carries RC config only")
assertFalse(capturedReq[1].payload.rcLootCouncilIntegration.recordAllAwardTypes, "REQ carries the unaccepted proposal")
local pendingFollower = follower:GetProposedRCLootCouncilIntegrationConfig()
assertTrue(pendingFollower ~= nil, "follower keeps a pending proposal until SET")
assertFalse(pendingFollower.recordAllAwardTypes, "pending proposal has record-all=false")

-- Concurrent A/B edits: opposite SET delivery still converges
resetEnv()
local shared = makeProfile("RC Concurrent")
addMember(shared, WINNER)
addMember(shared, ADMIN_A)
addMember(shared, ADMIN_B)
assertTrue(shared:AddAdminMemberId(ADMIN_A, { skipPermission = true, skipBroadcast = true }), "Admin A joined concurrent profile")
assertTrue(shared:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B joined concurrent profile")
assertTrue(shared:AddRCLootCouncilBisResponse({
    text = "Need",
    typeCode = "default",
    responseId = 1,
    isAwardReason = false,
}), "shared starting Need BiS")
setActive(shared)
startSessionOn(shared)
local peerC = cloneProfileAs("PeerC", shared)
local peerD = cloneProfileAs("PeerD", shared)
capturedReq = {}
SF.LootHelperComm = {
    Send = function(_, channel, msgType, payload, dist, target)
        capturedReq[#capturedReq + 1] = {
            channel = channel,
            msgType = msgType,
            payload = payload,
            dist = dist,
            target = target,
        }
    end,
}
local cfgA = {
    recordAwards = true,
    recordAllAwardTypes = false,
    allowedResponses = { "Need" },
    bisResponses = {
        { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
    },
}
local cfgB = {
    recordAwards = true,
    recordAllAwardTypes = true,
    allowedResponses = {},
    bisResponses = {
        { text = "Greed", typeCode = "default", responseId = 2, isAwardReason = false },
    },
}
Sync:HandleRCConfigRequest(ADMIN_A, {
    sessionId = Sync.state.sessionId,
    profileId = shared:GetProfileId(),
    rcLootCouncilIntegration = cfgA,
})
Sync:HandleRCConfigRequest(ADMIN_B, {
    sessionId = Sync.state.sessionId,
    profileId = shared:GetProfileId(),
    rcLootCouncilIntegration = cfgB,
})
local sets = {}
for i = 1, #capturedReq do
    if capturedReq[i].msgType == Sync.MSG.RC_CONFIG_SET then
        sets[#sets + 1] = capturedReq[i].payload
    end
end
assertEq(#sets, 2, "coordinator published two authoritative SETs")
assertTrue(sets[1].seq < sets[2].seq, "coordinator seq is monotonic")

local function applySets(profile, order)
    local previousPlayer = PLAYER
    PLAYER = "Peer-Garona"
    withLocalProfile(profile, function()
        for i = 1, #order do
            Sync:HandleRCConfigSet("Tester-Garona", order[i])
        end
    end)
    PLAYER = previousPlayer
end
applySets(peerC, { sets[1], sets[2] })
applySets(peerD, { sets[2], sets[1] })
local coordCfg = shared:GetRCLootCouncilIntegrationConfig()
local cCfg = peerC:GetRCLootCouncilIntegrationConfig()
local dCfg = peerD:GetRCLootCouncilIntegrationConfig()
assertTrue(cfgEqual(coordCfg, cCfg), "peer C matches coordinator")
assertTrue(cfgEqual(coordCfg, dCfg), "peer D matches coordinator despite reversed delivery")
assertTrue(coordCfg.recordAllAwardTypes, "later coordinator-accepted config is B")
assertEq(coordCfg.bisResponses[1].responseId, 2, "converged BiS list is Admin B's Greed")
assertEq(peerC._rcConfigSeq, sets[2].seq, "peer C stored the highest seq")
assertEq(peerD._rcConfigSeq, sets[2].seq, "peer D stored the highest seq")

local greedCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
    id = "1700000911-1",
    response = "Greed",
    responseID = 2,
}))
assertTrue(shared:TryAddRCLootCouncilAward(greedCanon), "coordinator records the converged Greed award")
assertTrue(peerC:TryAddRCLootCouncilAward(greedCanon), "peer C records the same award")
assertTrue(peerD:TryAddRCLootCouncilAward(greedCanon), "peer D records the same award")
local function awardOutcome(profile)
    for _, log in ipairs(profile:GetLootLogs() or {}) do
        local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
        if data and data.awardKey == greedCanon.awardKey then
            return data.outcome, data.qualified
        end
    end
end
local o1, q1 = awardOutcome(shared)
local o2, q2 = awardOutcome(peerC)
local o3, q3 = awardOutcome(peerD)
assertEq(q1, true, "coordinator qualifies Greed after convergence")
assertEq(q2, q1, "peer C matches coordinator qualification")
assertEq(q3, q1, "peer D matches coordinator qualification")
assertEq(o2, o1, "peer C matches coordinator outcome")
assertEq(o3, o1, "peer D matches coordinator outcome")
SF.LootHelperComm = nil

resetEnv()
local seqGuard = makeProfile("SeqGuard")
addMember(seqGuard, WINNER)
assertTrue(seqGuard:ApplyRCLootCouncilIntegrationConfig({
    recordAwards = true,
    recordAllAwardTypes = true,
    allowedResponses = {},
    bisResponses = {
        { text = "Greed", typeCode = "default", responseId = 2, isAwardReason = false },
    },
}, { skipPermission = true, skipSync = true }), "seed newer RC config")
seqGuard._rcConfigSeq = 2
local staleSnap = seqGuard:ExportSnapshot()
staleSnap.rcConfigSeq = 1
staleSnap.rcLootCouncilIntegration = {
    recordAwards = true,
    recordAllAwardTypes = false,
    allowedResponses = { "Need" },
    bisResponses = {
        { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
    },
}
assertTrue((select(1, seqGuard:ImportSnapshot(staleSnap))), "stale trusted snapshot still imports")
assertEq(seqGuard._rcConfigSeq, 2, "stale snapshot cannot lower rcConfigSeq")
assertTrue(seqGuard:IsBisQualifyingResponse("Greed", {
    typeCode = "default",
    responseId = 2,
    isAwardReason = false,
}), "stale snapshot cannot regress bisResponses")
assertFalse(seqGuard:IsBisQualifyingResponse("Need", {
    typeCode = "default",
    responseId = 1,
    isAwardReason = false,
}), "stale snapshot cannot replace the newer BiS list")
staleSnap.rcConfigSeq = 3
assertTrue((select(1, seqGuard:ImportSnapshot(staleSnap))), "newer snapshot seq is accepted")
assertEq(seqGuard._rcConfigSeq, 3, "newer snapshot advances rcConfigSeq")
assertTrue(seqGuard:IsBisQualifyingResponse("Need", {
    typeCode = "default",
    responseId = 1,
    isAwardReason = false,
}), "newer snapshot may update RC config")

local function testAcceptedVsPendingAndTakeover()
    local function captureComm()
        local captured = {}
        SF.LootHelperComm = {
            Send = function(_, channel, msgType, payload, dist, target)
                captured[#captured + 1] = {
                    channel = channel,
                    msgType = msgType,
                    payload = payload,
                    dist = dist,
                    target = target,
                }
            end,
        }
        return captured
    end

    local function lastOfType(captured, msgType)
        local found
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                found = captured[i]
            end
        end
        return found
    end

    local function greedMeta()
        return { typeCode = "default", responseId = 2, isAwardReason = false }
    end

    local function greedHistory(historyId)
        return historyTable({
            id = historyId,
            response = "Greed",
            responseID = 2,
            isAwardReason = false,
        })
    end

    local function awardOutcome(profile, awardKey)
        for _, log in ipairs(profile:GetLootLogs() or {}) do
            local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
            if data and data.awardKey == awardKey then
                return data.outcome, data.qualified
            end
        end
    end

    local function seedNeedOnlyConfig(profile)
        assertTrue(profile:ApplyRCLootCouncilIntegrationConfig({
            recordAwards = true,
            recordAllAwardTypes = false,
            allowedResponses = { "Need" },
            bisResponses = {
                { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
            },
        }, { skipPermission = true, skipSync = true }), "seed accepted Need-only RC config")
    end

    -- Award after local proposal, before coordinator acceptance
    resetEnv()
    local previousPlayer = PLAYER
    local adminA = makeProfile("RC Pre-SET A")
    addMember(adminA, WINNER)
    addMember(adminA, ADMIN_B)
    assertTrue(adminA:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B can propose from a follower client")
    seedNeedOnlyConfig(adminA)
    setActive(adminA)
    startSessionOn(adminA)
    adminA._rcConfigSeq = 4
    adminA._rcConfigEpoch = Sync.state.coordEpoch
    Sync.state.rcConfigSeq = 4
    local adminB = cloneProfileAs("RC Pre-SET B", adminA)
    assertEq(adminB._rcConfigSeq, 4, "both clients start at accepted seq 4")
    assertFalse(adminA:IsBisQualifyingResponse("Greed", greedMeta()), "Admin A does not treat Greed as BiS")
    assertFalse(adminB:IsBisQualifyingResponse("Greed", greedMeta()), "Admin B starts without Greed as BiS")

    local captured = captureComm()
    PLAYER = ADMIN_B
    Sync.state.isCoordinator = false
    Sync.state.coordinator = previousPlayer
    SF.lootHelperDB.profiles[adminB:GetProfileId()] = adminB
    assertTrue(adminB:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    }), "non-coordinator can send an RC_CONFIG_REQ proposal")
    local req = lastOfType(captured, Sync.MSG.RC_CONFIG_REQ)
    assertTrue(req ~= nil, "Admin B sent RC_CONFIG_REQ")
    assertTrue(req.payload.rcLootCouncilIntegration ~= nil, "REQ carries the proposal")
    local proposed = adminB:GetProposedRCLootCouncilIntegrationConfig()
    assertTrue(proposed ~= nil, "Admin B stores a pending proposal")
    assertEq(proposed.bisResponses[#proposed.bisResponses].responseId, 2, "pending proposal adds Greed as BiS")
    assertFalse(adminB:IsBisQualifyingResponse("Greed", greedMeta()), "pending Greed BiS is not accepted yet")
    assertEq(adminB._rcConfigSeq, 4, "proposal does not advance accepted seq")

    local preSetCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, greedHistory("1700003000-pre"))
    PLAYER = previousPlayer
    SF.lootHelperDB.profiles[adminA:GetProfileId()] = adminA
    Sync.state.isCoordinator = true
    Sync.state.coordinator = previousPlayer
    assertEq(select(2, adminA:TryAddRCLootCouncilAward(preSetCanon)), "filtered", "coordinator still filters Greed before accepting the REQ")
    PLAYER = ADMIN_B
    assertEq(select(2, adminB:TryAddRCLootCouncilAward(preSetCanon)), "filtered", "proposer still filters Greed before RC_CONFIG_SET")
    assertEq(countRCLogs(adminA), 0, "coordinator did not freeze a pre-SET Greed award")
    assertEq(countRCLogs(adminB), 0, "proposer did not freeze a pre-SET Greed award")
    assertEq(awardOutcome(adminA, preSetCanon.awardKey), nil, "coordinator wrote no pre-SET BIS_OUTCOME")
    assertEq(awardOutcome(adminB, preSetCanon.awardKey), nil, "proposer wrote no pre-SET BIS_OUTCOME")

    -- Failed RC_CONFIG_REQ send discards the proposal
    resetEnv()
    previousPlayer = PLAYER
    local failProfile = makeProfile("RC REQ Fail")
    addMember(failProfile, WINNER)
    seedNeedOnlyConfig(failProfile)
    setActive(failProfile)
    startSessionOn(failProfile)
    failProfile._rcConfigSeq = 5
    Sync.state.rcConfigSeq = 5
    Sync.state.isCoordinator = false
    Sync.state.coordinator = "Coord-Garona"
    SF.LootHelperComm = {
        Send = function()
            return false
        end,
    }
    local okFail, failErr = failProfile:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    })
    assertFalse(okFail, "failed REQ send does not report success")
    assertEq(failErr, "send failed", "failed REQ send surfaces the send error")
    assertTrue(failProfile:GetProposedRCLootCouncilIntegrationConfig() == nil, "failed REQ send discards pending proposal")
    assertFalse(failProfile:IsBisQualifyingResponse("Greed", greedMeta()), "failed REQ cannot make Greed BiS-authoritative")
    assertTrue(failProfile:GetRCLootCouncilIntegrationConfig().recordAllAwardTypes == false, "accepted config is unchanged after REQ failure")

    -- Helper snapshot while a proposal is pending exports accepted config only
    resetEnv()
    previousPlayer = PLAYER
    local helper = makeProfile("RC Helper Pending")
    addMember(helper, WINNER)
    addMember(helper, ADMIN_B)
    assertTrue(helper:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "helper is an admin")
    seedNeedOnlyConfig(helper)
    setActive(helper)
    startSessionOn(helper)
    helper._rcConfigSeq = 6
    helper._rcConfigEpoch = Sync.state.coordEpoch
    Sync.state.rcConfigSeq = 6
    captured = captureComm()
    PLAYER = ADMIN_B
    Sync.state.isCoordinator = false
    Sync.state.coordinator = "Coord-Garona"
    assertTrue(helper:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    }), "helper can propose Greed BiS")
    assertEq(helper._rcConfigSeq, 6, "helper accepted seq stays at 6")
    local pendingSnap = helper:ExportSnapshot()
    assertEq(pendingSnap.rcConfigSeq, 6, "helper snapshot keeps accepted seq 6")
    assertEq(pendingSnap.rcConfigEpoch, helper._rcConfigEpoch, "helper snapshot keeps accepted epoch")
    assertEq(#pendingSnap.rcLootCouncilIntegration.bisResponses, 1, "helper snapshot does not export the pending BiS list")
    assertEq(pendingSnap.rcLootCouncilIntegration.bisResponses[1].responseId, 1, "helper snapshot still exports Need-only accepted config")
    local joiner = makeProfile("RC Joiner")
    joiner._profileId = helper:GetProfileId()
    assertTrue((select(1, joiner:ImportSnapshot(pendingSnap))), "joiner imports helper snapshot at equal seq")
    assertEq(joiner._rcConfigSeq, 6, "joiner stores accepted seq 6")
    assertFalse(joiner:IsBisQualifyingResponse("Greed", greedMeta()), "equal-seq helper snapshot cannot install the unaccepted proposal")
    assertTrue(joiner:IsBisQualifyingResponse("Need", {
        typeCode = "default",
        responseId = 1,
        isAwardReason = false,
    }), "joiner keeps the last accepted Need BiS")

    -- Proposal accepted via SET, then a subsequent award uses the new config
    PLAYER = previousPlayer
    resetEnv()
    previousPlayer = PLAYER
    adminA = makeProfile("RC Post-SET A")
    addMember(adminA, WINNER)
    addMember(adminA, ADMIN_B)
    assertTrue(adminA:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B may propose")
    seedNeedOnlyConfig(adminA)
    setActive(adminA)
    startSessionOn(adminA)
    adminA._rcConfigSeq = 7
    adminA._rcConfigEpoch = Sync.state.coordEpoch
    Sync.state.rcConfigSeq = 7
    adminB = cloneProfileAs("RC Post-SET B", adminA)
    captured = captureComm()
    PLAYER = ADMIN_B
    Sync.state.isCoordinator = false
    Sync.state.coordinator = previousPlayer
    SF.lootHelperDB.profiles[adminB:GetProfileId()] = adminB
    assertTrue(adminB:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    }), "Admin B proposes Greed BiS")
    req = lastOfType(captured, Sync.MSG.RC_CONFIG_REQ)
    PLAYER = previousPlayer
    SF.lootHelperDB.profiles[adminA:GetProfileId()] = adminA
    Sync.state.isCoordinator = true
    Sync.state.coordinator = previousPlayer
    captured = captureComm()
    Sync:HandleRCConfigRequest(ADMIN_B, req.payload)
    local setMsg = lastOfType(captured, Sync.MSG.RC_CONFIG_SET)
    assertTrue(setMsg ~= nil, "coordinator accepts the REQ and publishes RC_CONFIG_SET")
    assertTrue(adminA:IsBisQualifyingResponse("Greed", greedMeta()), "coordinator accepted Greed as BiS")
    PLAYER = "Peer-Garona"
    withLocalProfile(adminB, function()
        Sync:HandleRCConfigSet(previousPlayer, setMsg.payload)
    end)
    PLAYER = previousPlayer
    assertTrue(adminB:IsBisQualifyingResponse("Greed", greedMeta()), "follower accepted Greed as BiS from SET")
    assertTrue(cfgEqual(adminA:GetRCLootCouncilIntegrationConfig(), adminB:GetRCLootCouncilIntegrationConfig()), "both accepted configs match after SET")
    assertTrue(adminB:GetProposedRCLootCouncilIntegrationConfig() == nil, "SET clears the follower proposal")
    local postSetCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, greedHistory("1700003001-post"))
    assertTrue(adminA:TryAddRCLootCouncilAward(postSetCanon), "coordinator records Greed after SET")
    assertTrue(adminB:TryAddRCLootCouncilAward(postSetCanon), "follower records Greed after SET")
    local postOutcomeA, postQualA = awardOutcome(adminA, postSetCanon.awardKey)
    local postOutcomeB, postQualB = awardOutcome(adminB, postSetCanon.awardKey)
    assertEq(postQualA, true, "coordinator qualifies Greed after SET")
    assertEq(postQualB, true, "follower qualifies Greed after SET")
    assertEq(postOutcomeB, postOutcomeA, "post-SET BIS_OUTCOME matches on both clients")

    -- Coordinator takeover with a stale RC seq must not reuse an ignored generation
    resetEnv()
    local COORD_C = PLAYER
    local ADMIN_D = "AdminD-Garona"
    local coordC = makeProfile("RC Takeover C")
    addMember(coordC, WINNER)
    addMember(coordC, ADMIN_D)
    assertTrue(coordC:AddAdminMemberId(ADMIN_D, { skipPermission = true, skipBroadcast = true }), "Admin D can take over")
    seedNeedOnlyConfig(coordC)
    setActive(coordC)
    startSessionOn(coordC)
    captured = captureComm()
    assertTrue(coordC:AddRCLootCouncilAllowedResponse("Offspec"), "coordinator C publishes SET seq N")
    local firstSet = lastOfType(captured, Sync.MSG.RC_CONFIG_SET)
    assertTrue(firstSet ~= nil, "coordinator C sent RC_CONFIG_SET")
    assertEq(firstSet.payload.seq, 1, "first SET is seq 1")
    local peer = cloneProfileAs("RC Takeover Peer", coordC)
    assertEq(peer._rcConfigSeq, 1, "peer accepted seq N")
    local staleD = cloneProfileAs("RC Takeover D", coordC)
    staleD._rcConfigSeq = 0
    staleD._rcConfigEpoch = 0
    seedNeedOnlyConfig(staleD)
    assertEq(staleD._rcConfigSeq, 0, "Admin D missed SET N and still has N-1")

    PLAYER = ADMIN_D
    SF.lootHelperDB.profiles[staleD:GetProfileId()] = staleD
    Sync.state.coordinator = COORD_C
    Sync.state.isCoordinator = false
    Sync.state.rcConfigSeq = 0
    local oldEpoch = tonumber(Sync.state.coordEpoch) or 0
    captured = captureComm()
    assertTrue(Sync:TakeoverSession(Sync.state.sessionId, staleD:GetProfileId(), "coord-offline"), "Admin D takes over through production TakeoverSession")
    assertTrue(Sync.state.isCoordinator, "Admin D is coordinator after takeover")
    assertTrue(Sync.state.coordEpoch > oldEpoch, "takeover bumps coordEpoch")
    assertTrue(lastOfType(captured, Sync.MSG.COORD_TAKEOVER) ~= nil, "takeover broadcasts COORD_TAKEOVER")
    assertTrue(lastOfType(captured, Sync.MSG.SES_REANNOUNCE) ~= nil, "takeover reannounces the session")
    assertEq(Sync.state.rcConfigSeq, 0, "new coordinator adopted its last accepted RC seq")
    captured = captureComm()
    assertTrue(staleD:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    }), "new coordinator publishes RC config after takeover")
    local takeoverSet = lastOfType(captured, Sync.MSG.RC_CONFIG_SET)
    assertTrue(takeoverSet ~= nil, "new coordinator sent RC_CONFIG_SET")
    assertEq(takeoverSet.payload.seq, 1, "stale coordinator would reuse seq N")
    assertTrue(takeoverSet.payload.coordEpoch > oldEpoch, "new SET is tagged with the takeover epoch")
    assertTrue(takeoverSet.payload.coordEpoch > (tonumber(peer._rcConfigEpoch) or 0), "incoming epoch is newer than the peer's accepted epoch")

    PLAYER = "Peer-Garona"
    withLocalProfile(peer, function()
        Sync:HandleRCConfigSet(ADMIN_D, takeoverSet.payload)
    end)
    PLAYER = COORD_C
    assertTrue(peer:IsBisQualifyingResponse("Greed", greedMeta()), "peer accepts the new coordinator SET despite a colliding seq")
    assertEq(peer._rcConfigSeq, 1, "peer stores the reused seq under the new epoch")
    assertEq(peer._rcConfigEpoch, takeoverSet.payload.coordEpoch, "peer stores the takeover RC config epoch")
    assertTrue(staleD:IsBisQualifyingResponse("Greed", greedMeta()), "new coordinator's accepted config includes Greed")
end
testAcceptedVsPendingAndTakeover()

local function testExistingProfileReconnectCatchesUpRCConfig()
    loadModule("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")

    local function captureComm()
        local captured = {}
        SF.LootHelperComm = {
            Send = function(_, channel, msgType, payload, dist, target)
                captured[#captured + 1] = {
                    channel = channel,
                    msgType = msgType,
                    payload = payload,
                    dist = dist,
                    target = target,
                }
                return true
            end,
        }
        return captured
    end

    local function lastOfType(captured, msgType)
        local found
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                found = captured[i]
            end
        end
        return found
    end

    local function greedMeta()
        return { typeCode = "default", responseId = 2, isAwardReason = false }
    end

    function Sync:NewRequestId()
        return "REQ-RC-CATCHUP"
    end
    function Sync:GetPeer(nameRealm)
        self.state.peers = self.state.peers or {}
        local peer = self.state.peers[nameRealm]
        if not peer then
            peer = { name = nameRealm, inGroup = true }
            self.state.peers[nameRealm] = peer
        end
        peer.inGroup = true
        return peer
    end
    function Sync:_ApplySessionSafeModeFromPayload()
    end
    function Sync:EnsureHeartbeatMonitor()
        return false
    end
    function Sync:SetPeerSyncState()
    end
    function Sync:RegisterRequest(requestId, kind, target, meta)
        self.state.requests = self.state.requests or {}
        self.state.requests[requestId] = { id = requestId, kind = kind, target = target, meta = meta }
        if kind == "NEED_PROFILE" and SF.LootHelperComm then
            SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_PROFILE, {
                sessionId = self.state.sessionId,
                profileId = self.state.profileId,
                requestId = requestId,
            }, "WHISPER", target, "NORMAL")
        end
        return true
    end

    local function settleSnapshot(coordProfile, follower, captured)
        assertTrue(lastOfType(captured, Sync.MSG.NEED_PROFILE) == nil, "RC catch-up does not request NEED_PROFILE")
        assertTrue(lastOfType(captured, Sync.MSG.PROFILE_SNAPSHOT) == nil, "RC catch-up does not require PROFILE_SNAPSHOT")
    end

    resetEnv()
    local coord = makeProfile("RC Reconnect Coord")
    addMember(coord, WINNER)
    addMember(coord, ADMIN_B)
    assertTrue(coord:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B shares the profile")
    assertTrue(coord:ApplyRCLootCouncilIntegrationConfig({
        recordAwards = true,
        recordAllAwardTypes = false,
        allowedResponses = { "Need" },
        bisResponses = {
            { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
        },
    }, { skipPermission = true, skipSync = true }), "shared accepted config excludes Greed")
    setActive(coord)
    startSessionOn(coord)
    Sync.state.coordinator = PLAYER
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 1
    coord._rcConfigSeq = 1
    coord._rcConfigEpoch = 1
    Sync.state.rcConfigSeq = 1
    local follower = cloneProfileAs("RC Reconnect B", coord)
    assertEq(follower._rcConfigSeq, 1, "Admin B starts at accepted seq 1")
    assertFalse(follower:IsBisQualifyingResponse("Greed", greedMeta()), "Admin B starts without Greed as BiS")

    local captured = captureComm()
    assertTrue(coord:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    }), "coordinator accepts Greed as BiS")
    local setMsg = lastOfType(captured, Sync.MSG.RC_CONFIG_SET)
    assertTrue(setMsg ~= nil, "coordinator published the next SET")
    assertTrue(coord:IsBisQualifyingResponse("Greed", greedMeta()), "coordinator accepted Greed")
    assertFalse(follower:IsBisQualifyingResponse("Greed", greedMeta()), "Admin B missed the SET")
    assertEq(follower._rcConfigSeq, 1, "Admin B still has the previous accepted seq")

    captured = captureComm()
    Sync.state.isCoordinator = true
    Sync:BroadcastSessionHeartbeat()
    local heartbeat = lastOfType(captured, Sync.MSG.SES_HEARTBEAT)
    assertTrue(heartbeat ~= nil, "coordinator heartbeat was sent")
    Sync:ReannounceSession()
    local reannounce = lastOfType(captured, Sync.MSG.SES_REANNOUNCE)
    if not reannounce then
        reannounce = {
            payload = heartbeat.payload,
        }
    end

    PLAYER = ADMIN_B
    captured = captureComm()
    withLocalProfile(follower, function()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.isCoordinator = false
        Sync.state.coordEpoch = 1
        Sync.state._sentJoinStatusForSessionId = Sync.state.sessionId
        Sync.state._sentJoinStatusType = "HAVE_PROFILE"
        Sync.state._profileReqInFlight = nil
        Sync.state.heartbeat = { lastCatchupAt = nil }
        Sync:HandleSessionReannounce("Tester-Garona", reannounce.payload)
        Sync:SendJoinStatus()
    end)
    settleSnapshot(coord, follower, captured)
    assertTrue(follower:IsBisQualifyingResponse("Greed", greedMeta()), "reannounce/join catch-up applies coordinator-accepted Greed")
    assertEq(follower._rcConfigSeq, coord._rcConfigSeq, "follower accepted seq matches coordinator after join catch-up")

    resetEnv()
    coord = makeProfile("RC Heartbeat Catchup")
    addMember(coord, WINNER)
    addMember(coord, ADMIN_B)
    assertTrue(coord:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "heartbeat catch-up Admin B shares the profile")
    assertTrue(coord:ApplyRCLootCouncilIntegrationConfig({
        recordAwards = true,
        recordAllAwardTypes = false,
        allowedResponses = { "Need" },
        bisResponses = {
            { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
        },
    }, { skipPermission = true, skipSync = true }), "heartbeat catch-up seeds Need-only config")
    setActive(coord)
    startSessionOn(coord)
    Sync.state.coordinator = PLAYER
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 1
    coord._rcConfigSeq = 1
    coord._rcConfigEpoch = 1
    Sync.state.rcConfigSeq = 1
    follower = cloneProfileAs("RC Heartbeat B", coord)
    captured = captureComm()
    assertTrue(coord:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    }), "heartbeat-path coordinator accepts Greed as BiS")
    captured = captureComm()
    Sync:BroadcastSessionHeartbeat()
    heartbeat = lastOfType(captured, Sync.MSG.SES_HEARTBEAT)
    assertTrue(heartbeat ~= nil, "heartbeat advertises session state")

    PLAYER = ADMIN_B
    captured = captureComm()
    withLocalProfile(follower, function()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.isCoordinator = false
        Sync.state.coordEpoch = 1
        Sync.state._sentJoinStatusForSessionId = Sync.state.sessionId
        Sync.state._sentJoinStatusType = "HAVE_PROFILE"
        Sync.state._profileReqInFlight = nil
        Sync.state.heartbeat = { lastCatchupAt = nil }
        Sync:HandleSessionHeartbeat("Tester-Garona", heartbeat.payload)
    end)
    settleSnapshot(coord, follower, captured)
    assertTrue(follower:IsBisQualifyingResponse("Greed", greedMeta()), "heartbeat catch-up applies coordinator-accepted Greed")
    assertTrue(follower:GetProposedRCLootCouncilIntegrationConfig() == nil, "catch-up writes accepted config, not a pending proposal")

    local greedCanon = SF.LootLog.BuildRCLootCouncilCanonical("Tester-Garona", WINNER, {
        lootWon = ITEM_LINK,
        response = "Greed",
        id = "1700000912-1",
        owner = WINNER,
        responseID = 2,
        isAwardReason = false,
    })
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[follower:GetProfileId()] = follower
    SF.lootHelperDB.activeProfileId = follower:GetProfileId()
    SF.lootHelperDB.activeProfile = follower
    assertTrue(follower:TryAddRCLootCouncilAward(greedCanon), "Admin B records a Greed award after catch-up")
    local qualified
    local outcome
    for _, log in ipairs(follower:GetLootLogs() or {}) do
        local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
        if data and data.awardKey == greedCanon.awardKey then
            qualified = data.qualified
            outcome = data.outcome
        end
    end
    assertEq(qualified, true, "Greed is qualified BiS on Admin B after reconnect catch-up")
    assertTrue(outcome ~= "NOT_BIS", "caught-up Greed is not recorded as NOT_BIS")
    PLAYER = "Tester-Garona"

    resetEnv()
    local idle = makeProfile("RC Idle Reconnect")
    addMember(idle, WINNER)
    addMember(idle, ADMIN_B)
    assertTrue(idle:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "idle reconnect Admin B shares the profile")
    assertTrue(idle:ApplyRCLootCouncilIntegrationConfig({
        recordAwards = true,
        recordAllAwardTypes = false,
        allowedResponses = { "Need" },
        bisResponses = {
            { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
        },
    }, { skipPermission = true, skipSync = true }), "idle reconnect has accepted Need-only config and no SET")
    setActive(idle)
    startSessionOn(idle)
    Sync.state.coordinator = PLAYER
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 5
    idle._rcConfigSeq = 0
    idle._rcConfigEpoch = 0
    Sync.state.rcConfigSeq = 0
    local idleB = cloneProfileAs("RC Idle B", idle)
    captured = captureComm()
    Sync:BroadcastSessionHeartbeat()
    heartbeat = lastOfType(captured, Sync.MSG.SES_HEARTBEAT)
    assertTrue(heartbeat ~= nil, "idle reconnect heartbeat was sent")
    assertEq(heartbeat.payload.rcConfigSeq, 0, "no SET advertises accepted seq 0")
    assertEq(heartbeat.payload.rcConfigEpoch, 0, "no SET advertises accepted epoch 0, not live coordEpoch")
    assertEq(heartbeat.payload.coordEpoch, 5, "session coordEpoch remains 5")
    PLAYER = ADMIN_B
    captured = captureComm()
    withLocalProfile(idleB, function()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.isCoordinator = false
        Sync.state.coordEpoch = 5
        Sync.state._sentJoinStatusForSessionId = nil
        Sync.state._sentJoinStatusType = nil
        Sync.state._profileReqInFlight = nil
        Sync.state.heartbeat = { lastCatchupAt = nil }
        Sync:HandleSessionHeartbeat("Tester-Garona", heartbeat.payload)
        Sync:SendJoinStatus()
    end)
    assertTrue(lastOfType(captured, Sync.MSG.NEED_PROFILE) == nil, "matching RC generation does not request a snapshot")
    PLAYER = "Tester-Garona"
    SF.LootHelperComm = nil
end
testExistingProfileReconnectCatchesUpRCConfig()

local function testOutOfSessionRCConfigBecomesSessionAuthoritative()
    loadModule("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")

    local function captureComm()
        local captured = {}
        SF.LootHelperComm = {
            Send = function(_, channel, msgType, payload, dist, target)
                captured[#captured + 1] = {
                    channel = channel,
                    msgType = msgType,
                    payload = payload,
                    dist = dist,
                    target = target,
                }
                return true
            end,
        }
        return captured
    end

    local function lastOfType(captured, msgType)
        local found
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                found = captured[i]
            end
        end
        return found
    end

    local function greedMeta()
        return { typeCode = "default", responseId = 2, isAwardReason = false }
    end

    function Sync:_NextNonce(tag)
        return tostring(tag or "N") .. "-START"
    end
    function Sync:_ResetSessionSafeMode()
    end
    function Sync:_ResetLocalSafeMode()
    end
    function Sync:BeginAdminConvergence()
        self:BroadcastSessionStart()
    end
    function Sync:BroadcastSessionStart()
        local profile = self.FindLocalProfileById and self:FindLocalProfileById(self.state.profileId) or nil
        if self._MintDirtySessionRCConfig then
            self:_MintDirtySessionRCConfig(profile)
        end
        if self._RefreshAdvertisedAuthorMax then
            self:_RefreshAdvertisedAuthorMax(self.state.profileId)
        end
        local payload = {
            sessionId = self.state.sessionId,
            profileId = self.state.profileId,
            coordinator = self.state.coordinator,
            coordEpoch = self.state.coordEpoch,
            authorMax = self.state.authorMax or {},
            authorWindowSummary = (self.ComputeAuthorWindowSummary and self:ComputeAuthorWindowSummary(self.state.profileId)) or {},
            helpers = {},
        }
        if self._AttachRCConfigGeneration then
            self:_AttachRCConfigGeneration(payload, self.state.profileId)
        end
        if self._RememberAdvertisedRCConfigGeneration then
            self:_RememberAdvertisedRCConfigGeneration(payload)
        end
        if SF.LootHelperComm and SF.LootHelperComm.Send then
            SF.LootHelperComm:Send("CONTROL", self.MSG.SES_START, payload, "RAID", nil, "ALERT")
        end
    end
    function Sync:NewRequestId()
        return "REQ-RC-SESSION-START"
    end
    function Sync:GetPeer(nameRealm)
        self.state.peers = self.state.peers or {}
        local peer = self.state.peers[nameRealm]
        if not peer then
            peer = { name = nameRealm, inGroup = true }
            self.state.peers[nameRealm] = peer
        end
        peer.inGroup = true
        return peer
    end
    function Sync:_ApplySessionSafeModeFromPayload()
    end
    function Sync:EnsureHeartbeatMonitor()
        return false
    end
    function Sync:SetPeerSyncState()
    end
    function Sync:RegisterRequest(requestId, kind, target, meta)
        self.state.requests = self.state.requests or {}
        self.state.requests[requestId] = { id = requestId, kind = kind, target = target, meta = meta }
        if kind == "NEED_PROFILE" and SF.LootHelperComm then
            SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_PROFILE, {
                sessionId = self.state.sessionId,
                profileId = self.state.profileId,
                requestId = requestId,
            }, "WHISPER", target, "NORMAL")
        end
        return true
    end

    local function settleSnapshot(coordProfile, follower, captured)
        assertTrue(lastOfType(captured, Sync.MSG.NEED_PROFILE) == nil, "session-start RC catch-up does not request NEED_PROFILE")
        assertTrue(lastOfType(captured, Sync.MSG.PROFILE_SNAPSHOT) == nil, "session-start RC catch-up does not require PROFILE_SNAPSHOT")
    end

    local function joinFromStart(coordProfile, follower, startCaptured)
        local startMsg = lastOfType(startCaptured, Sync.MSG.SES_START)
        assertTrue(startMsg ~= nil, "StartSession announced SES_START")
        PLAYER = "Tester-Garona"
        Sync.state.active = true
        Sync.state.isCoordinator = true
        Sync.state.coordinator = PLAYER
        Sync.state.sessionId = startMsg.payload.sessionId
        Sync.state.profileId = startMsg.payload.profileId
        Sync.state.coordEpoch = startMsg.payload.coordEpoch
        local captured = captureComm()
        assertTrue(Sync:BroadcastSessionHeartbeat(), "coordinator heartbeat was sent")
        local heartbeat = lastOfType(captured, Sync.MSG.SES_HEARTBEAT)
        assertTrue(heartbeat ~= nil, "session heartbeat advertised RC generation")
        PLAYER = ADMIN_B
        captured = captureComm()
        withLocalProfile(follower, function()
            Sync.state.active = true
            Sync.state.sessionId = startMsg.payload.sessionId
            Sync.state.profileId = startMsg.payload.profileId
            Sync.state.coordinator = "Tester-Garona"
            Sync.state.coordEpoch = startMsg.payload.coordEpoch
            Sync.state.isCoordinator = false
            Sync.state._sentJoinStatusForSessionId = Sync.state.sessionId
            Sync.state._sentJoinStatusType = "HAVE_PROFILE"
            Sync.state._profileReqInFlight = nil
            Sync.state.heartbeat = { lastCatchupAt = nil }
            Sync:HandleSessionHeartbeat("Tester-Garona", heartbeat.payload)
            Sync:SendJoinStatus()
        end)
        PLAYER = "Tester-Garona"
        settleSnapshot(coordProfile, follower, captured)
        return captured
    end

    local function seedSharedNeedConfig(profile)
        assertTrue(profile:ApplyRCLootCouncilIntegrationConfig({
            recordAwards = true,
            recordAllAwardTypes = false,
            allowedResponses = { "Need" },
            bisResponses = {
                { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
            },
        }, { skipPermission = true, skipSync = true }), "shared accepted Need-only RC config")
    end

    -- Prior accepted generation, out-of-session Greed BiS, then StartSession.
    resetEnv()
    local clock = 100
    function Sync:_Now()
        return clock
    end
    local coord = makeProfile("RC Session Config Coord")
    addMember(coord, WINNER)
    addMember(coord, ADMIN_B)
    assertTrue(coord:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B shares the profile")
    seedSharedNeedConfig(coord)
    setActive(coord)
    startSessionOn(coord)
    Sync.state.coordinator = PLAYER
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 100
    coord._rcConfigSeq = 4
    coord._rcConfigEpoch = 100
    Sync.state.rcConfigSeq = 4
    local greedCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700004001-prior",
        response = "Need",
        responseID = 1,
    }))
    assertTrue(coord:TryAddRCLootCouncilAward(greedCanon), "shared complete logs include a Need award")
    local follower = cloneProfileAs("RC Session Config B", coord)
    assertEq(follower._rcConfigSeq, 4, "Admin B starts at accepted seq 4")
    assertEq(follower._rcConfigEpoch, 100, "Admin B starts at accepted epoch 100")
    assertTrue(cfgEqual(coord:GetRCLootCouncilIntegrationConfig(), follower:GetRCLootCouncilIntegrationConfig()), "A and B share accepted RC config")
    assertTrue(Sync:EndSession("manual", false), "coordinator ends the prior session")
    assertEq(Sync.state.active, false, "no session is active during the RC edit")
    assertTrue(coord:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    }), "out-of-session mutator adds Greed as BiS")
    assertEq(coord._rcConfigDirty, true, "starter out-of-session edit is unpublished")
    assertFalse(coord:IsBisQualifyingResponse("Greed", greedMeta()), "unpublished Greed is not award-time accepted")
    local proposed = coord:GetProposedRCLootCouncilIntegrationConfig()
    assertTrue(proposed ~= nil, "starter keeps an unpublished Greed proposal")
    local proposedGreed = false
    for _, entry in ipairs((proposed and proposed.bisResponses) or {}) do
        if entry.responseId == 2 and entry.isAwardReason == false then
            proposedGreed = true
        end
    end
    assertTrue(proposedGreed, "unpublished proposal includes Greed")
    assertEq(coord._rcConfigSeq, 4, "out-of-session edit does not mint a sequence by itself")
    assertEq(coord._rcConfigEpoch, 100, "out-of-session edit does not change the accepted epoch")
    assertFalse(follower:IsBisQualifyingResponse("Greed", greedMeta()), "Admin B still has the previous accepted config")

    clock = 200
    local captured = captureComm()
    local sessionId = Sync:StartSession(coord:GetProfileId())
    assertTrue(sessionId ~= nil, "production StartSession starts the next session")
    local setMsg = lastOfType(captured, Sync.MSG.RC_CONFIG_SET)
    local startMsg = lastOfType(captured, Sync.MSG.SES_START)
    assertTrue(startMsg ~= nil, "session start advertised SES_START")
    assertTrue(
        SF.LootProfile.IsNewerRCConfigGeneration(
            startMsg.payload.rcConfigEpoch,
            startMsg.payload.rcConfigSeq,
            follower._rcConfigEpoch,
            follower._rcConfigSeq
        ),
        "session start advertises a strictly newer RC generation"
    )
    joinFromStart(coord, follower, captured)
    assertTrue(coord:IsBisQualifyingResponse("Greed", greedMeta()), "starter minted unpublished Greed at session start")
    assertTrue(follower:IsBisQualifyingResponse("Greed", greedMeta()), "Admin B accepted Greed from session-initial catch-up")
    assertTrue(cfgEqual(coord:GetRCLootCouncilIntegrationConfig(), follower:GetRCLootCouncilIntegrationConfig()), "accepted configs match after StartSession catch-up")
    local laterGreed = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700004002-later",
        response = "Greed",
        responseID = 2,
        isAwardReason = false,
    }))
    assertTrue(coord:TryAddRCLootCouncilAward(laterGreed), "coordinator records later Greed")
    assertTrue(follower:TryAddRCLootCouncilAward(laterGreed), "follower records later Greed after catch-up")
    local function lastGreedOutcome(profile)
        for _, log in ipairs(profile:GetLootLogs() or {}) do
            local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
            if data and data.awardKey == laterGreed.awardKey then
                return data.outcome, data.qualified
            end
        end
    end
    local laterOutcomeA, laterQualA = lastGreedOutcome(coord)
    local laterOutcomeB, laterQualB = lastGreedOutcome(follower)
    assertEq(laterQualA, true, "coordinator qualifies later Greed")
    assertEq(laterQualB, true, "follower qualifies later Greed after session-initial catch-up")
    assertEq(laterOutcomeB, laterOutcomeA, "later Greed BIS_OUTCOME matches")
    assertTrue(setMsg == nil, "dirty session-initial config is advertised on SES_START, not RC_CONFIG_SET")

    -- Fresh zero-generation profile, out-of-session disable recording, then StartSession.
    resetEnv()
    clock = 300
    function Sync:_Now()
        return clock
    end
    coord = makeProfile("RC Zero Gen Coord")
    addMember(coord, WINNER)
    addMember(coord, ADMIN_B)
    assertTrue(coord:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "zero-gen Admin B shares the profile")
    seedSharedNeedConfig(coord)
    setActive(coord)
    assertEq(tonumber(coord._rcConfigSeq) or 0, 0, "fresh profile has no accepted RC seq")
    assertEq(tonumber(coord._rcConfigEpoch) or 0, 0, "fresh profile has no accepted RC epoch")
    local zeroFollower = cloneProfileAs("RC Zero Gen B", coord)
    assertTrue(coord:SetRCLootCouncilRecordAwards(false), "out-of-session mutator disables recording")
    assertEq(coord:GetRCLootCouncilIntegrationConfig().recordAwards, false, "coordinator accepted recording off")
    assertEq(zeroFollower:GetRCLootCouncilIntegrationConfig().recordAwards, true, "zero-gen follower still records")
    captured = captureComm()
    assertTrue(Sync:StartSession(coord:GetProfileId()) ~= nil, "zero-gen StartSession starts")
    joinFromStart(coord, zeroFollower, captured)
    assertEq(zeroFollower:GetRCLootCouncilIntegrationConfig().recordAwards, false, "zero-gen follower accepted recording off")
    local ignored = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700004003-ignored",
        response = "Need",
        responseID = 1,
    }))
    assertFalse(coord:TryAddRCLootCouncilAward(ignored), "coordinator ignores awards after recording off")
    assertFalse(zeroFollower:TryAddRCLootCouncilAward(ignored), "follower ignores awards after session-initial catch-up")
    PLAYER = "Tester-Garona"
    SF.LootHelperComm = nil
end
testOutOfSessionRCConfigBecomesSessionAuthoritative()

local function testSessionStartRCAuthorityAndFanout()
    loadModule("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua")
    loadModule("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")

    local ADMIN_C = "PeerC-Garona"
    local ADMIN_D = "PeerD-Garona"
    local nonce = 0
    local deferred = {}
    local captured = {}

    local function greedMeta()
        return { typeCode = "default", responseId = 2, isAwardReason = false }
    end

    local function lastOfType(msgType)
        local found
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                found = captured[i]
            end
        end
        return found
    end

    local function countOfType(msgType)
        local n = 0
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                n = n + 1
            end
        end
        return n
    end

    local function resetCaptured()
        captured = {}
        SF.LootHelperComm = {
            Send = function(_, channel, msgType, payload, dist, target)
                captured[#captured + 1] = {
                    channel = channel,
                    msgType = msgType,
                    payload = payload,
                    dist = dist,
                    target = target,
                }
                return true
            end,
        }
    end

    local function installHarness()
        nonce = 0
        deferred = {}
        function Sync:_NextNonce(tag)
            nonce = nonce + 1
            return tostring(tag or "N") .. "-" .. tostring(nonce)
        end
        function Sync:_ResetSessionSafeMode()
        end
        function Sync:_ResetLocalSafeMode()
        end
        function Sync:_ApplySessionSafeModeFromPayload()
        end
        function Sync:EnsureHeartbeatMonitor()
            return false
        end
        function Sync:StopHeartbeatSender()
        end
        function Sync:NewRequestId()
            nonce = nonce + 1
            return "REQ-START-" .. tostring(nonce)
        end
        function Sync:GetPeer(nameRealm)
            self.state.peers = self.state.peers or {}
            local peer = self.state.peers[nameRealm]
            if not peer then
                peer = { name = nameRealm, inGroup = true }
                self.state.peers[nameRealm] = peer
            end
            peer.inGroup = true
            return peer
        end
        function Sync:RegisterRequest(requestId, kind, target, meta)
            self.state.requests = self.state.requests or {}
            self.state.requests[requestId] = { id = requestId, kind = kind, target = target, meta = meta }
            if kind == "NEED_PROFILE" and SF.LootHelperComm then
                SF.LootHelperComm:Send("CONTROL", self.MSG.NEED_PROFILE, {
                    sessionId = self.state.sessionId,
                    profileId = self.state.profileId,
                    requestId = requestId,
                }, "WHISPER", target, "NORMAL")
            end
            return true
        end
        function Sync:RunWithJitter(_, _, fn)
            if type(fn) == "function" then
                fn()
            end
        end
        function Sync:RunAfter(delaySec, fn)
            if type(fn) ~= "function" then
                return
            end
            delaySec = tonumber(delaySec) or 0
            if delaySec <= 0 then
                fn()
                return
            end
            deferred[#deferred + 1] = fn
        end
    end

    local function flushDeferred()
        local queued = deferred
        deferred = {}
        for i = 1, #queued do
            queued[i]()
        end
    end

    local function seedNeedConfig(profile)
        assertTrue(profile:ApplyRCLootCouncilIntegrationConfig({
            recordAwards = true,
            recordAllAwardTypes = false,
            allowedResponses = { "Need" },
            bisResponses = {
                { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
            },
        }, { skipPermission = true, skipSync = true }), "seed accepted Need-only RC config")
    end

    local function lastGreedOutcome(profile, awardKey)
        for _, log in ipairs(profile:GetLootLogs() or {}) do
            local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
            if data and data.awardKey == awardKey then
                return data.outcome, data.qualified
            end
        end
    end

    local function driveResponderStatus(starterPlayer, responderPlayer, responderProfile)
        local syncMsg = lastOfType(Sync.MSG.ADMIN_SYNC)
        assertTrue(syncMsg ~= nil, "StartSession whispered ADMIN_SYNC to the other admin")
        local previous = PLAYER
        PLAYER = responderPlayer
        withLocalProfile(responderProfile, function()
            Sync:HandleAdminSync(starterPlayer, syncMsg.payload)
        end)
        local statusMsg = lastOfType(Sync.MSG.ADMIN_STATUS)
        assertTrue(statusMsg ~= nil, "present admin replied ADMIN_STATUS")
        PLAYER = starterPlayer
        Sync:HandleAdminStatus(responderPlayer, statusMsg.payload)
        flushDeferred()
        PLAYER = previous
        return statusMsg
    end

    local function receiveSessionStart(playerId, follower, coordinatorName, startPayload)
        local previous = PLAYER
        PLAYER = playerId
        withLocalProfile(follower, function()
            Sync.state.active = false
            Sync.state.isCoordinator = false
            Sync.state._sentJoinStatusForSessionId = nil
            Sync.state._sentJoinStatusType = nil
            Sync.state._profileReqInFlight = nil
            Sync.state.heartbeat = { lastCatchupAt = nil }
            Sync:HandleSessionStart(coordinatorName, startPayload)
        end)
        PLAYER = previous
    end

    -- BLOCKER: stale admin B starts Session 2; present admin A still holds (100, 5) Greed.
    resetEnv()
    installHarness()
    local clock = 100
    function Sync:_Now()
        return clock
    end
    local coordA = makeProfile("RC Stale Starter A")
    addMember(coordA, WINNER)
    addMember(coordA, ADMIN_B)
    assertTrue(coordA:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B shares the profile")
    seedNeedConfig(coordA)
    setActive(coordA)
    startSessionOn(coordA)
    Sync.state.coordinator = PLAYER
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 100
    coordA._rcConfigSeq = 4
    coordA._rcConfigEpoch = 100
    Sync.state.rcConfigSeq = 4
    assertTrue(coordA:TryAddRCLootCouncilAward(SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700004101-prior",
        response = "Need",
        responseID = 1,
    }))), "shared complete logs include a Need award")
    local staleB = cloneProfileAs("RC Stale Starter B", coordA)
    assertEq(staleB._rcConfigSeq, 4, "Admin B cloned at accepted seq 4")
    assertEq(staleB._rcConfigEpoch, 100, "Admin B cloned at accepted epoch 100")
    resetCaptured()
    assertTrue(coordA:AddRCLootCouncilBisResponse({
        text = "Greed",
        typeCode = "default",
        responseId = 2,
        isAwardReason = false,
    }), "Session 1 coordinator accepts Greed as BiS")
    local liveSet = lastOfType(Sync.MSG.RC_CONFIG_SET)
    assertTrue(liveSet ~= nil, "Session 1 published RC_CONFIG_SET (100, 5)")
    assertEq(coordA._rcConfigSeq, 5, "accepted seq advanced to 5")
    assertEq(coordA._rcConfigEpoch, 100, "accepted epoch stays 100")
    assertTrue(coordA:IsBisQualifyingResponse("Greed", greedMeta()), "Admin A holds Greed")
    assertFalse(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "Admin B missed the SET")
    assertEq(staleB._rcConfigSeq, 4, "Admin B remains at seq 4")
    assertTrue(Sync:EndSession("manual", false), "Session 1 ended")
    assertEq(Sync.state.active, false, "no session is active before Session 2")
    assertFalse(staleB._rcConfigDirty == true, "missed SET does not mark the stale starter dirty")

    clock = 200
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[staleB:GetProfileId()] = staleB
    setActive(staleB)
    installHarness()
    resetCaptured()
    local sessionId = Sync:StartSession(staleB:GetProfileId())
    assertTrue(sessionId ~= nil, "production StartSession starts Session 2 as stale Admin B")
    driveResponderStatus(ADMIN_B, "Tester-Garona", coordA)
    local startMsg = lastOfType(Sync.MSG.SES_START)
    assertTrue(startMsg ~= nil, "Session 2 announced SES_START after admin convergence")
    assertTrue(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "stale starter adopted the last accepted Greed configuration")
    assertEq(staleB._rcConfigEpoch, 100, "stale starter did not mint a new coordEpoch over the last accepted generation")
    assertEq(staleB._rcConfigSeq, 5, "stale starter adopted accepted seq 5")
    assertEq(startMsg.payload.rcConfigEpoch, 100, "SES_START advertises the previously accepted epoch")
    assertEq(startMsg.payload.rcConfigSeq, 5, "SES_START advertises the previously accepted seq")
    assertTrue(
        not SF.LootProfile.IsNewerRCConfigGeneration(
            startMsg.payload.rcConfigEpoch,
            startMsg.payload.rcConfigSeq,
            100,
            5
        ),
        "new coordEpoch must not make stale contents a strictly newer generation"
    )
    local setBeforeStart = nil
    for i = 1, #captured do
        if captured[i].msgType == Sync.MSG.SES_START then
            break
        end
        if captured[i].msgType == Sync.MSG.RC_CONFIG_SET then
            setBeforeStart = captured[i]
        end
    end
    assertTrue(setBeforeStart == nil, "stale StartSession does not serialize RC_CONFIG_SET before SES_START")

    PLAYER = "Tester-Garona"
    resetCaptured()
    receiveSessionStart("Tester-Garona", coordA, ADMIN_B, startMsg.payload)
    assertTrue(coordA:IsBisQualifyingResponse("Greed", greedMeta()), "present Admin A kept Greed after Session 2 start")
    assertEq(coordA._rcConfigSeq, 5, "present Admin A kept seq 5")
    assertEq(countOfType(Sync.MSG.NEED_PROFILE), 0, "present Admin A does not request a profile snapshot")
    local laterGreed = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700004102-later",
        response = "Greed",
        responseID = 2,
        isAwardReason = false,
    }))
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[staleB:GetProfileId()] = staleB
    assertTrue(staleB:TryAddRCLootCouncilAward(laterGreed), "stale starter records later Greed after adopting")
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[coordA:GetProfileId()] = coordA
    assertTrue(coordA:TryAddRCLootCouncilAward(laterGreed), "Admin A still records later Greed")
    local _, laterQualA = lastGreedOutcome(coordA, laterGreed.awardKey)
    local _, laterQualB = lastGreedOutcome(staleB, laterGreed.awardKey)
    assertEq(laterQualA, true, "Admin A qualifies later Greed")
    assertEq(laterQualB, true, "stale starter qualifies later Greed after adopting")

    -- HIGH: unchanged second raid must not fan out PROFILE_SNAPSHOT for RC config.
    local function runUnchangedStart(peerCount)
        resetEnv()
        installHarness()
        clock = 300
        function Sync:_Now()
            return clock
        end
        local coord = makeProfile("RC Unchanged Start " .. tostring(peerCount))
        addMember(coord, WINNER)
        addMember(coord, ADMIN_B)
        addMember(coord, ADMIN_C)
        addMember(coord, ADMIN_D)
        assertTrue(coord:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "unchanged-start Admin B shares the profile")
        seedNeedConfig(coord)
        setActive(coord)
        startSessionOn(coord)
        Sync.state.coordinator = PLAYER
        Sync.state.isCoordinator = true
        Sync.state.coordEpoch = 100
        coord._rcConfigSeq = 4
        coord._rcConfigEpoch = 100
        Sync.state.rcConfigSeq = 4
        assertTrue(coord:TryAddRCLootCouncilAward(SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
            id = "1700004200-shared-" .. tostring(peerCount),
            response = "Need",
            responseID = 1,
        }))), "unchanged-start shared logs are complete")
        local followerB = cloneProfileAs("RC Unchanged B " .. tostring(peerCount), coord)
        local extra = {}
        local extraPlayers = {}
        if peerCount > 1 then
            extra[#extra + 1] = cloneProfileAs("RC Unchanged C " .. tostring(peerCount), coord)
            extraPlayers[#extraPlayers + 1] = ADMIN_C
            extra[#extra + 1] = cloneProfileAs("RC Unchanged D " .. tostring(peerCount), coord)
            extraPlayers[#extraPlayers + 1] = ADMIN_D
        end
        assertTrue(cfgEqual(coord:GetRCLootCouncilIntegrationConfig(), followerB:GetRCLootCouncilIntegrationConfig()), "peers already share RC config")
        assertTrue(Sync:EndSession("manual", false), "prior session ended with no RC edits")
        clock = 400
        PLAYER = "Tester-Garona"
        SF.lootHelperDB.profiles[coord:GetProfileId()] = coord
        setActive(coord)
        installHarness()
        resetCaptured()
        assertTrue(Sync:StartSession(coord:GetProfileId()) ~= nil, "production StartSession starts the next unchanged raid")
        driveResponderStatus("Tester-Garona", ADMIN_B, followerB)
        local start = lastOfType(Sync.MSG.SES_START)
        assertTrue(start ~= nil, "unchanged raid announced SES_START")
        assertTrue(lastOfType(Sync.MSG.RC_CONFIG_SET) == nil, "unchanged raid does not publish RC_CONFIG_SET")
        assertEq(start.payload.rcConfigEpoch, 100, "unchanged raid advertises the existing RC epoch")
        assertEq(start.payload.rcConfigSeq, 4, "unchanged raid advertises the existing RC seq")
        assertTrue(
            not SF.LootProfile.IsNewerRCConfigGeneration(
                start.payload.rcConfigEpoch,
                start.payload.rcConfigSeq,
                followerB._rcConfigEpoch,
                followerB._rcConfigSeq
            ),
            "unchanged raid does not advertise a strictly newer RC generation"
        )
        local setBeforeStart = nil
        for i = 1, #captured do
            if captured[i].msgType == Sync.MSG.SES_START then
                break
            end
            if captured[i].msgType == Sync.MSG.RC_CONFIG_SET then
                setBeforeStart = captured[i]
            end
        end
        assertTrue(setBeforeStart == nil, "unchanged raid does not send RC_CONFIG_SET before SES_START")
        PLAYER = "Tester-Garona"
        SF.lootHelperDB.profiles[coord:GetProfileId()] = coord
        Sync.state.active = true
        Sync.state.isCoordinator = true
        Sync.state.coordinator = PLAYER
        Sync.state.sessionId = start.payload.sessionId
        Sync.state.profileId = start.payload.profileId
        Sync.state.coordEpoch = start.payload.coordEpoch
        resetCaptured()
        assertTrue(Sync:BroadcastSessionHeartbeat(), "unchanged raid heartbeat was sent")
        local heartbeat = lastOfType(Sync.MSG.SES_HEARTBEAT)
        assertTrue(heartbeat ~= nil, "unchanged raid heartbeat advertised RC generation")
        local function joinSyncedPeer(playerId, follower)
            PLAYER = playerId
            resetCaptured()
            withLocalProfile(follower, function()
                Sync.state.active = true
                Sync.state.sessionId = start.payload.sessionId
                Sync.state.profileId = start.payload.profileId
                Sync.state.coordinator = "Tester-Garona"
                Sync.state.coordEpoch = start.payload.coordEpoch
                Sync.state.isCoordinator = false
                Sync.state._sentJoinStatusForSessionId = Sync.state.sessionId
                Sync.state._sentJoinStatusType = "HAVE_PROFILE"
                Sync.state._profileReqInFlight = nil
                Sync.state.heartbeat = { lastCatchupAt = nil }
                Sync:HandleSessionHeartbeat("Tester-Garona", heartbeat.payload)
                Sync:SendJoinStatus()
            end)
            assertEq(countOfType(Sync.MSG.NEED_PROFILE), 0, "already-synced peer does not send NEED_PROFILE for RC config")
            assertEq(countOfType(Sync.MSG.PROFILE_SNAPSHOT), 0, "already-synced peer does not receive PROFILE_SNAPSHOT for RC config")
            assertEq(countOfType(Sync.MSG.RC_CONFIG_REQ), 0, "already-synced unchanged peer does not request RC config catch-up")
        end
        joinSyncedPeer(ADMIN_B, followerB)
        for i = 1, #extra do
            joinSyncedPeer(extraPlayers[i], extra[i])
        end
        assertTrue(cfgEqual(coord:GetRCLootCouncilIntegrationConfig(), followerB:GetRCLootCouncilIntegrationConfig()), "follower still matches coordinator RC config")
        PLAYER = "Tester-Garona"
        return start
    end

    runUnchangedStart(1)
    runUnchangedStart(3)

    PLAYER = "Tester-Garona"
    SF.LootHelperComm = nil
end
testSessionStartRCAuthorityAndFanout()

local function testRCGenerationIdentityUniqueness()
    loadModule("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua")
    loadModule("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")

    local ADMIN_C = "AdminC-Garona"
    local nonce = 0
    local deferred = {}
    local captured = {}

    local function greedMeta()
        return { typeCode = "default", responseId = 2, isAwardReason = false }
    end

    local function lastOfType(msgType)
        local found
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                found = captured[i]
            end
        end
        return found
    end

    local function resetCaptured()
        captured = {}
        SF.LootHelperComm = {
            Send = function(_, channel, msgType, payload, dist, target)
                captured[#captured + 1] = {
                    channel = channel,
                    msgType = msgType,
                    payload = payload,
                    dist = dist,
                    target = target,
                }
                return true
            end,
        }
    end

    local function installHarness()
        nonce = 0
        deferred = {}
        function Sync:_NextNonce(tag)
            nonce = nonce + 1
            return tostring(tag or "N") .. "-" .. tostring(nonce)
        end
        function Sync:_ResetSessionSafeMode()
        end
        function Sync:_ResetLocalSafeMode()
        end
        function Sync:_ApplySessionSafeModeFromPayload()
        end
        function Sync:EnsureHeartbeatMonitor()
            return false
        end
        function Sync:StopHeartbeatSender()
        end
        function Sync:NewRequestId()
            nonce = nonce + 1
            return "REQ-GEN-" .. tostring(nonce)
        end
        function Sync:GetPeer(nameRealm)
            self.state.peers = self.state.peers or {}
            local peer = self.state.peers[nameRealm]
            if not peer then
                peer = { name = nameRealm, inGroup = true }
                self.state.peers[nameRealm] = peer
            end
            peer.inGroup = true
            return peer
        end
        function Sync:RegisterRequest()
            return true
        end
        function Sync:RunWithJitter(_, _, fn)
            if type(fn) == "function" then
                fn()
            end
        end
        function Sync:RunAfter(delaySec, fn)
            if type(fn) ~= "function" then
                return
            end
            delaySec = tonumber(delaySec) or 0
            if delaySec <= 0 then
                fn()
                return
            end
            deferred[#deferred + 1] = fn
        end
    end

    local function flushDeferred()
        local queued = deferred
        deferred = {}
        for i = 1, #queued do
            queued[i]()
        end
    end

    local function seedNeedConfig(profile)
        assertTrue(profile:ApplyRCLootCouncilIntegrationConfig({
            recordAwards = true,
            recordAllAwardTypes = false,
            allowedResponses = { "Need" },
            bisResponses = {
                { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
            },
        }, { skipPermission = true, skipSync = true }), "seed accepted Need-only RC config")
    end

    local function addGreed(profile)
        return profile:AddRCLootCouncilBisResponse({
            text = "Greed",
            typeCode = "default",
            responseId = 2,
            isAwardReason = false,
        })
    end

    local function lastGreedOutcome(profile, awardKey)
        for _, log in ipairs(profile:GetLootLogs() or {}) do
            local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
            if data and data.awardKey == awardKey then
                return data.outcome, data.qualified
            end
        end
    end

    local function driveResponderStatuses(starterPlayer, responders)
        local syncs = {}
        for i = 1, #captured do
            if captured[i].msgType == Sync.MSG.ADMIN_SYNC then
                syncs[#syncs + 1] = captured[i]
            end
        end
        assertTrue(#syncs > 0, "StartSession whispered ADMIN_SYNC")
        for i = 1, #syncs do
            local target = syncs[i].target
            local responder
            for j = 1, #responders do
                if responders[j].player == target then
                    responder = responders[j]
                    break
                end
            end
            assertTrue(responder ~= nil, "ADMIN_SYNC target is a known admin")
            local previous = PLAYER
            PLAYER = responder.player
            withLocalProfile(responder.profile, function()
                Sync:HandleAdminSync(starterPlayer, syncs[i].payload)
            end)
            PLAYER = starterPlayer
            local statusMsg = lastOfType(Sync.MSG.ADMIN_STATUS)
            assertTrue(statusMsg ~= nil, "admin replied ADMIN_STATUS")
            Sync:HandleAdminStatus(responder.player, statusMsg.payload)
            PLAYER = previous
        end
        flushDeferred()
    end

    -- Case A: non-starter dirty edit must not share generation G with different contents.
    resetEnv()
    installHarness()
    local clock = 100
    function Sync:_Now()
        return clock
    end
    local coordA = makeProfile("RC Gen A")
    addMember(coordA, WINNER)
    addMember(coordA, ADMIN_B)
    assertTrue(coordA:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Case A Admin B shares the profile")
    seedNeedConfig(coordA)
    setActive(coordA)
    startSessionOn(coordA)
    Sync.state.coordinator = PLAYER
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 100
    coordA._rcConfigSeq = 4
    coordA._rcConfigEpoch = 100
    Sync.state.rcConfigSeq = 4
    assertTrue(coordA:TryAddRCLootCouncilAward(SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700005101-prior",
        response = "Need",
        responseID = 1,
    }))), "Case A shared logs are complete")
    local dirtyB = cloneProfileAs("RC Gen Dirty B", coordA)
    assertTrue(Sync:EndSession("manual", false), "Case A prior session ended")
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[dirtyB:GetProfileId()] = dirtyB
    setActive(dirtyB)
    assertTrue(addGreed(dirtyB), "Case A Admin B adds Greed with no session")
    assertEq(dirtyB._rcConfigDirty, true, "Case A Admin B is dirty")
    assertEq(dirtyB._rcConfigSeq, 4, "Case A dirty edit stays on seq 4")
    assertEq(dirtyB._rcConfigEpoch, 100, "Case A dirty edit stays on epoch 100")
    assertTrue(dirtyB:GetProposedRCLootCouncilIntegrationConfig() ~= nil, "Case A unpublished proposal exists")
    assertFalse(dirtyB:IsBisQualifyingResponse("Greed", greedMeta()), "unpublished dirty Greed is not award-time accepted")
    assertFalse(coordA:IsBisQualifyingResponse("Greed", greedMeta()), "Admin A remains Need-only")

    clock = 200
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[coordA:GetProfileId()] = coordA
    setActive(coordA)
    installHarness()
    resetCaptured()
    assertTrue(Sync:StartSession(coordA:GetProfileId()) ~= nil, "Case A Admin A starts the next session")
    driveResponderStatuses("Tester-Garona", { { player = ADMIN_B, profile = dirtyB } })
    local dirtyStatus
    for i = 1, #captured do
        if captured[i].msgType == Sync.MSG.ADMIN_STATUS then
            dirtyStatus = captured[i]
        end
    end
    assertTrue(dirtyStatus ~= nil, "Case A Admin B sent ADMIN_STATUS")
    assertEq(dirtyStatus.payload.rcConfigDirty, true, "Case A ADMIN_STATUS reports unpublished dirty")
    local statusGreed = false
    for _, entry in ipairs((dirtyStatus.payload.rcLootCouncilIntegration and dirtyStatus.payload.rcLootCouncilIntegration.bisResponses) or {}) do
        if entry.responseId == 2 and entry.isAwardReason == false then
            statusGreed = true
        end
    end
    assertFalse(statusGreed, "Case A ADMIN_STATUS advertises accepted Need-only, not unpublished Greed")
    local startMsg = lastOfType(Sync.MSG.SES_START)
    assertTrue(startMsg ~= nil, "Case A announced SES_START")
    assertFalse(coordA:IsBisQualifyingResponse("Greed", greedMeta()), "starter who did not edit stays Need-only")
    PLAYER = ADMIN_B
    resetCaptured()
    withLocalProfile(dirtyB, function()
        Sync.state.active = true
        Sync.state.sessionId = startMsg.payload.sessionId
        Sync.state.profileId = startMsg.payload.profileId
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = startMsg.payload.coordEpoch
        Sync.state.isCoordinator = false
        Sync.state.heartbeat = { lastCatchupAt = nil }
        Sync:HandleSessionStart("Tester-Garona", startMsg.payload)
        Sync:HandleSessionHeartbeat("Tester-Garona", startMsg.payload)
    end)
    assertTrue(cfgEqual(coordA:GetRCLootCouncilIntegrationConfig(), dirtyB:GetRCLootCouncilIntegrationConfig()), "Case A accepted configs match after establishment")
    assertEq(dirtyB._rcConfigEpoch, coordA._rcConfigEpoch, "Case A epochs match")
    assertEq(dirtyB._rcConfigSeq, coordA._rcConfigSeq, "Case A seqs match")
    assertFalse(dirtyB._rcConfigDirty == true, "Case A dirty flag cleared after advertised accepted blob")
    assertEq(dirtyB:GetProposedRCLootCouncilIntegrationConfig(), nil, "Case A unpublished proposal discarded")
    assertFalse(dirtyB:IsBisQualifyingResponse("Greed", greedMeta()), "dirty follower converged off unpublished Greed")
    local laterGreed = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700005102-later",
        response = "Greed",
        responseID = 2,
        isAwardReason = false,
    }))
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[coordA:GetProfileId()] = coordA
    local recordedA = coordA:TryAddRCLootCouncilAward(laterGreed)
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[dirtyB:GetProfileId()] = dirtyB
    local recordedB = dirtyB:TryAddRCLootCouncilAward(laterGreed)
    assertEq(recordedB, recordedA, "Case A both clients record or reject the same Greed award")
    local outcomeA, qualA = lastGreedOutcome(coordA, laterGreed.awardKey)
    local outcomeB, qualB = lastGreedOutcome(dirtyB, laterGreed.awardKey)
    assertEq(qualB, qualA, "Case A Greed qualification matches")
    assertEq(outcomeB, outcomeA, "Case A Greed BIS_OUTCOME matches")

    -- Case B: stale starter must not treat a dirty blob as the accepted blob of G.
    resetEnv()
    installHarness()
    clock = 100
    function Sync:_Now()
        return clock
    end
    local cleanC = makeProfile("RC Gen Clean C")
    addMember(cleanC, WINNER)
    addMember(cleanC, ADMIN_B)
    addMember(cleanC, ADMIN_C)
    assertTrue(cleanC:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Case B Admin B shares the profile")
    assertTrue(cleanC:AddAdminMemberId(ADMIN_C, { skipPermission = true, skipBroadcast = true }), "Case B Admin C shares the profile")
    seedNeedConfig(cleanC)
    setActive(cleanC)
    startSessionOn(cleanC)
    Sync.state.coordinator = PLAYER
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 100
    cleanC._rcConfigSeq = 4
    cleanC._rcConfigEpoch = 100
    Sync.state.rcConfigSeq = 4
    local dirtyB2 = cloneProfileAs("RC Gen Dirty B2", cleanC)
    local staleA = cloneProfileAs("RC Gen Stale A", cleanC)
    staleA._rcConfigSeq = 3
    staleA._rcConfigEpoch = 100
    assertTrue(Sync:EndSession("manual", false), "Case B prior session ended")
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[dirtyB2:GetProfileId()] = dirtyB2
    setActive(dirtyB2)
    assertTrue(addGreed(dirtyB2), "Case B Admin B dirty-edits Greed")
    assertEq(dirtyB2._rcConfigSeq, 4, "Case B dirty B remains on generation G")
    assertEq(cleanC._rcConfigSeq, 4, "Case B clean C remains on generation G")
    assertFalse(cleanC:IsBisQualifyingResponse("Greed", greedMeta()), "clean C keeps accepted Need-only")

    clock = 200
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[staleA:GetProfileId()] = staleA
    setActive(staleA)
    installHarness()
    resetCaptured()
    assertTrue(Sync:StartSession(staleA:GetProfileId()) ~= nil, "Case B stale Admin A starts")
    driveResponderStatuses("Tester-Garona", {
        { player = ADMIN_B, profile = dirtyB2 },
        { player = ADMIN_C, profile = cleanC },
    })
    startMsg = lastOfType(Sync.MSG.SES_START)
    assertTrue(startMsg ~= nil, "Case B announced SES_START")
    assertFalse(staleA:IsBisQualifyingResponse("Greed", greedMeta()), "stale starter did not adopt unpublished Greed as accepted G")
    assertEq(staleA._rcConfigEpoch, 100, "Case B starter adopted accepted epoch G")
    assertEq(staleA._rcConfigSeq, 4, "Case B starter adopted accepted seq G")
    PLAYER = ADMIN_C
    withLocalProfile(cleanC, function()
        Sync.state.active = true
        Sync.state.sessionId = startMsg.payload.sessionId
        Sync.state.profileId = startMsg.payload.profileId
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = startMsg.payload.coordEpoch
        Sync.state.isCoordinator = false
        Sync:HandleSessionStart("Tester-Garona", startMsg.payload)
    end)
    PLAYER = ADMIN_B
    withLocalProfile(dirtyB2, function()
        Sync.state.active = true
        Sync.state.sessionId = startMsg.payload.sessionId
        Sync.state.profileId = startMsg.payload.profileId
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = startMsg.payload.coordEpoch
        Sync.state.isCoordinator = false
        Sync:HandleSessionStart("Tester-Garona", startMsg.payload)
    end)
    assertTrue(cfgEqual(staleA:GetRCLootCouncilIntegrationConfig(), cleanC:GetRCLootCouncilIntegrationConfig()), "Case B starter matches clean C")
    assertTrue(cfgEqual(staleA:GetRCLootCouncilIntegrationConfig(), dirtyB2:GetRCLootCouncilIntegrationConfig()), "Case B dirty B converged to accepted G")
    assertEq(cleanC._rcConfigSeq, staleA._rcConfigSeq, "Case B C seq matches starter")
    assertEq(dirtyB2._rcConfigSeq, staleA._rcConfigSeq, "Case B B seq matches starter")
    assertEq(cleanC._rcConfigEpoch, staleA._rcConfigEpoch, "Case B C epoch matches starter")
    assertEq(dirtyB2._rcConfigEpoch, staleA._rcConfigEpoch, "Case B B epoch matches starter")
    assertFalse(cleanC:IsBisQualifyingResponse("Greed", greedMeta()), "clean C still Need-only")
    assertFalse(dirtyB2:IsBisQualifyingResponse("Greed", greedMeta()), "dirty B no longer awards Greed at generation G")
    local caseBGreed = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700005103-caseb",
        response = "Greed",
        responseID = 2,
        isAwardReason = false,
    }))
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[staleA:GetProfileId()] = staleA
    local recA = staleA:TryAddRCLootCouncilAward(caseBGreed)
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[dirtyB2:GetProfileId()] = dirtyB2
    local recB = dirtyB2:TryAddRCLootCouncilAward(caseBGreed)
    PLAYER = ADMIN_C
    SF.lootHelperDB.profiles[cleanC:GetProfileId()] = cleanC
    local recC = cleanC:TryAddRCLootCouncilAward(caseBGreed)
    assertEq(recB, recA, "Case B A and B record the same Greed award")
    assertEq(recC, recA, "Case B A and C record the same Greed award")

    -- Replay must preserve accepted (100, 5), not rewrite it as (liveCoordEpoch, 5).
    resetEnv()
    installHarness()
    clock = 200
    function Sync:_Now()
        return clock
    end
    local replayCoord = makeProfile("RC Replay Coord")
    addMember(replayCoord, WINNER)
    addMember(replayCoord, ADMIN_B)
    assertTrue(replayCoord:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "replay Admin B shares the profile")
    seedNeedConfig(replayCoord)
    assertTrue(replayCoord:ApplyRCLootCouncilIntegrationConfig({
        recordAwards = true,
        recordAllAwardTypes = false,
        allowedResponses = { "Need", "Greed" },
        bisResponses = {
            { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
            { text = "Greed", typeCode = "default", responseId = 2, isAwardReason = false },
        },
    }, { skipPermission = true, skipSync = true }), "replay coordinator has accepted Greed")
    replayCoord._rcConfigSeq = 5
    replayCoord._rcConfigEpoch = 100
    setActive(replayCoord)
    startSessionOn(replayCoord)
    Sync.state.coordinator = PLAYER
    Sync.state.isCoordinator = true
    Sync.state.coordEpoch = 200
    Sync.state.rcConfigSeq = 5
    local replayB = cloneProfileAs("RC Replay B", replayCoord)
    replayB._rcConfigSeq = 4
    replayB._rcConfigEpoch = 100
    replayB:ApplyRCLootCouncilIntegrationConfig({
        recordAwards = true,
        recordAllAwardTypes = false,
        allowedResponses = { "Need" },
        bisResponses = {
            { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
        },
    }, { skipPermission = true, skipSync = true })
    replayB._rcConfigSeq = 4
    replayB._rcConfigEpoch = 100
    resetCaptured()
    local hb = {
        sessionId = Sync.state.sessionId,
        profileId = replayCoord:GetProfileId(),
        coordinator = PLAYER,
        coordEpoch = 200,
        rcConfigEpoch = 100,
        rcConfigSeq = 5,
        authorMax = {},
        helpers = {},
        sentAt = clock,
    }
    PLAYER = ADMIN_B
    withLocalProfile(replayB, function()
        Sync.state.active = true
        Sync.state.sessionId = hb.sessionId
        Sync.state.profileId = hb.profileId
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 200
        Sync.state.isCoordinator = false
        Sync.state._rcConfigCatchUpInFlight = nil
        Sync.state.heartbeat = { lastCatchupAt = nil }
        Sync:HandleSessionHeartbeat("Tester-Garona", hb)
        Sync:SendJoinStatus()
    end)
    local catchReq = lastOfType(Sync.MSG.RC_CONFIG_REQ)
    assertTrue(catchReq ~= nil, "behind follower used RC-only catchUp")
    assertEq(catchReq.payload.catchUp, true, "catch-up REQ is not a config proposal")
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[replayCoord:GetProfileId()] = replayCoord
    Sync.state.active = true
    Sync.state.isCoordinator = true
    Sync.state.coordinator = PLAYER
    Sync.state.sessionId = hb.sessionId
    Sync.state.profileId = hb.profileId
    Sync.state.coordEpoch = 200
    Sync.state.rcConfigSeq = 5
    resetCaptured()
    Sync:HandleRCConfigRequest(ADMIN_B, catchReq.payload)
    local replaySet = lastOfType(Sync.MSG.RC_CONFIG_SET)
    assertTrue(replaySet ~= nil, "coordinator replayed RC_CONFIG_SET")
    local replayedEpoch = tonumber(replaySet.payload.rcConfigEpoch)
    if replayedEpoch == nil then
        replayedEpoch = tonumber(replaySet.payload.coordEpoch)
    end
    assertEq(replayedEpoch, 100, "replay preserves accepted epoch 100")
    assertEq(replaySet.payload.rcConfigEpoch, 100, "replay rcConfigEpoch is the accepted generation")
    assertEq(replaySet.payload.coordEpoch, 200, "replay control coordEpoch is the live session epoch")
    assertEq(replaySet.payload.seq, 5, "replay preserves accepted seq 5")
    assertEq(replayCoord._rcConfigEpoch, 100, "coordinator accepted epoch stays 100")
    assertEq(replayCoord._rcConfigSeq, 5, "coordinator accepted seq stays 5")
    PLAYER = ADMIN_B
    withLocalProfile(replayB, function()
        Sync.state.active = true
        Sync.state.sessionId = hb.sessionId
        Sync.state.profileId = hb.profileId
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 200
        Sync.state.isCoordinator = false
        Sync:HandleRCConfigSet("Tester-Garona", replaySet.payload)
    end)
    assertEq(replayB._rcConfigEpoch, replayCoord._rcConfigEpoch, "catch-up receiver stores coordinator accepted epoch")
    assertEq(replayB._rcConfigSeq, replayCoord._rcConfigSeq, "catch-up receiver stores coordinator accepted seq")
    assertTrue(cfgEqual(replayCoord:GetRCLootCouncilIntegrationConfig(), replayB:GetRCLootCouncilIntegrationConfig()), "replay contents match")
    local replayAward = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
        id = "1700005104-replay",
        response = "Greed",
        responseID = 2,
        isAwardReason = false,
    }))
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[replayCoord:GetProfileId()] = replayCoord
    assertTrue(replayCoord:TryAddRCLootCouncilAward(replayAward), "coordinator records replay Greed")
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[replayB:GetProfileId()] = replayB
    assertTrue(replayB:TryAddRCLootCouncilAward(replayAward), "follower records replay Greed")
    local _, replayQualA = lastGreedOutcome(replayCoord, replayAward.awardKey)
    local _, replayQualB = lastGreedOutcome(replayB, replayAward.awardKey)
    assertEq(replayQualA, true, "coordinator qualifies replay Greed")
    assertEq(replayQualB, true, "follower qualifies replay Greed")

    PLAYER = "Tester-Garona"
    SF.LootHelperComm = nil
end
testRCGenerationIdentityUniqueness()

local function testPendingRCProposalDoesNotSurviveSessionEnd()
    loadModule("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua")
    loadModule("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")

    local nonce = 0
    local deferred = {}
    local captured = {}

    local function greedMeta()
        return { typeCode = "default", responseId = 2, isAwardReason = false }
    end

    local function lastOfType(msgType)
        local found
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                found = captured[i]
            end
        end
        return found
    end

    local function resetCaptured()
        captured = {}
        SF.LootHelperComm = {
            Send = function(_, channel, msgType, payload, dist, target)
                captured[#captured + 1] = {
                    channel = channel,
                    msgType = msgType,
                    payload = payload,
                    dist = dist,
                    target = target,
                }
                return true
            end,
        }
    end

    local function installHarness()
        nonce = 0
        deferred = {}
        function Sync:_NextNonce(tag)
            nonce = nonce + 1
            return tostring(tag or "N") .. "-" .. tostring(nonce)
        end
        function Sync:_ResetSessionSafeMode()
        end
        function Sync:_ResetLocalSafeMode()
        end
        function Sync:_ApplySessionSafeModeFromPayload()
        end
        function Sync:EnsureHeartbeatMonitor()
            return false
        end
        function Sync:StopHeartbeatSender()
        end
        function Sync:NewRequestId()
            nonce = nonce + 1
            return "REQ-PEND-" .. tostring(nonce)
        end
        function Sync:GetPeer(nameRealm)
            self.state.peers = self.state.peers or {}
            local peer = self.state.peers[nameRealm]
            if not peer then
                peer = { name = nameRealm, inGroup = true }
                self.state.peers[nameRealm] = peer
            end
            peer.inGroup = true
            return peer
        end
        function Sync:RegisterRequest()
            return true
        end
        function Sync:RunWithJitter(_, _, fn)
            if type(fn) == "function" then
                fn()
            end
        end
        function Sync:RunAfter(delaySec, fn)
            if type(fn) ~= "function" then
                return
            end
            delaySec = tonumber(delaySec) or 0
            if delaySec <= 0 then
                fn()
                return
            end
            deferred[#deferred + 1] = fn
        end
        function Sync:_CancelRequestTimer()
        end
        function Sync:_GetSessionSafeModePayload()
            return { enabled = false, rev = 0 }
        end
    end

    local function flushDeferred()
        local queued = deferred
        deferred = {}
        for i = 1, #queued do
            queued[i]()
        end
    end

    local function seedNeedConfig(profile)
        assertTrue(profile:ApplyRCLootCouncilIntegrationConfig({
            recordAwards = true,
            recordAllAwardTypes = false,
            allowedResponses = { "Need" },
            bisResponses = {
                { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
            },
        }, { skipPermission = true, skipSync = true }), "seed accepted Need-only RC config")
    end

    local function addGreed(profile)
        return profile:AddRCLootCouncilBisResponse({
            text = "Greed",
            typeCode = "default",
            responseId = 2,
            isAwardReason = false,
        })
    end

    local function hasGreedBis(cfg)
        for _, entry in ipairs((cfg and cfg.bisResponses) or {}) do
            if entry.responseId == 2 and entry.isAwardReason == false then
                return true
            end
        end
        return false
    end

    local function assertVisibleMatchesAccepted(profile, message)
        local editable = profile:GetEditableRCLootCouncilIntegrationConfig()
        local accepted = profile:GetRCLootCouncilIntegrationConfig()
        assertTrue(cfgEqual(editable, accepted), message .. ": Settings/editable matches accepted")
        assertEq(profile:GetProposedRCLootCouncilIntegrationConfig(), nil, message .. ": no pending proposal")
        assertFalse(profile._rcConfigDirty == true, message .. ": not an unpublished out-of-session draft")
        assertFalse(hasGreedBis(editable), message .. ": visible config is not unpublished Greed")
        assertFalse(profile:IsBisQualifyingResponse("Greed", greedMeta()), message .. ": award-time Greed is not BiS")
        assertFalse(profile:ShouldRecordRCResponse("Greed", greedMeta()), message .. ": award-time does not record Greed")
    end

    local function driveResponderStatuses(starterPlayer, responders)
        local syncs = {}
        for i = 1, #captured do
            if captured[i].msgType == Sync.MSG.ADMIN_SYNC then
                syncs[#syncs + 1] = captured[i]
            end
        end
        assertTrue(#syncs > 0, "StartSession whispered ADMIN_SYNC")
        for i = 1, #syncs do
            local target = syncs[i].target
            local responder
            for j = 1, #responders do
                if responders[j].player == target then
                    responder = responders[j]
                    break
                end
            end
            assertTrue(responder ~= nil, "ADMIN_SYNC target is a known admin")
            local previous = PLAYER
            PLAYER = responder.player
            withLocalProfile(responder.profile, function()
                Sync:HandleAdminSync(starterPlayer, syncs[i].payload)
            end)
            PLAYER = starterPlayer
            local statusMsg = lastOfType(Sync.MSG.ADMIN_STATUS)
            assertTrue(statusMsg ~= nil, "admin replied ADMIN_STATUS")
            Sync:HandleAdminStatus(responder.player, statusMsg.payload)
            PLAYER = previous
        end
        flushDeferred()
    end

    local function beginSharedSession()
        resetEnv()
        installHarness()
        function Sync:_Now()
            return 100
        end
        local coord = makeProfile("RC Pending Lifecycle A")
        addMember(coord, WINNER)
        addMember(coord, ADMIN_B)
        assertTrue(coord:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B shares the profile")
        seedNeedConfig(coord)
        setActive(coord)
        startSessionOn(coord)
        Sync.state.coordinator = PLAYER
        Sync.state.isCoordinator = true
        Sync.state.coordEpoch = 100
        coord._rcConfigSeq = 4
        coord._rcConfigEpoch = 100
        Sync.state.rcConfigSeq = 4
        local follower = cloneProfileAs("RC Pending Lifecycle B", coord)
        follower._rcConfigSeq = 4
        follower._rcConfigEpoch = 100
        return coord, follower
    end

    local function proposeGreedAsFollower(coord, follower)
        resetCaptured()
        PLAYER = ADMIN_B
        SF.lootHelperDB.profiles[follower:GetProfileId()] = follower
        withLocalProfile(follower, function()
            Sync.state.active = true
            Sync.state.sessionId = "SES1"
            Sync.state.profileId = follower:GetProfileId()
            Sync.state.coordinator = "Tester-Garona"
            Sync.state.coordEpoch = 100
            Sync.state.isCoordinator = false
            assertTrue(addGreed(follower), "follower can propose Greed during the session")
        end)
        local req = lastOfType(Sync.MSG.RC_CONFIG_REQ)
        assertTrue(req ~= nil, "follower sent RC_CONFIG_REQ")
        assertEq(req.payload.catchUp == true, false, "proposal REQ is not catch-up replay")
        local proposed = follower:GetProposedRCLootCouncilIntegrationConfig()
        assertTrue(proposed ~= nil, "follower retained the Greed proposal")
        assertTrue(hasGreedBis(proposed), "pending proposal includes Greed")
        assertFalse(hasGreedBis(follower:GetRCLootCouncilIntegrationConfig()), "accepted config remains Need-only")
        assertFalse(follower._rcConfigDirty == true, "successful in-session REQ is not _rcConfigDirty")
        assertTrue(hasGreedBis(follower:GetEditableRCLootCouncilIntegrationConfig()), "Settings show the live pending Greed proposal")
        assertFalse(follower:IsBisQualifyingResponse("Greed", greedMeta()), "award-time stays Need-only before SET")
        PLAYER = "Tester-Garona"
        SF.lootHelperDB.profiles[coord:GetProfileId()] = coord
        Sync.state.active = true
        Sync.state.isCoordinator = true
        Sync.state.coordinator = PLAYER
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = coord:GetProfileId()
        Sync.state.coordEpoch = 100
        return req
    end

    -- Remote SES_END discards the unaccepted in-session proposal.
    local coord, follower = beginSharedSession()
    proposeGreedAsFollower(coord, follower)
    resetCaptured()
    assertTrue(Sync:EndSession("manual", true), "coordinator broadcasts SES_END")
    local endMsg = lastOfType(Sync.MSG.SES_END)
    assertTrue(endMsg ~= nil, "SES_END was broadcast")
    PLAYER = ADMIN_B
    withLocalProfile(follower, function()
        Sync.state.active = true
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = follower:GetProfileId()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 100
        Sync.state.isCoordinator = false
        Sync:HandleSessionEnd("Tester-Garona", endMsg.payload)
    end)
    assertVisibleMatchesAccepted(follower, "after remote SES_END")

    -- Former proposer starts the next session: visible Settings and award-time agree.
    function Sync:_Now()
        return 200
    end
    installHarness()
    resetCaptured()
    SF.lootHelperDB.profiles[follower:GetProfileId()] = follower
    setActive(follower)
    assertTrue(Sync:StartSession(follower:GetProfileId()) ~= nil, "former proposer starts the next session")
    driveResponderStatuses(ADMIN_B, { { player = "Tester-Garona", profile = coord } })
    local startAsB = lastOfType(Sync.MSG.SES_START)
    assertTrue(startAsB ~= nil, "former proposer's StartSession announced SES_START")
    assertFalse(hasGreedBis(startAsB.payload.rcLootCouncilIntegration), "new session descriptor is Need-only")
    assertFalse(follower._rcConfigDirty == true, "former proposer did not mint a dead-session proposal")
    assertVisibleMatchesAccepted(follower, "former proposer new session")
    assertEq(startAsB.payload.rcConfigSeq, follower._rcConfigSeq, "descriptor seq matches accepted")
    assertEq(startAsB.payload.rcConfigEpoch, follower._rcConfigEpoch, "descriptor epoch matches accepted")

    -- Another admin starts the next session after the proposal died with SES_END.
    coord, follower = beginSharedSession()
    proposeGreedAsFollower(coord, follower)
    resetCaptured()
    assertTrue(Sync:EndSession("manual", true), "coordinator broadcasts SES_END for the A-starts case")
    endMsg = lastOfType(Sync.MSG.SES_END)
    PLAYER = ADMIN_B
    withLocalProfile(follower, function()
        Sync.state.active = true
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = follower:GetProfileId()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 100
        Sync.state.isCoordinator = false
        Sync:HandleSessionEnd("Tester-Garona", endMsg.payload)
    end)
    function Sync:_Now()
        return 200
    end
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[coord:GetProfileId()] = coord
    setActive(coord)
    installHarness()
    resetCaptured()
    assertTrue(Sync:StartSession(coord:GetProfileId()) ~= nil, "Admin A starts the next session")
    driveResponderStatuses("Tester-Garona", { { player = ADMIN_B, profile = follower } })
    local startAsA = lastOfType(Sync.MSG.SES_START)
    assertTrue(startAsA ~= nil, "Admin A announced SES_START")
    assertFalse(hasGreedBis(startAsA.payload.rcLootCouncilIntegration), "Admin A's descriptor is Need-only")
    PLAYER = ADMIN_B
    withLocalProfile(follower, function()
        Sync:HandleSessionStart("Tester-Garona", startAsA.payload)
    end)
    assertVisibleMatchesAccepted(follower, "follower after another admin starts")
    assertTrue(cfgEqual(coord:GetRCLootCouncilIntegrationConfig(), follower:GetRCLootCouncilIntegrationConfig()), "both accepted configs match")

    -- Session change to a different sessionId discards the old in-session proposal.
    coord, follower = beginSharedSession()
    proposeGreedAsFollower(coord, follower)
    PLAYER = ADMIN_B
    withLocalProfile(follower, function()
        Sync.state.active = true
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = follower:GetProfileId()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 100
        Sync.state.isCoordinator = false
        Sync:HandleSessionStart("Tester-Garona", {
            sessionId = "SES2",
            profileId = follower:GetProfileId(),
            coordinator = "Tester-Garona",
            coordEpoch = 200,
            rcConfigEpoch = 100,
            rcConfigSeq = 4,
            rcLootCouncilIntegration = coord:GetRCLootCouncilIntegrationConfig(),
            authorMax = {},
            helpers = {},
        })
    end)
    assertEq(Sync.state.sessionId, "SES2", "follower accepted the new session")
    assertVisibleMatchesAccepted(follower, "after session_changed SES_START")
    assertTrue(Sync.state.active == true, "new session is active")
    assertTrue(cfgEqual(
        follower:GetEditableRCLootCouncilIntegrationConfig(),
        follower:GetRCLootCouncilIntegrationConfig()
    ), "active new session Settings match accepted Need-only")

    -- Session change without an advertised RC blob still drops the dead proposal.
    coord, follower = beginSharedSession()
    proposeGreedAsFollower(coord, follower)
    PLAYER = ADMIN_B
    withLocalProfile(follower, function()
        Sync.state.active = true
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = follower:GetProfileId()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 100
        Sync.state.isCoordinator = false
        Sync:HandleSessionStart("Tester-Garona", {
            sessionId = "SES2",
            profileId = follower:GetProfileId(),
            coordinator = "Tester-Garona",
            coordEpoch = 200,
            authorMax = {},
            helpers = {},
        })
    end)
    assertEq(Sync.state.sessionId, "SES2", "follower accepted the blob-less new session")
    assertVisibleMatchesAccepted(follower, "after blob-less session_changed SES_START")
    assertTrue(Sync.state.active == true, "blob-less new session is active")

    -- Accepted SET before session end remains the live configuration.
    coord, follower = beginSharedSession()
    local req = proposeGreedAsFollower(coord, follower)
    resetCaptured()
    Sync:HandleRCConfigRequest(ADMIN_B, req.payload)
    local setMsg = lastOfType(Sync.MSG.RC_CONFIG_SET)
    assertTrue(setMsg ~= nil, "coordinator serialized RC_CONFIG_SET")
    PLAYER = ADMIN_B
    withLocalProfile(follower, function()
        Sync.state.active = true
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = follower:GetProfileId()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 100
        Sync.state.isCoordinator = false
        Sync:HandleRCConfigSet("Tester-Garona", setMsg.payload)
    end)
    assertTrue(follower:IsBisQualifyingResponse("Greed", greedMeta()), "SET makes Greed award-time BiS")
    assertEq(follower:GetProposedRCLootCouncilIntegrationConfig(), nil, "SET clears the pending proposal")
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[coord:GetProfileId()] = coord
    Sync.state.active = true
    Sync.state.isCoordinator = true
    Sync.state.coordinator = PLAYER
    Sync.state.sessionId = "SES1"
    Sync.state.profileId = coord:GetProfileId()
    Sync.state.coordEpoch = 100
    resetCaptured()
    assertTrue(Sync:EndSession("manual", true), "coordinator ends after accepted SET")
    endMsg = lastOfType(Sync.MSG.SES_END)
    PLAYER = ADMIN_B
    withLocalProfile(follower, function()
        Sync.state.active = true
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = follower:GetProfileId()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 100
        Sync.state.isCoordinator = false
        Sync:HandleSessionEnd("Tester-Garona", endMsg.payload)
    end)
    assertTrue(follower:IsBisQualifyingResponse("Greed", greedMeta()), "accepted Greed survives session end")
    assertTrue(hasGreedBis(follower:GetEditableRCLootCouncilIntegrationConfig()), "Settings keep accepted Greed")
    assertTrue(cfgEqual(
        follower:GetEditableRCLootCouncilIntegrationConfig(),
        follower:GetRCLootCouncilIntegrationConfig()
    ), "accepted Greed Settings match award-time after SES_END")
    assertEq(follower:GetProposedRCLootCouncilIntegrationConfig(), nil, "no pending remains after accepted SET + SES_END")

    -- Failed RC_CONFIG_REQ still discards immediately, and session end stays empty.
    coord, follower = beginSharedSession()
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[follower:GetProfileId()] = follower
    SF.LootHelperComm = {
        Send = function()
            return false
        end,
    }
    withLocalProfile(follower, function()
        Sync.state.active = true
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = follower:GetProfileId()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 100
        Sync.state.isCoordinator = false
        local ok, err = follower:AddRCLootCouncilBisResponse({
            text = "Greed",
            typeCode = "default",
            responseId = 2,
            isAwardReason = false,
        })
        assertFalse(ok, "failed REQ does not report success")
        assertEq(err, "send failed", "failed REQ surfaces send failed")
    end)
    assertEq(follower:GetProposedRCLootCouncilIntegrationConfig(), nil, "failed REQ discards the proposal")
    assertFalse(follower:IsBisQualifyingResponse("Greed", greedMeta()), "failed REQ is not award-time Greed")
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[coord:GetProfileId()] = coord
    installHarness()
    resetCaptured()
    Sync.state.active = true
    Sync.state.isCoordinator = true
    Sync.state.coordinator = PLAYER
    Sync.state.sessionId = "SES1"
    Sync.state.profileId = coord:GetProfileId()
    Sync.state.coordEpoch = 100
    assertTrue(Sync:EndSession("manual", true), "session can end after failed REQ")
    endMsg = lastOfType(Sync.MSG.SES_END)
    PLAYER = ADMIN_B
    withLocalProfile(follower, function()
        Sync.state.active = true
        Sync.state.sessionId = "SES1"
        Sync.state.profileId = follower:GetProfileId()
        Sync.state.coordinator = "Tester-Garona"
        Sync.state.coordEpoch = 100
        Sync.state.isCoordinator = false
        Sync:HandleSessionEnd("Tester-Garona", endMsg.payload)
    end)
    assertVisibleMatchesAccepted(follower, "after failed REQ and SES_END")

    -- Intentional out-of-session dirty drafts from the previous pass still survive session reset.
    coord, follower = beginSharedSession()
    PLAYER = "Tester-Garona"
    SF.lootHelperDB.profiles[coord:GetProfileId()] = coord
    assertTrue(Sync:EndSession("manual", false), "prior session ended before the dirty edit")
    PLAYER = ADMIN_B
    SF.lootHelperDB.profiles[follower:GetProfileId()] = follower
    setActive(follower)
    assertTrue(addGreed(follower), "out-of-session dirty edit still works")
    assertEq(follower._rcConfigDirty, true, "out-of-session edit is dirty")
    assertTrue(follower:GetProposedRCLootCouncilIntegrationConfig() ~= nil, "dirty unpublished proposal is kept")
    assertFalse(follower:IsBisQualifyingResponse("Greed", greedMeta()), "dirty Greed is not award-time accepted")
    Sync.state.profileId = follower:GetProfileId()
    Sync.state.active = false
    Sync:_ResetSessionState("post-dirty-reset")
    assertEq(follower._rcConfigDirty, true, "session reset does not drop an out-of-session dirty draft")
    assertTrue(follower:GetProposedRCLootCouncilIntegrationConfig() ~= nil, "dirty proposal survives _ResetSessionState")
    assertTrue(hasGreedBis(follower:GetEditableRCLootCouncilIntegrationConfig()), "Settings still show the unpublished dirty Greed")

    PLAYER = "Tester-Garona"
    SF.LootHelperComm = nil
end
testPendingRCProposalDoesNotSurviveSessionEnd()

function testTakeoverRCAuthorityWithoutPostEdit()
    loadModule("SpectrumFederation/modules/LootHelperSync/09_AdminConvergence.lua")
    loadModule("SpectrumFederation/modules/LootHelperSync/11_Heartbeat.lua")

    local ADMIN_C = "AdminC-Garona"
    local nonce = 0
    local deferred = {}
    local captured = {}

    local function greedMeta()
        return { typeCode = "default", responseId = 2, isAwardReason = false }
    end

    local function lastOfType(msgType)
        local found
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                found = captured[i]
            end
        end
        return found
    end

    local function countOfType(msgType)
        local n = 0
        for i = 1, #captured do
            if captured[i].msgType == msgType then
                n = n + 1
            end
        end
        return n
    end

    local function resetCaptured()
        captured = {}
        SF.LootHelperComm = {
            Send = function(_, channel, msgType, payload, dist, target)
                captured[#captured + 1] = {
                    channel = channel,
                    msgType = msgType,
                    payload = payload,
                    dist = dist,
                    target = target,
                }
                return true
            end,
        }
    end

    local function installHarness()
        nonce = 0
        deferred = {}
        function Sync:_NextNonce(tag)
            nonce = nonce + 1
            return tostring(tag or "N") .. "-" .. tostring(nonce)
        end
        function Sync:_ResetSessionSafeMode()
        end
        function Sync:_ResetLocalSafeMode()
        end
        function Sync:_ApplySessionSafeModeFromPayload()
        end
        function Sync:EnsureHeartbeatMonitor()
            return false
        end
        function Sync:StopHeartbeatSender()
        end
        function Sync:NewRequestId()
            nonce = nonce + 1
            return "REQ-TAKEOVER-" .. tostring(nonce)
        end
        function Sync:GetPeer(nameRealm)
            self.state.peers = self.state.peers or {}
            local peer = self.state.peers[nameRealm]
            if not peer then
                peer = { name = nameRealm, inGroup = true }
                self.state.peers[nameRealm] = peer
            end
            peer.inGroup = true
            return peer
        end
        function Sync:RegisterRequest()
            return true
        end
        function Sync:RunWithJitter(_, _, fn)
            if type(fn) == "function" then
                fn()
            end
        end
        function Sync:RunAfter(delaySec, fn)
            if type(fn) ~= "function" then
                return
            end
            delaySec = tonumber(delaySec) or 0
            if delaySec <= 0 then
                fn()
                return
            end
            deferred[#deferred + 1] = fn
        end
    end

    local function flushDeferred()
        local guard = 0
        while #deferred > 0 and guard < 8 do
            guard = guard + 1
            local queued = deferred
            deferred = {}
            for i = 1, #queued do
                queued[i]()
            end
        end
    end

    local function seedNeedConfig(profile)
        assertTrue(profile:ApplyRCLootCouncilIntegrationConfig({
            recordAwards = true,
            recordAllAwardTypes = false,
            allowedResponses = { "Need" },
            bisResponses = {
                { text = "Need", typeCode = "default", responseId = 1, isAwardReason = false },
            },
        }, { skipPermission = true, skipSync = true }), "seed accepted Need-only RC config")
    end

    local function addGreed(profile)
        return profile:AddRCLootCouncilBisResponse({
            text = "Greed",
            typeCode = "default",
            responseId = 2,
            isAwardReason = false,
        })
    end

    local function lastGreedOutcome(profile, awardKey)
        for _, log in ipairs(profile:GetLootLogs() or {}) do
            local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
            if data and data.awardKey == awardKey then
                return data.outcome, data.qualified
            end
        end
    end

    local function driveAvailableAdminStatuses(coordPlayer, responders)
        local syncs = {}
        for i = 1, #captured do
            if captured[i].msgType == Sync.MSG.ADMIN_SYNC then
                syncs[#syncs + 1] = captured[i]
            end
        end
        for i = 1, #syncs do
            local target = syncs[i].target
            local responder
            for j = 1, #responders do
                if responders[j].player == target then
                    responder = responders[j]
                    break
                end
            end
            if responder then
                local previous = PLAYER
                PLAYER = responder.player
                withLocalProfile(responder.profile, function()
                    Sync:HandleAdminSync(coordPlayer, syncs[i].payload)
                end)
                PLAYER = coordPlayer
                local statusMsg = lastOfType(Sync.MSG.ADMIN_STATUS)
                assertTrue(statusMsg ~= nil, "present admin replied ADMIN_STATUS")
                Sync:HandleAdminStatus(responder.player, statusMsg.payload)
                PLAYER = previous
            end
        end
        flushDeferred()
    end

    local function receiveReannounce(playerId, follower, coordinatorName, payload)
        local previous = PLAYER
        PLAYER = playerId
        withLocalProfile(follower, function()
            Sync.state.active = true
            Sync.state.isCoordinator = false
            Sync.state.coordinator = coordinatorName
            Sync.state._sentJoinStatusForSessionId = nil
            Sync.state._sentJoinStatusType = nil
            Sync.state._profileReqInFlight = nil
            Sync.state.heartbeat = { lastCatchupAt = nil }
            Sync:HandleSessionReannounce(coordinatorName, payload)
        end)
        PLAYER = previous
    end

    local function restoreCoordinator(coordProfile, coordPlayer)
        PLAYER = coordPlayer
        SF.lootHelperDB.profiles[coordProfile:GetProfileId()] = coordProfile
        setActive(coordProfile)
        Sync.state.active = true
        Sync.state.isCoordinator = true
        Sync.state.coordinator = coordPlayer
        Sync.state.profileId = coordProfile:GetProfileId()
    end

    local function assertSameAccepted(a, b, label)
        assertEq(a._rcConfigEpoch, b._rcConfigEpoch, label .. " accepted rcConfigEpoch matches")
        assertEq(a._rcConfigSeq, b._rcConfigSeq, label .. " accepted rcConfigSeq matches")
        assertTrue(cfgEqual(a:GetRCLootCouncilIntegrationConfig(), b:GetRCLootCouncilIntegrationConfig()), label .. " accepted RC blobs match")
    end

    local function assertSameGreedAward(a, b, awardKeySuffix)
        local canon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
            id = "1700006101-" .. awardKeySuffix,
            response = "Greed",
            responseID = 2,
        }))
        local okA = a:TryAddRCLootCouncilAward(canon)
        local okB = b:TryAddRCLootCouncilAward(canon)
        assertEq(okB, okA, awardKeySuffix .. " recording decision matches")
        local outcomeA, qualA = lastGreedOutcome(a, canon.awardKey)
        local outcomeB, qualB = lastGreedOutcome(b, canon.awardKey)
        assertEq(qualB, qualA, awardKeySuffix .. " qualification matches")
        assertEq(outcomeB, outcomeA, awardKeySuffix .. " BIS_OUTCOME matches")
        return okA, qualA
    end

    local function beginSharedG0()
        local coordA = makeProfile("RC Takeover Auth A")
        addMember(coordA, WINNER)
        addMember(coordA, ADMIN_B)
        addMember(coordA, ADMIN_C)
        assertTrue(coordA:AddAdminMemberId(ADMIN_B, { skipPermission = true, skipBroadcast = true }), "Admin B shares the profile")
        assertTrue(coordA:AddAdminMemberId(ADMIN_C, { skipPermission = true, skipBroadcast = true }), "Admin C shares the profile")
        seedNeedConfig(coordA)
        setActive(coordA)
        startSessionOn(coordA)
        Sync.state.coordinator = PLAYER
        Sync.state.isCoordinator = true
        Sync.state.coordEpoch = 100
        coordA._rcConfigSeq = 4
        coordA._rcConfigEpoch = 100
        Sync.state.rcConfigSeq = 4
        assertTrue(coordA:TryAddRCLootCouncilAward(SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable({
            id = "1700006100-prior",
            response = "Need",
            responseID = 1,
        }))), "shared complete logs include a Need award")
        return coordA
    end

    local function takeoverAsB(staleB, reason)
        PLAYER = ADMIN_B
        SF.lootHelperDB.profiles[staleB:GetProfileId()] = staleB
        setActive(staleB)
        installHarness()
        resetCaptured()
        local oldEpoch = tonumber(Sync.state.coordEpoch) or 0
        assertTrue(Sync:TakeoverSession(Sync.state.sessionId, staleB:GetProfileId(), reason, {
            rerunAdminConvergence = true,
        }), "Admin B takes over with admin convergence")
        assertTrue(Sync.state.isCoordinator, "Admin B is coordinator after takeover")
        assertTrue(Sync.state.coordEpoch > oldEpoch, "takeover bumps live coordEpoch")
        return oldEpoch
    end

    -- Case A: stale takeover coordinator must adopt a newer accepted peer before any new edit.
    resetEnv()
    installHarness()
    function Sync:_Now()
        return 100
    end
    local coordA = beginSharedG0()
    local staleB = cloneProfileAs("RC Takeover Auth B", coordA)
    assertEq(staleB._rcConfigSeq, 4, "Case A Admin B cloned at G0 seq 4")
    resetCaptured()
    assertTrue(addGreed(coordA), "Case A coordinator A accepts Greed as BiS")
    local liveSet = lastOfType(Sync.MSG.RC_CONFIG_SET)
    assertTrue(liveSet ~= nil, "Case A Session 1 published RC_CONFIG_SET G1")
    assertEq(coordA._rcConfigSeq, 5, "Case A accepted seq advanced to 5")
    assertEq(coordA._rcConfigEpoch, 100, "Case A accepted epoch stays 100")
    local peerC = cloneProfileAs("RC Takeover Auth C", coordA)
    assertTrue(peerC:IsBisQualifyingResponse("Greed", greedMeta()), "Case A Admin C holds G1")
    assertFalse(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "Case A Admin B missed G1")
    function Sync:_Now()
        return 200
    end
    local oldEpoch = takeoverAsB(staleB, "coord-offline-stale")
    driveAvailableAdminStatuses(ADMIN_B, { { player = ADMIN_C, profile = peerC } })
    local reannounce = lastOfType(Sync.MSG.SES_REANNOUNCE)
    assertTrue(reannounce ~= nil, "Case A takeover reannounced the session")
    assertEq(countOfType(Sync.MSG.PROFILE_SNAPSHOT), 0, "Case A did not fan out PROFILE_SNAPSHOT for RC config")
    assertEq(countOfType(Sync.MSG.RC_CONFIG_SET), 0, "Case A did not mint a new RC SET merely because takeover occurred")
    assertEq(staleB._rcConfigEpoch, 100, "Case A adopted previously accepted epoch 100")
    assertEq(staleB._rcConfigSeq, 5, "Case A adopted previously accepted seq 5")
    assertTrue(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "Case A takeover coordinator now holds G1")
    receiveReannounce(ADMIN_C, peerC, ADMIN_B, reannounce.payload)
    restoreCoordinator(staleB, ADMIN_B)
    assertSameAccepted(staleB, peerC, "Case A after takeover")
    assertEq(reannounce.payload.rcConfigEpoch, 100, "Case A SES_REANNOUNCE advertises accepted epoch 100")
    assertEq(reannounce.payload.rcConfigSeq, 5, "Case A SES_REANNOUNCE advertises accepted seq 5")
    local recorded, qualified = assertSameGreedAward(staleB, peerC, "case-a")
    assertTrue(recorded, "Case A Greed award records after G1 authority")
    assertEq(qualified, true, "Case A Greed qualifies after G1 authority")

    -- Case D: after takeover authority, a deliberate coordinator edit still publishes normally.
    restoreCoordinator(staleB, ADMIN_B)
    resetCaptured()
    assertTrue(staleB:AddRCLootCouncilAllowedResponse("Offspec"), "Case D new coordinator deliberately edits RC settings")
    local postEditSet = lastOfType(Sync.MSG.RC_CONFIG_SET)
    assertTrue(postEditSet ~= nil, "Case D published RC_CONFIG_SET for the live edit")
    assertTrue(postEditSet.payload.coordEpoch > oldEpoch, "Case D SET uses the takeover session epoch")
    assertEq(postEditSet.payload.seq, 6, "Case D increments seq from the adopted generation")
    PLAYER = ADMIN_C
    withLocalProfile(peerC, function()
        Sync:HandleRCConfigSet(ADMIN_B, postEditSet.payload)
    end)
    PLAYER = ADMIN_B
    assertSameAccepted(staleB, peerC, "Case D after live edit")
    assertEq(peerC._rcConfigEpoch, postEditSet.payload.coordEpoch, "Case D peer stores the new accepted epoch")
    assertEq(staleB._rcConfigSeq, 6, "Case D coordinator accepted seq is 6")

    -- Case B: takeover does not mint when the new coordinator already holds current G1.
    resetEnv()
    installHarness()
    function Sync:_Now()
        return 100
    end
    coordA = beginSharedG0()
    resetCaptured()
    assertTrue(addGreed(coordA), "Case B coordinator A accepts Greed as BiS")
    local currentB = cloneProfileAs("RC Takeover Current B", coordA)
    peerC = cloneProfileAs("RC Takeover Current C", coordA)
    assertEq(currentB._rcConfigSeq, 5, "Case B Admin B already holds G1")
    function Sync:_Now()
        return 200
    end
    takeoverAsB(currentB, "coord-offline-current")
    driveAvailableAdminStatuses(ADMIN_B, { { player = ADMIN_C, profile = peerC } })
    reannounce = lastOfType(Sync.MSG.SES_REANNOUNCE)
    assertTrue(reannounce ~= nil, "Case B takeover reannounced the session")
    assertEq(countOfType(Sync.MSG.PROFILE_SNAPSHOT), 0, "Case B did not fan out PROFILE_SNAPSHOT for RC config")
    assertEq(countOfType(Sync.MSG.RC_CONFIG_SET), 0, "Case B did not mint another RC generation")
    assertEq(currentB._rcConfigEpoch, 100, "Case B kept accepted epoch 100")
    assertEq(currentB._rcConfigSeq, 5, "Case B kept accepted seq 5")
    receiveReannounce(ADMIN_C, peerC, ADMIN_B, reannounce.payload)
    restoreCoordinator(currentB, ADMIN_B)
    assertSameAccepted(currentB, peerC, "Case B after takeover")
    recorded, qualified = assertSameGreedAward(currentB, peerC, "case-b")
    assertTrue(recorded, "Case B Greed still records")
    assertEq(qualified, true, "Case B Greed still qualifies")

    -- Case C: unpublished/dirty peer contents are not takeover authority.
    resetEnv()
    installHarness()
    function Sync:_Now()
        return 100
    end
    coordA = beginSharedG0()
    staleB = cloneProfileAs("RC Takeover Dirty B", coordA)
    local dirtyC = cloneProfileAs("RC Takeover Dirty C", coordA)
    PLAYER = ADMIN_C
    SF.lootHelperDB.profiles[dirtyC:GetProfileId()] = dirtyC
    setActive(dirtyC)
    Sync.state.active = false
    Sync.state.isCoordinator = false
    assertTrue(addGreed(dirtyC), "Case C Admin C has an unpublished Greed draft")
    assertEq(dirtyC._rcConfigDirty, true, "Case C Admin C is dirty")
    assertEq(dirtyC._rcConfigSeq, 4, "Case C dirty draft stays on seq 4")
    assertFalse(dirtyC:IsBisQualifyingResponse("Greed", greedMeta()), "Case C unpublished Greed is not accepted")
    function Sync:_Now()
        return 200
    end
    takeoverAsB(staleB, "coord-offline-dirty")
    driveAvailableAdminStatuses(ADMIN_B, { { player = ADMIN_C, profile = dirtyC } })
    reannounce = lastOfType(Sync.MSG.SES_REANNOUNCE)
    assertTrue(reannounce ~= nil, "Case C takeover reannounced the session")
    assertEq(countOfType(Sync.MSG.RC_CONFIG_SET), 0, "Case C did not mint from a dirty peer")
    local dirtyStatus
    for i = 1, #captured do
        if captured[i].msgType == Sync.MSG.ADMIN_STATUS then
            dirtyStatus = captured[i]
        end
    end
    assertTrue(dirtyStatus ~= nil, "Case C Admin C sent ADMIN_STATUS")
    assertEq(dirtyStatus.payload.rcConfigDirty, true, "Case C ADMIN_STATUS reports unpublished dirty")
    assertEq(staleB._rcConfigSeq, 4, "Case C coordinator stayed on accepted G0")
    assertFalse(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "Case C dirty peer did not become accepted Greed")
    receiveReannounce(ADMIN_C, dirtyC, ADMIN_B, reannounce.payload)
    restoreCoordinator(staleB, ADMIN_B)
    assertEq(staleB._rcConfigSeq, 4, "Case C accepted seq remains G0 after reannounce")
    assertFalse(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "Case C award-time still uses accepted Need-only")

    -- Case E: authorized newer holder joining after takeover still converges.
    resetEnv()
    installHarness()
    function Sync:_Now()
        return 100
    end
    coordA = beginSharedG0()
    staleB = cloneProfileAs("RC Takeover Late B", coordA)
    resetCaptured()
    assertTrue(addGreed(coordA), "Case E coordinator A accepts Greed as BiS")
    peerC = cloneProfileAs("RC Takeover Late C", coordA)
    assertTrue(peerC:IsBisQualifyingResponse("Greed", greedMeta()), "Case E Admin C holds G1 before takeover")
    assertFalse(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "Case E Admin B missed G1")
    function Sync:_Now()
        return 200
    end
    takeoverAsB(staleB, "coord-offline-late")
    driveAvailableAdminStatuses(ADMIN_B, {})
    reannounce = lastOfType(Sync.MSG.SES_REANNOUNCE)
    assertTrue(reannounce ~= nil, "Case E takeover reannounced without Admin C")
    assertEq(staleB._rcConfigSeq, 4, "Case E coordinator still has G0 before the late join")
    assertFalse(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "Case E G0 is still Need-only before the late join")
    resetCaptured()
    receiveReannounce(ADMIN_C, peerC, ADMIN_B, reannounce.payload)
    local haveProfile = lastOfType(Sync.MSG.HAVE_PROFILE)
    assertTrue(haveProfile ~= nil, "Case E late admin sent HAVE_PROFILE on the join path")
    assertEq(haveProfile and haveProfile.payload and haveProfile.payload.rcConfigSeq, 5, "Case E HAVE_PROFILE advertises accepted seq 5")
    assertEq(haveProfile and haveProfile.payload and haveProfile.payload.rcConfigEpoch, 100, "Case E HAVE_PROFILE advertises accepted epoch 100")
    assertEq(haveProfile and haveProfile.payload and haveProfile.payload.rcConfigDirty, false, "Case E HAVE_PROFILE is not a dirty draft")
    restoreCoordinator(staleB, ADMIN_B)
    if haveProfile then
        Sync:HandleHaveProfile(ADMIN_C, haveProfile.payload)
    end
    local lateReannounce = lastOfType(Sync.MSG.SES_REANNOUNCE)
    assertTrue(lateReannounce ~= nil, "Case E coordinator reannounced after adopting the late newer holder")
    assertEq(staleB._rcConfigSeq, 5, "Case E coordinator adopted G1 from the late join")
    assertEq(staleB._rcConfigEpoch, 100, "Case E adopted accepted epoch 100 rather than minting")
    assertTrue(staleB:IsBisQualifyingResponse("Greed", greedMeta()), "Case E coordinator now holds G1")
    if lateReannounce then
        receiveReannounce(ADMIN_C, peerC, ADMIN_B, lateReannounce.payload)
    end
    assertSameAccepted(staleB, peerC, "Case E after late join")
    recorded, qualified = assertSameGreedAward(staleB, peerC, "case-e")
    assertTrue(recorded, "Case E Greed records after late convergence")
    assertEq(qualified, true, "Case E Greed qualifies after late convergence")
    assertEq(countOfType(Sync.MSG.PROFILE_SNAPSHOT), 0, "Case E did not fan out PROFILE_SNAPSHOT for RC config")

    PLAYER = "Tester-Garona"
    SF.LootHelperComm = nil
end
testTakeoverRCAuthorityWithoutPostEdit()

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
