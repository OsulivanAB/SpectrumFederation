-- Production-Lua tests for item-aware BiS reconstruction (#275).
-- Run from the repository root: lua5.1 tests/lua/bis_reconstruction_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(message) .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. tostring(message or "") .. "\n")
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

local PLAYER = "Owner-Garona"
local OWNER = "Owner-Garona"
local ALT_A = "Alpha-Garona"
local ALT_B = "Bravo-Garona"
local ALT_C = "Charlie-Garona"
local ZULU = "Zulu-Garona"

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

local NOW = 1700001000
function GetServerTime()
    NOW = NOW + 1
    return NOW
end

function GetTime()
    return 0
end

local ITEM_META = {
    ["19001"] = { loc = "INVTYPE_HEAD", class = 4, sub = 4 },
    ["19002"] = { loc = "INVTYPE_FINGER", class = 4, sub = 0 },
    ["19003"] = { loc = "INVTYPE_TRINKET", class = 4, sub = 0 },
    ["19004"] = { loc = "INVTYPE_2HWEAPON", class = 2, sub = 8 },
    ["19005"] = { loc = "INVTYPE_WEAPON", class = 2, sub = 7 },
    ["19006"] = { loc = "INVTYPE_WEAPONOFFHAND", class = 2, sub = 0 },
    ["19007"] = { loc = "INVTYPE_CLOAK", class = 4, sub = 1 },
    ["19008"] = { loc = "INVTYPE_CHEST", class = 4, sub = 4 },
    ["19009"] = { loc = "INVTYPE_HOLDABLE", class = 4, sub = 0 },
    ["19010"] = { loc = "INVTYPE_HEAD", class = 4, sub = 4 },
    ["19011"] = { loc = "INVTYPE_SHIELD", class = 4, sub = 6 },
    ["19012"] = { loc = "INVTYPE_2HWEAPON", class = 2, sub = 10 },
    ["19013"] = { loc = "INVTYPE_2HWEAPON", class = 2, sub = 6 },
    ["19014"] = { loc = "INVTYPE_2HWEAPON", class = 2, sub = 5 },
    ["19015"] = { loc = "INVTYPE_WEAPON", class = 2, sub = 15 },
    ["19016"] = { loc = "INVTYPE_RANGED", class = 2, sub = 2 },
    ["19017"] = { loc = "INVTYPE_RANGEDRIGHT", class = 2, sub = 19 },
    ["19018"] = { loc = "INVTYPE_WEAPON", class = 2, sub = 9 },
    ["19019"] = { loc = "INVTYPE_2HWEAPON", class = 2, sub = 1 },
}

function GetItemInfoInstant(link)
    local text = tostring(link)
    local id = text:match("item:(%d+)") or text:match("^(%d+)$")
    local rec = ITEM_META[id]
    if not rec then
        return nil
    end
    return tonumber(id), "Armor", "Plate", rec.loc, 134400, rec.class, rec.sub
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
loadModule("SpectrumFederation/modules/LootHelper/SyncProtocol.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/00_Namespace.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/01_Constants.lua")

function SF:GetPlayerFullIdentifier()
    return PLAYER
end

function SF:GetPlayerClass()
    return "WARRIOR"
end

function SF:PrintWarning(message)
    printed[#printed + 1] = { "warn", tostring(message) }
end

function SF:PrintError(message)
    printed[#printed + 1] = { "error", tostring(message) }
end

function SF:PrintInfo(message)
    printed[#printed + 1] = { "info", tostring(message) }
end

SF.Debug = {
    Info = function() end,
    Warn = function() end,
    Error = function() end,
    Verbose = function() end,
}

local function resetEnv()
    printed = {}
    PLAYER = OWNER
    NOW = 1700001000
    SF.lootHelperDB = {
        enabled = true,
        profiles = {},
        activeProfileId = nil,
        activeProfile = nil,
        window = {},
        syncSession = {},
    }
    SpectrumFederationDB.lootHelper = SF.lootHelperDB
end

local function makeProfile(name)
    local profile = SF.LootProfile.new(name)
    assert(profile, "failed to create profile " .. tostring(name))
    SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
    SF.lootHelperDB.activeProfileId = profile:GetProfileId()
    SF.lootHelperDB.activeProfile = profile
    return profile
end

local function addMember(profile, memberId, role, class)
    local member = SF.Member.new(memberId, role or "member", class or "WARRIOR")
    assert(member, "failed to create member " .. tostring(memberId))
    assert(profile:AddMember(member), "failed to add member " .. tostring(memberId))
    return member
end

local function addLog(profile, eventType, data, extra)
    extra = extra or {}
    data = data or {}
    if data.preOpAuthorMax == nil then
        data.preOpAuthorMax = {}
    end
    local opts = {
        profile = profile,
        skipPermission = true,
        author = extra.author or PLAYER,
        timestamp = extra.timestamp,
        counter = extra.counter,
    }
    if opts.counter == nil then
        opts.counter = profile:AllocateNextCounter(opts.author)
    end
    local log = SF.LootLog.new(eventType, data, opts)
    assert(log, "failed to create " .. tostring(eventType))
    assert(profile:AddLootLog(log, { skipPermission = true, skipBroadcast = true }), "failed to insert " .. tostring(eventType))
    return log
end

local function asPlayer(memberId, fn)
    local previous = PLAYER
    PLAYER = memberId
    local a, b, c = fn()
    PLAYER = previous
    return a, b, c
end

local function itemLink(itemId, name)
    return string.format("|cffa335ee|Hitem:%s::::::::80:259:::::::::|h[%s]|h|r", tostring(itemId), name or "Item")
end

local function withFrozen(data, itemId)
    local classif = SF.LootHelperBis.ClassifyItem(itemLink(itemId, "x"))
    assertTrue(classif ~= nil, "frozen classif exists for item " .. tostring(itemId))
    data.equipLoc = classif.equipLoc
    data.itemClass = classif.itemClass
    data.itemSubClass = classif.itemSubClass
    data.itemFamily = classif.family
    data.isTwoHand = classif.isTwoHand
    return data
end

local function insertRC(profile, canonical)
    local eventData = SF.LootLog.BuildRCLootCouncilEventData(canonical)
    local log = SF.LootLog.new(SF.LootLogEventTypes.RC_LOOT_COUNCIL, eventData, {
        profile = profile,
        skipPermission = true,
        author = canonical.awarder,
        timestamp = canonical.timestamp,
        externalId = canonical.awardKey,
        counter = 0,
    })
    assert(log, "failed to create RC log")
    assert(profile:AddLootLog(log, { skipPermission = true, skipBroadcast = true }), "failed to insert RC log")
    return log
end

local function makeCanonical(winner, itemId, response, stamp)
    stamp = stamp or tostring(GetServerTime())
    return SF.LootLog.BuildRCLootCouncilCanonical(PLAYER, winner, {
        lootWon = itemLink(itemId, "Item" .. tostring(itemId)),
        response = response or "Need",
        id = stamp .. "-7",
        owner = winner,
    })
end

local function slotState(profile, memberId, slot)
    local slots = profile:GetIdentityBisSlots(memberId)
    return slots and slots[slot] and slots[slot].state or "AVAILABLE"
end

local function warnCount()
    local n = 0
    for i = 1, #printed do
        if printed[i][1] == "warn" then
            n = n + 1
        end
    end
    return n
end

resetEnv()

-- Schema rejects contradictory qualified/outcome pairs
assertFalse(SF.LootHelperBis.IsOutcomeSchemaValid({
    sourceLogId = "k", awardKey = "k", awardMember = ALT_A,
    qualified = true, outcome = "NOT_BIS", assignedSlots = {},
}), "NOT_BIS cannot be qualified")
assertFalse(SF.LootHelperBis.IsOutcomeSchemaValid({
    sourceLogId = "k", awardKey = "k", awardMember = ALT_A,
    qualified = false, outcome = "ASSIGNED", assignedSlots = { "Head" }, slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
}), "ASSIGNED cannot be unqualified")
assertFalse(SF.LootHelperBis.IsOutcomeSchemaValid({
    sourceLogId = "k", awardKey = "k", awardMember = ALT_A,
    qualified = true, outcome = "OVERFLOW", assignedSlots = { "Head" },
}), "OVERFLOW assignedSlots must be empty")
assertTrue(SF.LootHelperBis.IsOutcomeSchemaValid({
    sourceLogId = "k", awardKey = "k", awardMember = ALT_A,
    qualified = false, outcome = "NOT_BIS", assignedSlots = {},
}), "valid NOT_BIS")
assertTrue(SF.LootHelperBis.IsOutcomeSchemaValid({
    sourceLogId = "k", awardKey = "k", awardMember = ALT_A,
    qualified = true, outcome = "ASSIGNED", assignedSlots = { "Head" },
    slotBinding = "BOUND", assignmentScopeMembers = { ALT_A },
}), "valid ASSIGNED")

-- Same-second observed SPEC edits: last causal write wins
resetEnv()
local specProfile = makeProfile("Spec")
addMember(specProfile, ALT_A)
addLog(specProfile, "SPEC_CHANGE", { member = ALT_A, specId = 72 }, { author = ZULU, timestamp = 1700005000 })
addLog(specProfile, "SPEC_CHANGE", { member = ALT_A, specId = 71 }, { author = OWNER, timestamp = 1700005000 })
specProfile:ApplyIdentityProjection({ force = true })
assertEq(specProfile:getMemberByID(ALT_A):GetSpecId(), 71, "Replay last causal SPEC_CHANGE is Arms")

-- Automatic NOT_BIS / ASSIGNED / OVERFLOW / UNRESOLVED
resetEnv()
local auto = makeProfile("Auto")
addMember(auto, ALT_A)
assertTrue(auto:AddRCLootCouncilBisResponse("Need"), "add BiS response")
local notBis = makeCanonical(ALT_A, 19001, "Greed", "1700002001")
assertTrue(auto:TryAddRCLootCouncilAward(notBis), "record non-BiS award")
auto:ApplyIdentityProjection({ force = true })
local pool = auto:GetIdentityAwardPool(ALT_A)
assertTrue(#pool >= 1, "RC-only/non-BiS award still enters the pool")
assertEq(slotState(auto, ALT_A, "Head"), "AVAILABLE", "NOT_BIS does not occupy Head")

local assigned = makeCanonical(ALT_A, 19001, "Need", "1700002002")
assertTrue(auto:TryAddRCLootCouncilAward(assigned), "record BiS head")
auto:ApplyIdentityProjection({ force = true })
assertEq(slotState(auto, ALT_A, "Head"), "ASSIGNED_AUTO", "first BiS head is assigned")

local overflow = makeCanonical(ALT_A, 19001, "Need", "1700002003")
assertTrue(auto:TryAddRCLootCouncilAward(overflow), "record second BiS head")
auto:ApplyIdentityProjection({ force = true })
assertEq(slotState(auto, ALT_A, "Head"), "ASSIGNED_AUTO", "first head remains assigned")
local sawOverflow = false
for _, log in ipairs(auto:GetLootLogs()) do
    if log:GetEventType() == "BIS_OUTCOME" and log:GetEventData().outcome == "OVERFLOW" then
        sawOverflow = true
    end
end
assertTrue(sawOverflow, "second head is frozen OVERFLOW")
assertTrue(warnCount() >= 1, "live overflow warns once")

local unknown = makeCanonical(ALT_A, 19999, "Need", "1700002004")
assertTrue(auto:TryAddRCLootCouncilAward(unknown), "record unclassifiable item")
local sawUnresolved = false
for _, log in ipairs(auto:GetLootLogs()) do
    if log:GetEventType() == "BIS_OUTCOME" and log:GetEventData().outcome == "UNRESOLVED" then
        sawUnresolved = true
    end
end
assertTrue(sawUnresolved, "unknown item is UNRESOLVED")

-- Duplicate RC insert does not write another automatic outcome
local before = #(auto:GetLootLogs() or {})
assertFalse(auto:TryAddRCLootCouncilAward(assigned), "duplicate RC is rejected")
assertEq(#(auto:GetLootLogs() or {}), before, "duplicate RC does not add another outcome")

-- Outcome-before-RC then RC arrives
resetEnv()
local orphan = makeProfile("Orphan")
addMember(orphan, ALT_A)
local rcCanon = makeCanonical(ALT_A, 19007, "Need", "1700002100")
assertTrue(orphan:AddRCLootCouncilBisResponse("Need"))
addLog(orphan, "BIS_OUTCOME", withFrozen({
    sourceLogId = rcCanon.awardKey,
    awardKey = rcCanon.awardKey,
    awardMember = ALT_A,
    qualified = true,
    outcome = "ASSIGNED",
    assignedSlots = { "Back" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
}, 19007))
orphan:ApplyIdentityProjection({ force = true })
assertEq(slotState(orphan, ALT_A, "Back"), "AVAILABLE", "orphan outcome does not assign without RC")
assertTrue(orphan:TryAddRCLootCouncilAward(rcCanon), "RC source arrives later")
orphan:ApplyIdentityProjection({ force = true })
assertEq(slotState(orphan, ALT_A, "Back"), "ASSIGNED_AUTO", "outcome applies once RC exists")

-- First source-consistent valid outcome wins; later duplicates ignored
resetEnv()
local firstWins = makeProfile("FirstWins")
addMember(firstWins, ALT_A)
local keyCanon = makeCanonical(ALT_A, 19008, "Need", "1700002200")
insertRC(firstWins, keyCanon)
addLog(firstWins, "BIS_OUTCOME", withFrozen({
    sourceLogId = keyCanon.awardKey,
    awardKey = keyCanon.awardKey,
    awardMember = ALT_A,
    qualified = true,
    outcome = "ASSIGNED",
    assignedSlots = { "Chest" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
}, 19008), { author = ZULU })
addLog(firstWins, "BIS_OUTCOME", {
    sourceLogId = keyCanon.awardKey,
    awardKey = keyCanon.awardKey,
    awardMember = ALT_A,
    qualified = true,
    outcome = "OVERFLOW",
    assignedSlots = {},
}, { author = OWNER })
firstWins:ApplyIdentityProjection({ force = true })
assertEq(slotState(firstWins, ALT_A, "Chest"), "ASSIGNED_AUTO", "first valid outcome wins")

-- Inconsistent awardMember is retained but does not win
resetEnv()
local mismatch = makeProfile("Mismatch")
addMember(mismatch, ALT_A)
addMember(mismatch, ALT_B)
local rcA = makeCanonical(ALT_A, 19001, "Need", "1700002300")
insertRC(mismatch, rcA)
addLog(mismatch, "BIS_OUTCOME", {
    sourceLogId = rcA.awardKey,
    awardKey = rcA.awardKey,
    awardMember = ALT_B,
    qualified = true,
    outcome = "ASSIGNED",
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_B },
})
addLog(mismatch, "BIS_OUTCOME", withFrozen({
    sourceLogId = rcA.awardKey,
    awardKey = rcA.awardKey,
    awardMember = ALT_A,
    qualified = true,
    outcome = "ASSIGNED",
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
}, 19001))
mismatch:ApplyIdentityProjection({ force = true })
assertEq(slotState(mismatch, ALT_A, "Head"), "ASSIGNED_AUTO", "first source-consistent outcome wins")
assertEq(slotState(mismatch, ALT_B, "Head"), "AVAILABLE", "mismatched outcome does not retarget B")

-- Manual award does not auto-consume; assign; reverse deactivates
resetEnv()
local manual = makeProfile("Manual")
addMember(manual, ALT_A)
assertTrue(manual:AddManualAward(ALT_A, itemLink(19001, "Helm")))
manual:ApplyIdentityProjection({ force = true })
assertEq(slotState(manual, ALT_A, "Head"), "AVAILABLE", "manual add does not consume")
local manualId
for _, award in ipairs(manual:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        manualId = award.id
    end
end
assertTrue(manualId ~= nil, "manual award is in the pool")
assertTrue(manual:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = manualId },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}), "assign manual loot")
manual:ApplyIdentityProjection({ force = true })
assertEq(slotState(manual, ALT_A, "Head"), "ASSIGNED_OVERRIDE", "manual loot can be assigned")
assertTrue(manual:ReverseManualAward(manualId), "reverse manual loot")
manual:ApplyIdentityProjection({ force = true })
assertEq(slotState(manual, ALT_A, "Head"), "AVAILABLE", "reverse deactivates assignment")
assertFalse(manual:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = manualId },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}), "reversed manual cannot be assigned")

-- One award / one active assignment, including concurrent ASSIGN
resetEnv()
local uniq = makeProfile("Uniq")
addMember(uniq, ALT_A)
assertTrue(uniq:AddRCLootCouncilBisResponse("Need"))
local ringCanon = makeCanonical(ALT_A, 19002, "Greed", "1700002400")
assertTrue(uniq:TryAddRCLootCouncilAward(ringCanon))
assertTrue(uniq:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "RC", id = ringCanon.awardKey },
    assignedSlots = { "Ring1" },
    slotBinding = "BOUND",
}))
assertFalse(uniq:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "RC", id = ringCanon.awardKey },
    assignedSlots = { "Ring2" },
    slotBinding = "BOUND",
}), "second ASSIGN of the same award is a no-op")
uniq:ApplyIdentityProjection({ force = true })
assertEq(slotState(uniq, ALT_A, "Ring1"), "ASSIGNED_OVERRIDE", "first ring assignment remains")
assertEq(slotState(uniq, ALT_A, "Ring2"), "AVAILABLE", "second ring stays free")

-- REPLACE using another already-active award fails atomically
local ring2 = makeCanonical(ALT_A, 19002, "Greed", "1700002401")
assertTrue(uniq:TryAddRCLootCouncilAward(ring2))
assertTrue(uniq:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "RC", id = ring2.awardKey },
    assignedSlots = { "Ring2" },
    slotBinding = "BOUND",
}))
local firstAssignment
local slots = uniq:GetIdentityBisSlots(ALT_A)
firstAssignment = slots.Ring1.assignmentId
assertFalse(uniq:ApplyBisOverride("REPLACE", {
    viewMember = ALT_A,
    targetAssignmentId = firstAssignment,
    awardRef = { kind = "RC", id = ring2.awardKey },
    assignedSlots = { "Ring1" },
    slotBinding = "BOUND",
}), "REPLACE with already-active other award fails")
uniq:ApplyIdentityProjection({ force = true })
assertEq(uniq:GetIdentityBisSlots(ALT_A).Ring1.assignmentId, firstAssignment, "failed REPLACE leaves old assignment")
assertEq(slotState(uniq, ALT_A, "Ring2"), "ASSIGNED_OVERRIDE", "other award remains on Ring2")

local ring2Assignment = uniq:GetIdentityBisSlots(ALT_A).Ring2.assignmentId
assertTrue(uniq:ApplyBisOverride("CLEAR", { viewMember = ALT_A, targetAssignmentId = ring2Assignment }), "clear Ring2 for rebind")
uniq:ApplyIdentityProjection({ force = true })

-- Move/rebind same award onto the other ring
assertTrue(uniq:ApplyBisOverride("REPLACE", {
    viewMember = ALT_A,
    targetAssignmentId = firstAssignment,
    awardRef = { kind = "RC", id = ringCanon.awardKey },
    assignedSlots = { "Ring2" },
    slotBinding = "BOUND",
}), "move/rebind same award Ring1 -> Ring2")
uniq:ApplyIdentityProjection({ force = true })
assertEq(slotState(uniq, ALT_A, "Ring2"), "ASSIGNED_OVERRIDE", "rebind occupies Ring2")
assertEq(slotState(uniq, ALT_A, "Ring1"), "AVAILABLE", "old ring hole remains after move")
assertFalse(uniq:ApplyBisOverride("REPLACE", {
    viewMember = ALT_A,
    targetAssignmentId = uniq:GetIdentityBisSlots(ALT_A).Ring2.assignmentId,
    awardRef = { kind = "RC", id = ringCanon.awardKey },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}), "Ring cannot be rebound to Head")

-- Frozen overflow does not backfill after CLEAR
resetEnv()
local pack = makeProfile("Pack")
addMember(pack, ALT_A)
assertTrue(pack:AddRCLootCouncilBisResponse("Need"))
local r1 = makeCanonical(ALT_A, 19002, "Need", "1700002500")
local r2 = makeCanonical(ALT_A, 19002, "Need", "1700002501")
local r3 = makeCanonical(ALT_A, 19002, "Need", "1700002502")
assertTrue(pack:TryAddRCLootCouncilAward(r1))
assertTrue(pack:TryAddRCLootCouncilAward(r2))
assertTrue(pack:TryAddRCLootCouncilAward(r3))
pack:ApplyIdentityProjection({ force = true })
assertEq(slotState(pack, ALT_A, "Ring1"), "ASSIGNED_AUTO", "first ring assigned")
assertEq(slotState(pack, ALT_A, "Ring2"), "ASSIGNED_AUTO", "second ring assigned")
local ring2Id = pack:GetIdentityBisSlots(ALT_A).Ring2.assignmentId
assertTrue(pack:ApplyBisOverride("CLEAR", { viewMember = ALT_A, targetAssignmentId = ring2Id }))
pack:ApplyIdentityProjection({ force = true })
assertEq(slotState(pack, ALT_A, "Ring1"), "ASSIGNED_AUTO", "first ring remains")
assertEq(slotState(pack, ALT_A, "Ring2"), "AVAILABLE", "cleared ring is a hole")
local thirdStillOverflow = false
for _, log in ipairs(pack:GetLootLogs()) do
    if log:GetEventType() == "BIS_OUTCOME" and log:GetEventData().awardKey == r3.awardKey then
        thirdStillOverflow = log:GetEventData().outcome == "OVERFLOW"
    end
end
assertTrue(thirdStillOverflow, "frozen OVERFLOW remains overflow after CLEAR")

-- Independent singleton Ring1 + Ring1 then LINK => Ring1 + Ring2
resetEnv()
local linkP = makeProfile("LinkRings")
addMember(linkP, ALT_A)
addMember(linkP, ALT_B)
assertTrue(linkP:AddRCLootCouncilBisResponse("Need"))
local aRing = makeCanonical(ALT_A, 19002, "Need", "1700002600")
local bRing = makeCanonical(ALT_B, 19002, "Need", "1700002601")
assertTrue(linkP:TryAddRCLootCouncilAward(aRing))
assertTrue(linkP:TryAddRCLootCouncilAward(bRing))
assertTrue(linkP:LinkCharacters(ALT_A, ALT_B))
linkP:ApplyIdentityProjection({ force = true })
assertEq(slotState(linkP, ALT_A, "Ring1"), "ASSIGNED_AUTO", "merged Ring1 occupied")
assertEq(slotState(linkP, ALT_A, "Ring2"), "ASSIGNED_AUTO", "merged Ring2 occupied")
assertEq(slotState(linkP, ALT_B, "Ring1"), "ASSIGNED_AUTO", "linked B sees the same board")

-- Three independent rings => merge overflow
resetEnv()
local three = makeProfile("ThreeRings")
addMember(three, ALT_A)
addMember(three, ALT_B)
addMember(three, ALT_C)
assertTrue(three:AddRCLootCouncilBisResponse("Need"))
assertTrue(three:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19002, "Need", "1700002700")))
assertTrue(three:TryAddRCLootCouncilAward(makeCanonical(ALT_B, 19002, "Need", "1700002701")))
assertTrue(three:TryAddRCLootCouncilAward(makeCanonical(ALT_C, 19002, "Need", "1700002702")))
assertTrue(three:LinkCharacters(ALT_A, ALT_B))
assertTrue(three:LinkCharacters(ALT_B, ALT_C))
three:ApplyIdentityProjection({ force = true })
local merged = three:GetIdentityBisSlots(ALT_A)
assertTrue(merged.Ring1.state ~= "AVAILABLE", "two rings remain assigned after 3-way link")
assertTrue(merged.Ring2.state ~= "AVAILABLE", "second ring occupied")
local overflowCount = 0
local view = SF.LootHelperBis.ProjectComponent(three._identityProjection.bis.state, three:GetIdentityMembers(ALT_A))
overflowCount = #(view.mergeOverflow or {})
assertTrue(overflowCount >= 1, "third independent ring is merge-overflow")

-- Unlink recomputes; relink does not resurrect a CLEARed assignment
resetEnv()
local relink = makeProfile("Relink")
addMember(relink, ALT_A)
addMember(relink, ALT_B)
assertTrue(relink:AddRCLootCouncilBisResponse("Need"))
local shared = makeCanonical(ALT_A, 19007, "Need", "1700002800")
assertTrue(relink:TryAddRCLootCouncilAward(shared))
assertTrue(relink:LinkCharacters(ALT_A, ALT_B))
relink:ApplyIdentityProjection({ force = true })
local asgId = relink:GetIdentityBisSlots(ALT_A).Back.assignmentId
assertTrue(relink:ApplyBisOverride("CLEAR", { viewMember = ALT_B, targetAssignmentId = asgId }), "clear via B viewMember")
assertTrue(relink:UnlinkCharacter(ALT_B))
assertTrue(relink:LinkCharacters(ALT_A, ALT_B))
relink:ApplyIdentityProjection({ force = true })
assertEq(slotState(relink, ALT_A, "Back"), "AVAILABLE", "relink does not resurrect cleared assignment")

-- 2H Arms occupies Weapon+OffHand as one assignment
resetEnv()
local arms = makeProfile("Arms")
addMember(arms, ALT_A)
assertTrue(arms:SetMemberSpec(ALT_A, 71))
assertTrue(arms:AddRCLootCouncilBisResponse("Need"))
local twoH = makeCanonical(ALT_A, 19004, "Need", "1700002900")
assertTrue(arms:TryAddRCLootCouncilAward(twoH))
arms:ApplyIdentityProjection({ force = true })
assertEq(slotState(arms, ALT_A, "Weapon"), "ASSIGNED_AUTO", "2H occupies Weapon")
assertEq(slotState(arms, ALT_A, "OffHand"), "ASSIGNED_AUTO", "2H occupies OffHand")
local wcell = arms:GetIdentityBisSlots(ALT_A).Weapon
local ocell = arms:GetIdentityBisSlots(ALT_A).OffHand
assertEq(wcell.assignmentId, ocell.assignmentId, "one 2H assignment occupies both slots")

-- Fury dual 2H: first Weapon, second OffHand
resetEnv()
local fury = makeProfile("Fury")
addMember(fury, ALT_A)
assertTrue(fury:SetMemberSpec(ALT_A, 72))
assertTrue(fury:AddRCLootCouncilBisResponse("Need"))
assertTrue(fury:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19004, "Need", "1700003000")))
assertTrue(fury:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19004, "Need", "1700002901")))
fury:ApplyIdentityProjection({ force = true })
assertEq(slotState(fury, ALT_A, "Weapon"), "ASSIGNED_AUTO", "first Fury 2H is Weapon")
assertEq(slotState(fury, ALT_A, "OffHand"), "ASSIGNED_AUTO", "second Fury 2H is OffHand")
assertTrue(fury:GetIdentityBisSlots(ALT_A).Weapon.assignmentId ~= fury:GetIdentityBisSlots(ALT_A).OffHand.assignmentId, "dual-2H uses two assignments")

-- Unknown spec weapon is UNRESOLVED
resetEnv()
local nospec = makeProfile("NoSpec")
addMember(nospec, ALT_A)
assertTrue(nospec:AddRCLootCouncilBisResponse("Need"))
assertTrue(nospec:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19004, "Need", "1700003100")))
local unresolvedWeapon = false
for _, log in ipairs(nospec:GetLootLogs()) do
    if log:GetEventType() == "BIS_OUTCOME" and log:GetEventData().outcome == "UNRESOLVED" then
        unresolvedWeapon = true
    end
end
assertTrue(unresolvedWeapon, "weapon without spec is UNRESOLVED")

-- Historical award does not move when spec later changes
resetEnv()
local laterSpec = makeProfile("LaterSpec")
addMember(laterSpec, ALT_A)
assertTrue(laterSpec:SetMemberSpec(ALT_A, 71))
assertTrue(laterSpec:AddRCLootCouncilBisResponse("Need"))
assertTrue(laterSpec:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19004, "Need", "1700003200")))
laterSpec:ApplyIdentityProjection({ force = true })
local beforeWeapon = laterSpec:GetIdentityBisSlots(ALT_A).Weapon.assignmentId
assertTrue(laterSpec:SetMemberSpec(ALT_A, 72))
laterSpec:ApplyIdentityProjection({ force = true })
assertEq(laterSpec:GetIdentityBisSlots(ALT_A).Weapon.assignmentId, beforeWeapon, "later spec change does not rewrite frozen 2H")
assertEq(slotState(laterSpec, ALT_A, "OffHand"), "ASSIGNED_AUTO", "Arms 2H still occupies OffHand after Fury spec")

-- Trinket equivalent packing
resetEnv()
local trink = makeProfile("Trink")
addMember(trink, ALT_A)
assertTrue(trink:AddRCLootCouncilBisResponse("Need"))
assertTrue(trink:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19003, "Need", "1700003300")))
assertTrue(trink:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19003, "Need", "1700003301")))
trink:ApplyIdentityProjection({ force = true })
assertEq(slotState(trink, ALT_A, "Trinket1"), "ASSIGNED_AUTO", "first trinket assigned")
assertEq(slotState(trink, ALT_A, "Trinket2"), "ASSIGNED_AUTO", "second trinket assigned")

-- Points / pot / attendance isolation
resetEnv()
local iso = makeProfile("Iso")
addMember(iso, ALT_A)
local pointsBefore = iso:GetIdentityPoints(ALT_A)
local attBefore = iso:GetIdentityAttendance(ALT_A)
assertTrue(iso:AddRCLootCouncilBisResponse("Need"))
assertTrue(iso:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19001, "Need", "1700003400")))
iso:ApplyIdentityProjection({ force = true })
assertEq(iso:GetIdentityPoints(ALT_A), pointsBefore, "BiS does not spend points")
assertEq(iso:GetIdentityAttendance(ALT_A), attBefore, "BiS does not change Attendance")

-- Replay / snapshot does not warn
resetEnv()
local live = makeProfile("Warn")
addMember(live, ALT_A)
assertTrue(live:AddRCLootCouncilBisResponse("Need"))
assertTrue(live:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19001, "Need", "1700003500")))
assertTrue(live:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19001, "Need", "1700003501")))
local liveWarns = warnCount()
assertTrue(liveWarns >= 1, "live overflow warned")
local snapshot = live:ExportSnapshot()
resetEnv()
local restored = makeProfile("Restored")
restored._profileId = snapshot.meta._profileId
assertTrue(select(1, restored:ImportSnapshot(snapshot)), "snapshot import")
assertEq(warnCount(), 0, "snapshot import does not warn")

-- Item-aware popup after BiS config or events
assertTrue(live:IsItemAwareEquipmentPopup(), "configured BiS responses make the popup item-aware")
resetEnv()
local fallback = makeProfile("Fallback")
addMember(fallback, ALT_A)
assertFalse(fallback:IsItemAwareEquipmentPopup(), "no BiS config or events keeps manual popup")

-- Protocol 2 rejected, 3 accepted
assertEq(SF.SyncProtocol.PROTO_CURRENT, 3, "protocol is 3")
assertFalse(select(1, SF.SyncProtocol.ValidateProtocolVersion(2)), "protocol 2 is rejected")
assertTrue(SF.SyncProtocol.ValidateProtocolVersion(3), "protocol 3 is accepted")

-- Back icon is distinct from Chest
local eqSource = io.open("SpectrumFederation/modules/UI/LootHelper/EquipmentWindow.lua"):read("*a")
assertTrue(eqSource:find("INV_Misc_Cape_01", 1, true) ~= nil, "Back uses a distinct cape fallback icon")
assertTrue(eqSource:find("UI%-PaperDoll%-Slot%-Chest") ~= nil, "Chest keeps the chest paperdoll icon")

-- Legacy association
resetEnv()
local legacy = makeProfile("Legacy")
addMember(legacy, ALT_A)
addLog(legacy, "ARMOR_CHANGE", {
    member = ALT_A,
    slot = "Head",
    action = "USED",
})
legacy:ApplyIdentityProjection({ force = true })
assertTrue(legacy:AddManualAward(ALT_A, itemLink(19001, "Helm")))
local manId
for _, award in ipairs(legacy:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        manId = award.id
    end
end
local origins = legacy:GetIdentityLegacyOrigins(ALT_A)
assertTrue(#origins >= 1, "local USED origin is exposed")
assertTrue(legacy:ApplyBisOverride("ASSOCIATE_LEGACY", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = manId },
    legacyOriginLogId = origins[1].originLogId,
}), "associate legacy origin")
legacy:ApplyIdentityProjection({ force = true })
assertEq(slotState(legacy, ALT_A, "Head"), "ASSIGNED_OVERRIDE", "association occupies the origin slot")
addLog(legacy, "ARMOR_CHANGE", {
    member = ALT_A,
    slot = "Head",
    action = "AVAILABLE",
})
legacy:ApplyIdentityProjection({ force = true })
assertEq(slotState(legacy, ALT_A, "Head"), "AVAILABLE", "clearing the origin deactivates the association")
assertFalse(legacy:ApplyBisOverride("ASSOCIATE_LEGACY", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = manId },
    legacyOriginLogId = origins[1].originLogId,
}), "inactive origin cannot be associated")
assertTrue(legacy:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = manId },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}), "expired association does not block reuse")
legacy:ApplyIdentityProjection({ force = true })
assertEq(slotState(legacy, ALT_A, "Head"), "ASSIGNED_OVERRIDE", "same award can be assigned after origin expiry")

-- Stale CLEAR does not remove a replacement
resetEnv()
local stale = makeProfile("Stale")
addMember(stale, ALT_A)
local addedA = stale:AddManualAward(ALT_A, itemLink(19001, "HelmA"))
local addedB = stale:AddManualAward(ALT_A, itemLink(19010, "HelmB"))
assertTrue(addedA, "first manual loot added")
assertTrue(addedB, "second manual loot added")
local ids = {}
for _, award in ipairs(stale:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        ids[#ids + 1] = award.id
    end
end
assertTrue(stale:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = ids[1] },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}))
stale:ApplyIdentityProjection({ force = true })
local oldId = stale:GetIdentityBisSlots(ALT_A).Head.assignmentId
assertTrue(stale:ApplyBisOverride("REPLACE", {
    viewMember = ALT_A,
    targetAssignmentId = oldId,
    awardRef = { kind = "MANUAL", id = ids[2] },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}))
stale:ApplyIdentityProjection({ force = true })
assertTrue(stale:ApplyBisOverride("CLEAR", {
    viewMember = ALT_A,
    targetAssignmentId = oldId,
}), "stale CLEAR is accepted as a no-op")
stale:ApplyIdentityProjection({ force = true })
assertTrue(stale:GetIdentityBisSlots(ALT_A).Head.assignmentId ~= oldId, "replacement assignment survives stale CLEAR")
assertEq(slotState(stale, ALT_A, "Head"), "ASSIGNED_OVERRIDE", "replacement remains assigned")

-- A+B BOUND Ring2 + C singleton Ring1 then LINK preserves both holes
resetEnv()
local hole = makeProfile("HoleMerge")
addMember(hole, ALT_A)
addMember(hole, ALT_B)
addMember(hole, ALT_C)
assertTrue(hole:LinkCharacters(ALT_A, ALT_B), "link A+B")
assertTrue(hole:AddManualAward(ALT_A, itemLink(19002, "RingAB")))
local abRingId
for _, award in ipairs(hole:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        abRingId = award.id
    end
end
assertTrue(hole:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = abRingId },
    assignedSlots = { "Ring2" },
    slotBinding = "BOUND",
}), "A+B explicit Ring2")
assertTrue(hole:AddRCLootCouncilBisResponse("Need"))
assertTrue(hole:TryAddRCLootCouncilAward(makeCanonical(ALT_C, 19002, "Need", "1700003600")))
hole:ApplyIdentityProjection({ force = true })
assertEq(slotState(hole, ALT_C, "Ring1"), "ASSIGNED_AUTO", "C singleton occupies Ring1")
assertTrue(hole:LinkCharacters(ALT_A, ALT_C), "link C into A+B")
hole:ApplyIdentityProjection({ force = true })
assertEq(slotState(hole, ALT_A, "Ring1"), "ASSIGNED_AUTO", "merged C remains Ring1")
assertEq(slotState(hole, ALT_A, "Ring2"), "ASSIGNED_OVERRIDE", "A+B Ring2 is preserved")

-- Overlapping historical scope keys: singleton {A} plus later {A,B}
resetEnv()
local overlap = makeProfile("Overlap")
addMember(overlap, ALT_A)
addMember(overlap, ALT_B)
assertTrue(overlap:AddRCLootCouncilBisResponse("Need"))
assertTrue(overlap:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19002, "Need", "1700003700")))
assertTrue(overlap:LinkCharacters(ALT_A, ALT_B))
assertTrue(overlap:TryAddRCLootCouncilAward(makeCanonical(ALT_B, 19002, "Need", "1700003701")))
overlap:ApplyIdentityProjection({ force = true })
assertEq(slotState(overlap, ALT_A, "Ring1"), "ASSIGNED_AUTO", "overlapping scope first ring")
assertEq(slotState(overlap, ALT_A, "Ring2"), "ASSIGNED_AUTO", "overlapping scope second ring")

-- 1H then OffHand holdable; dual-wield 1H; incompatible later 2H
resetEnv()
local weapons = makeProfile("Weapons")
addMember(weapons, ALT_A, "member", "PALADIN")
assertTrue(weapons:SetMemberSpec(ALT_A, 65), "Holy paladin spec")
assertTrue(weapons:AddRCLootCouncilBisResponse("Need"))
assertTrue(weapons:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700003800")))
assertTrue(weapons:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19009, "Need", "1700003801")))
weapons:ApplyIdentityProjection({ force = true })
assertEq(slotState(weapons, ALT_A, "Weapon"), "ASSIGNED_AUTO", "1H occupies Weapon")
assertEq(slotState(weapons, ALT_A, "OffHand"), "ASSIGNED_AUTO", "holdable occupies OffHand")

resetEnv()
local dw = makeProfile("DualWield")
addMember(dw, ALT_A)
assertTrue(dw:SetMemberSpec(ALT_A, 72), "Fury spec")
assertTrue(dw:AddRCLootCouncilBisResponse("Need"))
assertTrue(dw:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700003900")))
assertTrue(dw:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700003901")))
dw:ApplyIdentityProjection({ force = true })
assertEq(slotState(dw, ALT_A, "Weapon"), "ASSIGNED_AUTO", "first 1H is Weapon")
assertEq(slotState(dw, ALT_A, "OffHand"), "ASSIGNED_AUTO", "dual-wield second 1H is OffHand")

resetEnv()
local later2h = makeProfile("Later2H")
addMember(later2h, ALT_A)
assertTrue(later2h:SetMemberSpec(ALT_A, 71), "Arms spec")
assertTrue(later2h:AddRCLootCouncilBisResponse("Need"))
assertTrue(later2h:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700004000")))
assertTrue(later2h:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19004, "Need", "1700004001")))
later2h:ApplyIdentityProjection({ force = true })
assertEq(slotState(later2h, ALT_A, "Weapon"), "ASSIGNED_AUTO", "existing 1H remains")
local sawLaterOverflow = false
for _, log in ipairs(later2h:GetLootLogs()) do
    if log:GetEventType() == "BIS_OUTCOME" and log:GetEventData().outcome == "OVERFLOW" then
        sawLaterOverflow = true
    end
end
assertTrue(sawLaterOverflow, "incompatible later 2H is frozen OVERFLOW")

-- Gear Override 2H on Arms occupies both slots as one assignment
resetEnv()
local ov2h = makeProfile("Override2H")
addMember(ov2h, ALT_A)
assertTrue(ov2h:SetMemberSpec(ALT_A, 71))
assertTrue(ov2h:AddManualAward(ALT_A, itemLink(19004, "TwoHand")))
local twoHId
for _, award in ipairs(ov2h:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        twoHId = award.id
    end
end
assertTrue(ov2h:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = twoHId },
    assignedSlots = { "Weapon" },
    slotBinding = "BOUND",
}), "assign 2H via Weapon")
ov2h:ApplyIdentityProjection({ force = true })
assertEq(slotState(ov2h, ALT_A, "Weapon"), "ASSIGNED_OVERRIDE", "override 2H occupies Weapon")
assertEq(slotState(ov2h, ALT_A, "OffHand"), "ASSIGNED_OVERRIDE", "override 2H occupies OffHand")
assertEq(ov2h:GetIdentityBisSlots(ALT_A).Weapon.assignmentId, ov2h:GetIdentityBisSlots(ALT_A).OffHand.assignmentId, "override 2H is one assignment")

-- Identity-scoped origin association expires after unlink
resetEnv()
local idOrigin = makeProfile("IdOrigin")
addMember(idOrigin, ALT_A)
addMember(idOrigin, ALT_B)
assertTrue(idOrigin:LinkCharacters(ALT_A, ALT_B))
assertTrue(idOrigin:getMemberByID(ALT_A):ToggleEquipment("Head", { profile = idOrigin, scope = "identity" }))
idOrigin:ApplyIdentityProjection({ force = true })
assertTrue(idOrigin:AddManualAward(ALT_A, itemLink(19001, "Helm")))
local idMan
for _, award in ipairs(idOrigin:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        idMan = award.id
    end
end
local idOrigins = idOrigin:GetIdentityLegacyOrigins(ALT_A)
local identityOriginId
for i = 1, #idOrigins do
    if idOrigins[i].kind == "identity" then
        identityOriginId = idOrigins[i].originLogId
    end
end
assertTrue(identityOriginId ~= nil, "identity-scoped origin is exposed")
assertTrue(idOrigin:ApplyBisOverride("ASSOCIATE_LEGACY", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = idMan },
    legacyOriginLogId = identityOriginId,
}), "associate identity-scoped origin")
idOrigin:ApplyIdentityProjection({ force = true })
assertEq(slotState(idOrigin, ALT_A, "Head"), "ASSIGNED_OVERRIDE", "identity origin association occupies Head")
assertTrue(idOrigin:UnlinkCharacter(ALT_B), "unlink expires identity origin")
idOrigin:ApplyIdentityProjection({ force = true })
assertEq(slotState(idOrigin, ALT_A, "Head"), "AVAILABLE", "expired identity origin deactivates association")
assertTrue(idOrigin:LinkCharacters(ALT_A, ALT_B), "relink")
idOrigin:ApplyIdentityProjection({ force = true })
assertEq(slotState(idOrigin, ALT_A, "Head"), "AVAILABLE", "relink does not resurrect expired association")
assertTrue(idOrigin:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = idMan },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}), "expired identity association does not block reuse")
idOrigin:ApplyIdentityProjection({ force = true })
assertEq(slotState(idOrigin, ALT_A, "Head"), "ASSIGNED_OVERRIDE", "same award can be assigned after identity origin expiry")

-- Packed local ring origins associate to historical usage, not display packing
resetEnv()
local packed = makeProfile("PackedOrigin")
addMember(packed, ALT_A)
addLog(packed, "ARMOR_CHANGE", { member = ALT_A, slot = "Ring1", action = "USED" })
addLog(packed, "ARMOR_CHANGE", { member = ALT_A, slot = "Ring2", action = "USED" })
packed:ApplyIdentityProjection({ force = true })
assertTrue(packed:AddManualAward(ALT_A, itemLink(19002, "Ring")))
local packedMan
for _, award in ipairs(packed:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        packedMan = award.id
    end
end
local packedOrigins = packed:GetIdentityLegacyOrigins(ALT_A)
local ring2Origin
for i = 1, #packedOrigins do
    if packedOrigins[i].slot == "Ring2" then
        ring2Origin = packedOrigins[i].originLogId
    end
end
assertTrue(ring2Origin ~= nil, "Ring2 origin is exposed")
assertTrue(packed:ApplyBisOverride("ASSOCIATE_LEGACY", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = packedMan },
    legacyOriginLogId = ring2Origin,
}), "associate historical Ring2 origin")
packed:ApplyIdentityProjection({ force = true })
assertEq(slotState(packed, ALT_A, "Ring2"), "ASSIGNED_OVERRIDE", "association follows origin slot")
assertEq(slotState(packed, ALT_A, "Ring1"), "LEGACY_UNKNOWN", "unassociated Ring1 origin remains unknown")

-- MergeLogTables / AUTH_LOGS-like import rebuilds BiS without live warnings
resetEnv()
local src = makeProfile("SrcLogs")
addMember(src, ALT_A)
assertTrue(src:AddRCLootCouncilBisResponse("Need"))
assertTrue(src:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19001, "Need", "1700004100")))
src:ApplyIdentityProjection({ force = true })
local exported = {}
for _, log in ipairs(src:GetLootLogs()) do
    exported[#exported + 1] = log:ToTable()
end
resetEnv()
local dest = makeProfile("DestLogs")
addMember(dest, ALT_A)
assertTrue(dest:MergeLogTables(exported) >= 0, "MergeLogTables inserts history")
dest:ApplyIdentityProjection({ force = true })
assertEq(slotState(dest, ALT_A, "Head"), "ASSIGNED_AUTO", "imported RC+outcome assigns Head")
assertEq(warnCount(), 0, "MergeLogTables does not warn")

-- BiS-qualified responses cannot be filtered from recorded history
resetEnv()
local cfg = makeProfile("Cfg")
assertTrue(cfg:AddRCLootCouncilAllowedResponse("Need"), "record Need")
assertTrue(cfg:AddRCLootCouncilBisResponse("Need"), "Need is BiS")
assertFalse(cfg:RemoveRCLootCouncilAllowedResponse("Need"), "cannot un-record a BiS response")

-- SpecName reads the display name, not the specialization ID
function GetSpecializationInfoByID(specId)
    return specId, "Arms From API", "description", 123, "DAMAGER"
end
assertEq(SF.LootHelperBis.SpecWeapons.SpecName(71), "Arms From API", "SpecName uses the name return value")
GetSpecializationInfoByID = nil
assertEq(SF.LootHelperBis.SpecWeapons.SpecName(1480), "Devourer", "Devourer fallback name")

-- Class/spec validation
resetEnv()
local specP = makeProfile("SpecVal")
addMember(specP, ALT_A)
assertTrue(specP:SetMemberSpec(ALT_A, 71), "Warrior Arms is valid")
assertFalse(specP:SetMemberSpec(ALT_A, 62), "Warrior cannot take Mage spec")
assertFalse(specP:SetMemberSpec(ALT_A, 9999), "unknown spec is rejected")
addMember(specP, ALT_B, "member", "DEMONHUNTER")
assertTrue(specP:SetMemberSpec(ALT_B, 1480), "Devourer is valid for Demon Hunter")
assertFalse(specP:SetMemberSpec(ALT_A, 1480), "Warrior cannot take Devourer")

-- Incompatible item/slot assignments are rejected
resetEnv()
local badSlot = makeProfile("BadSlot")
addMember(badSlot, ALT_A)
assertTrue(badSlot:AddManualAward(ALT_A, itemLink(19002, "Ring")))
local badRingId
for _, award in ipairs(badSlot:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        badRingId = award.id
    end
end
assertFalse(badSlot:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = badRingId },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}), "Ring cannot be assigned to Head")
assertFalse(badSlot:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = badRingId },
    assignedSlots = { "Head", "Ring1" },
    slotBinding = "BOUND",
}), "mixed-family assignedSlots are rejected")
assertFalse(SF.LootHelperBis.IsLegalSlotShape({ "Head", "Ring1" }), "Head+Ring1 is not a legal shape")
assertTrue(SF.LootHelperBis.IsLegalSlotShape({ "Weapon", "OffHand" }), "Weapon+OffHand is legal")

-- Missing spec rejects weapon override instead of guessing 2H expansion
resetEnv()
local miss = makeProfile("MissSpec")
addMember(miss, ALT_A)
assertTrue(miss:AddManualAward(ALT_A, itemLink(19004, "TwoHand")))
local twoId
for _, award in ipairs(miss:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        twoId = award.id
    end
end
assertFalse(miss:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = twoId },
    assignedSlots = { "Weapon" },
    slotBinding = "BOUND",
}), "2H override without stored spec fails closed")

-- AB identity USED then ABC AVAILABLE no longer contributes
resetEnv()
local superset = makeProfile("SupersetAvail")
addMember(superset, ALT_A)
addMember(superset, ALT_B)
addMember(superset, ALT_C)
assertTrue(superset:LinkCharacters(ALT_A, ALT_B))
assertTrue(superset:getMemberByID(ALT_A):ToggleEquipment("Head", { profile = superset, scope = "identity" }))
superset:ApplyIdentityProjection({ force = true })
local abOrigins = superset:GetIdentityLegacyOrigins(ALT_A)
assertTrue(#abOrigins >= 1, "AB Head USED origin is active")
local originO = abOrigins[1].originLogId
assertTrue(superset:LinkCharacters(ALT_A, ALT_C))
assertTrue(superset:getMemberByID(ALT_A):ToggleEquipment("Head", { profile = superset, scope = "identity" }))
superset:ApplyIdentityProjection({ force = true })
local abcOrigins = superset:GetIdentityLegacyOrigins(ALT_A)
local originStillActive = false
for i = 1, #abcOrigins do
    if abcOrigins[i].originLogId == originO then
        originStillActive = true
    end
end
assertFalse(originStillActive, "ABC AVAILABLE supersedes AB USED origin")
assertTrue(superset:AddManualAward(ALT_A, itemLink(19001, "Helm")))
local supMan
for _, award in ipairs(superset:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        supMan = award.id
    end
end
assertFalse(superset:ApplyBisOverride("ASSOCIATE_LEGACY", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = supMan },
    legacyOriginLogId = originO,
}), "superseded origin cannot be associated")

-- Local USED replaced by later USED, then AVAILABLE
resetEnv()
local localOrig = makeProfile("LocalOrig")
addMember(localOrig, ALT_A)
addLog(localOrig, "ARMOR_CHANGE", { member = ALT_A, slot = "Head", action = "USED" })
localOrig:ApplyIdentityProjection({ force = true })
local firstLocal = localOrig:GetIdentityLegacyOrigins(ALT_A)[1]
assertTrue(firstLocal ~= nil, "first local USED is active")
addLog(localOrig, "ARMOR_CHANGE", { member = ALT_A, slot = "Head", action = "USED" })
localOrig:ApplyIdentityProjection({ force = true })
local afterReplace = localOrig:GetIdentityLegacyOrigins(ALT_A)
local firstStill = false
for i = 1, #afterReplace do
    if afterReplace[i].originLogId == firstLocal.originLogId then
        firstStill = true
    end
end
assertFalse(firstStill, "later local USED replaces previous origin")
addLog(localOrig, "ARMOR_CHANGE", { member = ALT_A, slot = "Head", action = "AVAILABLE" })
localOrig:ApplyIdentityProjection({ force = true })
assertEq(#localOrig:GetIdentityLegacyOrigins(ALT_A), 0, "local AVAILABLE clears contributing origin")

-- Manual item ID normalization
resetEnv()
local manNorm = makeProfile("ManNorm")
addMember(manNorm, ALT_A)
assertTrue(manNorm:AddManualAward(ALT_A, "19001"), "bare item ID is accepted")
assertFalse(manNorm:AddManualAward(ALT_A, "not-an-item"), "invalid text is rejected")
local manItem
for _, award in ipairs(manNorm:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        manItem = award
    end
end
assertTrue(manItem ~= nil and tostring(manItem.itemString):find("item:19001", 1, true) ~= nil, "numeric ID becomes item:19001")
assertEq(slotState(manNorm, ALT_A, "Head"), "AVAILABLE", "manual add does not consume a slot")
assertTrue(manNorm:AddManualAward(ALT_A, "item:19010"), "item token is accepted")
assertTrue(manNorm:AddManualAward(ALT_A, itemLink(19008, "Chest")), "hyperlink is accepted")

-- Contextual RCLC BiS identity
resetEnv()
local ctxP = makeProfile("CtxBis")
assertTrue(ctxP:AddRCLootCouncilBisResponse({
    text = "Need",
    typeCode = "default",
    responseId = 1,
    isAwardReason = false,
}), "contextual BiS response")
assertTrue(ctxP:IsBisQualifyingResponse("Need", { typeCode = "default", responseId = 1, isAwardReason = false }), "same context matches")
assertFalse(ctxP:IsBisQualifyingResponse("Need", { typeCode = "WEAPON", responseId = 1, isAwardReason = false }), "same responseId different typeCode does not match")
assertFalse(ctxP:IsBisQualifyingResponse("Need", { typeCode = "default", responseId = 1, isAwardReason = true }), "award reason does not match normal response")
assertFalse(ctxP:IsBisQualifyingResponse("Need", { typeCode = "default" }), "contextual entry does not fall back to label matching")
assertTrue(ctxP:AddRCLootCouncilBisResponse({
    text = "Need",
    typeCode = "WEAPON",
    responseId = 1,
    isAwardReason = false,
}), "same responseId in a second typeCode")
assertTrue(ctxP:IsBisQualifyingResponse("Need", { typeCode = "WEAPON", responseId = 1, isAwardReason = false }), "second typeCode matches its own contextual entry")
assertTrue(ctxP:AddRCLootCouncilBisResponse({
    text = "Bank",
    isAwardReason = true,
    responseId = 3,
}), "award reason uses persisted history responseId")
assertTrue(ctxP:IsBisQualifyingResponse("Bank", { typeCode = "default", responseId = 3, isAwardReason = true }), "award reason matches despite item typeCode default")
assertTrue(ctxP:IsBisQualifyingResponse("Bank", { typeCode = "WEAPON", responseId = 3, isAwardReason = true }), "award reason ignores item typeCode")
assertFalse(ctxP:IsBisQualifyingResponse("Need", { typeCode = "default", responseId = 3, isAwardReason = false }), "non-award responseId does not match award reason")
assertFalse(ctxP:IsBisQualifyingResponse("Bank", { typeCode = "awardReason", responseId = 1, isAwardReason = true }), "array index is not assumed to be the persisted award-reason id")
resetEnv()
local textP = makeProfile("TextBis")
assertTrue(textP:AddRCLootCouncilBisResponse("Need"), "text-only fallback")
assertTrue(textP:IsBisQualifyingResponse("Need", { typeCode = "default" }), "legacy text entry still qualifies label-only awards")
assertTrue(textP:IsBisQualifyingResponse("Need", { typeCode = "WEAPON", responseId = 2 }), "historical text-only still matches by label")
assertTrue(textP:SetRCLootCouncilRecordAwards(false))
assertFalse(textP:ShouldRecordRCResponse("Need"), "recordAwards off disables live recording")
assertFalse(textP:IsItemAwareEquipmentPopup(), "recording off does not make the popup item-aware from saved BiS config")
assertTrue(textP:SetRCLootCouncilRecordAwards(true))
assertTrue(textP:ShouldRecordRCResponse("Need"), "re-enabling recording uses saved BiS config")

-- Current Retail weapon flags: Vengeance, Brewmaster, Devourer dual-wield 1H
resetEnv()
local ven = makeProfile("Vengeance")
addMember(ven, ALT_A, "member", "DEMONHUNTER")
assertTrue(ven:SetMemberSpec(ALT_A, 581))
assertTrue(ven:AddRCLootCouncilBisResponse("Need"))
assertTrue(ven:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700005000")))
assertTrue(ven:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700005001")))
ven:ApplyIdentityProjection({ force = true })
assertEq(slotState(ven, ALT_A, "Weapon"), "ASSIGNED_AUTO", "Vengeance first 1H is Weapon")
assertEq(slotState(ven, ALT_A, "OffHand"), "ASSIGNED_AUTO", "Vengeance dual-wields 1H into OffHand")

resetEnv()
local brew = makeProfile("Brew")
addMember(brew, ALT_A, "member", "MONK")
assertTrue(brew:SetMemberSpec(ALT_A, 268))
assertTrue(brew:AddRCLootCouncilBisResponse("Need"))
assertTrue(brew:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700005100")))
assertTrue(brew:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700005101")))
brew:ApplyIdentityProjection({ force = true })
assertEq(slotState(brew, ALT_A, "OffHand"), "ASSIGNED_AUTO", "Brewmaster dual-wields 1H")

resetEnv()
local devour = makeProfile("Devourer")
addMember(devour, ALT_A, "member", "DEMONHUNTER")
assertTrue(devour:SetMemberSpec(ALT_A, 1480), "Devourer spec stores")
assertTrue(devour:AddRCLootCouncilBisResponse("Need"))
assertTrue(devour:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700005200")))
assertTrue(devour:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700005201")))
devour:ApplyIdentityProjection({ force = true })
assertEq(slotState(devour, ALT_A, "OffHand"), "ASSIGNED_AUTO", "Devourer dual-wields 1H")

-- Shield-capable spec vs invalid offhand weapon
resetEnv()
local shieldP = makeProfile("Shield")
addMember(shieldP, ALT_A)
assertTrue(shieldP:SetMemberSpec(ALT_A, 73), "Protection Warrior")
assertTrue(shieldP:AddRCLootCouncilBisResponse("Need"))
assertTrue(shieldP:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19011, "Need", "1700005300")))
shieldP:ApplyIdentityProjection({ force = true })
assertEq(slotState(shieldP, ALT_A, "OffHand"), "ASSIGNED_AUTO", "Prot Warrior shield occupies OffHand")
assertTrue(shieldP:AddManualAward(ALT_A, itemLink(19006, "OHWeapon")))
local ohId
for _, award in ipairs(shieldP:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        ohId = award.id
    end
end
assertFalse(shieldP:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = ohId },
    assignedSlots = { "OffHand" },
    slotBinding = "BOUND",
}), "Prot Warrior cannot assign an offhand weapon")
assertTrue(shieldP:AddManualAward(ALT_A, itemLink(19004, "TwoHand")))
local protTwoId
for _, award in ipairs(shieldP:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" and tostring(award.itemString or ""):find("item:19004", 1, true) then
        protTwoId = award.id
    end
end
assertFalse(shieldP:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = protTwoId },
    assignedSlots = { "Weapon" },
    slotBinding = "BOUND",
}), "Prot Warrior 2H override is rejected")

-- Gear Override page uses an equipment-slot board
local lootHelperSource = io.open("SpectrumFederation/modules/UI/Settings/Pages/LootHelper.lua"):read("*a")
assertTrue(lootHelperSource:find('type = "equipmentBoard"', 1, true) ~= nil, "Character page uses equipmentBoard")
assertTrue(io.open("SpectrumFederation/modules/UI/Settings/Control/Controls.lua"):read("*a"):find("AddEquipmentBoard", 1, true) ~= nil, "settings Controls expose AddEquipmentBoard")

-- BIS_OVERRIDE ASSIGN requires sourceLogId == awardRef.id
resetEnv()
local valP = makeProfile("ValOverride")
addMember(valP, ALT_A)
assertTrue(valP:AddManualAward(ALT_A, itemLink(19001, "Helm")))
local valId
for _, award in ipairs(valP:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        valId = award.id
    end
end
local badOverride = SF.LootLog.new("BIS_OVERRIDE", {
    action = "ASSIGN",
    awardRef = { kind = "MANUAL", id = valId },
    sourceLogId = "not-the-award",
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
    preOpAuthorMax = {},
}, { profile = valP, skipPermission = true, author = PLAYER, counter = valP:AllocateNextCounter(PLAYER) })
assertTrue(badOverride == nil, "malformed BIS_OVERRIDE sourceLogId is rejected")

local badClear = SF.LootLog.new("BIS_OVERRIDE", {
    action = "CLEAR",
    targetAssignmentId = valId,
    assignedSlots = { "Head" },
    preOpAuthorMax = {},
}, { profile = valP, skipPermission = true, author = PLAYER, counter = valP:AllocateNextCounter(PLAYER) })
assertTrue(badClear == nil, "CLEAR with assignedSlots is rejected")

-- SPEC_CHANGE writer and AUTH_LOGS/import reject class mismatch and unknown specs
resetEnv()
local specImport = makeProfile("SpecImport")
addMember(specImport, ALT_A)
local badSpecLog = SF.LootLog.new("SPEC_CHANGE", {
    member = ALT_A,
    specId = 62,
    preOpAuthorMax = {},
}, { profile = specImport, skipPermission = true, author = PLAYER, counter = specImport:AllocateNextCounter(PLAYER) })
assertTrue(badSpecLog == nil, "Warrior cannot write a Mage SPEC_CHANGE")
local unknownSpecLog = SF.LootLog.new("SPEC_CHANGE", {
    member = ALT_A,
    specId = 9999,
    preOpAuthorMax = {},
}, { profile = specImport, skipPermission = true, author = PLAYER, counter = specImport:AllocateNextCounter(PLAYER) })
assertTrue(unknownSpecLog == nil, "unknown specId cannot be written")

local forged = {
    version = 2,
    _id = PLAYER .. ":80",
    _timestamp = 1700008000,
    _author = PLAYER,
    _counter = 80,
    _eventType = "SPEC_CHANGE",
    _data = { member = ALT_A, specId = 62, preOpAuthorMax = {} },
}
forged._fingerprint = SF.LootLog.ComputeFingerprintFromTable(forged)
assertEq(specImport:MergeLogTables({ forged }), 0, "AUTH_LOGS-like import rejects Warrior+Mage SPEC_CHANGE")
local forgedUnknown = {
    version = 2,
    _id = PLAYER .. ":81",
    _timestamp = 1700008001,
    _author = PLAYER,
    _counter = 81,
    _eventType = "SPEC_CHANGE",
    _data = { member = ALT_A, specId = 9999, preOpAuthorMax = {} },
}
forgedUnknown._fingerprint = SF.LootLog.ComputeFingerprintFromTable(forgedUnknown)
assertEq(specImport:MergeLogTables({ forgedUnknown }), 0, "AUTH_LOGS-like import rejects unknown specId")

-- BIS_OUTCOME stores RCLC typeCode separately from itemFamily
resetEnv()
local typed = makeProfile("TypeCode")
addMember(typed, ALT_A)
assertTrue(typed:AddRCLootCouncilBisResponse("Need"))
local typedCanon = SF.LootLog.BuildRCLootCouncilCanonical(PLAYER, ALT_A, {
    lootWon = itemLink(19001, "Helm"),
    response = "Need",
    id = "1700009000-7",
    owner = ALT_A,
    typeCode = "default",
    responseID = 1,
})
assertTrue(typed:TryAddRCLootCouncilAward(typedCanon), "typed RC award records")
local outcomeData
for _, log in ipairs(typed:GetLootLogs()) do
    if log:GetEventType() == "BIS_OUTCOME" then
        outcomeData = log:GetEventData()
    end
end
assertTrue(outcomeData ~= nil, "BIS_OUTCOME exists")
assertEq(outcomeData.typeCode, "default", "typeCode is RCLC context, not item family")
assertEq(outcomeData.itemFamily, "ordinary", "itemFamily is the classified family")

-- Malformed AUTO BIS_OUTCOME does not pin the winner or occupy an incompatible slot
resetEnv()
local badAuto = makeProfile("BadAuto")
addMember(badAuto, ALT_A)
assertTrue(badAuto:SetMemberSpec(ALT_A, 73), "Protection Warrior")
local shieldCanon = makeCanonical(ALT_A, 19011, "Need", "1700010000")
insertRC(badAuto, shieldCanon)
addLog(badAuto, "BIS_OUTCOME", withFrozen({
    sourceLogId = shieldCanon.awardKey,
    awardKey = shieldCanon.awardKey,
    awardMember = ALT_A,
    qualified = true,
    outcome = "ASSIGNED",
    assignedSlots = { "Weapon" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
    specIdUsed = 73,
}, 19011), { author = ZULU })
addLog(badAuto, "BIS_OUTCOME", withFrozen({
    sourceLogId = shieldCanon.awardKey,
    awardKey = shieldCanon.awardKey,
    awardMember = ALT_A,
    qualified = true,
    outcome = "ASSIGNED",
    assignedSlots = { "OffHand" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
    specIdUsed = 73,
}, 19011), { author = OWNER })
badAuto:ApplyIdentityProjection({ force = true })
assertEq(slotState(badAuto, ALT_A, "Weapon"), "AVAILABLE", "shield AUTO cannot occupy Weapon")
assertEq(slotState(badAuto, ALT_A, "OffHand"), "ASSIGNED_AUTO", "later compatible AUTO outcome still wins")

-- AUTO ASSIGNED cannot freeze onto a slot #278 already occupies
resetEnv()
local occupiedAuto = makeProfile("OccupiedAuto")
addMember(occupiedAuto, ALT_A)
addLog(occupiedAuto, "ARMOR_CHANGE", { member = ALT_A, slot = "Head", action = "USED" })
local occupiedCanon = makeCanonical(ALT_A, 19001, "Need", "1700011000")
insertRC(occupiedAuto, occupiedCanon)
addLog(occupiedAuto, "BIS_OUTCOME", withFrozen({
    sourceLogId = occupiedCanon.awardKey,
    awardKey = occupiedCanon.awardKey,
    awardMember = ALT_A,
    qualified = true,
    outcome = "ASSIGNED",
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
}, 19001))
occupiedAuto:ApplyIdentityProjection({ force = true })
assertEq(slotState(occupiedAuto, ALT_A, "Head"), "LEGACY_UNKNOWN", "malformed AUTO does not overlay #278 occupancy")

local function extraCorrectnessTests()
-- Frozen AUTO replay ignores live classifier/proficiency changes
resetEnv()
local frozenAuto = makeProfile("FrozenAuto")
addMember(frozenAuto, ALT_A)
assertTrue(frozenAuto:AddRCLootCouncilBisResponse("Need"))
assertTrue(frozenAuto:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19001, "Need", "1700012000")))
frozenAuto:ApplyIdentityProjection({ force = true })
assertEq(slotState(frozenAuto, ALT_A, "Head"), "ASSIGNED_AUTO", "AUTO helm assigned before stub")
local origClassify = SF.LootHelperBis.ClassifyItem
local origAllowed = SF.LootHelperBis.SpecWeapons.IsItemAllowedForSpec
SF.LootHelperBis.ClassifyItem = function()
    return nil
end
SF.LootHelperBis.SpecWeapons.IsItemAllowedForSpec = function()
    return false
end
frozenAuto:ApplyIdentityProjection({ force = true })
assertEq(slotState(frozenAuto, ALT_A, "Head"), "ASSIGNED_AUTO", "frozen AUTO still reconstructs after live classifier stub")
SF.LootHelperBis.ClassifyItem = origClassify
SF.LootHelperBis.SpecWeapons.IsItemAllowedForSpec = origAllowed

-- ASSIGNED AUTO without frozen facts fails closed
resetEnv()
local missingFrozen = makeProfile("MissingFrozen")
addMember(missingFrozen, ALT_A)
local missingCanon = makeCanonical(ALT_A, 19001, "Need", "1700012100")
insertRC(missingFrozen, missingCanon)
addLog(missingFrozen, "BIS_OUTCOME", {
    sourceLogId = missingCanon.awardKey,
    awardKey = missingCanon.awardKey,
    awardMember = ALT_A,
    qualified = true,
    outcome = "ASSIGNED",
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
})
missingFrozen:ApplyIdentityProjection({ force = true })
assertEq(slotState(missingFrozen, ALT_A, "Head"), "AVAILABLE", "ASSIGNED AUTO without frozen facts does not reconstruct")

-- Weapon subclass: two 2H specs, different subtypes
resetEnv()
local priestStaff = makeProfile("PriestStaff")
addMember(priestStaff, ALT_A, "member", "PRIEST")
assertTrue(priestStaff:SetMemberSpec(ALT_A, 257))
assertTrue(priestStaff:AddRCLootCouncilBisResponse("Need"))
assertTrue(priestStaff:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19012, "Need", "1700013000")))
priestStaff:ApplyIdentityProjection({ force = true })
assertEq(slotState(priestStaff, ALT_A, "Weapon"), "ASSIGNED_AUTO", "Holy Priest accepts a staff")
assertEq(slotState(priestStaff, ALT_A, "OffHand"), "ASSIGNED_AUTO", "Priest 2H staff occupies both slots")
assertTrue(priestStaff:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19004, "Need", "1700013001")))
local priestSwordUnresolved = false
for _, log in ipairs(priestStaff:GetLootLogs()) do
    local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
    if data and data.unresolvedReason == "UNKNOWN_COMPAT" then
        priestSwordUnresolved = true
    end
end
assertTrue(priestSwordUnresolved, "Holy Priest rejects a 2H sword")

resetEnv()
local retP = makeProfile("RetStaff")
addMember(retP, ALT_A, "member", "PALADIN")
assertTrue(retP:SetMemberSpec(ALT_A, 70))
assertTrue(retP:AddRCLootCouncilBisResponse("Need"))
assertTrue(retP:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19004, "Need", "1700013100")))
retP:ApplyIdentityProjection({ force = true })
assertEq(slotState(retP, ALT_A, "Weapon"), "ASSIGNED_AUTO", "Ret Paladin accepts a 2H sword")
assertTrue(retP:AddManualAward(ALT_A, itemLink(19012, "Staff")))
local staffId
for _, award in ipairs(retP:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        staffId = award.id
    end
end
assertFalse(retP:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = staffId },
    assignedSlots = { "Weapon" },
    slotBinding = "BOUND",
}), "Ret Paladin cannot assign a staff")

resetEnv()
local surv = makeProfile("SurvMace")
addMember(surv, ALT_A, "member", "HUNTER")
assertTrue(surv:SetMemberSpec(ALT_A, 255))
assertTrue(surv:AddRCLootCouncilBisResponse("Need"))
assertTrue(surv:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19013, "Need", "1700013200")))
surv:ApplyIdentityProjection({ force = true })
assertEq(slotState(surv, ALT_A, "Weapon"), "ASSIGNED_AUTO", "Survival Hunter accepts a polearm")
assertTrue(surv:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19014, "Need", "1700013201")))
local survMaceUnresolved = false
for _, log in ipairs(surv:GetLootLogs()) do
    local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
    if data and data.unresolvedReason == "UNKNOWN_COMPAT" then
        survMaceUnresolved = true
    end
end
assertTrue(survMaceUnresolved, "Survival Hunter rejects a 2H mace")

-- Ranged vs melee / dual-wield
resetEnv()
local bm = makeProfile("BMBow")
addMember(bm, ALT_A, "member", "HUNTER")
assertTrue(bm:SetMemberSpec(ALT_A, 253))
assertTrue(bm:AddRCLootCouncilBisResponse("Need"))
assertTrue(bm:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19016, "Need", "1700013300")))
bm:ApplyIdentityProjection({ force = true })
assertEq(slotState(bm, ALT_A, "Weapon"), "ASSIGNED_AUTO", "Beast Mastery bow occupies Weapon")
assertEq(slotState(bm, ALT_A, "OffHand"), "AVAILABLE", "ranged loc is never an OffHand candidate")

resetEnv()
local rogueBow = makeProfile("RogueBow")
addMember(rogueBow, ALT_A, "member", "ROGUE")
assertTrue(rogueBow:SetMemberSpec(ALT_A, 259))
assertTrue(rogueBow:AddRCLootCouncilBisResponse("Need"))
assertTrue(rogueBow:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19016, "Need", "1700013400")))
local rogueBowUnresolved = false
for _, log in ipairs(rogueBow:GetLootLogs()) do
    local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
    if data and data.unresolvedReason == "UNKNOWN_COMPAT" then
        rogueBowUnresolved = true
    end
end
assertTrue(rogueBowUnresolved, "Rogue rejects a bow")
assertTrue(rogueBow:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19015, "Need", "1700013401")))
assertTrue(rogueBow:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19015, "Need", "1700013402")))
rogueBow:ApplyIdentityProjection({ force = true })
assertEq(slotState(rogueBow, ALT_A, "Weapon"), "ASSIGNED_AUTO", "Rogue first dagger is Weapon")
assertEq(slotState(rogueBow, ALT_A, "OffHand"), "ASSIGNED_AUTO", "Rogue dual-wields a second dagger")

resetEnv()
local mageWand = makeProfile("MageWand")
addMember(mageWand, ALT_A, "member", "MAGE")
assertTrue(mageWand:SetMemberSpec(ALT_A, 62))
assertTrue(mageWand:AddRCLootCouncilBisResponse("Need"))
assertTrue(mageWand:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19017, "Need", "1700013500")))
mageWand:ApplyIdentityProjection({ force = true })
assertEq(slotState(mageWand, ALT_A, "Weapon"), "ASSIGNED_AUTO", "Mage wand occupies Weapon")
assertTrue(mageWand:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19004, "Need", "1700013501")))
local mageTwoHUnresolved = false
for _, log in ipairs(mageWand:GetLootLogs()) do
    local data = log:GetEventType() == "BIS_OUTCOME" and log:GetEventData()
    if data and data.unresolvedReason == "UNKNOWN_COMPAT" then
        mageTwoHUnresolved = true
    end
end
assertTrue(mageTwoHUnresolved, "Mage rejects a 2H sword")

-- Writer occupancy parity: 2H OffHand click cannot succeed while Weapon is occupied
resetEnv()
local twoHBlock = makeProfile("TwoHBlock")
addMember(twoHBlock, ALT_A)
assertTrue(twoHBlock:SetMemberSpec(ALT_A, 71), "Arms")
assertTrue(twoHBlock:AddRCLootCouncilBisResponse("Need"))
assertTrue(twoHBlock:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700013600")))
twoHBlock:ApplyIdentityProjection({ force = true })
assertEq(slotState(twoHBlock, ALT_A, "Weapon"), "ASSIGNED_AUTO", "1H occupies Weapon")
assertTrue(twoHBlock:AddManualAward(ALT_A, itemLink(19004, "TwoHand")))
local twoHId
for _, award in ipairs(twoHBlock:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" and tostring(award.itemString or ""):find("item:19004", 1, true) then
        twoHId = award.id
    end
end
local beforeLogs = #(twoHBlock:GetLootLogs() or {})
assertFalse(twoHBlock:ApplyBisOverride("ASSIGN", {
    viewMember = ALT_A,
    awardRef = { kind = "MANUAL", id = twoHId },
    assignedSlots = { "OffHand" },
    slotBinding = "BOUND",
}), "normal 2H cannot expand onto occupied Weapon")
assertEq(#(twoHBlock:GetLootLogs() or {}), beforeLogs, "ineffective 2H override is not appended")

-- REPLACE 2H also accounts for the other occupied slot
resetEnv()
local holyReplace = makeProfile("HolyReplace")
addMember(holyReplace, ALT_A, "member", "PALADIN")
assertTrue(holyReplace:SetMemberSpec(ALT_A, 65))
assertTrue(holyReplace:AddRCLootCouncilBisResponse("Need"))
assertTrue(holyReplace:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19005, "Need", "1700014000")))
assertTrue(holyReplace:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19011, "Need", "1700014001")))
holyReplace:ApplyIdentityProjection({ force = true })
assertEq(slotState(holyReplace, ALT_A, "Weapon"), "ASSIGNED_AUTO", "Holy 1H Weapon")
assertEq(slotState(holyReplace, ALT_A, "OffHand"), "ASSIGNED_AUTO", "Holy shield OffHand")
local holyWeaponAsg = holyReplace:GetIdentityBisSlots(ALT_A).Weapon.assignmentId
assertTrue(holyReplace:AddManualAward(ALT_A, itemLink(19004, "TwoHand")))
local holyTwoH
for _, award in ipairs(holyReplace:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" and tostring(award.itemString or ""):find("item:19004", 1, true) then
        holyTwoH = award.id
    end
end
local holyBefore = #(holyReplace:GetLootLogs() or {})
assertFalse(holyReplace:ApplyBisOverride("REPLACE", {
    viewMember = ALT_A,
    targetAssignmentId = holyWeaponAsg,
    awardRef = { kind = "MANUAL", id = holyTwoH },
    assignedSlots = { "Weapon" },
    slotBinding = "BOUND",
}), "replacing Weapon with 2H is rejected while OffHand stays occupied")
assertEq(#(holyReplace:GetLootLogs() or {}), holyBefore, "ineffective REPLACE is not appended")

-- Forged ASSIGN cannot hide #278 occupancy
resetEnv()
local forgedAssign = makeProfile("ForgedAssign")
addMember(forgedAssign, ALT_A)
addLog(forgedAssign, "ARMOR_CHANGE", { member = ALT_A, slot = "Head", action = "USED" })
assertTrue(forgedAssign:AddManualAward(ALT_A, itemLink(19001, "Helm")))
local forgedId
for _, award in ipairs(forgedAssign:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        forgedId = award.id
    end
end
addLog(forgedAssign, "BIS_OVERRIDE", {
    action = "ASSIGN",
    awardRef = { kind = "MANUAL", id = forgedId },
    sourceLogId = forgedId,
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
})
forgedAssign:ApplyIdentityProjection({ force = true })
assertEq(slotState(forgedAssign, ALT_A, "Head"), "LEGACY_UNKNOWN", "plain ASSIGN does not cover #278 occupancy")

-- Overflow origins are not associable Gear Override opportunities
resetEnv()
local overflowOrg = makeProfile("OverflowOrg")
addMember(overflowOrg, ALT_A)
addLog(overflowOrg, "ARMOR_CHANGE", { member = ALT_A, slot = "Ring1", action = "USED" })
addLog(overflowOrg, "ARMOR_CHANGE", { member = ALT_A, slot = "Ring2", action = "USED" })
addLog(overflowOrg, "ARMOR_CHANGE", { member = ALT_A, slot = "Ring1", action = "USED" })
overflowOrg:ApplyIdentityProjection({ force = true })
assertEq(slotState(overflowOrg, ALT_A, "Ring1"), "LEGACY_UNKNOWN")
assertEq(slotState(overflowOrg, ALT_A, "Ring2"), "LEGACY_UNKNOWN")
local visOrigins = overflowOrg:GetIdentityLegacyOrigins(ALT_A)
assertEq(#visOrigins, 2, "only two visible ring origins are associable")
local displayed = {}
for i = 1, #visOrigins do
    displayed[visOrigins[i].displayedSlot or visOrigins[i].slot] = true
    assertFalse(visOrigins[i].isOverflow == true, "displayed origin is not overflow")
end
assertTrue(displayed.Ring1 and displayed.Ring2, "visible origins are Ring1 and Ring2")

-- Atomic move/rebind: Ring1 assignment can be selected for empty Ring2
resetEnv()
local moveP = makeProfile("MoveRing")
addMember(moveP, ALT_A)
assertTrue(moveP:AddRCLootCouncilBisResponse("Need"))
assertTrue(moveP:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19002, "Need", "1700014100")))
moveP:ApplyIdentityProjection({ force = true })
assertEq(slotState(moveP, ALT_A, "Ring1"), "ASSIGNED_AUTO")
assertEq(slotState(moveP, ALT_A, "Ring2"), "AVAILABLE")
local ringOpts = moveP:GetGearOverrideCompatibleAwards(ALT_A, "Ring2")
local ringAward
for _, award in ipairs(moveP:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "RC" then
        ringAward = award
    end
end
local listed = false
for i = 1, #ringOpts do
    if ringOpts[i].awardRef and ringOpts[i].awardRef.id == ringAward.id then
        listed = true
    end
end
assertTrue(listed, "active Ring1 award is listed for empty Ring2")
local overrideCountBefore = 0
for _, log in ipairs(moveP:GetLootLogs()) do
    if log:GetEventType() == "BIS_OVERRIDE" then
        overrideCountBefore = overrideCountBefore + 1
    end
end
assertTrue(moveP:PlaceGearOverrideAward(ALT_A, "Ring2", { kind = "RC", id = ringAward.id }), "atomic move succeeds")
moveP:ApplyIdentityProjection({ force = true })
assertEq(slotState(moveP, ALT_A, "Ring1"), "AVAILABLE", "source ring is vacated")
assertEq(slotState(moveP, ALT_A, "Ring2"), "ASSIGNED_OVERRIDE", "destination ring is occupied")
local overrideCountAfter = 0
local replaceCount = 0
for _, log in ipairs(moveP:GetLootLogs()) do
    if log:GetEventType() == "BIS_OVERRIDE" then
        overrideCountAfter = overrideCountAfter + 1
        if log:GetEventData().action == "REPLACE" then
            replaceCount = replaceCount + 1
        end
    end
end
assertEq(overrideCountAfter, overrideCountBefore + 1, "move writes one override")
assertEq(replaceCount, 1, "move is a single REPLACE")

-- REPLACE cannot overlay remaining #278 occupancy under a BiS assignment
resetEnv()
local replace278 = makeProfile("Replace278")
addMember(replace278, ALT_A)
assertTrue(replace278:AddRCLootCouncilBisResponse("Need"))
assertTrue(replace278:TryAddRCLootCouncilAward(makeCanonical(ALT_A, 19001, "Need", "1700014300")))
replace278:ApplyIdentityProjection({ force = true })
assertEq(slotState(replace278, ALT_A, "Head"), "ASSIGNED_AUTO")
local headAsg = replace278:GetIdentityBisSlots(ALT_A).Head.assignmentId
addLog(replace278, "ARMOR_CHANGE", { member = ALT_A, slot = "Head", action = "USED" })
assertTrue(replace278:AddManualAward(ALT_A, itemLink(19001, "Helm")))
local replaceHelm
for _, award in ipairs(replace278:GetIdentityAwardPool(ALT_A)) do
    if award.kind == "MANUAL" then
        replaceHelm = award.id
    end
end
local replaceBefore = #(replace278:GetLootLogs() or {})
assertFalse(replace278:ApplyBisOverride("REPLACE", {
    viewMember = ALT_A,
    targetAssignmentId = headAsg,
    awardRef = { kind = "MANUAL", id = replaceHelm },
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
}), "REPLACE cannot overlay remaining #278 occupancy")
assertEq(#(replace278:GetLootLogs() or {}), replaceBefore, "ineffective REPLACE over #278 is not appended")
replace278:ApplyIdentityProjection({ force = true })
assertEq(slotState(replace278, ALT_A, "Head"), "ASSIGNED_AUTO", "original AUTO assignment remains")
addLog(replace278, "BIS_OVERRIDE", {
    action = "REPLACE",
    awardRef = { kind = "MANUAL", id = replaceHelm },
    sourceLogId = replaceHelm,
    targetAssignmentId = headAsg,
    assignedSlots = { "Head" },
    slotBinding = "BOUND",
    assignmentScopeMembers = { ALT_A },
})
replace278:ApplyIdentityProjection({ force = true })
assertEq(slotState(replace278, ALT_A, "Head"), "ASSIGNED_AUTO", "injected REPLACE over #278 is a reducer no-op")
local injectedReplace = false
for _, log in ipairs(replace278:GetLootLogs()) do
    local data = log:GetEventType() == "BIS_OVERRIDE" and log:GetEventData()
    if data and data.action == "REPLACE" and data.targetAssignmentId == headAsg then
        injectedReplace = true
    end
end
assertTrue(injectedReplace, "injected REPLACE row is retained")
assertEq(slotState(replace278, ALT_A, "Head"), "ASSIGNED_AUTO")

-- Import-boundary semantic validation for protocol-3 item-aware types
resetEnv()
local importP = makeProfile("ImportSem")
addMember(importP, ALT_A)
local badOutcome = {
    version = 2,
    _id = PLAYER .. ":90",
    _timestamp = 1700009000,
    _author = PLAYER,
    _counter = 90,
    _eventType = "BIS_OUTCOME",
    _data = {
        sourceLogId = "k",
        awardKey = "k",
        awardMember = ALT_A,
        qualified = true,
        outcome = "ASSIGNED",
        assignedSlots = { "Head", "Ring1" },
        slotBinding = "BOUND",
        assignmentScopeMembers = { ALT_A },
        preOpAuthorMax = {},
    },
}
badOutcome._fingerprint = SF.LootLog.ComputeFingerprintFromTable(badOutcome)
assertFalse(select(1, SF.LootLog.ValidateTable(badOutcome, { profile = importP })), "malformed BIS_OUTCOME fails import validation")
local badManual = {
    version = 2,
    _id = PLAYER .. ":91",
    _timestamp = 1700009001,
    _author = PLAYER,
    _counter = 91,
    _eventType = "MANUAL_AWARD",
    _data = { member = ALT_A, itemLink = "", itemString = "", preOpAuthorMax = {} },
}
badManual._fingerprint = SF.LootLog.ComputeFingerprintFromTable(badManual)
assertFalse(select(1, SF.LootLog.ValidateTable(badManual, { profile = importP })), "malformed MANUAL_AWARD fails import validation")
local badReverse = {
    version = 2,
    _id = PLAYER .. ":92",
    _timestamp = 1700009002,
    _author = PLAYER,
    _counter = 92,
    _eventType = "MANUAL_AWARD_REVERSE",
    _data = { sourceLogId = "", preOpAuthorMax = {} },
}
badReverse._fingerprint = SF.LootLog.ComputeFingerprintFromTable(badReverse)
assertFalse(select(1, SF.LootLog.ValidateTable(badReverse, { profile = importP })), "malformed MANUAL_AWARD_REVERSE fails import validation")
local unknownType = {
    version = 2,
    _id = PLAYER .. ":93",
    _timestamp = 1700009003,
    _author = PLAYER,
    _counter = 93,
    _eventType = "FUTURE_EVENT",
    _data = { ok = true },
}
unknownType._fingerprint = SF.LootLog.ComputeFingerprintFromTable(unknownType)
assertTrue(select(1, SF.LootLog.ValidateTable(unknownType)), "unknown future event types stay forward-compatible")

-- Multi-admin bisResponses: profile snapshot config is not an append-only log
resetEnv()
local adminA = makeProfile("AdminA")
addMember(adminA, ALT_A)
assertTrue(adminA:AddRCLootCouncilBisResponse({
    text = "Need",
    typeCode = "default",
    responseId = 1,
    isAwardReason = false,
}))
local adminB = makeProfile("AdminB")
addMember(adminB, ALT_A)
assertTrue(adminB:AddRCLootCouncilBisResponse({
    text = "Greed",
    typeCode = "default",
    responseId = 2,
    isAwardReason = false,
}))
assertTrue(adminA:IsBisQualifyingResponse("Need", { typeCode = "default", responseId = 1, isAwardReason = false }), "admin A qualifies Need")
assertFalse(adminA:IsBisQualifyingResponse("Greed", { typeCode = "default", responseId = 2, isAwardReason = false }), "admin A does not have Greed")
assertTrue(adminB:IsBisQualifyingResponse("Greed", { typeCode = "default", responseId = 2, isAwardReason = false }), "admin B qualifies Greed")
assertFalse(adminB:IsBisQualifyingResponse("Need", { typeCode = "default", responseId = 1, isAwardReason = false }), "admin B does not have Need")
local snapA = adminA:ExportSnapshot()
assertTrue(type(snapA.rcLootCouncilIntegration) == "table", "bisResponses travels on the profile snapshot")
assertEq(snapA.rcLootCouncilIntegration.bisResponses[1].responseId, 1, "snapshot carries admin A's contextual Need")
end
extraCorrectnessTests()

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end

