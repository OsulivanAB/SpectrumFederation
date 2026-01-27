# Settings UI Controls

The Controls module provides 14+ control types for building settings pages. Each control auto-saves changes and integrates with the Store system.

## Control Types Reference

### Checkbox

Boolean toggle control.

**Factory**: `Controls.CreateCheckbox(parent, opts)`

**Options**:

- `label` (string) - Display label
- `path` (string) - Store path OR
- `get` (function) - Custom getter `() => boolean`
- `set` (function) - Custom setter `(value: boolean) => void`
- `tooltip` (string, optional) - Hover tooltip
- `help` (string, optional) - Help text below control
- `enabled` (function, optional) - Enable state `() => boolean`
- `visible` (function, optional) - Visibility `() => boolean`

**Example**:

```lua
{
    type = "checkbox",
    label = "Enable Feature",
    path = "global.featureEnabled",
    tooltip = "Enables the cool new feature",
    help = "Requires UI reload to take effect"
}
```

**Visual**:

```
☑ Enable Feature
  Requires UI reload to take effect
```

---

### Slider

Numeric range control with min/max bounds.

**Factory**: `Controls.CreateSlider(parent, opts)`

**Options**:

- `label` (string) - Display label
- `min` (number) - Minimum value
- `max` (number) - Maximum value
- `step` (number, optional) - Step increment (default: 1)
- `format` (string, optional) - Value format (default: "%.0f")
- `path` (string) - Store path OR
- `get` (function) - Custom getter `() => number`
- `set` (function) - Custom setter `(value: number) => void`
- `tooltip` (string, optional) - Hover tooltip
- `help` (string, optional) - Help text
- `enabled` (function, optional) - Enable state
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "slider",
    label = "Font Size",
    path = "global.fontSize",
    min = 8,
    max = 24,
    step = 1,
    format = "%d pt",
    tooltip = "Adjust the UI font size"
}
```

**Visual**:

```
Font Size: 14 pt
[========●===]
8           24
```

---

### Dropdown

Selection list control.

**Factory**: `Controls.CreateDropdown(parent, opts)`

**Options**:

- `label` (string) - Display label
- `items` (table or function) - Items array OR function `() => items[]`
  - Each item: `{ value = any, text = string }`
- `width` (number, optional) - Dropdown width (default: 200)
- `path` (string) - Store path OR
- `get` (function) - Custom getter `() => value`
- `set` (function) - Custom setter `(value) => void`
- `tooltip` (string, optional) - Hover tooltip
- `help` (string, optional) - Help text
- `enabled` (function, optional) - Enable state
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "dropdown",
    label = "Window Style",
    path = "global.windowStyle",
    items = {
        { value = "blizzard", text = "Blizzard" },
        { value = "custom", text = "Custom" }
    },
    tooltip = "Choose window appearance"
}
```

**Dynamic Items**:

```lua
{
    type = "dropdown",
    label = "Active Profile",
    get = function()
        return SF.Settings.Store:Get("lootHelper.activeProfileId")
    end,
    set = function(profileId)
        SF.Settings.Store:SetActiveLootHelperProfileId(profileId)
    end,
    items = function()
        local profiles = SF.Settings.Store:Get("lootHelper.profiles", {})
        local items = {}
        for id, profile in pairs(profiles) do
            table.insert(items, { value = id, text = profile.name })
        end
        return items
    end
}
```

**Visual**:

```
Window Style: [Blizzard ▼]
```

---

### Editbox

Text input control.

**Factory**: `Controls.CreateEditbox(parent, opts)`

**Options**:

- `label` (string) - Display label
- `placeholder` (string, optional) - Placeholder text
- `maxLetters` (number, optional) - Character limit (default: 0 = unlimited)
- `width` (number, optional) - Editbox width (default: 200)
- `multiline` (boolean, optional) - Multi-line mode (default: false)
- `path` (string) - Store path OR
- `get` (function) - Custom getter `() => string`
- `set` (function) - Custom setter `(value: string) => void`
- `tooltip` (string, optional) - Hover tooltip
- `help` (string, optional) - Help text
- `enabled` (function, optional) - Enable state
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "editbox",
    label = "Profile Name",
    placeholder = "Enter name...",
    maxLetters = 24,
    path = "lootHelper.newProfileName",
    tooltip = "Enter a unique profile name"
}
```

**Visual**:

```
Profile Name
[Enter name...        ]
```

---

### Button

Click action control.

**Factory**: `Controls.CreateButton(parent, opts)`

**Options**:

- `label` (string) - Button text
- `onClick` (function) - Click handler `() => void`
- `width` (number, optional) - Button width (default: auto)
- `tooltip` (string, optional) - Hover tooltip
- `enabled` (function, optional) - Enable state
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "button",
    label = "Create Profile",
    onClick = function()
        CreateNewProfile()
    end,
    enabled = function()
        return CanCreateProfile()
    end
}
```

**Visual**:

```
[ Create Profile ]
```

---

### Display

Read-only value display.

**Factory**: `Controls.CreateDisplay(parent, opts)`

**Options**:

- `label` (string) - Display label
- `get` (function) - Value getter `() => value`
- `format` (string or function, optional) - Format string or function
- `tooltip` (string, optional) - Hover tooltip
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "display",
    label = "Profile Owner",
    get = function()
        local profile = SF.Settings.Store:GetActiveLootHelperProfileData()
        return profile and profile.ownerId or "None"
    end
}
```

**Visual**:

```
Profile Owner: PlayerName-RealmName
```

---

### Help

Formatted help text control.

**Factory**: `Controls.CreateHelp(parent, opts)`

**Options**:

- `text` (string) - Help text (supports `|n` for newlines)
- `color` (table, optional) - RGB color `{r, g, b}` (default: white)
- `fontSize` (number, optional) - Font size (default: 12)
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "help",
    text = "Profiles store loot tracking data.|nChanges take effect immediately.",
    color = {0.7, 0.7, 0.7}
}
```

**Visual**:

```
Profiles store loot tracking data.
Changes take effect immediately.
```

---

### Text

Simple label control.

**Factory**: `Controls.CreateText(parent, opts)`

**Options**:

- `text` (string or function) - Text content OR function `() => string`
- `fontSize` (number, optional) - Font size (default: 14)
- `color` (table, optional) - RGB color (default: white)
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "text",
    text = function()
        local count = GetProfileCount()
        return count .. " profile(s) configured"
    end,
    fontSize = 12,
    color = {0.5, 0.8, 1.0}
}
```

---

### Spacer

Vertical spacing control.

**Factory**: `Controls.CreateSpacer(parent, opts)`

**Options**:

- `height` (number) - Spacing height in pixels

**Example**:

```lua
{
    type = "spacer",
    height = 20
}
```

---

### Dropdown Icon Button

Dropdown with an icon button (e.g., delete).

**Factory**: `Controls.CreateDropdownIconButton(parent, opts)`

**Options**:

- Same as Dropdown, plus:
- `iconButton` (table) - Icon button config
  - `icon` (string) - Icon texture path
  - `onClick` (function) - Click handler
  - `tooltip` (string) - Icon tooltip

**Example**:

```lua
{
    type = "dropdownIconButton",
    label = "Active Profile",
    path = "lootHelper.activeProfileId",
    items = function() return GetProfiles() end,
    iconButton = {
        icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
        onClick = function()
            DeleteActiveProfile()
        end,
        tooltip = "Delete Profile"
    }
}
```

**Visual**:

```
Active Profile: [My Profile ▼] [🗑]
```

---

### Editbox Button

Editbox with an action button.

**Factory**: `Controls.CreateEditboxButton(parent, opts)`

**Options**:

- Same as Editbox, plus:
- `buttonLabel` (string) - Button text
- `onButtonClick` (function) - Button click handler

**Example**:

```lua
{
    type = "editboxButton",
    label = "New Profile",
    placeholder = "Enter name...",
    buttonLabel = "Create",
    onButtonClick = function(text)
        CreateProfile(text)
    end
}
```

**Visual**:

```
New Profile
[Enter name...        ] [ Create ]
```

---

### Scroll List

Scrollable list of items with optional remove buttons, dynamic height, and border styling.

**Factory**: `Controls.CreateScrollList(parent, opts)`

**Options**:

- `items` (function) - Items getter `() => items[]`
- `height` (number, optional) - Fixed list height in pixels (default: 160)
- `maxHeight` (number, optional) - Maximum height when using auto-resize (default: same as height)
- `resize` (boolean, optional) - Auto-resize to fit content (default: true)
- `border` (boolean, optional) - Show border around list (default: false)
- `borderInset` (number, optional) - Border inset padding (default: 4, only if border=true)
- `rowHeight` (number, optional) - Height of each row (default: 20)
- `rowSpacing` (number, optional) - Spacing between rows (default: 2)
- `removeAtlas` (string, optional) - Atlas name for remove button icon (default: "common-icon-redx")
- `onRemove` (function, optional) - Remove button handler `(item) => void`
- `itemTemplate` (function) - Item renderer `(itemFrame, item, index) => void`
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "scrollList",
    height = 200,
    maxHeight = 400,
    resize = true,
    border = true,
    rowHeight = 24,
    rowSpacing = 2,
    items = function()
        return GetAdminList()
    end,
    itemTemplate = function(frame, admin, index)
        frame.text:SetText(admin.name)
        frame.text:SetTextColor(admin.classColor.r, admin.classColor.g, admin.classColor.b)
    end,
    onRemove = function(admin)
        RemoveAdmin(admin)
    end
}
```

**Visual** (with border):

```
┌────────────────┐
│ PlayerName1  X │
│ PlayerName2  X │
│ PlayerName3  X │
│ ...            │
└────────────────┘
```

**Dynamic Height**: When `resize=true`, the list automatically adjusts its height to fit the content, respecting `maxHeight`. When content is smaller than `height`, the list shrinks. When content exceeds `maxHeight`, a scrollbar appears.

**Border Styling**: When `border=true`, a subtle border is drawn around the list with configurable inset padding.

---

## Common Patterns

### Conditional Visibility

Hide controls based on other settings:

```lua
{
    type = "slider",
    label = "Advanced Setting",
    path = "global.advancedValue",
    visible = function()
        return SF.Settings.Store:Get("global.advancedMode") == true
    end
}
```

### Custom Validation

Validate input before saving:

```lua
{
    type = "editbox",
    label = "Profile Name",
    get = function() return tempName end,
    set = function(value)
        local valid, error = SF.Settings.Schema.ValidateProfileName(value)
        if valid then
            tempName = value
        else
            SF:PrintError(error)
        end
    end
}
```

### Dependent Controls

Enable/disable controls based on other values:

```lua
{
    type = "checkbox",
    label = "Use Custom Color",
    path = "global.useCustomColor"
},
{
    type = "slider",
    label = "Color Red",
    path = "global.customColorR",
    min = 0,
    max = 1,
    step = 0.01,
    format = "%.2f",
    enabled = function()
        return SF.Settings.Store:Get("global.useCustomColor") == true
    end
}
```

### Dynamic Items

Update dropdown items dynamically:

```lua
{
    type = "dropdown",
    label = "Select Character",
    path = "global.selectedCharacter",
    items = function()
        -- Re-fetched on each page refresh
        local characters = GetCharacterList()
        local items = {}
        for _, char in ipairs(characters) do
            table.insert(items, {
                value = char.guid,
                text = char.name .. " (" .. char.level .. ")"
            })
        end
        return items
    end
}
```

### Confirmation Dialogs

Add confirmation for destructive actions:

```lua
{
    type = "button",
    label = "Delete All Profiles",
    onClick = function()
        SF.Settings.Dialogs.Confirm(
            "Delete all profiles? This cannot be undone.",
            "Delete All",
            function()
                DeleteAllProfiles()
                SF.Settings.Registry:RefreshPage("lootHelper")
            end
        )
    end
}
```

### Formatted Display Values

Show computed or formatted values:

```lua
{
    type = "display",
    label = "Total Points",
    get = function()
        return CalculateTotalPoints()
    end,
    format = function(value)
        return string.format("%d points", value)
    end
}
```

## Styling Controls

### Colors

Use consistent colors from Style module:

```lua
local Style = SF.Settings.Style

{
    type = "text",
    text = "Warning Message",
    color = Style.COLORS.WARNING  -- {1, 0.5, 0}
}
```

### Fonts

Apply custom fonts:

```lua
{
    type = "text",
    text = "Section Header",
    fontSize = 16,
    -- Font is applied via Style module
}
```

### Spacing

Use consistent spacing:

```lua
{
    type = "spacer",
    height = SF.Settings.Style.SPACING.SECTION  -- 20px
}
```

## Best Practices

### Control Selection

**DO**:

- Use checkbox for on/off toggles
- Use slider for continuous ranges (e.g., 8-24)
- Use dropdown for 3+ discrete options
- Use editbox for free-form text
- Use button for actions (not settings)

**DON'T**:

- Use editbox for booleans (use checkbox)
- Use slider for 2-3 values (use dropdown)
- Use button to set a value (use checkbox/dropdown)

### Labels and Help Text

**DO**:

- Use clear, action-oriented labels
- Provide tooltips for clarification
- Use help text for important notes
- Explain restart requirements

**DON'T**:

- Use technical jargon
- Repeat the label in help text
- Write essay-length explanations

### State Management

**DO**:

- Use path-based binding when possible
- Register callbacks in Apply module for side effects
- Validate input before saving
- Refresh page after structural changes

**DON'T**:

- Fetch data in `get()` on every call (cache it)
- Modify settings in `get()` (side effects)
- Call expensive operations in `visible()` (debounce)

### Performance

**DO**:

- Cache expensive computations
- Use `visible` to skip hidden controls
- Lazy-load dropdown items
- Debounce slider changes in Apply module

**DON'T**:

- Fetch data from server in control functions
- Create controls for permanently hidden items
- Re-compute static data on every refresh

## Debugging Controls

Enable debug logging:

```lua
/sfdebug on
```

**Log Categories**:

- `SETTINGS:CONTROLS` - Control creation and interaction
- `SETTINGS:RENDERER` - Control rendering

**Example Output**:

```
[SETTINGS:CONTROLS] Creating checkbox: Enable Feature
[SETTINGS:CONTROLS] Checkbox 'global.featureEnabled' changed: true → false
[SETTINGS:CONTROLS] Dropdown refreshed with 3 items
```

---

### Scrollable Text

Multi-line, read-only text display with scrolling (useful for logs or large text content).

**Factory**: `Controls.AddScrollableText(section, opts)`

**Options**:

- `label` (string) - Display label
- `height` (number, optional) - Height in pixels (default: 200)
- `get` (function) - Function returning text to display `() => string`
- `tooltip` (string, optional) - Hover tooltip
- `enabled` (function, optional) - Enable state
- `visible` (function, optional) - Visibility

**Example**:

```lua
{
    type = "scrollableText",
    label = "Debug Logs",
    height = 300,
    get = function()
        return GetFormattedLogs()
    end,
    tooltip = "View recent debug messages"
}
```

**Visual**:

```
Debug Logs: [scrollable window]
┌─────────────────────────────┐
│ [2024-01-25] INFO: Started │
│ [2024-01-25] WARN: Memory  │
│ [2024-01-25] ERROR: Failed │
│                             │
└─────────────────────────────┘
```

**Features**:

- Multiline text display
- Scrollable content area
- Copyable text (Ctrl+A, Ctrl+C)
- Auto-refresh on page refresh
- Read-only mode

## Next Steps

- Learn how to [create pages](creating-pages.md) using these controls
- Review [best practices](best-practices.md) for control design
- Explore the [UI layer](ui-layer.md) architecture
