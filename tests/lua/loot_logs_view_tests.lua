-- Loot Logs presentation for visible BIS_OUTCOME rows (#317).
-- Run from the repository root: lua5.1 tests/lua/loot_logs_view_tests.lua

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

local AWARDER = "Vanncint-Garona"
local WRITER = "Ursully-Garona"
local WINNER = "Tyndara-Garona"
local PLAYER = WRITER

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
    return 1700007000
end

function time()
    return 1700007000
end

function date(fmt, timestamp)
    return os.date(fmt, timestamp)
end

function GetTime()
    return 0
end

function GetItemInfoInstant(link)
    local id = tostring(link):match("item:(%d+)")
    if id == "19001" or id == "19010" then
        return tonumber(id), "Armor", "Plate", "INVTYPE_HEAD", 134400, 4, 4
    end
    return nil
end

SpectrumFederationDB = { lootHelper = { profiles = {}, syncSession = {}, window = {} } }
SpectrumFederationDebugDB = { enabled = false, logs = {} }

local SF = {}

local function noop()
end

SF.Debug = setmetatable({
    Info = noop,
    Warn = noop,
    Error = noop,
    Verbose = noop,
    Log = noop,
}, {
    __call = function()
    end,
})

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

function SF:GetPlayerFullIdentifier()
    return PLAYER
end

function SF:GetPlayerClass()
    return "WARRIOR"
end

SF.SettingsUI = {
    pagesById = {},
    pages = {},
    DefinitionRenderer = {},
}

function SF.SettingsUI:RegisterPage(page)
    self.pagesById[page.id] = page
    self.pages[#self.pages + 1] = page
end

function SF.SettingsUI.DefinitionRenderer:Build(panel, def)
    panel.__capturedDef = def
end

function SF.SettingsUI.DefinitionRenderer:Refresh()
end

loadModule("SpectrumFederation/modules/UI/Settings/Pages/LootLogs.lua")

local function plain(text)
    local stripped = tostring(text or "")
    stripped = stripped:gsub("|c%x%x%x%x%x%x%x%x", "")
    stripped = stripped:gsub("|r", "")
    return stripped
end

local function itemLink(itemId, name)
    return string.format("|cffa335ee|Hitem:%s::::::::80:259:::::::::|h[%s]|h|r", tostring(itemId), name)
end

local function historyTable(id, response, responseId, link, equipLoc)
    return {
        id = id,
        response = response,
        responseID = responseId,
        lootWon = link,
        equipLoc = equipLoc,
    }
end

local function makeProfile()
    SF.lootHelperDB = {
        enabled = true,
        profiles = {},
        activeProfileId = nil,
        activeProfile = nil,
        window = {},
        syncSession = {},
    }
    SpectrumFederationDB.lootHelper = SF.lootHelperDB
    local profile = SF.LootProfile.new("Loot Logs View")
    assert(profile, "profile was created")
    local winner = SF.Member.new(WINNER, "member", "WARRIOR")
    assert(winner, "winner member was created")
    assert(profile:AddMember(winner), "winner was added")
    SF.lootHelperDB.profiles[profile:GetProfileId()] = profile
    SF.lootHelperDB.activeProfileId = profile:GetProfileId()
    SF.lootHelperDB.activeProfile = profile
    return profile
end

local function storeRc(profile, canon, stamp)
    local row = SF.LootLog.new(SF.LootLogEventTypes.RC_LOOT_COUNCIL, SF.LootLog.BuildRCLootCouncilEventData(canon), {
        profile = profile,
        author = canon.awarder,
        timestamp = stamp,
        externalId = canon.awardKey,
        counter = 0,
        skipPermission = true,
    })
    assert(row, "RC row was created")
    assert(profile:AddLootLog(row, { skipPermission = true, skipBroadcast = true }), "RC row was stored")
    return row
end

local function storeOutcome(profile, canon, outcome, counter, stamp, link, equipLoc)
    local eventData = SF.LootLog.GetEventDataTemplate(SF.LootLogEventTypes.BIS_OUTCOME)
    eventData.sourceLogId = canon.awardKey
    eventData.awardKey = canon.awardKey
    eventData.awardMember = WINNER
    eventData.qualified = outcome ~= "NOT_BIS"
    eventData.outcome = outcome
    eventData.itemLink = link
    eventData.itemString = SF.LootLog.ExtractItemString(link)
    eventData.response = "Need"
    if outcome == "ASSIGNED" then
        eventData.assignedSlots = { "Head" }
        eventData.slotBinding = "BOUND"
        eventData.assignmentScopeMembers = { WINNER }
        eventData.equipLoc = equipLoc
        eventData.itemFamily = "ordinary"
    else
        eventData.assignedSlots = {}
    end
    local row = SF.LootLog.new(SF.LootLogEventTypes.BIS_OUTCOME, eventData, {
        profile = profile,
        author = WRITER,
        timestamp = stamp,
        counter = counter,
        skipPermission = true,
    })
    assert(row, outcome .. " row was created")
    assert(profile:AddLootLog(row, { skipPermission = true, skipBroadcast = true }), outcome .. " row was stored")
    return row
end

local function storeBonus(profile, stamp)
    local link = itemLink(19003, "Bonus Trinket")
    local canon = SF.LootLog.BuildBonusRollCanonical(AWARDER, WINNER, {
        id = "1700007100-9",
        responseID = "BONUS_ROLL",
        lootWon = link,
    })
    assert(canon, "bonus canonical was created")
    local row = SF.LootLog.new(SF.LootLogEventTypes.BONUS_ROLL, SF.LootLog.BuildBonusRollEventData(canon), {
        profile = profile,
        author = canon.awarder,
        timestamp = stamp,
        externalId = canon.awardKey,
        counter = 0,
        skipPermission = true,
    })
    assert(row, "bonus row was created")
    assert(profile:AddLootLog(row, { skipPermission = true, skipBroadcast = true }), "bonus row was stored")
    return row
end

local function storePointChange(profile)
    local row = SF.LootLog.new(SF.LootLogEventTypes.POINT_CHANGE, {
        member = WINNER,
        change = "INCREMENT",
    }, {
        profile = profile,
        author = WRITER,
        timestamp = 1700007200,
        counter = 20,
        skipPermission = true,
    })
    assert(row, "point change was created")
    assert(profile:AddLootLog(row, { skipPermission = true, skipBroadcast = true }), "point change was stored")
    return row
end

local function countType(logs, eventType)
    local count = 0
    for _, log in ipairs(logs) do
        if log:GetEventType() == eventType then
            count = count + 1
        end
    end
    return count
end

local function findRows(rows, needle)
    local found = {}
    for _, row in ipairs(rows) do
        local action = plain(row.action)
        local changeType = plain(row.changeType)
        if action:find(needle, 1, true) or changeType:find(needle, 1, true) then
            found[#found + 1] = row
        end
    end
    return found
end

local profile = makeProfile()
local assignedLink = itemLink(19001, "Helm of Need")
local overflowLink = itemLink(19010, "Helm of Overflow")
local unresolvedLink = itemLink(99999, "Unknown Curio")
local notBisLink = itemLink(19007, "Sszorak's Ferocity")

local assignedCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable(
    "1700007001-1", "Need", 1, assignedLink, "INVTYPE_HEAD"
))
local overflowCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable(
    "1700007002-2", "Need", 1, overflowLink, "INVTYPE_HEAD"
))
local unresolvedCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable(
    "1700007003-3", "Need", 1, unresolvedLink, nil
))
local notBisCanon = SF.LootLog.BuildRCLootCouncilCanonical(AWARDER, WINNER, historyTable(
    "1700007004-4", "Alt Spec", 3, notBisLink, "INVTYPE_CLOAK"
))

assert(assignedCanon and overflowCanon and unresolvedCanon and notBisCanon, "RC canonical awards were built")

storeRc(profile, assignedCanon, 1700007001)
local assignedOutcome = storeOutcome(profile, assignedCanon, "ASSIGNED", 1, 1700007011, assignedLink, "INVTYPE_HEAD")
storeRc(profile, overflowCanon, 1700007002)
local overflowOutcome = storeOutcome(profile, overflowCanon, "OVERFLOW", 2, 1700007012, overflowLink, nil)
storeRc(profile, unresolvedCanon, 1700007003)
local unresolvedOutcome = storeOutcome(profile, unresolvedCanon, "UNRESOLVED", 3, 1700007013, unresolvedLink, nil)
storeRc(profile, notBisCanon, 1700007004)
local notBisOutcome = storeOutcome(profile, notBisCanon, "NOT_BIS", 4, 1700007014, notBisLink, nil)
storeBonus(profile, 1700007100)
storePointChange(profile)

local storedCount = #(profile:GetLootLogs() or {})
local storedAuthors = {}
for _, log in ipairs(profile:GetLootLogs() or {}) do
    storedAuthors[log:GetID()] = log:GetAuthor()
end

assertEq(SF.LootLogEventTypes.BIS_OUTCOME, "BIS_OUTCOME", "BIS_OUTCOME remains an internal event type")
assertEq(countType(profile:GetLootLogs(), "BIS_OUTCOME"), 4, "one stored BIS_OUTCOME per fixture award")
assertEq(assignedOutcome:GetAuthor(), WRITER, "ASSIGNED persisted author is the Spectrum writer")
assertEq(assignedOutcome._author, WRITER, "ASSIGNED _author is the Spectrum writer")

local view = SF.LootLogsView
assertEq(view.EventTypeLabel("RC_LOOT_COUNCIL"), "RC Loot Council", "RC rows are labeled RC Loot Council")
assertEq(view.EventTypeLabel("BIS_OUTCOME"), "RC Loot Council", "visible BiS outcomes use the RC label")
assertEq(view.EventTypeLabel("BONUS_ROLL"), "Bonus Roll", "bonus rolls keep their own label")
assertEq(view.EventTypeColor("BIS_OUTCOME"), view.EventTypeColor("RC_LOOT_COUNCIL"), "BiS outcomes use the RC category color")
assertTrue(view.EventTypeColor("BIS_OUTCOME") ~= view.EventTypeColor("BONUS_ROLL"), "bonus rolls keep a distinct category color")

local rcOptionCount = 0
local bisOptionCount = 0
for _, option in ipairs(view.EventTypeOptions()) do
    if option.label == "RC Loot Council" then
        rcOptionCount = rcOptionCount + 1
    end
    if option.label == "BiS Outcome" or option.value == "BIS_OUTCOME" then
        bisOptionCount = bisOptionCount + 1
    end
end
assertEq(rcOptionCount, 1, "the type filter has one RC Loot Council option")
assertEq(bisOptionCount, 0, "the type filter has no BiS Outcome option")
assertTrue(view.MatchesEventTypeFilter("RC_LOOT_COUNCIL", "RC_LOOT_COUNCIL"), "RC filter includes RC rows")
assertTrue(view.MatchesEventTypeFilter("BIS_OUTCOME", "RC_LOOT_COUNCIL"), "RC filter includes BIS_OUTCOME rows")
assertFalse(view.MatchesEventTypeFilter("BONUS_ROLL", "RC_LOOT_COUNCIL"), "RC filter excludes bonus rolls")
assertFalse(view.MatchesEventTypeFilter("POINT_CHANGE", "RC_LOOT_COUNCIL"), "RC filter excludes other types")
assertTrue(view.MatchesEventTypeFilter("BIS_OUTCOME", "BIS_OUTCOME"), "a stale BiS Outcome selection still groups with RC")

assertEq(view.DisplayAuthor(assignedOutcome), AWARDER, "ASSIGNED displays the source RC awarder")
assertEq(view.DisplayAuthor(overflowOutcome), AWARDER, "OVERFLOW displays the source RC awarder")
assertEq(view.DisplayAuthor(unresolvedOutcome), AWARDER, "UNRESOLVED displays the source RC awarder")
assertEq(assignedOutcome:GetAuthor(), WRITER, "display attribution does not rewrite the persisted author")
assertEq(assignedOutcome._author, WRITER, "display attribution does not rewrite _author")

local missing = {
    GetEventType = function()
        return "BIS_OUTCOME"
    end,
    GetAuthor = function()
        return WRITER
    end,
    GetEventData = function()
        return {
            sourceLogId = "missing-award",
            awardKey = "missing-award",
            awardMember = WINNER,
            qualified = true,
            outcome = "OVERFLOW",
            assignedSlots = {},
        }
    end,
}
assertEq(view.DisplayAuthor(missing), WRITER, "a missing source award falls back to the persisted author")

local mismatchedData = assignedOutcome:GetEventData()
local mismatched = {
    GetEventType = function()
        return "BIS_OUTCOME"
    end,
    GetAuthor = function()
        return WRITER
    end,
    GetEventData = function()
        local copy = {}
        for key, value in pairs(mismatchedData) do
            copy[key] = value
        end
        copy.itemLink = itemLink(19008, "Different Chest")
        copy.itemString = SF.LootLog.ExtractItemString(copy.itemLink)
        return copy
    end,
}
assertEq(view.DisplayAuthor(mismatched), WRITER, "an inconsistent source award falls back to the persisted author")
assertEq(assignedOutcome:GetEventData().itemString, SF.LootLog.ExtractItemString(assignedLink), "author resolution does not mutate outcome data")

local page = SF.SettingsUI.pagesById.lootLogs
assertTrue(page ~= nil, "Loot Logs page registered")
local panel = {}
page:Build(panel)
local def = panel.__capturedDef
local controls = def.sections[1].items[1].items
local typeDropdown = controls[1]
local authorDropdown = controls[2]
local logTable = def.sections[1].items[2]

local function authorNames()
    local names = {}
    for _, option in ipairs(authorDropdown.options()) do
        names[option.value] = true
    end
    return names
end

local rows = logTable.getRows()
assertEq(#findRows(rows, "Not BiS"), 0, "NOT_BIS is absent from the visible log")
assertEq(#findRows(rows, "BiS assigned"), 1, "ASSIGNED stays visible")
assertEq(#findRows(rows, "BiS overflow"), 1, "OVERFLOW stays visible")
assertEq(#findRows(rows, "BiS unresolved"), 1, "UNRESOLVED stays visible")
assertEq(#findRows(rows, "Bonus Trinket"), 1, "bonus rolls stay visible")
assertEq(#findRows(rows, "Points Increased"), 1, "unrelated logs stay visible")

local function assertRcPresentation(row, message)
    local changeType = plain(row.changeType)
    assertEq(changeType, "RC Loot Council", message .. " type")
    assertTrue(row.changeType:find(view.EventTypeColor("RC_LOOT_COUNCIL"), 1, true) == 1, message .. " color")
    assertTrue(plain(row.author):find(AWARDER, 1, true) ~= nil, message .. " author")
    assertTrue(plain(row.author):find(WRITER, 1, true) == nil, message .. " does not show the stored writer")
end

assertRcPresentation(findRows(rows, "BiS assigned")[1], "ASSIGNED")
assertRcPresentation(findRows(rows, "BiS overflow")[1], "OVERFLOW")
assertRcPresentation(findRows(rows, "BiS unresolved")[1], "UNRESOLVED")
local function countActions(rows, needle, excluded)
    local count = 0
    for _, row in ipairs(rows) do
        local action = plain(row.action)
        if action:find(needle, 1, true) and (not excluded or not action:find(excluded, 1, true)) then
            count = count + 1
        end
    end
    return count
end

assertEq(countActions(rows, "[Helm of Need]", "BiS assigned"), 1, "source RC row stays visible")
local sourceRcRow
for _, row in ipairs(rows) do
    local action = plain(row.action)
    if action:find("[Helm of Need]", 1, true) and not action:find("BiS assigned", 1, true) then
        sourceRcRow = row
    end
end
assertEq(sourceRcRow and plain(sourceRcRow.changeType), "RC Loot Council", "source RC row stays RC Loot Council")
assertEq(sourceRcRow and plain(sourceRcRow.author), AWARDER, "source RC row author is the master looter")
assertEq(plain(findRows(rows, "Bonus Trinket")[1].changeType), "Bonus Roll", "bonus roll category is unchanged")
assertEq(plain(findRows(rows, "Sszorak's Ferocity")[1].changeType), "RC Loot Council", "non-BiS RC award stays visible as RC Loot Council")

typeDropdown.set("RC_LOOT_COUNCIL")
local rcRows = logTable.getRows()
assertEq(#findRows(rcRows, "BiS assigned"), 1, "RC filter includes ASSIGNED")
assertEq(#findRows(rcRows, "BiS overflow"), 1, "RC filter includes OVERFLOW")
assertEq(#findRows(rcRows, "BiS unresolved"), 1, "RC filter includes UNRESOLVED")
assertEq(countActions(rcRows, "[Helm of Need]", "BiS assigned"), 1, "RC filter includes the RC award")
assertEq(#findRows(rcRows, "Sszorak's Ferocity"), 1, "RC filter includes the non-BiS RC award")
assertEq(#findRows(rcRows, "Not BiS"), 0, "RC filter still hides NOT_BIS")
assertEq(#findRows(rcRows, "Bonus Trinket"), 0, "RC filter excludes bonus rolls")
assertEq(#findRows(rcRows, "Points Increased"), 0, "RC filter excludes point changes")

typeDropdown.set("BIS_OUTCOME")
assertEq(typeDropdown.get(), "RC_LOOT_COUNCIL", "a stale BiS Outcome filter displays as RC Loot Council")
assertEq(#findRows(logTable.getRows(), "Bonus Trinket"), 0, "stale BiS Outcome filter does not include bonus rolls")
assertEq(#findRows(logTable.getRows(), "BiS assigned"), 1, "stale BiS Outcome filter still includes visible outcomes")

typeDropdown.set(nil)
authorDropdown.set(AWARDER)
local awarderRows = logTable.getRows()
assertEq(#findRows(awarderRows, "BiS assigned"), 1, "author filter includes the BiS row under the RC awarder")
assertEq(#findRows(awarderRows, "Points Increased"), 0, "author filter excludes the Spectrum writer point change")
authorDropdown.set(WRITER)
local writerRows = logTable.getRows()
assertEq(#findRows(writerRows, "BiS assigned"), 0, "author filter does not match the hidden persisted BiS writer")
assertEq(#findRows(writerRows, "Points Increased"), 1, "author filter still matches the stored writer of other rows")

local names = authorNames()
assertTrue(names[AWARDER] == true, "author dropdown lists the displayed RC awarder")
assertTrue(names[WRITER] == true, "author dropdown lists authors of other rows")

for _, log in ipairs(profile:GetLootLogs() or {}) do
    assertEq(log:GetAuthor(), storedAuthors[log:GetID()], "rendering leaves stored authors unchanged")
end
assertEq(#(profile:GetLootLogs() or {}), storedCount, "rendering does not append or delete logs")
assertEq(notBisOutcome:GetEventType(), "BIS_OUTCOME", "hidden NOT_BIS remains BIS_OUTCOME")
assertEq(overflowOutcome:GetEventType(), "BIS_OUTCOME", "visible overflow remains BIS_OUTCOME")
assertEq(unresolvedOutcome:GetEventType(), "BIS_OUTCOME", "visible unresolved remains BIS_OUTCOME")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
