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
        SF:PrintError("LootProfileDropdown not found.")
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

-- Helper function to create the enable/disable checkbox
-- @param panel: The parent frame
-- @param anchorFrame: The frame to anchor below
-- @return: The created checkbox frame
local function CreateEnableCheckbox(panel, anchorFrame)
    local enableCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    enableCheckbox:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -20)
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
        SF:PrintSuccess("Loot Helper " .. (enabled and "enabled" or "disabled") .. ".")
    end)
    
    return enableCheckbox
end

-- Helper function to create the profile dropdown with delete button
-- @param panel: The parent frame
-- @param anchorFrame: The frame to anchor below
-- @return: The dropdown frame
local function CreateProfileDropdown(panel, anchorFrame)
    -- Label for the Dropdown
    local profileLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    profileLabel:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -20)
    profileLabel:SetText("Select Active Profile:")

    -- Dropdown for selecting active profile
    local LootProfileDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    LootProfileDropdown:SetPoint("LEFT", profileLabel, "RIGHT", 10, 0)
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
    
    return LootProfileDropdown
end

-- Helper function to create the delete button for active profile
-- @param panel: The parent frame
-- @param dropdown: The dropdown to anchor next to
-- @return: The delete button frame
local function CreateDeleteButton(panel, dropdown)
    local deleteProfileBtn = CreateFrame("Button", nil, panel)
    deleteProfileBtn:SetSize(20, 20)
    deleteProfileBtn:SetPoint("LEFT", dropdown, "RIGHT", 5, 0)

    -- Set the icon texture
    deleteProfileBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    deleteProfileBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
    deleteProfileBtn:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")

    -- Tooltip
    SF:CreateTooltip(deleteProfileBtn, "Delete Active Profile")

    -- logic to delete
    deleteProfileBtn:SetScript("OnClick", function()
        if SF.lootHelperDB.activeLootProfile then
            if SF.Debug then SF.Debug:Info("UI", "User clicked delete button for profile '%s'", SF.lootHelperDB.activeLootProfile) end
            SF:DeleteProfile(SF.lootHelperDB.activeLootProfile)
        else
            if SF.Debug then SF.Debug:Warn("UI", "User clicked delete button but no active profile exists") end
            SF:PrintError("No active profile to delete.")
        end
    end)

    SF.LootProfileDeleteButton = deleteProfileBtn
    
    return deleteProfileBtn
end

-- Helper function to create the profile creation section
-- @param panel: The parent frame
-- @param anchorFrame: The frame to anchor below
-- @return: The label frame (for use as next anchor)
local function CreateProfileInput(panel, anchorFrame)
    local createLootProfileLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    createLootProfileLabel:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -40)
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
            SF:PrintError("Profile name cannot be empty.")
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
    
    return createLootProfileLabel
end

-- Helper function to create the test mode toggle button
-- @param panel: The parent frame
-- @param anchorFrame: The frame to anchor below
-- @return: none
local function CreateTestModeButton(panel, anchorFrame)
    local testModeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testModeBtn:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -60)
    testModeBtn:SetSize(150, 30)
    
    -- Initialize button text based on current test mode state
    local testModeText = "Test Mode: OFF"
    if SF.LootWindow and SF.LootWindow.testModeActive then
        testModeText = "Test Mode: ON"
    end
    testModeBtn:SetText(testModeText)
    
    -- OnClick handler
    testModeBtn:SetScript("OnClick", function(self)
        if SF.LootWindow then
            SF.LootWindow:ToggleTestMode()
        else
            SF:PrintWarning("Loot Helper window not yet initialized. Use '/sf loot' to create it first.")
        end
    end)
    
    -- Tooltip
    SF:CreateTooltip(testModeBtn, "Toggle Test Mode", {
        "Shows fake members instead of real group data.",
        "Useful for testing UI without being in a raid."
    })
    
    -- Store button reference for updates from ToggleTestMode()
    SF.LootHelperTestModeButton = testModeBtn
end

-- Creates the Loot Helper section in the settings panel
function SF:CreateLootHelperSection(panel, anchorFrame)
    -- Create section title with horizontal lines
    local sectionTitle = SF:CreateSectionTitle(panel, "Loot Helper", anchorFrame, -20)
    
    -- Update subtitle lines when panel size changes
    local oldOnSizeChanged = panel:GetScript("OnSizeChanged")
    panel:SetScript("OnSizeChanged", function(self, width, height)
        if oldOnSizeChanged then oldOnSizeChanged(self, width, height) end
        sectionTitle.UpdateLines()
    end)
    
    -- Initial update for subtitle lines
    C_Timer.After(0.15, function()
        if panel:IsShown() then
            sectionTitle.UpdateLines()
        end
    end)

    -- Create UI components using helper functions
    local enableCheckbox = CreateEnableCheckbox(panel, sectionTitle.leftLine)
    local dropdown = CreateProfileDropdown(panel, enableCheckbox)
    CreateDeleteButton(panel, dropdown)
    SF:UpdateLootProfileDropdownText()
    
    local createLabel = CreateProfileInput(panel, dropdown)
    CreateTestModeButton(panel, createLabel)
end
