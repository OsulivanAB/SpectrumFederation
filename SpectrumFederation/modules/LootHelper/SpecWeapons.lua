-- Spec-keyed weapon compatibility. Unknown specId means do not guess.
-- Award-time historical authority for the current supported Retail/Midnight build.
-- luacheck: globals GetSpecializationInfoByID

local addonName, SF = ...

SF.LootHelperBis = SF.LootHelperBis or {}
local SpecWeapons = {}
SF.LootHelperBis.SpecWeapons = SpecWeapons

-- Flags answer only the reducer questions:
-- canDualWield1H: 1H / INVTYPE_WEAPON may occupy OffHand
-- canDualWield2H: INVTYPE_2HWEAPON may occupy Weapon or OffHand independently (Titan's Grip)
-- canTwoHand: INVTYPE_2HWEAPON is a valid combat weapon for this spec
-- offHandShield / offHandHoldable / offHandWeapon: OffHand item families
-- Omitted specId => unknown compatibility (fail closed).
local function Flags(dw1h, dw2h, twoH, shield, holdable, ohWeapon)
    return {
        canDualWield1H = dw1h and true or false,
        canDualWield2H = dw2h and true or false,
        canTwoHand = twoH and true or false,
        offHandShield = shield and true or false,
        offHandHoldable = holdable and true or false,
        offHandWeapon = ohWeapon and true or false,
    }
end

-- Retail Midnight (Interface 120100) specialization weapon facts.
local FLAGS = {
    -- Warrior
    [71] = Flags(false, false, true, false, false, false), -- Arms (2H; no shield)
    [72] = Flags(true, true, true, false, false, true),    -- Fury (Titan's Grip)
    [73] = Flags(false, false, false, true, false, false), -- Protection (1H + shield; not 2H)
    -- Paladin
    [65] = Flags(false, false, true, true, true, false),   -- Holy (1H+shield/holdable or 2H)
    [66] = Flags(false, false, false, true, false, false), -- Protection (1H + shield; not 2H)
    [70] = Flags(false, false, true, false, false, false), -- Retribution (2H; no shield)
    -- Hunter: BM/MM fight with ranged (not melee 2H). Survival fights with melee 2H.
    [253] = Flags(false, false, false, false, false, false), -- Beast Mastery
    [254] = Flags(false, false, false, false, false, false), -- Marksmanship
    [255] = Flags(false, false, true, false, false, false),  -- Survival
    -- Rogue: dual-wield 1H only; no 2H, shields, or frills
    [259] = Flags(true, false, false, false, false, true), -- Assassination
    [260] = Flags(true, false, false, false, false, true), -- Outlaw
    [261] = Flags(true, false, false, false, false, true), -- Subtlety
    -- Priest
    [256] = Flags(false, false, true, false, true, false), -- Discipline
    [257] = Flags(false, false, true, false, true, false), -- Holy
    [258] = Flags(false, false, true, false, true, false), -- Shadow
    -- Death Knight
    [250] = Flags(false, false, true, false, false, false), -- Blood
    [251] = Flags(true, false, true, false, false, true),   -- Frost
    [252] = Flags(false, false, true, false, false, false), -- Unholy
    -- Shaman: Enhancement is dual-wield 1H in current Retail; Ele/Resto use 2H or 1H+OH
    [262] = Flags(false, false, true, true, true, false),  -- Elemental
    [263] = Flags(true, false, false, false, false, true), -- Enhancement
    [264] = Flags(false, false, true, true, true, false),  -- Restoration
    -- Mage
    [62] = Flags(false, false, true, false, true, false), -- Arcane
    [63] = Flags(false, false, true, false, true, false), -- Fire
    [64] = Flags(false, false, true, false, true, false), -- Frost
    -- Warlock
    [265] = Flags(false, false, true, false, true, false), -- Affliction
    [266] = Flags(false, false, true, false, true, false), -- Demonology
    [267] = Flags(false, false, true, false, true, false), -- Destruction
    -- Monk: Brewmaster and Windwalker dual-wield 1H or use a 2H staff/polearm
    [268] = Flags(true, false, true, false, false, true),  -- Brewmaster
    [269] = Flags(true, false, true, false, false, true),  -- Windwalker
    [270] = Flags(false, false, true, false, true, false), -- Mistweaver
    -- Druid
    [102] = Flags(false, false, true, false, true, false),  -- Balance
    [103] = Flags(false, false, true, false, false, false), -- Feral
    [104] = Flags(false, false, true, false, false, false), -- Guardian
    [105] = Flags(false, false, true, false, true, false),  -- Restoration
    -- Demon Hunter: all three current specs dual-wield 1H (warglaives); no 2H
    [577] = Flags(true, false, false, false, false, true), -- Havoc
    [581] = Flags(true, false, false, false, false, true), -- Vengeance
    [1480] = Flags(true, false, false, false, false, true), -- Devourer
    -- Evoker
    [1467] = Flags(false, false, true, false, true, false), -- Devastation
    [1468] = Flags(false, false, true, false, true, false), -- Preservation
    [1473] = Flags(false, false, true, false, true, false), -- Augmentation
}

local CLASS_SPECS = {
    WARRIOR = { 71, 72, 73 },
    PALADIN = { 65, 66, 70 },
    HUNTER = { 253, 254, 255 },
    ROGUE = { 259, 260, 261 },
    PRIEST = { 256, 257, 258 },
    DEATHKNIGHT = { 250, 251, 252 },
    SHAMAN = { 262, 263, 264 },
    MAGE = { 62, 63, 64 },
    WARLOCK = { 265, 266, 267 },
    MONK = { 268, 269, 270 },
    DRUID = { 102, 103, 104, 105 },
    DEMONHUNTER = { 577, 581, 1480 },
    EVOKER = { 1467, 1468, 1473 },
}

-- Enum.ItemWeaponSubclass (stable). There is no reliable Retail API that answers
-- "can this other profile character/class/spec use this weapon?" C_Item.IsEquippableItem
-- is the local player; C_Item.GetItemSpecInfo is item-drop spec restriction, not class
-- proficiency. Unknown subclass IDs fail closed.
local AXE1H, AXE2H, BOW, GUN = 0, 1, 2, 3
local MACE1H, MACE2H, POLEARM = 4, 5, 6
local SWORD1H, SWORD2H, WARGLAIVE, STAFF = 7, 8, 9, 10
local FIST, DAGGER, CROSSBOW, WAND = 13, 15, 18, 19
local ITEM_CLASS_WEAPON, ITEM_CLASS_ARMOR = 2, 4
local ARMOR_SHIELD = 6

local function Subset(...)
    local t = {}
    local n = select("#", ...)
    for i = 1, n do
        t[select(i, ...)] = true
    end
    return t
end

-- Class-level weapon proficiency. Spec FLAGS still decide combat slotting
-- (2H vs 1H+shield vs dual-wield vs ranged-as-Weapon).
local CLASS_WEAPON_SUBCLASS = {
    WARRIOR = Subset(AXE1H, AXE2H, MACE1H, MACE2H, POLEARM, SWORD1H, SWORD2H, STAFF, FIST, DAGGER, BOW, GUN, CROSSBOW),
    PALADIN = Subset(AXE1H, AXE2H, MACE1H, MACE2H, POLEARM, SWORD1H, SWORD2H),
    HUNTER = Subset(AXE1H, AXE2H, SWORD1H, SWORD2H, POLEARM, STAFF, FIST, DAGGER, BOW, GUN, CROSSBOW),
    ROGUE = Subset(AXE1H, MACE1H, SWORD1H, FIST, DAGGER),
    PRIEST = Subset(MACE1H, STAFF, DAGGER, WAND),
    DEATHKNIGHT = Subset(AXE1H, AXE2H, MACE1H, MACE2H, POLEARM, SWORD1H, SWORD2H),
    SHAMAN = Subset(AXE1H, AXE2H, MACE1H, MACE2H, STAFF, FIST, DAGGER),
    MAGE = Subset(SWORD1H, STAFF, DAGGER, WAND),
    WARLOCK = Subset(SWORD1H, STAFF, DAGGER, WAND),
    MONK = Subset(AXE1H, MACE1H, SWORD1H, POLEARM, STAFF, FIST),
    DRUID = Subset(MACE1H, MACE2H, POLEARM, STAFF, FIST, DAGGER),
    DEMONHUNTER = Subset(AXE1H, SWORD1H, WARGLAIVE, FIST),
    EVOKER = Subset(MACE1H, MACE2H, STAFF, FIST, DAGGER),
}

-- Fallback display names when GetSpecializationInfoByID is unavailable.
local SPEC_NAMES = {
    [71] = "Arms",
    [72] = "Fury",
    [73] = "Protection",
    [65] = "Holy",
    [66] = "Protection",
    [70] = "Retribution",
    [253] = "Beast Mastery",
    [254] = "Marksmanship",
    [255] = "Survival",
    [259] = "Assassination",
    [260] = "Outlaw",
    [261] = "Subtlety",
    [256] = "Discipline",
    [257] = "Holy",
    [258] = "Shadow",
    [250] = "Blood",
    [251] = "Frost",
    [252] = "Unholy",
    [262] = "Elemental",
    [263] = "Enhancement",
    [264] = "Restoration",
    [62] = "Arcane",
    [63] = "Fire",
    [64] = "Frost",
    [265] = "Affliction",
    [266] = "Demonology",
    [267] = "Destruction",
    [268] = "Brewmaster",
    [269] = "Windwalker",
    [270] = "Mistweaver",
    [102] = "Balance",
    [103] = "Feral",
    [104] = "Guardian",
    [105] = "Restoration",
    [577] = "Havoc",
    [581] = "Vengeance",
    [1480] = "Devourer",
    [1467] = "Devastation",
    [1468] = "Preservation",
    [1473] = "Augmentation",
}

function SpecWeapons.GetFlags(specId)
    specId = tonumber(specId)
    if not specId then
        return nil
    end
    local flags = FLAGS[specId]
    if not flags then
        return nil
    end
    return flags
end

function SpecWeapons.IsKnownSpec(specId)
    return SpecWeapons.GetFlags(specId) ~= nil
end

function SpecWeapons.SpecsForClass(classToken)
    if type(classToken) ~= "string" then
        return {}
    end
    local list = CLASS_SPECS[string.upper(classToken)]
    if not list then
        return {}
    end
    local out = {}
    for i = 1, #list do
        out[i] = list[i]
    end
    return out
end

function SpecWeapons.IsSpecValidForClass(specId, classToken)
    specId = tonumber(specId)
    if not specId then
        return false
    end
    local list = SpecWeapons.SpecsForClass(classToken)
    for i = 1, #list do
        if list[i] == specId then
            return true
        end
    end
    return false
end

function SpecWeapons.ClassForSpec(specId)
    specId = tonumber(specId)
    if not specId then
        return nil
    end
    for classToken, list in pairs(CLASS_SPECS) do
        for i = 1, #list do
            if list[i] == specId then
                return classToken
            end
        end
    end
    return nil
end

function SpecWeapons.IsRangedEquipLoc(equipLoc)
    return equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT"
end

-- Fail-closed subclass/proficiency check for another profile character.
-- Shields and holdables are slot-flag questions, not weapon-subclass questions.
function SpecWeapons.IsItemAllowedForSpec(specId, classif)
    specId = tonumber(specId)
    if not specId or type(classif) ~= "table" then
        return false
    end
    if not SpecWeapons.IsKnownSpec(specId) then
        return false
    end
    local loc = classif.equipLoc
    if loc == "INVTYPE_SHIELD" then
        return tonumber(classif.itemClass) == ITEM_CLASS_ARMOR
            and tonumber(classif.itemSubClass) == ARMOR_SHIELD
    end
    if loc == "INVTYPE_HOLDABLE" then
        return tonumber(classif.itemClass) == ITEM_CLASS_ARMOR
    end
    if classif.family ~= "weapon" and not classif.isWeaponLoc and not classif.isOffHandLoc then
        return true
    end
    local classToken = SpecWeapons.ClassForSpec(specId)
    local allowed = classToken and CLASS_WEAPON_SUBCLASS[classToken]
    local itemClass = tonumber(classif.itemClass)
    local subClass = tonumber(classif.itemSubClass)
    if not allowed or itemClass ~= ITEM_CLASS_WEAPON or subClass == nil then
        return false
    end
    return allowed[subClass] == true
end

-- GetSpecializationInfoByID returns id, name, description, icon, role, ...
-- Capture the name return, not the specialization ID.
function SpecWeapons.SpecName(specId)
    specId = tonumber(specId)
    if not specId then
        return nil
    end
    if GetSpecializationInfoByID then
        local ok, specInfoId, name = pcall(GetSpecializationInfoByID, specId)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
        if ok and type(specInfoId) == "string" and specInfoId ~= "" and not tonumber(specInfoId) then
            return specInfoId
        end
    end
    return SPEC_NAMES[specId]
end
