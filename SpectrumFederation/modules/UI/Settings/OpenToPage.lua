-- modules/UI/Settings/OpenToPage.lua
local _, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI._categoryIdByPageId = UI._categoryIdByPageId or {}

function UI:RegisterPageCategory(pageId, categoryOrId)
    if type(pageId) ~= "string" or pageId == "" then return false end

    -- store numeric ID directly
    if type(categoryOrId) == "number" then
        UI._categoryIdByPageId[pageId] = categoryOrId
        return true
    end

    -- store category object's ID
    if type(categoryOrId) == "table" then
        if categoryOrId.GetID then
            self._categoryIdByPageId[pageId] = categoryOrId:GetID()
            return true
        elseif categoryOrId.ID then
            self._categoryIdByPageId[pageId] = categoryOrId.ID
            return true
        end
    end

    return false
end

function UI:GetPageCategoryId(pageId)
    return self._categoryIdByPageId and self._categoryIdByPageId[pageId] or nil
end

function UI:OpenToPage(pageId)
    if not Settings or not Settings.OpenToCategory then
        return false
    end

    local id = self:GetPageCategoryId(pageId)
    if id then
        Settings.OpenToCategory(id)
        return true
    end

    -- Fallback: open root addon category
    if SF.SettingsCategory and SF.SettingsCategory.GetID then
        Settings.OpenToCategory(SF.SettingsCategory:GetID())
        return true
    end

    return false
end