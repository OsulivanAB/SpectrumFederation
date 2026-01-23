# Settings UI Best Practices

This guide covers design patterns, conventions, and best practices for building high-quality settings pages.

## Design Principles

### Declarative Over Imperative

**DO**: Define UI structure as data

```lua
{
    type = "section",
    title = "General",
    controls = {
        { type = "checkbox", label = "Enable", path = "global.enabled" }
    }
}
```

**DON'T**: Build UI with imperative code

```lua
local checkbox = CreateFrame("CheckButton", nil, parent)
checkbox:SetPoint("TOPLEFT", 10, -10)
checkbox:SetScript("OnClick", function() ... end)
-- ... manual setup
```

### Path-based Storage

**DO**: Use Store paths for automatic binding

```lua
{
    type = "slider",
    label = "Font Size",
    path = "global.fontSize",  -- Auto-binds to Store
    min = 8,
    max = 24
}
```

**DON'T**: Manual get/set for simple values

```lua
{
    type = "slider",
    label = "Font Size",
    get = function() return SpectrumFederationDB.global.fontSize end,
    set = function(v) SpectrumFederationDB.global.fontSize = v end,
    min = 8,
    max = 24
}
```

**Exception**: Use custom get/set for computed values or validation.

### Reactive Over Polling

**DO**: Register callbacks in Apply module

```lua
-- In Apply module
SF.Settings.Apply:RegisterCallback("myFeature", function(newValue, oldValue, path)
    if path == "myFeature.enabled" then
        UpdateFeatureState(newValue)
    end
end)
```

**DON'T**: Poll settings in update loop

```lua
-- In OnUpdate handler
function MyAddon:OnUpdate()
    local enabled = SF.Settings.Store:Get("myFeature.enabled")
    if enabled ~= self.lastEnabled then
        UpdateFeatureState(enabled)
        self.lastEnabled = enabled
    end
end
```

### Combat-aware Operations

**DO**: Let Apply module handle combat lockdown

```lua
-- Apply module automatically queues UI operations during combat
SF.Settings.Apply:ApplyWindowStyle(style)
```

**DON'T**: Manual combat checks everywhere

```lua
if InCombatLockdown() then
    -- Manual queue management
else
    UpdateUI()
end
```

## Code Organization

### File Structure

Organize settings by feature:

```
modules/UI/Settings/Pages/
├── Main.lua          # Global/addon-wide settings
├── LootHelper.lua    # LootHelper feature settings
├── Notifications.lua # Notification settings
└── Advanced.lua      # Advanced/debug settings
```

**DO**: One page per file, related settings grouped

**DON'T**: All settings in one giant file

### Page Naming

**DO**: Use clear, feature-based names

- `lootHelper` - LootHelper settings
- `notifications` - Notification settings
- `profiles` - Profile management

**DON'T**: Use unclear or technical names

- `feature1` - What is feature1?
- `config` - Too generic
- `lhSettings` - Abbreviations unclear to new contributors

### Section Organization

**DO**: Logical grouping

```lua
{
    { type = "section", title = "General", controls = { ... } },
    { type = "section", title = "Appearance", controls = { ... } },
    { type = "section", title = "Advanced", controls = { ... } }
}
```

**DON'T**: Flat control lists

```lua
{
    { type = "section", title = "Settings", controls = {
        -- 50+ unrelated controls
    }}
}
```

## UI Design

### Control Selection

Choose the right control for the data type:

| Data Type | Control | Example |
|-----------|---------|---------|
| Boolean | `checkbox` | Enable/disable feature |
| Number (range) | `slider` | Font size (8-24) |
| Number (discrete) | `dropdown` | Difficulty (1-5) |
| String (fixed) | `dropdown` | Window style (3 options) |
| String (free-form) | `editbox` | Profile name |
| Action | `button` | Create profile |
| Read-only | `display` | Current profile owner |
| Info | `help` | Instructions/warnings |

### Labels and Help Text

**DO**: Clear, user-friendly labels

- "Enable Notifications" ✓
- "Display Position" ✓
- "Sound Type" ✓

**DON'T**: Technical or cryptic labels

- "notifyEnabled" ✗
- "pos" ✗
- "sndTyp" ✗

**Help Text Guidelines**:

- Explain what the setting does
- Mention if restart required
- Note any dependencies
- Keep under 100 characters

**Example**:

```lua
{
    type = "checkbox",
    label = "Enable Safe Mode",
    path = "lootHelper.safeMode",
    tooltip = "Pauses sync during combat",
    help = "Prevents frame errors during encounters. Can be toggled manually."
}
```

### Visual Hierarchy

**DO**: Use visual elements to guide users

```lua
{
    type = "section",
    title = "Important Settings",  -- Section title
    intro = "These settings affect core functionality",
    controls = {
        { type = "checkbox", label = "Enable Feature" },
        { type = "spacer", height = 10 },  -- Visual separation
        { type = "help", text = "Note: Changes take effect immediately" }
    }
}
```

**DON'T**: Wall of identical controls

```lua
{
    type = "section",
    controls = {
        { type = "checkbox", label = "Setting 1" },
        { type = "checkbox", label = "Setting 2" },
        { type = "checkbox", label = "Setting 3" },
        -- ... 20 more identical checkboxes
    }
}
```

### Conditional Visibility

**DO**: Hide advanced/irrelevant controls

```lua
{
    type = "slider",
    label = "Custom Color Alpha",
    path = "global.customAlpha",
    visible = function()
        return SF.Settings.Store:Get("global.useCustomColor") == true
    end
}
```

**DON'T**: Show all controls always

- Clutters UI
- Confuses users
- Poor performance with many controls

### Progressive Disclosure

**DO**: Start simple, reveal complexity gradually

```lua
{
    { type = "section", title = "Basic", controls = { ... } },
    {
        type = "section",
        title = "Advanced",
        condition = function()
            return SF.Settings.Store:Get("global.showAdvanced") == true
        end,
        controls = { ... }
    }
}
```

## Performance

### Lazy Loading

**DO**: Defer expensive operations

```lua
{
    type = "dropdown",
    label = "Select Item",
    items = function()
        -- Only fetch when dropdown opens
        return FetchItemList()
    end
}
```

**DON'T**: Pre-compute everything

```lua
-- At page load time
local itemList = FetchItemList()  -- Expensive!

{
    type = "dropdown",
    label = "Select Item",
    items = itemList
}
```

### Visibility Checks

**DO**: Cache visibility results when possible

```lua
local function IsAdvancedVisible()
    -- Cache the result if expensive
    if cachedResult ~= nil then return cachedResult end
    cachedResult = ComputeExpensiveCheck()
    return cachedResult
end

{
    type = "section",
    condition = IsAdvancedVisible,
    controls = { ... }
}
```

**DON'T**: Recompute on every refresh

```lua
{
    type = "section",
    condition = function()
        -- Called on every page refresh!
        return ExpensiveComputation()
    end,
    controls = { ... }
}
```

### Debouncing

**DO**: Debounce rapid changes (Apply module does this)

```lua
-- In Apply module
local debouncedApply = Debounce(0.05, function()
    ApplyFontChanges()
end)

SF.Settings.Store:RegisterCallback("fonts", function(newValue, oldValue, path)
    if path:match("^global%.font") then
        debouncedApply()
    end
end)
```

**DON'T**: Apply on every slider tick

```lua
-- Slider fires 50+ events during drag!
{
    type = "slider",
    set = function(value)
        ApplyFontChanges()  -- Called 50+ times!
    end
}
```

### Control Count

**DO**: Keep sections under 20 controls

```lua
{
    type = "section",
    title = "General Settings",
    controls = {
        -- 10-15 related controls
    }
}
```

**DON'T**: Create mega-sections

```lua
{
    type = "section",
    title = "All Settings",
    controls = {
        -- 100+ controls (slow to render, hard to use)
    }
}
```

## State Management

### Schema Defaults

**DO**: Define all defaults in Schema

```lua
-- Schema.lua
SF.Settings.Schema.DEFAULTS = {
    myFeature = {
        enabled = false,
        mode = "auto",
        threshold = 50
    }
}
```

**DON'T**: Hardcode defaults in controls

```lua
{
    type = "slider",
    path = "myFeature.threshold",
    get = function()
        return SF.Settings.Store:Get("myFeature.threshold") or 50  -- ✗ Don't do this
    end
}
```

### Validation

**DO**: Validate on set, show user-friendly errors

```lua
{
    type = "editbox",
    label = "Profile Name",
    set = function(value)
        local valid, error = SF.Settings.Schema.ValidateProfileName(value)
        if not valid then
            SF:PrintError(error)
            return
        end
        SF.Settings.Store:Set("lootHelper.newProfileName", value)
    end
}
```

**DON'T**: Silent failure or crashes

```lua
{
    type = "editbox",
    set = function(value)
        -- No validation - might crash or corrupt data
        SF.Settings.Store:Set("lootHelper.newProfileName", value)
    end
}
```

### Migrations

**DO**: Write migrations for breaking changes

```lua
-- Schema.lua
SF.Settings.Schema.MIGRATIONS = {
    [4] = function(db)
        -- Migrate from version 3 to 4
        if db.myFeature then
            db.myFeature.newField = db.myFeature.oldField or "default"
            db.myFeature.oldField = nil
        end
    end
}
```

**DON'T**: Break existing user data

## Debugging and Logging

### Debug Logging

**DO**: Log important operations

```lua
if SF.Debug then
    SF.Debug:Info("SETTINGS:MYFEATURE", "Profile created: %s", profileName)
    SF.Debug:Warn("SETTINGS:MYFEATURE", "Invalid value for %s: %s", path, value)
end
```

**DON'T**: Log everything or nothing

- Too much logging = noise
- No logging = hard to debug

### Error Handling

**DO**: Catch and report errors gracefully

```lua
local success, result = pcall(function()
    return ExpensiveOperation()
end)

if not success then
    if SF.Debug then
        SF.Debug:Error("SETTINGS:MYFEATURE", "Operation failed: %s", result)
    end
    SF:PrintError("An error occurred. Please report this.")
    return nil
end
```

**DON'T**: Let errors crash the UI

```lua
-- No error handling - crashes entire settings UI if this fails
local result = ExpensiveOperation()
```

### Testing

**DO**: Test edge cases

- Empty/nil values
- Maximum lengths
- Invalid input
- Rapid changes
- Combat scenarios
- Profile switching
- Window resize

**DON'T**: Only test happy path

## Accessibility

### Tooltips

**DO**: Add tooltips to all interactive controls

```lua
{
    type = "checkbox",
    label = "Enable Feature",
    tooltip = "Enables the awesome feature"  -- ✓
}
```

**DON'T**: Skip tooltips

```lua
{
    type = "checkbox",
    label = "Enable Feature"
    -- No tooltip - user has to guess
}
```

### Help Text

**DO**: Explain non-obvious settings

```lua
{
    type = "checkbox",
    label = "Raid-Wide Safe Mode",
    tooltip = "Pauses sync for entire raid",
    help = "When enabled, all raid members pause sync. Useful during progression."
}
```

**DON'T**: Leave complex settings unexplained

### Contrast and Readability

**DO**: Use Style constants for consistent colors

```lua
{
    type = "text",
    text = "Warning",
    color = SF.Settings.Style.COLORS.WARNING
}
```

**DON'T**: Use low-contrast colors

```lua
{
    type = "text",
    text = "Important",
    color = {0.1, 0.1, 0.1}  -- Nearly invisible on dark themes
}
```

## Documentation

### Code Comments

**DO**: Document complex logic

```lua
-- Generate controls for each installed addon
-- This is expensive, so we cache the result
local function GenerateAddonControls()
    if addonControlsCache then return addonControlsCache end
    
    local controls = {}
    for i = 1, GetNumAddOns() do
        -- ... logic ...
    end
    
    addonControlsCache = controls
    return controls
end
```

**DON'T**: Comment obvious code

```lua
-- Set the value
SF.Settings.Store:Set(path, value)
```

### Inline Documentation

**DO**: Use help controls for user guidance

```lua
{
    type = "help",
    text = "Profiles store loot tracking data. Changes take effect immediately.|n|nFor advanced options, enable 'Show Advanced Settings'."
}
```

### Example Settings

**DO**: Provide examples in help text

```lua
{
    type = "editbox",
    label = "Point Name",
    help = "Custom name for points (e.g., 'DKP', 'Loot Credits', 'Points')"
}
```

## Common Pitfalls

### Callback Loops

**DON'T**: Modify settings in their own callback

```lua
-- BAD: Infinite loop!
SF.Settings.Store:RegisterCallback("loop", function(newValue, oldValue, path)
    if path == "global.value" then
        SF.Settings.Store:Set("global.value", newValue + 1)  -- ✗ Loop!
    end
end)
```

**DO**: Use flags to prevent loops

```lua
local updating = false

SF.Settings.Store:RegisterCallback("safe", function(newValue, oldValue, path)
    if path == "global.value" and not updating then
        updating = true
        -- Modify related setting
        SF.Settings.Store:Set("global.related", ComputeRelated(newValue))
        updating = false
    end
end)
```

### Memory Leaks

**DON'T**: Create callbacks without cleanup

```lua
-- BAD: Creates new callback on every page open
function OpenPage()
    SF.Settings.Store:RegisterCallback("leak", function() ... end)
end
```

**DO**: Unregister on cleanup or use stable IDs

```lua
-- GOOD: Stable callback ID, auto-cleanup
SF.Settings.Store:RegisterCallback("myFeature:update", function() ... end)

-- Or unregister explicitly
function Cleanup()
    SF.Settings.Store:UnregisterCallback("myFeature:update")
end
```

### Combat Lockdown

**DON'T**: Modify protected frames during combat

```lua
-- BAD: Crashes if player is in combat
function ApplySetting()
    protectedFrame:SetAttribute("key", value)  -- ✗ Error during combat
end
```

**DO**: Use Apply module's combat queue

```lua
-- GOOD: Queued until out of combat
SF.Settings.Apply:RegisterCallback("safe", function(newValue, oldValue, path)
    if path == "myFeature.setting" then
        -- Apply module handles combat automatically
        SF.Settings.Apply:RunOrDefer(function()
            protectedFrame:SetAttribute("key", newValue)
        end)
    end
end)
```

### SavedVariables Race Conditions

**DON'T**: Access SavedVariables before PLAYER_LOGIN

```lua
-- BAD: SavedVariables not loaded yet
local value = SpectrumFederationDB.global.value  -- ✗ nil!
```

**DO**: Access after initialization

```lua
-- GOOD: Access after Store is initialized
EventFrame:RegisterEvent("PLAYER_LOGIN")
EventFrame:SetScript("OnEvent", function()
    SF.Settings.Store:InitializeDatabase(SpectrumFederationDB)
    local value = SF.Settings.Store:Get("global.value")
end)
```

## Review Checklist

Before submitting settings changes:

**Code Quality**:

- [ ] All controls have labels and tooltips
- [ ] Complex settings have help text
- [ ] Validation applied where needed
- [ ] Debug logging added for operations
- [ ] Error handling for failure cases

**User Experience**:

- [ ] Settings grouped logically
- [ ] Progressive disclosure for advanced options
- [ ] Clear, user-friendly language
- [ ] No technical jargon in UI
- [ ] Tested with edge cases

**Performance**:

- [ ] Expensive operations lazy-loaded
- [ ] Visibility checks cached if expensive
- [ ] Controls bound to Store paths
- [ ] No redundant computations

**Integration**:

- [ ] Schema defaults defined
- [ ] Migrations written if needed
- [ ] TOC file updated
- [ ] Page registered correctly
- [ ] Tested in-game with `/reload`

## Next Steps

- Review [Data Layer](data-layer.md) for state management patterns
- Study [Controls](controls.md) for all available control types
- Follow [Creating Pages](creating-pages.md) for page development
- Check [UI Layer](ui-layer.md) for architecture details
