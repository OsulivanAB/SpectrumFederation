-- Production-Lua tests for profile minimum item level configuration.
-- Run from the repository root: lua5.1 tests/lua/raid_check_item_level_config_tests.lua

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

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local PLAYER = "Owner-Garona"
local currentPlayer = PLAYER

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
        return currentPlayer:match("^([^%-]+)")
    end
    return "Unknown"
end

function UnitFullName(unit)
    if unit == "player" then
        return currentPlayer:match("^([^%-]+)"), "Garona"
    end
    return "Unknown", "Garona"
end

function UnitClass()
    return "Warrior", "WARRIOR"
end

function GetServerTime()
    return 1700001000
end

function GetTime()
    return 0
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
loadModule("SpectrumFederation/modules/RaidEquipment/Policy.lua")

function SF:GetPlayerFullIdentifier()
    return currentPlayer
end

function SF:GetPlayerClass()
    return "WARRIOR"
end

SF.Debug = {
    Info = function() end,
    Warn = function() end,
    Error = function() end,
    Verbose = function() end,
}

local noted = 0
SF.RaidCheck = {
    NoteEquipmentPolicyConfigChanged = function()
        noted = noted + 1
    end,
}

local profile = SF.LootProfile.new("Raid")
assertTrue(profile ~= nil, "profile can be created")

local fresh = profile:GetRaidCheckConfig()
assertEq(fresh.requireMinimumItemLevel, false, "new profile disables minimum item level")
assertEq(fresh.minimumItemLevel, nil, "new profile has no default threshold")
assertEq(fresh.whisperTemplatePreRaidMissing, "Spectrum Federation: You're missing the following requirements: {missing}.", "new pre-raid whisper names requirements")
assertEq(fresh.whisperTemplateRaidMissing, "Spectrum Federation: You're missing the following requirements: {missing}. No new {point_name} awarded.", "new raid whisper names requirements")

local ok = profile:SetRaidCheckMinimumItemLevelRequired(true)
assertTrue(ok, "admin can enable the requirement")
ok = profile:SetRaidCheckMinimumItemLevel(650)
assertTrue(ok, "admin can set the minimum")
assertEq(noted, 2, "changing the requirement asks for policy reevaluation")
local configured = profile:GetRaidCheckConfig()
assertEq(configured.requireMinimumItemLevel, true, "enabled flag round-trips")
assertEq(configured.minimumItemLevel, 650, "minimum round-trips")

local frozen = profile:GetRaidCheckConfig()
profile:SetRaidCheckMinimumItemLevel(660)
profile:SetRaidCheckMinimumItemLevelRequired(false)
assertEq(frozen.minimumItemLevel, 650, "a copied config stays at the value frozen for a run")
assertEq(frozen.requireMinimumItemLevel, true, "a copied enabled flag stays frozen")
assertEq(profile:GetRaidCheckConfig().minimumItemLevel, 660, "the live profile has the later minimum")
assertEq(profile:GetRaidCheckConfig().requireMinimumItemLevel, false, "the live profile has the later enabled flag")

profile:SetRaidCheckMinimumItemLevelRequired(true)
profile:SetRaidCheckMinimumItemLevel(-12)
assertEq(profile:GetRaidCheckConfig().minimumItemLevel, 0, "negative thresholds normalize to zero")
profile:SetRaidCheckMinimumItemLevel("nope")
assertEq(profile:GetRaidCheckConfig().minimumItemLevel, nil, "invalid thresholds normalize to nil")
assertEq(profile:GetRaidCheckConfig().requireMinimumItemLevel, true, "invalid threshold does not clear the enabled flag")

currentPlayer = "Visitor-Garona"
local denied, err = profile:SetRaidCheckMinimumItemLevelRequired(false)
assertTrue(not denied, "non-admin cannot change the enabled flag")
assertEq(err, "You must be an admin to change Raid Check settings.", "non-admin receives the raid check permission error")
denied = profile:SetRaidCheckMinimumItemLevel(700)
assertTrue(not denied, "non-admin cannot change the minimum")
assertEq(profile:GetRaidCheckConfig().minimumItemLevel, nil, "non-admin mutation did not stick")
currentPlayer = PLAYER

local snapshot = profile:ExportSnapshot()
assertEq(snapshot.raidCheck.requireMinimumItemLevel, true, "export includes the enabled flag")
assertEq(snapshot.raidCheck.minimumItemLevel, nil, "export includes a nil normalized threshold")
snapshot.raidCheck.requireMinimumItemLevel = true
snapshot.raidCheck.minimumItemLevel = 640
snapshot.raidCheck.itemLevelWhisperDefaultsApplied = true
local notedBeforeImport = noted
assertTrue(profile:ImportSnapshot(snapshot) ~= false, "snapshot import succeeds")
assertEq(profile:GetRaidCheckConfig().requireMinimumItemLevel, true, "import keeps an enabled requirement")
assertEq(profile:GetRaidCheckConfig().minimumItemLevel, 640, "import keeps the minimum")
assertEq(noted, notedBeforeImport + 1, "importing a changed minimum reevaluates cached policy")
local sameSnapshot = profile:ExportSnapshot()
local notedUnchanged = noted
assertTrue(profile:ImportSnapshot(sameSnapshot) ~= false, "unchanged snapshot import succeeds")
assertEq(noted, notedUnchanged, "unchanged item level config does not force another reevaluation")

local legacy = profile:ExportSnapshot()
legacy.raidCheck.requireMinimumItemLevel = nil
legacy.raidCheck.minimumItemLevel = nil
legacy.raidCheck.itemLevelWhisperDefaultsApplied = nil
legacy.raidCheck.whisperTemplatePreRaidMissing = "Spectrum Federation: You're missing the following enchants/gems: {missing}."
legacy.raidCheck.whisperTemplateRaidMissing = "Custom {missing} template"
assertTrue(profile:ImportSnapshot(legacy) ~= false, "older snapshot import succeeds")
local olderCfg = profile:GetRaidCheckConfig()
assertEq(olderCfg.requireMinimumItemLevel, true, "older snapshot keeps a minimum this client already configured")
assertEq(olderCfg.minimumItemLevel, 640, "older snapshot keeps the configured threshold")
assertEq(olderCfg.whisperTemplatePreRaidMissing, "Spectrum Federation: You're missing the following requirements: {missing}.", "unmodified default whisper is upgraded")
assertEq(olderCfg.whisperTemplateRaidMissing, "Custom {missing} template", "custom whisper template is preserved")

local blank = SF.LootProfile.new("Blank")
local blankSnapshot = blank:ExportSnapshot()
blankSnapshot.raidCheck.requireMinimumItemLevel = nil
blankSnapshot.raidCheck.minimumItemLevel = nil
assertTrue(blank:ImportSnapshot(blankSnapshot) ~= false, "legacy snapshot imports into a profile with no minimum")
assertEq(blank:GetRaidCheckConfig().requireMinimumItemLevel, false, "legacy snapshot does not enable a requirement")
assertEq(blank:GetRaidCheckConfig().minimumItemLevel, nil, "legacy snapshot does not invent a threshold")

local cleared = profile:ExportSnapshot()
cleared.raidCheck.requireMinimumItemLevel = true
cleared.raidCheck.minimumItemLevel = nil
assertTrue(profile:ImportSnapshot(cleared) ~= false, "explicit clear imports")
assertEq(profile:GetRaidCheckConfig().requireMinimumItemLevel, true, "explicit enabled flag still imports")
assertEq(profile:GetRaidCheckConfig().minimumItemLevel, nil, "a snapshot that knows the field can clear the threshold")

local disabled = profile:ExportSnapshot()
disabled.raidCheck.requireMinimumItemLevel = false
disabled.raidCheck.minimumItemLevel = 650
assertTrue(profile:ImportSnapshot(disabled) ~= false, "explicit disable imports")
assertEq(profile:GetRaidCheckConfig().requireMinimumItemLevel, false, "explicit false disables the requirement")
assertEq(profile:GetRaidCheckConfig().minimumItemLevel, 650, "an included threshold still imports with the flag")

local corrupt = profile:ExportSnapshot()
corrupt.raidCheck.minimumItemLevel = "banana"
corrupt.raidCheck.requireMinimumItemLevel = true
local importOk = profile:ImportSnapshot(corrupt)
assertTrue(importOk ~= false, "invalid threshold does not reject the snapshot")
assertEq(profile:GetRaidCheckConfig().minimumItemLevel, nil, "invalid imported threshold normalizes to nil")
assertEq(profile:GetRaidCheckConfig().requireMinimumItemLevel, true, "enabled flag still imports")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
