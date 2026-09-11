-- Spec-keyed weapon compatibility. Unknown specId means do not guess.
-- luacheck: globals GetSpecializationInfoByID

local addonName, SF = ...

SF.LootHelperBis = SF.LootHelperBis or {}
local SpecWeapons = {}
SF.LootHelperBis.SpecWeapons = SpecWeapons

-- Conservative Retail Midnight flags. Omitted specId => unknown compatibility.
local FLAGS = {
    -- Warrior
    [71] = { canDualWield1H = false, canDualWield2H = false, offHandShield = true, offHandHoldable = false, offHandWeapon = false }, -- Arms
    [72] = { canDualWield1H = true, canDualWield2H = true, offHandShield = false, offHandHoldable = false, offHandWeapon = true }, -- Fury
    [73] = { canDualWield1H = false, canDualWield2H = false, offHandShield = true, offHandHoldable = false, offHandWeapon = false }, -- Protection
    -- Paladin
    [65] = { canDualWield1H = false, canDualWield2H = false, offHandShield = true, offHandHoldable = true, offHandWeapon = false }, -- Holy
    [66] = { canDualWield1H = false, canDualWield2H = false, offHandShield = true, offHandHoldable = false, offHandWeapon = false }, -- Protection
    [70] = { canDualWield1H = false, canDualWield2H = false, offHandShield = true, offHandHoldable = false, offHandWeapon = false }, -- Retribution
    -- Hunter
    [253] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Beast Mastery
    [254] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Marksmanship
    [255] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Survival
    -- Rogue
    [259] = { canDualWield1H = true, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = true },
    [260] = { canDualWield1H = true, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = true },
    [261] = { canDualWield1H = true, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = true },
    -- Priest
    [256] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    [257] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    [258] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    -- Death Knight
    [250] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Blood
    [251] = { canDualWield1H = true, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = true }, -- Frost
    [252] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Unholy
    -- Shaman
    [262] = { canDualWield1H = false, canDualWield2H = false, offHandShield = true, offHandHoldable = true, offHandWeapon = false }, -- Elemental
    [263] = { canDualWield1H = true, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = true }, -- Enhancement
    [264] = { canDualWield1H = false, canDualWield2H = false, offHandShield = true, offHandHoldable = true, offHandWeapon = false }, -- Restoration
    -- Mage
    [62] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    [63] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    [64] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    -- Warlock
    [265] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    [266] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    [267] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    -- Monk
    [268] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Brewmaster
    [269] = { canDualWield1H = true, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = true }, -- Windwalker
    [270] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false }, -- Mistweaver
    -- Druid
    [102] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false }, -- Balance
    [103] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Feral
    [104] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Guardian
    [105] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false }, -- Restoration
    -- Demon Hunter
    [577] = { canDualWield1H = true, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = true }, -- Havoc
    [581] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = false, offHandWeapon = false }, -- Vengeance
    -- Evoker
    [1467] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    [1468] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
    [1473] = { canDualWield1H = false, canDualWield2H = false, offHandShield = false, offHandHoldable = true, offHandWeapon = false },
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
    DEMONHUNTER = { 577, 581 },
    EVOKER = { 1467, 1468, 1473 },
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

function SpecWeapons.SpecName(specId)
    specId = tonumber(specId)
    if not specId then
        return nil
    end
    if GetSpecializationInfoByID then
        local ok, name = pcall(GetSpecializationInfoByID, specId)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return nil
end
