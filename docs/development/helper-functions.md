# Helper Functions

This page documents all helper functions available in the SpectrumFederation addon. These functions provide reusable functionality for messaging, UI creation, member queries, debugging, and slash commands.

## MessageHelpers (`modules/MessageHelpers.lua`)

The MessageHelpers module provides color-coded user messaging functions for consistent communication with players throughout the addon.


!!! warning "TODO"
    Upload pictures of each message in game.

### SF:PrintSuccess(message)

Prints a success message in green to the chat frame.

**Parameters:**
- `message` (string) - The message to display

**Returns:** None

**WoW API Functions Used:**
- [print()](https://wowpedia.fandom.com/wiki/API_print)

**Example:**
```lua
SF:PrintSuccess("Profile 'Main Raid' created successfully!")
```

!!! tip "Best Practice"
    Use `PrintSuccess` for confirmation messages after successful operations like creating profiles, saving settings, or completing actions.

---

### SF:PrintError(message)

Prints an error message in red to the chat frame.

**Parameters:**
- `message` (string) - The error message to display

**Returns:** None

**WoW API Functions Used:**
- [print()](https://wowpedia.fandom.com/wiki/API_print)

**Example:**
```lua
SF:PrintError("Profile name cannot be empty!")
```

!!! warning "Error Handling"
    Always use `PrintError` for validation failures, missing data, or operations that cannot complete. Pair with debug logging for developer context.

---

### SF:PrintWarning(message)

Prints a warning message in orange to the chat frame.

**Parameters:**
- `message` (string) - The warning message to display

**Returns:** None

**WoW API Functions Used:**
- [print()](https://wowpedia.fandom.com/wiki/API_print)

**Example:**
```lua
SF:PrintWarning("Profile 'Old Raid' has not been used in 30 days")
```

!!! note "Use Case"
    Use `PrintWarning` for non-critical issues that users should be aware of, such as deprecation notices or suboptimal configurations.

---

### SF:PrintInfo(message)

Prints an informational message in white to the chat frame.

**Parameters:**
- `message` (string) - The informational message to display

**Returns:** None

**WoW API Functions Used:**
- [print()](https://wowpedia.fandom.com/wiki/API_print)

**Example:**
```lua
SF:PrintInfo("SpectrumFederation addon loaded. Type /sf to open settings.")
```

---

## UIHelpers (`modules/UIHelpers.lua`)

The UIHelpers module provides reusable UI component creation functions for consistent styling and behavior across the addon interface.

### SF:CreateTooltip(frame, title, lines)

Creates and attaches a tooltip to a frame that displays on mouse hover.

**Parameters:**
- `frame` (Frame) - The frame to attach the tooltip to
- `title` (string) - The tooltip title text
- `lines` (table) - Array of strings, each element becomes a line in the tooltip body

**Returns:** None

**WoW API Functions Used:**
- [GameTooltip:SetOwner()](https://wowpedia.fandom.com/wiki/API_GameTooltip_SetOwner)
- [GameTooltip:SetText()](https://wowpedia.fandom.com/wiki/API_GameTooltip_SetText)
- [GameTooltip:AddLine()](https://wowpedia.fandom.com/wiki/API_GameTooltip_AddLine)
- [GameTooltip:Show()](https://wowpedia.fandom.com/wiki/API_GameTooltip_Show)
- [GameTooltip_Hide()](https://wowpedia.fandom.com/wiki/API_GameTooltip_Hide)

**Example:**
```lua
SF:CreateTooltip(myButton, "Delete Profile", {
    "Permanently deletes this profile.",
    "This action cannot be undone."
})
```

!!! tip "Multi-line Tooltips"
    Pass an array of strings to create multi-line tooltips. Each string becomes a separate line in the tooltip body.

---

### SF:CreateHorizontalLine(parent, width)

Creates a horizontal line texture for visual separation in UI panels.

**Parameters:**
- `parent` (Frame) - The parent frame for the line
- `width` (number) - The width of the line in pixels

**Returns:** (Texture) The created line texture

**WoW API Functions Used:**
- [CreateTexture()](https://wowpedia.fandom.com/wiki/API_Region_CreateTexture)
- [Texture:SetColorTexture()](https://wowpedia.fandom.com/wiki/API_Texture_SetColorTexture)

**Example:**
```lua
local line = SF:CreateHorizontalLine(panel, 600)
line:SetPoint("TOP", title, "BOTTOM", 0, -5)
```

---

### SF:CreateSectionTitle(parent, titleText, anchorFrame, yOffset)

Creates a section title with horizontal lines on both sides for visual hierarchy.

**Parameters:**
- `parent` (Frame) - The parent frame
- `titleText` (string) - The title text to display
- `anchorFrame` (Frame) - The frame to anchor below
- `yOffset` (number, optional) - Vertical offset from anchor (negative = below, defaults to -20)

**Returns:** (table) A table containing:
    - `title` (FontString) - The title text object
    - `leftLine` (Texture) - The left horizontal line
    - `rightLine` (Texture) - The right horizontal line
    - `UpdateLines` (function) - Function to recalculate line widths

**WoW API Functions Used:**
- [CreateFontString()](https://wowpedia.fandom.com/wiki/API_Frame_CreateFontString)
- [FontString:GetStringWidth()](https://wowpedia.fandom.com/wiki/API_FontInstance_GetStringWidth)
- [CreateTexture()](https://wowpedia.fandom.com/wiki/API_Region_CreateTexture)
- [Texture:SetColorTexture()](https://wowpedia.fandom.com/wiki/API_Texture_SetColorTexture)

**Example:**
```lua
local sectionTitle = SF:CreateSectionTitle(panel, "Loot Helper", banner, -20)

-- Update line widths when panel is resized
panel:SetScript("OnSizeChanged", function()
    sectionTitle.UpdateLines()
end)
```

!!! note "Dynamic Sizing"
    The `UpdateLines` function recalculates line widths when the parent frame is resized. Call it in `OnSizeChanged` handlers for responsive layouts.

---

### SF:CreateIconButton(parent, iconPath, size)

Creates a square button with an icon texture.

**Parameters:**
- `parent` (Frame) - The parent frame
- `iconPath` (string) - Path to the icon texture (e.g., "Interface\\AddOns\\SpectrumFederation\\Media\\Icons\\Delete")
- `size` (number) - Width and height of the button in pixels

**Returns:** (Button) The created button

**WoW API Functions Used:**
- [CreateFrame("Button")](https://wowpedia.fandom.com/wiki/API_CreateFrame)
- [Button:SetNormalTexture()](https://wowpedia.fandom.com/wiki/API_Button_SetNormalTexture)
- [Button:SetHighlightTexture()](https://wowpedia.fandom.com/wiki/API_Button_SetHighlightTexture)
- [Button:SetPushedTexture()](https://wowpedia.fandom.com/wiki/API_Button_SetPushedTexture)

**Example:**
```lua
local deleteBtn = SF:CreateIconButton(
    panel,
    "Interface\\AddOns\\SpectrumFederation\\Media\\Icons\\Delete",
    20
)
deleteBtn:SetPoint("LEFT", profileDropdown, "RIGHT", 5, 0)
deleteBtn:SetScript("OnClick", function()
    -- Handle delete action
end)
```

---

## MemberQuery (`modules/LootHelper/MemberQuery.lua`)

The MemberQuery module provides functions for retrieving raid, party, or solo player information for the Loot Helper system.

### SF:GetTestMembers()

Returns a hardcoded list of 15 test members for development and testing purposes.

**Parameters:** None

**Returns:** (table) Array of member tables, each containing:
- `name` (string) - Character name
- `realm` (string) - Realm name
- `classFilename` (string) - Class identifier (e.g., "WARRIOR", "PRIEST")
- `points` (number) - Loot points (always 0 for test members)

**WoW API Functions Used:** None (hardcoded data)

**Example:**
```lua
local members = SF:GetTestMembers()
for i, member in ipairs(members) do
    print(member.name .. "-" .. member.realm .. " (" .. member.classFilename .. ")")
end
```

!!! warning "Test Data Only"
    This function returns hardcoded test data. Never use in production code. Use for UI development and testing only.

---

### SF:GetRaidMembers()

Queries all members in the player's raid group (1-40 players).

**Parameters:** None

**Returns:** (table) Array of member tables, each containing:
- `name` (string) - Character name
- `realm` (string) - Realm name
- `classFilename` (string) - Class identifier
- `points` (number) - Loot points (currently always 0)

**WoW API Functions Used:**
- [GetNumGroupMembers()](https://wowpedia.fandom.com/wiki/API_GetNumGroupMembers)
- [GetRaidRosterInfo()](https://wowpedia.fandom.com/wiki/API_GetRaidRosterInfo)
- [UnitName()](https://wowpedia.fandom.com/wiki/API_UnitName)

**Example:**
```lua
if IsInRaid() then
    local members = SF:GetRaidMembers()
    SF:PrintInfo(string.format("Found %d raid members", #members))
end
```

---

### SF:GetPartyMembers()

Queries all members in the player's party group (player + up to 4 party members).

**Parameters:** None

**Returns:** (table) Array of member tables with same structure as `GetRaidMembers`

**WoW API Functions Used:**
- [UnitName("player")](https://wowpedia.fandom.com/wiki/API_UnitName)
- [UnitClass("player")](https://wowpedia.fandom.com/wiki/API_UnitClass)
- [GetRealmName()](https://wowpedia.fandom.com/wiki/API_GetRealmName)
- [GetNumSubgroupMembers()](https://wowpedia.fandom.com/wiki/API_GetNumSubgroupMembers)
- [UnitExists("party1-4")](https://wowpedia.fandom.com/wiki/API_UnitExists)
- [UnitName("party1-4")](https://wowpedia.fandom.com/wiki/API_UnitName)
- [UnitClass("party1-4")](https://wowpedia.fandom.com/wiki/API_UnitClass)

**Example:**
```lua
if IsInGroup() and not IsInRaid() then
    local members = SF:GetPartyMembers()
    SF:PrintInfo(string.format("Found %d party members", #members))
end
```

---

### SF:GetSoloPlayer()

Returns information about the player when not in a group.

**Parameters:** None

**Returns:** (table) Array with a single member table containing player information

**WoW API Functions Used:**
- [UnitName("player")](https://wowpedia.fandom.com/wiki/API_UnitName)
- [UnitClass("player")](https://wowpedia.fandom.com/wiki/API_UnitClass)
- [GetRealmName()](https://wowpedia.fandom.com/wiki/API_GetRealmName)

**Example:**
```lua
if not IsInGroup() then
    local members = SF:GetSoloPlayer()
    SF:PrintInfo("Not in a group. Displaying solo player.")
end
```

---

## Debug (`modules/Debug.lua`)

The Debug module provides a structured logging system with multiple severity levels and category-based organization.

### SF.Debug:Initialize()

Initializes the debug system by loading saved variables and setting up the logging state.

**Parameters:** None

**Returns:** None

**WoW API Functions Used:** None (accesses SavedVariables)

**Example:**
```lua
-- Called automatically during PLAYER_LOGIN in SpectrumFederation.lua
if SF.Debug then
    SF.Debug:Initialize()
end
```

---

### SF.Debug:IsEnabled()

Checks whether debug logging is currently enabled.

**Parameters:** None

**Returns:** (boolean) `true` if debug logging is enabled, `false` otherwise

**WoW API Functions Used:** None

**Example:**
```lua
if SF.Debug and SF.Debug:IsEnabled() then
    -- Perform expensive debug operation
end
```

---

### SF.Debug:Log(level, category, message, ...)

Core logging function that handles all log levels. Generally, use the level-specific functions instead.

**Parameters:**
- `level` (string) - Log level: "VERBOSE", "INFO", "WARN", or "ERROR"
- `category` (string) - Log category (e.g., "ADDON", "PROFILES", "UI")
- `message` (string) - Log message with optional format placeholders
- `...` - Format arguments for `string.format`

**Returns:** None

**WoW API Functions Used:**
- [time()](https://wowpedia.fandom.com/wiki/API_time)
- [string.format()](https://wowpedia.fandom.com/wiki/API_string.format)

**Example:**
```lua
SF.Debug:Log("INFO", "PROFILES", "Profile '%s' created with %d members", profileName, memberCount)
```

---

### SF.Debug:Verbose(category, message, ...)

Logs a verbose-level message (detailed debugging information).

**Parameters:**
- `category` (string) - Log category
- `message` (string) - Message with optional format placeholders
- `...` - Format arguments

**Returns:** None

**WoW API Functions Used:** Same as `Log()`

**Example:**
```lua
SF.Debug:Verbose("UI", "Mouse entered button at coordinates (%.1f, %.1f)", x, y)
```

---

### SF.Debug:Info(category, message, ...)

Logs an info-level message (general information).

**Parameters:**
- `category` (string) - Log category
- `message` (string) - Message with optional format placeholders
- `...` - Format arguments

**Returns:** None

**WoW API Functions Used:** Same as `Log()`

**Example:**
```lua
SF.Debug:Info("ADDON", "SpectrumFederation version %s loaded", version)
```

---

### SF.Debug:Warn(category, message, ...)

Logs a warning-level message (potential issues).

**Parameters:**
- `category` (string) - Log category
- `message` (string) - Message with optional format placeholders
- `...` - Format arguments

**Returns:** None

**WoW API Functions Used:** Same as `Log()`

**Example:**
```lua
SF.Debug:Warn("DATABASE", "Profile '%s' has no members assigned", profileName)
```

---

### SF.Debug:Error(category, message, ...)

Logs an error-level message (serious problems).

**Parameters:**
- `category` (string) - Log category
- `message` (string) - Message with optional format placeholders
- `...` - Format arguments

**Returns:** None

**WoW API Functions Used:** Same as `Log()`

**Example:**
```lua
SF.Debug:Error("DATABASE", "Failed to save profile '%s': %s", profileName, errorMsg)
```

---

## SlashCommands (`modules/SlashCommands.lua`)

The SlashCommands module provides slash command registration and handling infrastructure.

### SF:RegisterSlashCommand(command, handler, description)

Registers a new slash command with the addon's command system.

**Parameters:**
- `command` (string) - The command name (without leading slash)
- `handler` (function) - Function to call when command is executed: `function(args)`
- `description` (string) - Human-readable description for help text

**Returns:** None

**WoW API Functions Used:**
- [SlashCmdList](https://wowpedia.fandom.com/wiki/API_SlashCmdList)

**Example:**
```lua
SF:RegisterSlashCommand("export", function(args)
    -- Export profile logic
    SF:PrintSuccess("Profile exported successfully!")
end, "Export the active profile")
```

---

### SF:InitializeSlashCommands()

Initializes all slash commands for the addon. Called automatically during addon load.

**Parameters:** None

**Returns:** None

**WoW API Functions Used:**
- [SlashCmdList](https://wowpedia.fandom.com/wiki/API_SlashCmdList)

**Example:**
```lua
-- Called automatically in SpectrumFederation.lua
SF:InitializeSlashCommands()
```

---

## Best Practices

### Combined Usage Example: Creating a Feature Panel

Here's how to combine multiple helper functions when creating a new feature panel:

```lua
function SF:CreateMyFeaturePanel(parent, anchorFrame)
    -- Create section title with lines
    local sectionTitle = SF:CreateSectionTitle(parent, "My Feature", anchorFrame, -20)
    
    -- Create an icon button
    local actionBtn = SF:CreateIconButton(
        parent,
        "Interface\\AddOns\\SpectrumFederation\\Media\\Icons\\Action",
        24
    )
    actionBtn:SetPoint("TOP", sectionTitle.title, "BOTTOM", 0, -20)
    
    -- Add tooltip to the button
    SF:CreateTooltip(actionBtn, "Perform Action", {
        "This button does something amazing.",
        "Click to execute the feature."
    })
    
    -- Handle button click with messaging and logging
    actionBtn:SetScript("OnClick", function()
        if SF.Debug then
            SF.Debug:Info("MYFEATURE", "Action button clicked")
        end
        
        -- Perform action
        local success, err = pcall(function()
            -- Feature logic here
        end)
        
        if success then
            SF:PrintSuccess("Action completed successfully!")
            if SF.Debug then
                SF.Debug:Info("MYFEATURE", "Action completed")
            end
        else
            SF:PrintError("Action failed: " .. tostring(err))
            if SF.Debug then
                SF.Debug:Error("MYFEATURE", "Action failed: %s", tostring(err))
            end
        end
    end)
    
    -- Update section title lines on resize
    parent:SetScript("OnSizeChanged", function()
        sectionTitle.UpdateLines()
    end)
end
```

### Member Query with Smart Detection

Automatically detect group type and query appropriate members:

```lua
function SF.LootWindow:RefreshMembers()
    local members
    
    if self.testMode then
        members = SF:GetTestMembers()
        if SF.Debug then
            SF.Debug:Verbose("LOOTWINDOW", "Using test members (test mode enabled)")
        end
    elseif IsInRaid() then
        members = SF:GetRaidMembers()
        if SF.Debug then
            SF.Debug:Info("LOOTWINDOW", "Queried %d raid members", #members)
        end
    elseif IsInGroup() then
        members = SF:GetPartyMembers()
        if SF.Debug then
            SF.Debug:Info("LOOTWINDOW", "Queried %d party members", #members)
        end
    else
        members = SF:GetSoloPlayer()
        if SF.Debug then
            SF.Debug:Verbose("LOOTWINDOW", "Solo player - not in group")
        end
    end
    
    self:UpdateMemberDisplay(members)
end
```

### Slash Command with Full Integration

Register a command that uses all helper systems:

```lua
SF:RegisterSlashCommand("export", function(args)
    -- Validate active profile
    if not SF.lootHelperDB or not SF.lootHelperDB.activeProfile then
        SF:PrintError("No active profile to export!")
        if SF.Debug then
            SF.Debug:Warn("EXPORT", "Export attempted with no active profile")
        end
        return
    end
    
    local profileName = SF.lootHelperDB.activeProfile
    local profile = SF.lootHelperDB.profiles[profileName]
    
    if not profile then
        SF:PrintError(string.format("Profile '%s' not found!", profileName))
        if SF.Debug then
            SF.Debug:Error("EXPORT", "Active profile '%s' not found in database", profileName)
        end
        return
    end
    
    -- Perform export
    if SF.Debug then
        SF.Debug:Info("EXPORT", "Exporting profile '%s' with %d members", 
            profileName, profile.members and #profile.members or 0)
    end
    
    local success, result = pcall(SF.ExportProfile, SF, profile)
    
    if success and result then
        SF:PrintSuccess(string.format("Profile '%s' exported successfully!", profileName))
        if SF.Debug then
            SF.Debug:Info("EXPORT", "Export completed: %d bytes", #result)
        end
    else
        SF:PrintError("Export failed: " .. tostring(result))
        if SF.Debug then
            SF.Debug:Error("EXPORT", "Export failed: %s", tostring(result))
        end
    end
end, "Export the active profile to a shareable string")
```

### Error Handling Pattern

Combine user messages with debug logging for comprehensive error handling:

```lua
function SF:SaveProfileChanges(profileName, changes)
    -- Validate input
    if not profileName or profileName == "" then
        SF:PrintError("Profile name is required!")
        if SF.Debug then
            SF.Debug:Error("PROFILES", "SaveProfileChanges called with empty profile name")
        end
        return false
    end
    
    -- Log start of operation
    if SF.Debug then
        SF.Debug:Info("PROFILES", "Saving changes to profile '%s'", profileName)
    end
    
    -- Perform operation with error handling
    local success, err = pcall(function()
        -- Save logic here
        SF.lootHelperDB.profiles[profileName] = changes
    end)
    
    -- Handle result
    if success then
        SF:PrintSuccess(string.format("Profile '%s' saved!", profileName))
        if SF.Debug then
            SF.Debug:Info("PROFILES", "Successfully saved profile '%s'", profileName)
        end
        return true
    else
        SF:PrintError(string.format("Failed to save profile: %s", tostring(err)))
        if SF.Debug then
            SF.Debug:Error("PROFILES", "Save failed for '%s': %s", profileName, tostring(err))
        end
        return false
    end
end
```

---

## General Guidelines

1. **Consistency**: Always use helper functions instead of creating one-off implementations
2. **User Communication**: Use MessageHelpers for all user-facing messages
3. **Developer Visibility**: Use Debug logging for all operations that might need troubleshooting
4. **Error Handling**: Combine user messages (`PrintError`) with debug logging (`Debug:Error`) for comprehensive error reporting
5. **Tooltips**: Add tooltips to all interactive UI elements using `CreateTooltip`
6. **Performance**: Check `Debug:IsEnabled()` before expensive debug operations
7. **Member Queries**: Use appropriate member query function based on group type (raid/party/solo)
8. **UI Consistency**: Use UIHelpers for section titles and lines to maintain consistent styling
