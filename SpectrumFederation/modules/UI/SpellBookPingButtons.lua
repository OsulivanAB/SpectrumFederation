local _, SF = ...

SF.SpellBookPingButtons = SF.SpellBookPingButtons or {}

local SpellBookPingButtons = SF.SpellBookPingButtons

local BLIZZARD_PLAYER_SPELLS = "Blizzard_PlayerSpells"
local PANEL_WIDTH = 308
local PANEL_HEIGHT = 86
local BUTTON_WIDTH = 56
local BUTTON_HEIGHT = 52
local BUTTON_SPACING = 4
local MACRO_ICON = QUESTION_MARK_ICON or [[Interface/Icons/INV_Misc_QuestionMark]]

-- Macro names must stay within WoW's 16-character macro name limit.
local PING_DEFINITIONS = {
    {
        id = "attack",
        label = "Attack Ping",
        buttonLabel = "Attack",
        atlas = "ping_chat_attack",
        macroName = "SF Attack Ping",
        macroBody = "/ping 1",
    },
    {
        id = "assist",
        label = "Assist Ping",
        buttonLabel = "Assist",
        atlas = "ping_chat_assist",
        macroName = "SF Assist Ping",
        macroBody = "/ping 4",
    },
    {
        id = "onmyway",
        label = "On My Way Ping",
        buttonLabel = "On My\nWay",
        atlas = "ping_chat_onmyway",
        macroName = "SF OnMyWayPing",
        macroBody = "/ping 3",
    },
    {
        id = "warning",
        label = "Warning Ping",
        buttonLabel = "Warning",
        atlas = "ping_chat_warning",
        macroName = "SF Warning Ping",
        macroBody = "/ping 2",
    },
    {
        id = "nonthreat",
        label = "Non-Threat Ping",
        buttonLabel = "Non-\nThreat",
        atlas = "ping_chat_nonthreat",
        macroName = "SF NonThreat",
        macroBody = "/ping 5",
    },
}

local function GetGeneralCategoryEnum()
    if PlayerSpellsUtil and PlayerSpellsUtil.SpellBookCategories then
        return PlayerSpellsUtil.SpellBookCategories.General
    end

    return nil
end

local function IsGeneralCategoryActive(spellBookFrame)
    if not spellBookFrame or not spellBookFrame.GetActiveCategoryMixin then
        return false
    end

    if spellBookFrame:IsInSearchResultsMode() then
        return false
    end

    local searchBox = spellBookFrame.SearchBox
    if searchBox and searchBox:GetText() and searchBox:GetText() ~= "" then
        return false
    end

    local generalCategoryEnum = GetGeneralCategoryEnum()
    if spellBookFrame.IsCategoryActive and generalCategoryEnum ~= nil then
        return spellBookFrame:IsCategoryActive(generalCategoryEnum)
    end

    local activeCategoryMixin = spellBookFrame:GetActiveCategoryMixin()
    if not activeCategoryMixin or not activeCategoryMixin.GetCategoryEnum then
        return false
    end

    local activeCategoryEnum = activeCategoryMixin:GetCategoryEnum()
    if generalCategoryEnum ~= nil then
        return activeCategoryEnum == generalCategoryEnum
    end

    local activeCategoryName = activeCategoryMixin.GetName and activeCategoryMixin:GetName() or activeCategoryMixin.displayName
    return activeCategoryName == GENERAL_SPELLS
end

local function FindMacroByName(name)
    local numAccountMacros, numCharacterMacros = GetNumMacros()

    for index = 1, numAccountMacros do
        if GetMacroInfo(index) == name then
            return index, false
        end
    end

    for characterIndex = 1, numCharacterMacros do
        local index = MAX_ACCOUNT_MACROS + characterIndex
        if GetMacroInfo(index) == name then
            return index, true
        end
    end

    return nil
end

local function SetButtonEnabled(button, enabled)
    button:SetEnabled(enabled)
    button:SetAlpha(enabled and 1 or 0.45)
end

local function IsAddOnLoadedSafe(addOnName)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded(addOnName)
    end

    if SF and SF.Debug and SF.Debug.Warn then
        SF.Debug:Warn("SPELLBOOK_PINGS", "C_AddOns.IsAddOnLoaded unavailable while checking %s", tostring(addOnName))
    end

    return false
end

function SpellBookPingButtons:Debug(level, message, ...)
    if not SF.Debug or not SF.Debug[level] then
        return
    end

    SF.Debug[level](SF.Debug, "SPELLBOOK_PINGS", message, ...)
end

function SpellBookPingButtons:BuildTooltipText(data, disabled)
    local text = string.format("Creates or updates the %s macro for your cursor location.", data.label)

    if disabled then
        return text .. "\n\nUnavailable in combat."
    end

    return text .. "\n\nIf your cursor is free, the macro is picked up so you can drag it onto an action bar."
end

function SpellBookPingButtons:ShowTooltip(button)
    local data = button.SFData
    if not data then
        return
    end

    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(data.label, 1, 1, 1)
    GameTooltip:AddLine(self:BuildTooltipText(data, not button:IsEnabled()), nil, nil, nil, true)
    GameTooltip:Show()
end

function SpellBookPingButtons:HideTooltip()
    GameTooltip:Hide()
end

function SpellBookPingButtons:EnsureMacro(data)
    local updated = false
    local isCharacterMacro = false

    local index
    index, isCharacterMacro = FindMacroByName(data.macroName)
    if index then
        local _, currentIcon, currentBody = GetMacroInfo(index)
        updated = currentIcon ~= MACRO_ICON or currentBody ~= data.macroBody
        if updated then
            EditMacro(index, data.macroName, MACRO_ICON, data.macroBody)
        end

        return index, false, updated, isCharacterMacro, nil
    end

    local numAccountMacros, numCharacterMacros = GetNumMacros()
    if numAccountMacros >= MAX_ACCOUNT_MACROS and numCharacterMacros >= MAX_CHARACTER_MACROS then
        return nil, false, false, false, "Both account and character macro slots are full. Delete an unused macro to create this SpellBook ping macro."
    end

    isCharacterMacro = numAccountMacros >= MAX_ACCOUNT_MACROS
    index = CreateMacro(data.macroName, MACRO_ICON, data.macroBody, isCharacterMacro)
    if not index then
        return nil, false, false, false, string.format("Failed to create the '%s' macro.", data.macroName)
    end

    return index, true, false, isCharacterMacro, nil
end

function SpellBookPingButtons:PickupMacroIfPossible(index)
    if GetCursorInfo() then
        return false
    end

    PickupMacro(index)
    return true
end

function SpellBookPingButtons:HandleButtonClick(button)
    if InCombatLockdown() then
        SF:PrintWarning("SpellBook ping macros cannot be created or updated during combat.")
        return
    end

    local data = button and button.SFData
    if not data then
        return
    end

    local index, created, updated, isCharacterMacro, err = self:EnsureMacro(data)
    if not index then
        SF:PrintError(err or string.format("Unable to create %s.", data.label))
        return
    end

    local pickedUp = self:PickupMacroIfPossible(index)
    local scopeText = isCharacterMacro and "character" or "account"
    local actionText = "Prepared"
    if created then
        actionText = "Created"
    elseif updated then
        actionText = "Updated"
    end
    local message = string.format("%s %s (%s macro).", actionText, data.label, scopeText)

    if pickedUp then
        SF:PrintSuccess(message .. " It is now on your cursor.")
    else
        SF:PrintInfo(message .. " Your cursor was already occupied, so it was not picked up.")
    end

    self:Debug("Info", "%s macro handled via SpellBook button", data.id)
end

function SpellBookPingButtons:CreateButton(parent, data, index)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
    button.SFData = data

    if index == 1 then
        button:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -24)
    else
        button:SetPoint("LEFT", parent.Buttons[index - 1], "RIGHT", BUTTON_SPACING, 0)
    end

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true,
        tileSize = 8,
        edgeSize = 1,
    })
    button:SetBackdropColor(0.08, 0.08, 0.08, 0.55)
    button:SetBackdropBorderColor(0.67, 0.56, 0.28, 0.85)
    button:SetMotionScriptsWhileDisabled(true)
    button:RegisterForClicks("LeftButtonUp")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("TOP", button, "TOP", 0, -6)
    icon:SetAtlas(data.atlas, true)
    button.Icon = icon

    local label = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("TOP", icon, "BOTTOM", 0, -2)
    label:SetWidth(BUTTON_WIDTH - 6)
    label:SetJustifyH("CENTER")
    label:SetText(data.buttonLabel)
    button.Label = label

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(button)
    highlight:SetColorTexture(1, 1, 1, 0.12)
    button.Highlight = highlight

    button:SetScript("OnClick", function(clickedButton)
        self:HandleButtonClick(clickedButton)
    end)
    button:SetScript("OnEnter", function(hoveredButton)
        self:ShowTooltip(hoveredButton)
    end)
    button:SetScript("OnLeave", function()
        self:HideTooltip()
    end)

    return button
end

function SpellBookPingButtons:EnsurePanel(spellBookFrame)
    if not spellBookFrame then
        return nil
    end

    if spellBookFrame.SFSpellBookPingPanel then
        return spellBookFrame.SFSpellBookPingPanel
    end

    if InCombatLockdown() then
        self.pendingRefresh = true
        return nil
    end

    local panel = CreateFrame("Frame", nil, spellBookFrame, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    panel:SetFrameStrata(spellBookFrame:GetFrameStrata())
    panel:SetFrameLevel(spellBookFrame:GetFrameLevel() + 5)
    panel.Buttons = {}

    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    panel:SetBackdropColor(0.04, 0.04, 0.04, 0.72)
    panel:SetBackdropBorderColor(0.55, 0.45, 0.23, 0.75)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 11, -9)
    title:SetText("Ping Macros")
    panel.Title = title

    for index, data in ipairs(PING_DEFINITIONS) do
        panel.Buttons[index] = self:CreateButton(panel, data, index)
    end

    spellBookFrame.SFSpellBookPingPanel = panel
    self:Debug("Info", "Created SpellBook ping macro panel")
    return panel
end

function SpellBookPingButtons:RefreshButtonState(panel)
    if not panel then
        return
    end

    local enabled = not InCombatLockdown()
    for _, button in ipairs(panel.Buttons) do
        SetButtonEnabled(button, enabled)
    end
end

function SpellBookPingButtons:LayoutPanel(spellBookFrame, panel)
    if not spellBookFrame or not panel or not spellBookFrame.SearchBox then
        return
    end

    panel:ClearAllPoints()
    panel:SetPoint("TOPRIGHT", spellBookFrame.SearchBox, "BOTTOMRIGHT", -2, -8)
end

function SpellBookPingButtons:Refresh(spellBookFrame)
    spellBookFrame = spellBookFrame or self.spellBookFrame
    if not spellBookFrame then
        return
    end

    local panel = self:EnsurePanel(spellBookFrame)
    if not panel then
        return
    end

    self:LayoutPanel(spellBookFrame, panel)
    self:RefreshButtonState(panel)

    local shouldShow = spellBookFrame:IsShown() and IsGeneralCategoryActive(spellBookFrame)
    panel:SetShown(shouldShow)
end

function SpellBookPingButtons:HandleCombatStateChange(inCombat)
    if inCombat then
        self:RefreshButtonState(self.spellBookFrame and self.spellBookFrame.SFSpellBookPingPanel)
        return
    end

    if self.pendingRefresh then
        self.pendingRefresh = false
        self:Refresh(self.spellBookFrame)
        return
    end

    self:RefreshButtonState(self.spellBookFrame and self.spellBookFrame.SFSpellBookPingPanel)
end

function SpellBookPingButtons:SetupSpellBookHooks()
    if self.hooksInstalled then
        return true
    end

    if not PlayerSpellsFrame or not PlayerSpellsFrame.SpellBookFrame or not SpellBookFrameMixin then
        self:Debug("Warn", "SpellBook frame not ready when installing ping hooks")
        return false
    end

    self.spellBookFrame = PlayerSpellsFrame.SpellBookFrame

    hooksecurefunc(SpellBookFrameMixin, "OnShow", function(frame)
        self:Refresh(frame)
    end)

    hooksecurefunc(SpellBookFrameMixin, "OnHide", function(frame)
        if frame.SFSpellBookPingPanel then
            frame.SFSpellBookPingPanel:Hide()
        end
    end)

    hooksecurefunc(SpellBookFrameMixin, "OnActiveCategoryChanged", function(frame)
        self:Refresh(frame)
    end)

    hooksecurefunc(SpellBookFrameMixin, "ResizeSearchBox", function(frame)
        self:Refresh(frame)
    end)

    if self.spellBookFrame.SearchBox then
        self.spellBookFrame.SearchBox:HookScript("OnTextChanged", function()
            self:Refresh(self.spellBookFrame)
        end)
    end

    self.hooksInstalled = true
    self:Debug("Info", "Installed SpellBook ping macro hooks")
    return true
end

function SpellBookPingButtons:TrySetupSpellBookHooksAndRefresh()
    if not self:SetupSpellBookHooks() then
        return false
    end

    self:Refresh(self.spellBookFrame)
    return true
end

function SpellBookPingButtons:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddonName = ...
        if loadedAddonName == BLIZZARD_PLAYER_SPELLS then
            if self:TrySetupSpellBookHooksAndRefresh() then
                self.eventFrame:UnregisterEvent("ADDON_LOADED")
            end
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        self:HandleCombatStateChange(true)
    elseif event == "PLAYER_REGEN_ENABLED" then
        self:HandleCombatStateChange(false)
    end
end

function SpellBookPingButtons:Initialize()
    if self.initialized then
        return
    end

    self.initialized = true
    self.eventFrame = CreateFrame("Frame")
    self.eventFrame:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)
    self.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    self.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

    local shouldWaitForPlayerSpells = not (IsAddOnLoadedSafe(BLIZZARD_PLAYER_SPELLS) and self:TrySetupSpellBookHooksAndRefresh())

    if shouldWaitForPlayerSpells then
        self.eventFrame:RegisterEvent("ADDON_LOADED")
    end

    self:Debug("Info", "Initialized SpellBook ping macro module")
end
