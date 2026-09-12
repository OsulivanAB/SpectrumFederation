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
    ["19007"] = { loc = "INVTYPE_CLOAK", class = 4, sub = 1 },
    ["19008"] = { loc = "INVTYPE_CHEST", class = 4, sub = 4 },
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

local function frozenMeta(itemId, name)
    local link = itemLink(itemId, name)
    local classif = SF.LootHelperBis.ClassifyItem(link)
    return {
        link = link,
        itemString = SF.LootLog.ExtractItemString(link) or ("item:" .. tostring(itemId)),
        equipLoc = classif and classif.equipLoc,
        itemClass = classif and classif.itemClass,
        itemSubClass = classif and classif.itemSubClass,
        itemFamily = classif and classif.family,
        isTwoHand = classif and classif.isTwoHand == true,
    }
end

-- Bounded mixed history with causally related item-aware events.
-- Each RC award is paired with a source-consistent BIS_OUTCOME, and
-- CLEAR/REPLACE/REVERSE only target assignments or manuals that exist.
local function generateMixedHistory(profile, count)
    local types = SF.LootLogEventTypes
    local logs = profile._lootLogs
    local created = 0
    local lastHeadId
    local lastManualId
    local lastManualAssigned = false
    local headFilled = false
    local ringsFilled = 0
    local chestFilled = false

    local function emit(eventType, data, extraOpts)
        local index = created + 1
        if appendLog(profile, logs, eventType, data, index, extraOpts) then
            created = created + 1
            return true
        end
        return false
    end

    local function emitSpec()
        return emit(types.SPEC_CHANGE, {
            member = ALT_A,
            specId = (created % 2 == 0) and 71 or 72,
        })
    end

    local function emitArmor(slot)
        return emit(types.ARMOR_CHANGE, {
            member = ALT_B,
            slot = slot,
            action = "USED",
        })
    end

    local function emitRcOutcome(member, itemId, name, loc)
        local awardKey = "ak-" .. tostring(created + 1)
        local meta = frozenMeta(itemId, name)
        local link = meta.link
        if not emit(types.RC_LOOT_COUNCIL, {
            member = member,
            itemLink = link,
            itemString = meta.itemString,
            response = "Need",
            rcAwardId = "rc-" .. awardKey,
            awardKey = awardKey,
            equipLoc = loc,
        }, { externalId = awardKey }) then
            return false
        end
        local extra = {
            sourceLogId = awardKey,
            awardKey = awardKey,
            awardMember = member,
            qualified = true,
            assignedSlots = {},
            itemLink = link,
            itemString = meta.itemString,
            equipLoc = loc,
        }
        if itemId == 19999 then
            extra.outcome = "UNRESOLVED"
        elseif itemId == 19001 then
            extra.itemClass = meta.itemClass
            extra.itemSubClass = meta.itemSubClass
            extra.itemFamily = meta.itemFamily
            extra.isTwoHand = meta.isTwoHand
            extra.equipLoc = meta.equipLoc or loc
            if not headFilled then
                extra.outcome = "ASSIGNED"
                extra.assignedSlots = { "Head" }
                extra.slotBinding = "BOUND"
                extra.assignmentScopeMembers = { ALT_A, ALT_B }
            else
                extra.outcome = "OVERFLOW"
            end
        elseif itemId == 19002 then
            extra.itemClass = meta.itemClass
            extra.itemSubClass = meta.itemSubClass
            extra.itemFamily = meta.itemFamily
            extra.isTwoHand = meta.isTwoHand
            extra.equipLoc = meta.equipLoc or loc
            if ringsFilled < 1 then
                extra.outcome = "ASSIGNED"
                extra.assignedSlots = { "Ring1" }
                extra.slotBinding = "PACKABLE"
                extra.assignmentScopeMembers = { ALT_A, ALT_B }
            elseif ringsFilled < 2 then
                extra.outcome = "ASSIGNED"
                extra.assignedSlots = { "Ring2" }
                extra.slotBinding = "PACKABLE"
                extra.assignmentScopeMembers = { ALT_A, ALT_B }
            else
                extra.outcome = "OVERFLOW"
            end
        else
            extra.outcome = "OVERFLOW"
        end
        if not emit(types.BIS_OUTCOME, extra) then
            return false
        end
        if extra.outcome == "ASSIGNED" then
            if itemId == 19001 then
                lastHeadId = logs[#logs]:GetID()
                headFilled = true
            elseif itemId == 19002 then
                ringsFilled = ringsFilled + 1
            end
        end
        return true
    end

    local function emitManualAssignChest()
        local meta = frozenMeta(19008, "Chest")
        if not emit(types.MANUAL_AWARD, {
            member = ALT_A,
            itemLink = meta.link,
            itemString = meta.itemString,
        }) then
            return false
        end
        lastManualId = logs[#logs]:GetID()
        lastManualAssigned = false
        if not emit(types.BIS_OVERRIDE, {
            action = "ASSIGN",
            viewMember = ALT_A,
            awardRef = { kind = "MANUAL", id = lastManualId },
            sourceLogId = lastManualId,
            assignedSlots = { "Chest" },
            slotBinding = "BOUND",
            assignmentScopeMembers = { ALT_A, ALT_B },
        }) then
            return false
        end
        lastManualAssigned = true
        chestFilled = true
        return true
    end

    local function emitManualReverse()
        if not (lastManualId and lastManualAssigned) then
            return emitSpec()
        end
        if not emit(types.MANUAL_AWARD_REVERSE, {
            sourceLogId = lastManualId,
        }) then
            return false
        end
        lastManualId = nil
        lastManualAssigned = false
        chestFilled = false
        return true
    end

    local function emitClearHead()
        if not lastHeadId then
            return emitArmor("Back")
        end
        if not emit(types.BIS_OVERRIDE, {
            action = "CLEAR",
            targetAssignmentId = lastHeadId,
            viewMember = ALT_A,
        }) then
            return false
        end
        lastHeadId = nil
        headFilled = false
        return true
    end

    local function emitReplaceHead()
        if not lastHeadId then
            return emitSpec()
        end
        local meta = frozenMeta(19010, "Helm2")
        if not emit(types.MANUAL_AWARD, {
            member = ALT_A,
            itemLink = meta.link,
            itemString = meta.itemString,
        }) then
            return false
        end
        local replaceManualId = logs[#logs]:GetID()
        if not emit(types.BIS_OVERRIDE, {
            action = "REPLACE",
            viewMember = ALT_A,
            targetAssignmentId = lastHeadId,
            awardRef = { kind = "MANUAL", id = replaceManualId },
            sourceLogId = replaceManualId,
            assignedSlots = { "Head" },
            slotBinding = "BOUND",
            assignmentScopeMembers = { ALT_A, ALT_B },
        }) then
            return false
        end
        lastHeadId = logs[#logs]:GetID()
        headFilled = true
        return true
    end

    while created < count do
        local left = count - created
        local phase = created % 12
        local ok = false
        if left == 1 then
            ok = emitSpec()
        elseif (phase == 0 or phase == 6) and left >= 2 then
            ok = emitRcOutcome(ALT_A, 19001, "Helm", "INVTYPE_HEAD")
        elseif (phase == 1 or phase == 7) and left >= 2 then
            ok = emitRcOutcome(ALT_B, 19002, "Ring", "INVTYPE_FINGER")
        elseif phase == 2 and left >= 2 then
            ok = emitRcOutcome(ALT_A, 19999, "Unknown", "INVTYPE_HEAD")
        elseif phase == 3 then
            ok = emitSpec()
        elseif phase == 4 then
            ok = emitArmor((created % 2 == 0) and "Bracers" or "Back")
        elseif phase == 5 and left >= 2 and not chestFilled then
            ok = emitManualAssignChest()
        elseif phase == 5 and lastManualAssigned and left > 8 then
            ok = emitManualReverse()
        elseif phase == 8 and lastHeadId and left >= 2 then
            ok = emitReplaceHead()
        elseif phase == 9 and lastHeadId and left > 8 then
            ok = emitClearHead()
        elseif phase == 10 then
            ok = emitArmor("Back")
        else
            ok = emitSpec()
        end
        if not ok then
            if not emitSpec() then
                break
            end
        end
    end
    return created
end

local function countKeys(t)
    local n = 0
    if type(t) ~= "table" then
        return 0
    end
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function assertMeaningfulBisState(profile, count)
    local label = tostring(count)
    local projection = profile._identityProjection
    local state = projection and projection.bis and projection.bis.state
    assertTrue(type(state) == "table", "production BiS state exists after reconstruction for " .. label)
    assertTrue(countKeys(state.outcomeWinner) > 0, "source-consistent BIS outcomes were accepted for " .. label)

    local activeAuto = 0
    local inactive = 0
    local activeOverride = 0
    for _, asg in pairs(state.assignments or {}) do
        if asg.active == true and asg.source == "AUTO" then
            activeAuto = activeAuto + 1
        elseif asg.active == true and asg.source == "OVERRIDE" then
            activeOverride = activeOverride + 1
        elseif asg.active ~= true then
            inactive = inactive + 1
        end
    end
    assertTrue(activeAuto > 0, "automatic assignments were created for " .. label)
    assertTrue(inactive > 0, "corrections actually changed assignment state for " .. label)
    assertTrue(countKeys(state.reversedManual) > 0, "manual reversals were honored for " .. label)

    local boardA = profile:GetIdentityBisSlots(ALT_A)
    local boardB = profile:GetIdentityBisSlots(ALT_B)
    assertTrue(type(boardA) == "table" and type(boardB) == "table", "linked characters both have boards for " .. label)
    local sawLegacy = false
    local autoId
    for slot, cell in pairs(boardA or {}) do
        if type(cell) == "table" then
            if cell.state == "LEGACY_UNKNOWN" then
                sawLegacy = true
            end
            if (cell.state == "ASSIGNED_AUTO" or cell.state == "ASSIGNED_OVERRIDE") and cell.assignmentId then
                autoId = autoId or cell.assignmentId
                local asg = state.assignments[cell.assignmentId]
                assertTrue(asg and asg.active == true, "board assignment is active in reducer state for " .. label)
                local other = boardB[slot]
                assertTrue(other and other.assignmentId == cell.assignmentId, "linked boards share item-aware occupancy for " .. label)
            end
        end
    end
    if not sawLegacy then
        for _, cell in pairs(boardB or {}) do
            if type(cell) == "table" and cell.state == "LEGACY_UNKNOWN" then
                sawLegacy = true
                break
            end
        end
    end
    assertTrue(sawLegacy, "legacy occupancy is represented for " .. label)
    assertTrue(autoId ~= nil or activeOverride > 0, "resulting board has item-aware occupancy for " .. label)
    local pool = profile:GetIdentityAwardPool(ALT_A)
    assertTrue(type(pool) == "table" and #pool > 0, "award pool is populated for " .. label)
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
    assertMeaningfulBisState(profile, count)

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
io.stdout:write("env os=Linux 6.12.94+\n")
io.stdout:write("Does not prove Retail combat/frame/UI budgets.\n")
if os and os.date then
    io.stdout:write("env date=" .. tostring(os.date("!%Y-%m-%dT%H:%M:%SZ")) .. "\n")
end
io.stdout:flush()
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
