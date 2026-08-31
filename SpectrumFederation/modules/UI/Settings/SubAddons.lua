-- C_AddOns adapter used only by Settings Registry.
-- Enumeration and enablement functions accept an optional api table so tests
-- can inject fakes without requiring WoW.

local addonName, SF = ...

SF.SettingsSubAddons = SF.SettingsSubAddons or {}
local SubAddons = SF.SettingsSubAddons

SubAddons.PARENT_METADATA_KEY = "X-SpectrumFederation-Parent"

local function GetApi(api, name, fallback)
    if type(api) == "table" and api[name] ~= nil then
        return api[name]
    end
    return fallback
end

function SubAddons.StripParentTitlePrefix(title, parentTitle)
    if SF.SettingsNavigationModel and SF.SettingsNavigationModel.StripParentTitlePrefix then
        return SF.SettingsNavigationModel.StripParentTitlePrefix(title, parentTitle)
    end
    if type(title) ~= "string" or title == "" then
        return title or ""
    end
    parentTitle = parentTitle or "Spectrum Federation"
    local prefix = parentTitle .. ": "
    if title:sub(1, #prefix):lower() == prefix:lower() then
        local stripped = title:sub(#prefix + 1)
        if stripped ~= "" then
            return stripped
        end
    end
    return title
end

function SubAddons.MatchesParent(metadataValue, parentAddonName)
    if type(metadataValue) ~= "string" or metadataValue == "" then
        return false
    end
    if type(parentAddonName) ~= "string" or parentAddonName == "" then
        return false
    end
    return metadataValue:lower() == parentAddonName:lower()
end

local function EnabledAllValue(api)
    local enumTable = GetApi(api, "AddOnEnableState", Enum and Enum.AddOnEnableState)
    if type(enumTable) == "table" and enumTable.All ~= nil then
        return enumTable.All
    end
    return 2
end

-- Returns true/false when the character identity is known, or nil when
-- enablement cannot be resolved yet (missing GUID or missing API).
function SubAddons.IsEnabledForCharacter(childAddonName, api)
    api = api or {}
    if type(childAddonName) ~= "string" or childAddonName == "" then
        return nil
    end

    local character = api.character
    if type(character) ~= "string" or character == "" then
        local unitGUID = GetApi(api, "UnitGUID", _G.UnitGUID)
        if type(unitGUID) == "function" then
            character = unitGUID("player")
        end
    end
    if type(character) ~= "string" or character == "" then
        local unitName = GetApi(api, "UnitName", _G.UnitName)
        if type(unitName) == "function" then
            character = unitName("player")
        end
    end
    if type(character) ~= "string" or character == "" then
        return nil
    end

    local getState = GetApi(api, "GetAddOnEnableState", C_AddOns and C_AddOns.GetAddOnEnableState)
    if type(getState) ~= "function" then
        return nil
    end

    local state = getState(childAddonName, character)
    return state == EnabledAllValue(api)
end

function SubAddons.EnumerateChildren(parentAddonName, api)
    api = api or {}
    parentAddonName = parentAddonName or addonName
    local results = {}

    local getNum = GetApi(api, "GetNumAddOns", C_AddOns and C_AddOns.GetNumAddOns)
    local getName = GetApi(api, "GetAddOnName", C_AddOns and C_AddOns.GetAddOnName)
    local getInfo = GetApi(api, "GetAddOnInfo", C_AddOns and C_AddOns.GetAddOnInfo)
    local getMeta = GetApi(api, "GetAddOnMetadata", C_AddOns and C_AddOns.GetAddOnMetadata)
    if type(getNum) ~= "function" or type(getMeta) ~= "function" then
        return results
    end
    if type(getName) ~= "function" and type(getInfo) ~= "function" then
        return results
    end

    local parentTitle = getMeta(parentAddonName, "Title") or "Spectrum Federation"
    local num = getNum() or 0
    for index = 1, num do
        local name
        if type(getName) == "function" then
            name = getName(index)
        end
        if (not name or name == "") and type(getInfo) == "function" then
            name = getInfo(index)
        end
        if type(name) == "string" and name ~= "" and name:lower() ~= parentAddonName:lower() then
            local parentValue = getMeta(name, SubAddons.PARENT_METADATA_KEY)
            if SubAddons.MatchesParent(parentValue, parentAddonName) then
                local title = getMeta(name, "Title") or name
                local notes = getMeta(name, "Notes")
                table.insert(results, {
                    addonName = name,
                    title = title,
                    navLabel = SubAddons.StripParentTitlePrefix(title, parentTitle),
                    notes = notes,
                })
            end
        end
    end

    return results
end
