-- Production-loaded Stage A Gate P benchmark for item-aware BiS reconstruction.
-- Measures standalone lua5.1 scaling; it does not claim Retail CPU/frame/UI budgets.
-- Run from the repository root: lua5.1 tests/lua/bis_acceptance_benchmark_tests.lua

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

local PLAYER = "Owner-Garona"
local ALT_A = "Alpha-Garona"
local ALT_B = "Bravo-Garona"

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
    ["19010"] = { loc = "INVTYPE_HEAD", class = 4, sub = 4 },
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
loadModule("SpectrumFederation/modules/LootHelperSync/02_State.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/05_Scheduling.lua")
loadModule("SpectrumFederation/modules/LootHelperSync/16_ProfileIntegration.lua")

function SF:GetPlayerFullIdentifier()
    return PLAYER
end

function SF:GetPlayerClass()
    return "WARRIOR"
end

function SF:PrintError()
end

function SF:PrintWarning()
end

function SF:PrintInfo()
end

SF.Debug = {
    Info = function() end,
    Warn = function() end,
    Error = function() end,
    Verbose = function() end,
}

SF.lootHelperDB = SpectrumFederationDB.lootHelper
SF.LootHelper = SF.LootHelper or {}
SF.LootHelper.GetDB = function()
    return SF.lootHelperDB
end

local Sync = SF.LootHelperSync
local Identity = SF.LootHelperIdentity

local function clock()
    if os and os.clock then
        return os.clock()
    end
    return 0
end

local function itemLink(itemId, name)
    return string.format("|cffa335ee|Hitem:%s::::::::80:259:::::::::|h[%s]|h|r", tostring(itemId), name or "Item")
end

local function makeProfile()
    local profile = SF.LootProfile.new("BisBench")
    SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
    SF.lootHelperDB.activeProfileId = profile:GetProfileId()
    SF.lootHelperDB.activeProfile = profile
    return profile
end

local function addMember(profile, memberId)
    local member = SF.Member.new(memberId, "member", "WARRIOR")
    assert(profile:AddMember(member))
    return member
end

local function appendLog(profile, logs, eventType, data, index, extraOpts)
    data = data or {}
    extraOpts = extraOpts or {}
    if data.preOpAuthorMax == nil then
        data.preOpAuthorMax = {}
    end
    local log = SF.LootLog.new(eventType, data, {
        profile = profile,
        skipPermission = true,
        author = PLAYER,
        timestamp = 1700002000 + index,
        counter = index + 20,
        externalId = extraOpts.externalId,
    })
    if not log then
        return false
    end
    logs[#logs + 1] = log
    return true
end

local function generateMixedHistory(profile, count)
    local types = SF.LootLogEventTypes
    local logs = profile._lootLogs
    local created = 0
    local function fill()
        local lastManualId
        local slots = { "Head", "Shoulder", "Chest", "Hands", "Belt", "Pants", "Boots", "Back", "Neck", "Bracers" }
        for index = 1, count do
            local cycle = index % 8
            local ok = false
            if cycle == 0 then
                local awardKey = "ak-" .. tostring(index)
                ok = appendLog(profile, logs, types.RC_LOOT_COUNCIL, {
                    member = ALT_A,
                    itemLink = itemLink(19001, "Helm"),
                    itemString = "item:19001",
                    response = "Need",
                    rcAwardId = "rc-" .. tostring(index),
                    awardKey = awardKey,
                    equipLoc = "INVTYPE_HEAD",
                }, index, { externalId = awardKey })
            elseif cycle == 1 then
                local awardKey = "out-" .. tostring(index)
                local outcome = "OVERFLOW"
                local assignedSlots = {}
                local extra = {}
                if index % 3 == 0 then
                    outcome = "ASSIGNED"
                    assignedSlots = { slots[(index % #slots) + 1] }
                    extra.slotBinding = "BOUND"
                    extra.assignmentScopeMembers = { ALT_A }
                    extra.equipLoc = "INVTYPE_HEAD"
                    extra.itemClass = 4
                    extra.itemSubClass = 4
                    extra.itemFamily = "ordinary"
                    extra.isTwoHand = false
                    extra.itemLink = itemLink(19001, "Helm")
                    extra.itemString = "item:19001"
                elseif index % 3 == 1 then
                    outcome = "UNRESOLVED"
                end
                extra.sourceLogId = awardKey
                extra.awardKey = awardKey
                extra.awardMember = ALT_A
                extra.qualified = true
                extra.outcome = outcome
                extra.assignedSlots = assignedSlots
                ok = appendLog(profile, logs, types.BIS_OUTCOME, extra, index)
            elseif cycle == 2 then
                ok = appendLog(profile, logs, types.SPEC_CHANGE, {
                    member = ALT_A,
                    specId = (index % 2 == 0) and 71 or 72,
                }, index)
            elseif cycle == 3 then
                ok = appendLog(profile, logs, types.ARMOR_CHANGE, {
                    member = ALT_B,
                    slot = (index % 2 == 0) and "Head" or "Chest",
                    action = "USED",
                }, index)
            elseif cycle == 4 then
                ok = appendLog(profile, logs, types.MANUAL_AWARD, {
                    member = ALT_A,
                    itemLink = itemLink(19002, "Ring"),
                    itemString = "item:19002",
                }, index)
                if ok then
                    lastManualId = logs[#logs]:GetID()
                end
            elseif cycle == 5 then
                local sourceId = lastManualId or ("Owner-Garona:" .. tostring(index + 20))
                ok = appendLog(profile, logs, types.MANUAL_AWARD_REVERSE, {
                    sourceLogId = sourceId,
                }, index)
            elseif cycle == 6 then
                ok = appendLog(profile, logs, types.BIS_OVERRIDE, {
                    action = "CLEAR",
                    targetAssignmentId = "asg-" .. tostring(index),
                    viewMember = ALT_A,
                }, index)
            else
                local awardKey = "ring-" .. tostring(index)
                ok = appendLog(profile, logs, types.RC_LOOT_COUNCIL, {
                    member = ALT_B,
                    itemLink = itemLink(19002, "Ring"),
                    itemString = "item:19002",
                    response = "Need",
                    rcAwardId = "rcb-" .. tostring(index),
                    awardKey = awardKey,
                    equipLoc = "INVTYPE_FINGER",
                }, index, { externalId = awardKey })
            end
            if ok then
                created = created + 1
            end
        end
    end
    fill()
    return created
end

local function setupProfile(count)
    SpectrumFederationDB.lootHelper = { profiles = {}, syncSession = {}, window = {} }
    SF.lootHelperDB = SpectrumFederationDB.lootHelper
    local profile = makeProfile()
    addMember(profile, PLAYER)
    addMember(profile, ALT_A)
    addMember(profile, ALT_B)
    local types = SF.LootLogEventTypes
    local seed = SF.LootLog.new(types.PROFILE_CREATION, { profileId = profile:GetProfileId(), preOpAuthorMax = {} }, {
        profile = profile,
        skipPermission = true,
        author = PLAYER,
        timestamp = 1700001000,
        counter = 1,
    })
    assert(seed)
    assert(profile:AddLootLog(seed, { skipPermission = true, skipBroadcast = true }))
    assert(profile:LinkCharacters(ALT_A, ALT_B, { skipPermission = true, skipBroadcast = true }))
    assert(profile:SetMemberSpec(ALT_A, 71))
    assert(profile:ApplyRCLootCouncilIntegrationConfig({
        recordAwards = true,
        recordAllAwardTypes = false,
        allowedResponses = { "Need" },
        bisResponses = {},
    }, { skipPermission = true, skipSync = true }))
    assert(profile:AddRCLootCouncilBisResponse("Need"))
    local created = generateMixedHistory(profile, count)
    if profile.RebuildLogIndex then
        profile:RebuildLogIndex()
    end
    return profile, created
end

local function measureSize(count)
    local profile, created = setupProfile(count)
    local logs = profile:GetLootLogs()
    assertTrue(created == count, "generated " .. tostring(count) .. " mixed BiS history records")
    assertTrue(#(logs or {}) >= count, "profile stores the generated mixed history")

    profile._identityProjection = nil
    local t0 = clock()
    local projection = profile:ApplyIdentityProjection({ force = true })
    local reconstructS = clock() - t0
    assertTrue(type(projection) == "table", "force reconstruction returned a projection for " .. tostring(count))
    assertTrue(projection.bis ~= nil, "reconstruction loaded production BiS state for " .. tostring(count))

    local t1 = clock()
    local board = profile:GetIdentityBisSlots(ALT_A)
    local cachedS = clock() - t1
    assertTrue(type(board) == "table", "cached board read returned slots for " .. tostring(count))

    local liveCanon = SF.LootLog.BuildRCLootCouncilCanonical(PLAYER, ALT_A, {
        lootWon = itemLink(19010, "Helm2"),
        response = "Need",
        id = tostring(1700090000 + count) .. "-7",
        owner = ALT_A,
    })
    liveCanon.equipLoc = "INVTYPE_HEAD"
    local t2 = clock()
    local awarded = profile:TryAddRCLootCouncilAward(liveCanon)
    local awardS = clock() - t2
    assertTrue(awarded, "representative live award processed for " .. tostring(count))

    local assignmentId = profile:GetIdentityBisSlots(ALT_A) and profile:GetIdentityBisSlots(ALT_A).Head and profile:GetIdentityBisSlots(ALT_A).Head.assignmentId
    local t3 = clock()
    if assignmentId then
        profile:ApplyBisOverride("CLEAR", { viewMember = ALT_A, targetAssignmentId = assignmentId })
    end
    profile:ApplyIdentityProjection({ force = true })
    local correctionS = clock() - t3

    profile._identityProjection = nil
    local t4 = clock()
    local rebuilt, rebuildErr = Sync:RebuildProfile(profile:GetProfileId(), "bis-acceptance-benchmark")
    local syncS = clock() - t4
    assertTrue(rebuilt, "sync RebuildProfile reconstructed " .. tostring(count) .. " (" .. tostring(rebuildErr) .. ")")

    local assessment = "negligible"
    if reconstructS >= 2.0 then
        assessment = "serious multi-second risk"
    elseif reconstructS >= 0.25 then
        assessment = "likely visible hitch"
    elseif reconstructS >= 0.05 then
        assessment = "measurable but acceptable"
    end

    return {
        count = count,
        created = created,
        traversed = #(logs or {}),
        reconstruct = reconstructS,
        cached = cachedS,
        award = awardS,
        correction = correctionS,
        sync = syncS,
        assessment = assessment,
        hasBis = projection.bis ~= nil,
    }
end

io.stdout:write("Gate P BiS acceptance benchmark (seconds, standalone lua5.1)\n")
io.stdout:write("env lua=" .. tostring(_VERSION) .. "\n")
if os and os.date then
    io.stdout:write("env date=" .. tostring(os.date("!%Y-%m-%dT%H:%M:%SZ")) .. "\n")
end
io.stdout:write(string.format("%10s %12s %12s %12s %12s %12s %s\n",
    "records", "reconstruct", "cachedBoard", "newAward", "correction", "syncRebuild", "assessment"))

local SIZES = { 1000, 10000, 50000 }
local results = {}
for i = 1, #SIZES do
    local row = measureSize(SIZES[i])
    results[#results + 1] = row
    io.stdout:write(string.format("%10d %12.4f %12.4f %12.4f %12.4f %12.4f %s\n",
        row.count, row.reconstruct, row.cached, row.award, row.correction, row.sync, row.assessment))
end

local largest = results[#results]
assertTrue(largest ~= nil, "benchmark produced results")
assertTrue(largest.traversed >= 1000, "largest run traversed the generated records")
assertTrue(largest.hasBis, "largest run exercised production BiS reconstruction")
assertTrue(Identity ~= nil and SF.LootHelperBis ~= nil, "production Identity and BiS modules are loaded")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
