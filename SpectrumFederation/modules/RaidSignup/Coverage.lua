-- Raid Signup planned class/spec coverage (#404).
-- Planned capability only — not live auras or talent inspection.
local addonName, SF = ...

SF.RaidSignup = SF.RaidSignup or {}
local RS = SF.RaidSignup

RS.CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT",
    "SHAMAN", "MAGE", "WARLOCK", "MONK", "DRUID", "DEMONHUNTER", "EVOKER",
}

-- Stable Retail specialization IDs (match SpecWeapons).
RS.CLASS_SPECS = {
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

RS.SPEC_NAMES = {
    [71] = "Arms", [72] = "Fury", [73] = "Protection",
    [65] = "Holy", [66] = "Protection", [70] = "Retribution",
    [253] = "Beast Mastery", [254] = "Marksmanship", [255] = "Survival",
    [259] = "Assassination", [260] = "Outlaw", [261] = "Subtlety",
    [256] = "Discipline", [257] = "Holy", [258] = "Shadow",
    [250] = "Blood", [251] = "Frost", [252] = "Unholy",
    [262] = "Elemental", [263] = "Enhancement", [264] = "Restoration",
    [62] = "Arcane", [63] = "Fire", [64] = "Frost",
    [265] = "Affliction", [266] = "Demonology", [267] = "Destruction",
    [268] = "Brewmaster", [269] = "Windwalker", [270] = "Mistweaver",
    [102] = "Balance", [103] = "Feral", [104] = "Guardian", [105] = "Restoration",
    [577] = "Havoc", [581] = "Vengeance", [1480] = "Devourer",
    [1467] = "Devastation", [1468] = "Preservation", [1473] = "Augmentation",
}

local function AllSpecs(classFile)
    return RS.CLASS_SPECS[classFile]
end

local function SpecSet(classFile, ...)
    local allowed = {}
    local n = select("#", ...)
    for i = 1, n do
        allowed[select(i, ...)] = true
    end
    local out = {}
    local list = AllSpecs(classFile) or {}
    for i = 1, #list do
        if allowed[list[i]] then
            out[#out + 1] = list[i]
        end
    end
    return out
end

-- providers: list of { classFile = "MAGE", specs = {62,63,64} | nil for all }
-- nil specs ⇒ every known spec of that class.
local function ClassAll(classFile)
    return { classFile = classFile, specs = nil }
end

local function ClassSpecs(classFile, ...)
    return { classFile = classFile, specs = SpecSet(classFile, ...) }
end

RS.MAJOR_CATEGORIES = {
    {
        id = "intellect",
        nameKey = "RAID_SIGNUP_COV_INTELLECT",
        nameDefault = "Intellect",
        tipKey = "RAID_SIGNUP_COV_INTELLECT_TIP",
        tipDefault = "Arcane Intellect — increases raid Intellect.",
        providers = { ClassAll("MAGE") },
    },
    {
        id = "attack_power",
        nameKey = "RAID_SIGNUP_COV_ATTACK_POWER",
        nameDefault = "Attack Power",
        tipKey = "RAID_SIGNUP_COV_ATTACK_POWER_TIP",
        tipDefault = "Battle Shout — increases raid attack power.",
        providers = { ClassAll("WARRIOR") },
    },
    {
        id = "stamina",
        nameKey = "RAID_SIGNUP_COV_STAMINA",
        nameDefault = "Stamina",
        tipKey = "RAID_SIGNUP_COV_STAMINA_TIP",
        tipDefault = "Power Word: Fortitude — increases raid Stamina.",
        providers = { ClassAll("PRIEST") },
    },
    {
        id = "devo_aura",
        nameKey = "RAID_SIGNUP_COV_DEVO",
        nameDefault = "3% DR (Devo Aura)",
        tipKey = "RAID_SIGNUP_COV_DEVO_TIP",
        tipDefault = "Devotion Aura — reduces damage taken (Holy and Protection Paladin).",
        -- Retribution uses Retribution Aura instead of Devotion Aura.
        providers = { ClassSpecs("PALADIN", 65, 66) },
    },
    {
        id = "physical",
        nameKey = "RAID_SIGNUP_COV_PHYSICAL",
        nameDefault = "5% Physical",
        tipKey = "RAID_SIGNUP_COV_PHYSICAL_TIP",
        tipDefault = "Mystic Touch — increases Physical damage taken by the enemy.",
        providers = { ClassAll("MONK") },
    },
    {
        id = "magic",
        nameKey = "RAID_SIGNUP_COV_MAGIC",
        nameDefault = "3% Magic",
        tipKey = "RAID_SIGNUP_COV_MAGIC_TIP",
        tipDefault = "Chaos Brand — increases magic damage taken by the enemy.",
        providers = { ClassAll("DEMONHUNTER") },
    },
    {
        id = "versatility",
        nameKey = "RAID_SIGNUP_COV_VERS",
        nameDefault = "3% Versatility",
        tipKey = "RAID_SIGNUP_COV_VERS_TIP",
        tipDefault = "Mark of the Wild — increases raid Versatility.",
        providers = { ClassAll("DRUID") },
    },
}

RS.UTILITY_CATEGORIES = {
    {
        id = "bloodlust",
        nameKey = "RAID_SIGNUP_COV_BLOODLUST",
        nameDefault = "Bloodlust",
        tipKey = "RAID_SIGNUP_COV_BLOODLUST_TIP",
        tipDefault = "Bloodlust / Heroism / Time Warp / Primal Rage / Fury of the Aspects.",
        providers = {
            ClassAll("SHAMAN"), ClassAll("MAGE"), ClassAll("HUNTER"), ClassAll("EVOKER"),
        },
    },
    {
        id = "combat_res",
        nameKey = "RAID_SIGNUP_COV_BATTLE_RES",
        nameDefault = "Combat Res",
        tipKey = "RAID_SIGNUP_COV_BATTLE_RES_TIP",
        tipDefault = "Combat resurrection (Rebirth, Raise Ally, Soulstone, Intercession).",
        providers = {
            ClassAll("DRUID"), ClassAll("DEATHKNIGHT"), ClassAll("WARLOCK"), ClassAll("PALADIN"),
        },
    },
    {
        id = "burst_move",
        nameKey = "RAID_SIGNUP_COV_BURST_MOVE",
        nameDefault = "Burst Move Speed",
        tipKey = "RAID_SIGNUP_COV_BURST_MOVE_TIP",
        tipDefault = "Planned burst movement tools (for example Stampeding Roar, Wind Rush Totem, Tiger's Lust).",
        providers = { ClassAll("DRUID"), ClassAll("SHAMAN"), ClassAll("MONK") },
    },
    {
        id = "lock_stuff",
        nameKey = "RAID_SIGNUP_COV_LOCK",
        nameDefault = "Lock Stuff (HS, Gate, Curse)",
        tipKey = "RAID_SIGNUP_COV_LOCK_TIP",
        tipDefault = "Warlock Healthstone, Demonic Gateway, and curses.",
        providers = { ClassAll("WARLOCK") },
    },
    {
        id = "mass_dispel",
        nameKey = "RAID_SIGNUP_COV_MD",
        nameDefault = "Mass Dispel",
        tipKey = "RAID_SIGNUP_COV_MD_TIP",
        tipDefault = "Mass Dispel — removes many harmful magic effects at once.",
        providers = { ClassAll("PRIEST") },
    },
    {
        id = "innervate",
        nameKey = "RAID_SIGNUP_COV_INNERVATE",
        nameDefault = "Innervate",
        tipKey = "RAID_SIGNUP_COV_INNERVATE_TIP",
        tipDefault = "Innervate — Restoration Druid mana acceleration for a healer.",
        providers = { ClassSpecs("DRUID", 105) },
    },
    {
        id = "dk_grip_amz",
        nameKey = "RAID_SIGNUP_COV_DK",
        nameDefault = "Death Grip/AMZ",
        tipKey = "RAID_SIGNUP_COV_DK_TIP",
        tipDefault = "Death Grip and Anti-Magic Zone from Death Knights.",
        providers = { ClassAll("DEATHKNIGHT") },
    },
    {
        id = "bop",
        nameKey = "RAID_SIGNUP_COV_BOP",
        nameDefault = "Blessing of Protection",
        tipKey = "RAID_SIGNUP_COV_BOP_TIP",
        tipDefault = "Blessing of Protection — physical immunity blessing.",
        providers = { ClassAll("PALADIN") },
    },
    {
        id = "rally",
        nameKey = "RAID_SIGNUP_COV_RALLY",
        nameDefault = "Rallying Cry",
        tipKey = "RAID_SIGNUP_COV_RALLY_TIP",
        tipDefault = "Rallying Cry — temporary raid health increase.",
        providers = { ClassAll("WARRIOR") },
    },
    {
        id = "darkness",
        nameKey = "RAID_SIGNUP_COV_DARKNESS",
        nameDefault = "Darkness",
        tipKey = "RAID_SIGNUP_COV_DARKNESS_TIP",
        tipDefault = "Darkness — Demon Hunter area damage reduction.",
        providers = { ClassAll("DEMONHUNTER") },
    },
    {
        id = "immunities",
        nameKey = "RAID_SIGNUP_COV_IMMUNE",
        nameDefault = "Immunities",
        tipKey = "RAID_SIGNUP_COV_IMMUNE_TIP",
        tipDefault = "Full damage immunities such as Ice Block, Divine Shield, and Aspect of the Turtle.",
        providers = { ClassAll("MAGE"), ClassAll("PALADIN"), ClassAll("HUNTER") },
    },
    {
        id = "skyfury",
        nameKey = "RAID_SIGNUP_COV_SKYFURY",
        nameDefault = "Skyfury",
        tipKey = "RAID_SIGNUP_COV_SKYFURY_TIP",
        tipDefault = "Skyfury — Mastery and empowered auto-attacks for the raid.",
        providers = { ClassAll("SHAMAN") },
    },
    {
        id = "atrophic_poison",
        nameKey = "RAID_SIGNUP_COV_ATROPHIC",
        nameDefault = "Atrophic Poison",
        tipKey = "RAID_SIGNUP_COV_ATROPHIC_TIP",
        tipDefault = "Atrophic Poison — reduces damage dealt by the affected enemy.",
        providers = { ClassAll("ROGUE") },
    },
    {
        id = "blessing_bronze",
        nameKey = "RAID_SIGNUP_COV_BRONZE",
        nameDefault = "Blessing of the Bronze",
        tipKey = "RAID_SIGNUP_COV_BRONZE_TIP",
        tipDefault = "Blessing of the Bronze — reduces major movement-ability cooldowns for the raid.",
        providers = { ClassAll("EVOKER") },
    },
    {
        id = "execute",
        nameKey = "RAID_SIGNUP_COV_EXECUTE",
        nameDefault = "Execute Damage",
        tipKey = "RAID_SIGNUP_COV_EXECUTE_TIP",
        tipDefault = "Execute-range finishing damage such as Execute or Kill Shot.",
        providers = { ClassAll("WARRIOR"), ClassAll("HUNTER") },
    },
    {
        id = "atk_speed_slow",
        nameKey = "RAID_SIGNUP_COV_ATK_SLOW",
        nameDefault = "Attack Speed Reduction",
        tipKey = "RAID_SIGNUP_COV_ATK_SLOW_TIP",
        tipDefault = "Attack-speed reduction such as Numbing Poison.",
        providers = { ClassAll("ROGUE") },
    },
    {
        id = "cast_speed_slow",
        nameKey = "RAID_SIGNUP_COV_CAST_SLOW",
        nameDefault = "Cast Speed Reduction",
        tipKey = "RAID_SIGNUP_COV_CAST_SLOW_TIP",
        tipDefault = "Cast-speed reduction such as Curse of Tongues or Numbing Poison.",
        providers = { ClassAll("WARLOCK"), ClassAll("ROGUE") },
    },
}

local function NormalizeClass(classFile)
    if type(classFile) ~= "string" or classFile == "" then
        return nil
    end
    return string.upper(classFile)
end

function RS.IsKnownClass(classFile)
    classFile = NormalizeClass(classFile)
    return classFile and RS.CLASS_SPECS[classFile] ~= nil
end

function RS.IsValidSpecForClass(classFile, specId)
    classFile = NormalizeClass(classFile)
    specId = tonumber(specId)
    if not classFile or not specId then
        return false
    end
    local list = RS.CLASS_SPECS[classFile]
    if not list then
        return false
    end
    for i = 1, #list do
        if list[i] == specId then
            return true
        end
    end
    return false
end

function RS.SpecDisplayName(specId)
    specId = tonumber(specId)
    if not specId then
        return nil
    end
    if GetSpecializationInfoByID then
        local ok, _, name = pcall(GetSpecializationInfoByID, specId)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return RS.SPEC_NAMES[specId]
end

function RS.ClassIconTexture(classFile)
    classFile = NormalizeClass(classFile)
    local data = classFile and SF.WOW_CLASSES and SF.WOW_CLASSES[classFile]
    return data and data.textureFile or "Interface\\Icons\\INV_Misc_QuestionMark"
end

function RS.SpecIconTexture(specId)
    specId = tonumber(specId)
    if not specId then
        return "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    if GetSpecializationInfoByID then
        local ok, _, _, icon = pcall(GetSpecializationInfoByID, specId)
        if ok and type(icon) == "string" and icon ~= "" then
            return icon
        end
        if ok and type(icon) == "number" then
            return icon
        end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function ProviderMatches(provider, classFile, specId)
    if not provider or provider.classFile ~= classFile then
        return false
    end
    if provider.specs == nil then
        return true
    end
    specId = tonumber(specId)
    if not specId then
        return false
    end
    for i = 1, #provider.specs do
        if provider.specs[i] == specId then
            return true
        end
    end
    return false
end

function RS.CategoryCoveredBySelection(category, classFile, specId)
    if type(category) ~= "table" or type(category.providers) ~= "table" then
        return false
    end
    classFile = NormalizeClass(classFile)
    if not classFile or not RS.IsValidSpecForClass(classFile, specId) then
        return false
    end
    for i = 1, #category.providers do
        if ProviderMatches(category.providers[i], classFile, specId) then
            return true
        end
    end
    return false
end

--- Build class counts + coverage from completed MAIN selections only.
-- entries: iterable of { mainClass, mainSpec, deleted? }
function RS.BuildSummary(entries)
    local counts = {}
    for i = 1, #RS.CLASS_ORDER do
        counts[RS.CLASS_ORDER[i]] = 0
    end

    local function markCategories(list, covered)
        for i = 1, #list do
            local cat = list[i]
            covered[cat.id] = false
        end
    end

    local majorCovered = {}
    local utilityCovered = {}
    markCategories(RS.MAJOR_CATEGORIES, majorCovered)
    markCategories(RS.UTILITY_CATEGORIES, utilityCovered)

    if type(entries) == "table" then
        for _, entry in pairs(entries) do
            if type(entry) == "table" and not entry.deleted then
                local classFile = NormalizeClass(entry.mainClass)
                local specId = tonumber(entry.mainSpec)
                if classFile and counts[classFile] ~= nil and RS.IsValidSpecForClass(classFile, specId) then
                    counts[classFile] = counts[classFile] + 1
                    for i = 1, #RS.MAJOR_CATEGORIES do
                        local cat = RS.MAJOR_CATEGORIES[i]
                        if not majorCovered[cat.id]
                            and RS.CategoryCoveredBySelection(cat, classFile, specId) then
                            majorCovered[cat.id] = true
                        end
                    end
                    for i = 1, #RS.UTILITY_CATEGORIES do
                        local cat = RS.UTILITY_CATEGORIES[i]
                        if not utilityCovered[cat.id]
                            and RS.CategoryCoveredBySelection(cat, classFile, specId) then
                            utilityCovered[cat.id] = true
                        end
                    end
                end
            end
        end
    end

    return {
        classCounts = counts,
        major = majorCovered,
        utility = utilityCovered,
    }
end
