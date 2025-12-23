-- Grab the namespace
local addonName, SF = ...

-- Helper Function to update the dropdown's text to match the database
-- Bug: When you delete a profile it does not change the dropdown text to "Select a Profile...", it still shows the old profile name until you click on the dropdown. Probably a UI refresh issue.
function SF:UpdateLootProfileDropdownText()

    if SF.Debug then SF.Debug:Verbose("UI", "Updating Loot Profile Dropdown Text") end
    print("Updating Loot Profile Dropdown Text...")

    -- Ensure the dropdown exists before trying to talk to it
    if not SF.LootProfileDropdown then
        if SF.Debug then SF.Debug:Error("UI", "UpdateLootProfileDropdownText failed: LootProfileDropdown not found") end
        print("|cFFFF0000" .. addonName .. "|r: LootProfileDropdown not found.")
        return
    end

    local currentProfile = SF.lootHelperDB.activeLootProfile
    if currentProfile then
        SF.LootProfileDropdown.Text:SetText(currentProfile)
        if SF.LootProfileDeleteButton then SF.LootProfileDeleteButton:Show() end
    else
        SF.LootProfileDropdown.Text:SetText("Select a Profile...")
        if SF.LootProfileDeleteButton then SF.LootProfileDeleteButton:Hide() end
    end
end

-- Creates the Loot Helper section in the settings panel
function SF:CreateLootHelperSection(panel, anchorFrame)
    -- Subtitle with horizontal lines
    local subTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    subTitle:SetPoint("TOP", anchorFrame, "BOTTOM", 0, -20)
    subTitle:SetText("Loot Helper")
    
    local leftLine = panel:CreateTexture(nil, "ARTWORK")
    leftLine:SetColorTexture(0.5, 0.5, 0.5, 1)  -- Gray line
    leftLine:SetPoint("RIGHT", subTitle, "LEFT", -10, 0)
    leftLine:SetHeight(1)
    
    local rightLine = panel:CreateTexture(nil, "ARTWORK")
    rightLine:SetColorTexture(0.5, 0.5, 0.5, 1)  -- Gray line
    rightLine:SetPoint("LEFT", subTitle, "RIGHT", 10, 0)
    rightLine:SetHeight(1)
    
    -- Function to update subtitle line widths
    local function UpdateSubtitleLines()
        local panelWidth = panel:GetWidth()
        if panelWidth and panelWidth > 0 then
            local totalWidth = panelWidth * 0.90
            local textWidth = subTitle:GetStringWidth()
            local lineWidth = (totalWidth - textWidth - 20) / 2  -- 20 is the total gap (10 on each side)
            if lineWidth > 0 then
                leftLine:SetWidth(lineWidth)
                rightLine:SetWidth(lineWidth)
            end
        end
    end
    
    -- Update subtitle lines when panel size changes
    local oldOnSizeChanged = panel:GetScript("OnSizeChanged")
    panel:SetScript("OnSizeChanged", function(self, width, height)
        if oldOnSizeChanged then oldOnSizeChanged(self, width, height) end
        UpdateSubtitleLines()
    end)
    
    -- Initial update for subtitle lines
    C_Timer.After(0.15, function()
        if panel:IsShown() then
            UpdateSubtitleLines()
        end
    end)

    -- Enable/Disable Loot Helper Checkbox
    local enableCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    enableCheckbox:SetPoint("TOPLEFT", subTitle, "BOTTOMLEFT", 0, -20)
    enableCheckbox:SetSize(24, 24)
    
    -- Checkbox Label
    local enableLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    enableLabel:SetPoint("LEFT", enableCheckbox, "RIGHT", 5, 0)
    enableLabel:SetText("Enable Loot Helper")
    
    -- Initialize checkbox state from database
    if SF.lootHelperDB and SF.lootHelperDB.windowSettings then
        enableCheckbox:SetChecked(SF.lootHelperDB.windowSettings.enabled)
    end
    
    -- OnClick handler
    enableCheckbox:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()
        
        -- Update database and frame visuals
        if SF.LootWindow and SF.LootWindow.SetEnabled then
            SF.LootWindow:SetEnabled(enabled)
        else
            -- Fallback if LootWindow not yet loaded
            if SF.lootHelperDB and SF.lootHelperDB.windowSettings then
                SF.lootHelperDB.windowSettings.enabled = enabled
            end
            if SF.Debug then
                SF.Debug:Info("LOOT_HELPER", "Loot Helper %s (window not yet created)", enabled and "enabled" or "disabled")
            end
        end
        
        -- Print feedback to user
        print("|cFF00FF00" .. addonName .. "|r: Loot Helper " .. (enabled and "enabled" or "disabled") .. ".")
    end)

    -- Label for the Dropdown
    local profileLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    profileLabel:SetPoint("TOPLEFT", enableCheckbox, "BOTTOMLEFT", 0, -20)
    profileLabel:SetText("Select Active Profile:")

    -- Dropdown for selecting active profile
    local LootProfileDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    LootProfileDropdown:SetPoint("LEFT", profileLabel, "RIGHT", 10, 0)  -- Place it to the right of the label
    LootProfileDropdown:SetWidth(200)

    LootProfileDropdown.UpdateText = function()
        SF:UpdateLootProfileDropdownText()
    end

    -- Populate the dropdown with profile names
    LootProfileDropdown:SetupMenu(function(dropdown, rootDescription)
       
        rootDescription:CreateTitle("Available Profiles")

        -- Sort the keys by modified descending
        local sortedNames = {}
        for profileName, _ in pairs(SF.lootHelperDB.lootProfiles) do
            table.insert(sortedNames, profileName)
        end
        table.sort(sortedNames, function(a, b)
            local timeA = SF.lootHelperDB.lootProfiles[a].modified or 0
            local timeB = SF.lootHelperDB.lootProfiles[b].modified or 0
            return timeA > timeB
        end)

        -- Generate the buttons
        for _, profileName in ipairs(sortedNames) do
            rootDescription:CreateButton(profileName, function()
                -- When clicked, tell the backend to switch profiles
                SF:SetActiveLootProfile(profileName)
            end)
        end

        if #sortedNames == 0 then
            local btn = rootDescription:CreateButton("No Profiles Found", function() end)
            btn:SetEnabled(false)
        end
    end)

    -- Store the dropdown in our namespace for later use
    SF.LootProfileDropdown = LootProfileDropdown

    -- Delete Button for active profile
    local deleteProfileBtn = CreateFrame("Button", nil, panel)
    deleteProfileBtn:SetSize(20, 20)
    deleteProfileBtn:SetPoint("LEFT", LootProfileDropdown, "RIGHT", 5, 0)

    -- Set the icon texture
    deleteProfileBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    deleteProfileBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
    deleteProfileBtn:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")

    -- Tooltip to explain what the button does
    deleteProfileBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Delete Active Profile", 1, 0, 0)   -- Red text
        GameTooltip:Show()
    end)
    deleteProfileBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- logic to delete
    deleteProfileBtn:SetScript("OnClick", function()
        if SF.lootHelperDB.activeLootProfile then
            if SF.Debug then SF.Debug:Info("UI", "User clicked delete button for profile '%s'", SF.lootHelperDB.activeLootProfile) end
            SF:DeleteProfile(SF.lootHelperDB.activeLootProfile)
        else
            if SF.Debug then SF.Debug:Warn("UI", "User clicked delete button but no active profile exists") end
            print("|cFFFF0000" .. addonName .. "|r: No active profile to delete.")
        end
    end)

    SF.LootProfileDeleteButton = deleteProfileBtn

    SF:UpdateLootProfileDropdownText()

    -- Create new profile section
    local createLootProfileLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    createLootProfileLabel:SetPoint("TOPLEFT", profileLabel, "BOTTOMLEFT", 0, -40)
    createLootProfileLabel:SetText("Create New Profile:")

    -- Input Box for new profile name
    local newLootProfileInputBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    newLootProfileInputBox:SetPoint("TOPLEFT", createLootProfileLabel, "BOTTOMLEFT", 0, -10)
    newLootProfileInputBox:SetSize(200, 30)
    newLootProfileInputBox:SetAutoFocus(false)
    newLootProfileInputBox:SetTextInsets(8, 8, 0, 0)   -- Padding

    -- Create Button for new loot profile
    local createLootProfileBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    createLootProfileBtn:SetPoint("LEFT", newLootProfileInputBox, "RIGHT", 10, 0)
    createLootProfileBtn:SetSize(100, 25)
    createLootProfileBtn:SetText("Create")
    createLootProfileBtn:SetScript("OnClick", function()

        local text = newLootProfileInputBox:GetText()

        -- Input Validation
        if text == "" then
            if SF.Debug then SF.Debug:Warn("UI", "User attempted to create profile with empty name") end
            print("|cFFFF0000" .. addonName .. "|r: Profile name cannot be empty.")
            return
        end

        if SF.Debug then SF.Debug:Info("UI", "User creating new profile: '%s'", text) end
        SF:CreateNewLootProfile(text)

        -- Clear the input box
        newLootProfileInputBox:SetText("")
        newLootProfileInputBox:ClearFocus()
    end)

    -- Pressing "Enter" in the input box also triggers creation
    newLootProfileInputBox:SetScript("OnEnterPressed", function()
        createLootProfileBtn:Click()
    end)
end
