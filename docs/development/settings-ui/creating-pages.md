# Creating Settings Pages

This guide walks through creating new settings pages for the Settings UI system.

## Quick Start

Creating a settings page involves three steps:

1. Create a page definition file
2. Register the page with the Registry
3. Update the TOC file

## Step 1: Create Page Definition

Create a new file in `SpectrumFederation/modules/UI/Settings/Pages/`:

```lua
-- SpectrumFederation/modules/UI/Settings/Pages/MyFeature.lua
local addonName, SF = ...

-- Define the page structure
SF.Settings.Pages = SF.Settings.Pages or {}
SF.Settings.Pages.MyFeature = {
    {
        type = "section",
        title = "General Settings",
        intro = "Configure basic feature behavior",
        controls = {
            {
                type = "checkbox",
                label = "Enable My Feature",
                path = "myFeature.enabled",
                tooltip = "Enable or disable this feature"
            },
            {
                type = "slider",
                label = "Feature Intensity",
                path = "myFeature.intensity",
                min = 0,
                max = 100,
                step = 5,
                format = "%d%%",
                tooltip = "Adjust feature intensity"
            }
        }
    },
    {
        type = "section",
        title = "Advanced Options",
        condition = function()
            return SF.Settings.Store:Get("myFeature.enabled") == true
        end,
        controls = {
            {
                type = "dropdown",
                label = "Mode",
                path = "myFeature.mode",
                items = {
                    { value = "auto", text = "Automatic" },
                    { value = "manual", text = "Manual" }
                },
                tooltip = "Select operating mode"
            }
        }
    }
}
```

## Step 2: Register the Page

Add registration code at the end of your page file or in a separate init function:

```lua
-- At the end of MyFeature.lua

-- Register the page when addon loads
local function RegisterMyFeaturePage()
    SF.Settings.Registry:RegisterPage(
        "myFeature",                    -- Page ID
        "My Feature",                   -- Display title
        SF.Settings.Pages.MyFeature,    -- Page definition
        {
            parent = nil,                -- nil = root page, or specify parent ID
            order = 100                  -- Display order (lower = first)
        }
    )
end

-- Call during addon initialization
if SF.Settings and SF.Settings.Registry then
    RegisterMyFeaturePage()
end
```

## Step 3: Update TOC File

Add your page file to `SpectrumFederation.toc` in the correct load order:

```
# UI Settings Pages
modules/UI/Settings/Pages/Main.lua
modules/UI/Settings/Pages/LootHelper.lua
modules/UI/Settings/Pages/MyFeature.lua    # <-- Add here
```

**Load Order**:

- Load after `Registry.lua`, `PageBuilder.lua`, `DefinitionRenderer.lua`
- Load before the main entry point that calls registration

## Step 4: Add Schema Defaults

Add default values to `modules/Settings/Schema.lua`:

```lua
SF.Settings.Schema.DEFAULTS = {
    version = 3,
    global = { ... },
    lootHelper = { ... },
    myFeature = {                  -- <-- Add here
        enabled = false,
        intensity = 50,
        mode = "auto"
    }
}
```

## Complete Example

Here's a complete example for a "Notifications" page:

### Page Definition

```lua
-- SpectrumFederation/modules/UI/Settings/Pages/Notifications.lua
local addonName, SF = ...

SF.Settings.Pages = SF.Settings.Pages or {}
SF.Settings.Pages.Notifications = {
    -- Section 1: Basic Settings
    {
        type = "section",
        title = "Notification Settings",
        intro = "Configure when and how you receive notifications",
        controls = {
            {
                type = "checkbox",
                label = "Enable Notifications",
                path = "notifications.enabled",
                tooltip = "Enable or disable all notifications",
                help = "You can still view history when disabled"
            },
            {
                type = "spacer",
                height = 10
            },
            {
                type = "dropdown",
                label = "Display Position",
                path = "notifications.position",
                items = {
                    { value = "top", text = "Top Center" },
                    { value = "bottom", text = "Bottom Center" },
                    { value = "topleft", text = "Top Left" },
                    { value = "topright", text = "Top Right" }
                },
                tooltip = "Where notifications appear on screen",
                enabled = function()
                    return SF.Settings.Store:Get("notifications.enabled") == true
                end
            },
            {
                type = "slider",
                label = "Display Duration",
                path = "notifications.duration",
                min = 1,
                max = 10,
                step = 0.5,
                format = "%.1f seconds",
                tooltip = "How long notifications stay visible",
                enabled = function()
                    return SF.Settings.Store:Get("notifications.enabled") == true
                end
            }
        }
    },
    
    -- Section 2: Notification Types
    {
        type = "section",
        title = "Notification Types",
        intro = "Choose which events trigger notifications",
        condition = function()
            return SF.Settings.Store:Get("notifications.enabled") == true
        end,
        controls = {
            {
                type = "checkbox",
                label = "Loot Received",
                path = "notifications.types.loot",
                tooltip = "Notify when you receive loot"
            },
            {
                type = "checkbox",
                label = "Profile Changes",
                path = "notifications.types.profileChange",
                tooltip = "Notify when profiles are modified"
            },
            {
                type = "checkbox",
                label = "Sync Events",
                path = "notifications.types.sync",
                tooltip = "Notify on sync start/complete"
            }
        }
    },
    
    -- Section 3: Sound
    {
        type = "section",
        title = "Sound",
        condition = function()
            return SF.Settings.Store:Get("notifications.enabled") == true
        end,
        controls = {
            {
                type = "checkbox",
                label = "Play Sound",
                path = "notifications.sound.enabled",
                tooltip = "Play a sound with notifications"
            },
            {
                type = "dropdown",
                label = "Sound Type",
                path = "notifications.sound.type",
                items = {
                    { value = "auction", text = "Auction House" },
                    { value = "level", text = "Level Up" },
                    { value = "quest", text = "Quest Complete" },
                    { value = "raid", text = "Raid Warning" }
                },
                enabled = function()
                    return SF.Settings.Store:Get("notifications.sound.enabled") == true
                end
            },
            {
                type = "button",
                label = "Test Sound",
                onClick = function()
                    local soundType = SF.Settings.Store:Get("notifications.sound.type", "auction")
                    PlayTestSound(soundType)
                end,
                enabled = function()
                    return SF.Settings.Store:Get("notifications.sound.enabled") == true
                end
            }
        }
    },
    
    -- Section 4: History
    {
        type = "section",
        title = "Notification History",
        controls = {
            {
                type = "display",
                label = "Total Notifications",
                get = function()
                    return GetNotificationCount()
                end,
                format = function(count)
                    return string.format("%d notification(s)", count)
                end
            },
            {
                type = "button",
                label = "Clear History",
                onClick = function()
                    SF.Settings.Dialogs.Confirm(
                        "Clear all notification history?",
                        "Clear",
                        function()
                            ClearNotificationHistory()
                            SF.Settings.Registry:RefreshPage("notifications")
                        end
                    )
                end
            }
        }
    }
}

-- Register the page
local function RegisterNotificationsPage()
    SF.Settings.Registry:RegisterPage(
        "notifications",
        "Notifications",
        SF.Settings.Pages.Notifications,
        { order = 50 }
    )
end

if SF.Settings and SF.Settings.Registry then
    RegisterNotificationsPage()
end
```

### Schema Defaults

```lua
-- In modules/Settings/Schema.lua
SF.Settings.Schema.DEFAULTS = {
    -- ... existing defaults
    notifications = {
        enabled = true,
        position = "top",
        duration = 3.0,
        types = {
            loot = true,
            profileChange = true,
            sync = false
        },
        sound = {
            enabled = true,
            type = "quest"
        }
    }
}
```

### TOC Update

```
# UI Settings Pages
modules/UI/Settings/Pages/Main.lua
modules/UI/Settings/Pages/LootHelper.lua
modules/UI/Settings/Pages/Notifications.lua
```

## Page Structure Best Practices

### Section Organization

**DO**:

- Start with most common settings
- Group related settings in sections
- Use conditional sections for advanced features
- Add intro text for complex sections

**DON'T**:

- Create single-control sections
- Mix unrelated settings in one section
- Nest more than 2 levels deep

### Control Layout

**DO**:

- Order controls logically (general → specific)
- Use spacers to separate groups
- Add help text for complex controls
- Use display controls to show computed values

**DON'T**:

- Put 50+ controls in one section
- Duplicate controls across sections
- Hide important settings behind conditions

### Conditional Visibility

**DO**:

- Hide advanced settings when feature is disabled
- Show/hide entire sections based on state
- Use `enabled` for temporarily unavailable controls
- Use `visible` for structurally hidden controls

**DON'T**:

- Nest conditions more than 2 levels
- Hide controls user needs to enable feature
- Use conditions for performance (cache instead)

## Sub-pages

Create hierarchical settings pages:

```lua
-- Parent page
SF.Settings.Registry:RegisterPage(
    "myFeature",
    "My Feature",
    SF.Settings.Pages.MyFeature
)

-- Sub-page
SF.Settings.Registry:RegisterPage(
    "myFeature.advanced",
    "Advanced Settings",
    SF.Settings.Pages.MyFeatureAdvanced,
    { parent = "myFeature" }
)
```

Sub-pages appear nested in the settings UI:

```
Settings
├── My Feature
│   └── Advanced Settings
└── Other Feature
```

## Dynamic Content

### Dynamic Sections

Show sections based on runtime state:

```lua
{
    type = "section",
    title = "Profile Settings",
    condition = function()
        local profile = SF.Settings.Store:GetActiveLootHelperProfileData()
        return profile ~= nil
    end,
    controls = { ... }
}
```

### Dynamic Controls

Generate controls programmatically:

```lua
-- Generate checkbox for each notification type
local function GenerateNotificationControls()
    local controls = {}
    local types = GetNotificationTypes()
    
    for _, notifType in ipairs(types) do
        table.insert(controls, {
            type = "checkbox",
            label = notifType.label,
            path = "notifications.types." .. notifType.id,
            tooltip = notifType.description
        })
    end
    
    return controls
end

-- Use in page definition
{
    type = "section",
    title = "Notification Types",
    controls = GenerateNotificationControls()
}
```

## Page Lifecycle

### Registration

```lua
-- Called during addon load (PLAYER_LOGIN)
SF.Settings.Registry:RegisterPage(id, title, definition, options)
```

### First Open

```lua
-- Triggered when user opens settings
-- Creates panel, builds sections, renders controls
PageBuilder:Build(panel, definition)
```

### Refresh

```lua
-- Called when settings change or page needs update
SF.Settings.Registry:RefreshPage(pageId)
```

Refreshes:

- Call `get()` for all controls
- Re-evaluate `visible()` and `enabled()`
- Update dropdown items
- Re-check section conditions

### Cleanup

```lua
-- When page is hidden or addon unloads
-- Cleanup is automatic (no manual teardown needed)
```

## Debugging Pages

Enable debug logging:

```lua
/sfdebug on
```

**Log Categories**:

- `SETTINGS:REGISTRY` - Page registration
- `SETTINGS:PAGEBUILDER` - Page building
- `SETTINGS:RENDERER` - Control rendering

**Example Output**:

```
[SETTINGS:REGISTRY] Registering page 'notifications' with 4 sections
[SETTINGS:PAGEBUILDER] Building page with 4 sections
[SETTINGS:RENDERER] Rendering section 'Notification Settings' with 3 controls
[SETTINGS:RENDERER] Creating checkbox: Enable Notifications
```

## Testing Pages

### In-Game Testing

1. `/reload` after code changes
2. Open settings: `/sf` or ESC → Interface → AddOns → Spectrum Federation
3. Navigate to your page
4. Test controls:
   - Click checkboxes
   - Drag sliders
   - Select dropdowns
   - Enter text
5. Check `/sfdebug show` for errors
6. Verify settings persist after `/reload`

### Edge Cases

Test these scenarios:

- Empty profiles/data
- Maximum value ranges
- Long text strings
- Rapid value changes (sliders)
- Conditional visibility toggles
- Sub-page navigation
- Window resize
- Theme changes

## Common Patterns

### Profile-Specific Settings

```lua
{
    type = "section",
    title = "Active Profile Settings",
    condition = function()
        return SF.Settings.Store:GetActiveLootHelperProfileData() ~= nil
    end,
    controls = {
        {
            type = "display",
            label = "Profile Name",
            get = function()
                local profile = SF.Settings.Store:GetActiveLootHelperProfileData()
                return profile and profile.name or "None"
            end
        },
        {
            type = "editbox",
            label = "Rename Profile",
            get = function() return tempName end,
            set = function(value) tempName = value end
        },
        {
            type = "button",
            label = "Apply Rename",
            onClick = function()
                RenameProfile(tempName)
                SF.Settings.Registry:RefreshPage("myPage")
            end
        }
    }
}
```

### Reset Buttons

```lua
{
    type = "section",
    title = "Advanced Settings",
    resetPath = "myFeature.advanced",
    controls = { ... }
}
```

The Section widget automatically adds a "Reset to Defaults" button.

### Validation

```lua
{
    type = "editbox",
    label = "Profile Name",
    get = function() return pendingName end,
    set = function(value)
        local valid, error = SF.Settings.Schema.ValidateProfileName(value)
        if not valid then
            SF:PrintError(error)
            return
        end
        pendingName = value
    end
}
```

### Dependent Settings

```lua
{
    type = "checkbox",
    label = "Enable Advanced Mode",
    path = "myFeature.advancedMode"
},
{
    type = "slider",
    label = "Advanced Setting",
    path = "myFeature.advancedValue",
    min = 0,
    max = 100,
    visible = function()
        return SF.Settings.Store:Get("myFeature.advancedMode") == true
    end
}
```

## Next Steps

- Review [Controls](controls.md) for all available control types
- Read [Best Practices](best-practices.md) for design patterns
- Explore [Data Layer](data-layer.md) for state management
- Check [UI Layer](ui-layer.md) for architecture details
