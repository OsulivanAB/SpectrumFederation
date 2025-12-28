# WoW Classes Dictionary

## Overview

The `SF.WOW_CLASSES` dictionary provides standardized information about all 13 World of Warcraft classes, including their official color codes and class icon texture paths. This data is used throughout the addon for consistent UI representation of player classes.

**Location**: `SpectrumFederation/modules/Core.lua`

**Purpose**: Centralized class metadata for UI coloring, class icons, and validation

## Dictionary Structure

Each class entry contains:

- **colorCode**: RGB color values (0-1 range) matching Blizzard's official class colors
- **textureFile**: Path to the class icon texture in WoW's Interface directory

```lua
SF.WOW_CLASSES = {
    CLASSNAME = {
        colorCode = {r = 0.00, g = 0.00, b = 0.00},
        textureFile = "Interface\\Icons\\ClassIcon_ClassName"
    }
}
```

## All Classes

| Class Key | Class Name | Color (RGB 0-1) | Texture Path |
|-----------|------------|-----------------|--------------|
| `WARRIOR` | Warrior | `{r=0.78, g=0.61, b=0.43}` | `Interface\Icons\ClassIcon_Warrior` |
| `PALADIN` | Paladin | `{r=0.96, g=0.55, b=0.73}` | `Interface\Icons\ClassIcon_Paladin` |
| `HUNTER` | Hunter | `{r=0.67, g=0.83, b=0.45}` | `Interface\Icons\ClassIcon_Hunter` |
| `ROGUE` | Rogue | `{r=1.00, g=0.96, b=0.41}` | `Interface\Icons\ClassIcon_Rogue` |
| `PRIEST` | Priest | `{r=1.00, g=1.00, b=1.00}` | `Interface\Icons\ClassIcon_Priest` |
| `DEATHKNIGHT` | Death Knight | `{r=0.77, g=0.12, b=0.23}` | `Interface\Icons\ClassIcon_DeathKnight` |
| `SHAMAN` | Shaman | `{r=0.00, g=0.44, b=0.87}` | `Interface\Icons\ClassIcon_Shaman` |
| `MAGE` | Mage | `{r=0.25, g=0.78, b=0.92}` | `Interface\Icons\ClassIcon_Mage` |
| `WARLOCK` | Warlock | `{r=0.53, g=0.53, b=0.93}` | `Interface\Icons\ClassIcon_Warlock` |
| `MONK` | Monk | `{r=0.00, g=1.00, b=0.59}` | `Interface\Icons\ClassIcon_Monk` |
| `DRUID` | Druid | `{r=1.00, g=0.49, b=0.04}` | `Interface\Icons\ClassIcon_Druid` |
| `DEMONHUNTER` | Demon Hunter | `{r=0.64, g=0.19, b=0.79}` | `Interface\Icons\ClassIcon_DemonHunter` |
| `EVOKER` | Evoker | `{r=0.20, g=0.58, b=0.50}` | `Interface\Icons\ClassIcon_Evoker` |

## Usage Examples

### Accessing Class Data

```lua
-- Get color for a specific class
local warriorColor = SF.WOW_CLASSES.WARRIOR.colorCode
print(warriorColor.r, warriorColor.g, warriorColor.b)  -- 0.78, 0.61, 0.43

-- Get texture path
local paladinTexture = SF.WOW_CLASSES.PALADIN.textureFile
-- "Interface\Icons\ClassIcon_Paladin"
```

### Validating Class Keys

```lua
-- Check if a class exists
local className = "MAGE"
if SF.WOW_CLASSES[className] then
    print("Valid class:", className)
end

-- Iterate through all classes
for className, classData in pairs(SF.WOW_CLASSES) do
    print(className, classData.colorCode.r, classData.textureFile)
end
```

### Creating Colored Text

```lua
-- Use class color for text formatting
local function GetColoredPlayerName(playerName, className)
    if not className or not SF.WOW_CLASSES[className] then
        return playerName  -- No color if class unknown
    end
    
    local color = SF.WOW_CLASSES[className].colorCode
    return string.format(
        "|cff%02x%02x%02x%s|r",
        color.r * 255,
        color.g * 255,
        color.b * 255,
        playerName
    )
end

-- Example usage
local coloredName = GetColoredPlayerName("Shadowbane", "WARRIOR")
-- Returns: "|cffc79b6eShadowbane|r" (tan/brown warrior color)
```

### Setting Texture on Frames

```lua
-- Apply class icon to a texture element
local function SetClassIcon(textureFrame, className)
    if not className or not SF.WOW_CLASSES[className] then
        textureFrame:SetTexture(nil)  -- Clear texture
        return
    end
    
    local texturePath = SF.WOW_CLASSES[className].textureFile
    textureFrame:SetTexture(texturePath)
end

-- Example: Create icon frame
local iconFrame = frame:CreateTexture(nil, "ARTWORK")
iconFrame:SetSize(32, 32)
SetClassIcon(iconFrame, "PALADIN")
```

### Coloring Frame Backgrounds

```lua
-- Set frame background to class color
local function SetClassBackgroundColor(frame, className, alpha)
    if not className or not SF.WOW_CLASSES[className] then
        frame:SetBackdropColor(0.1, 0.1, 0.1, alpha or 0.9)
        return
    end
    
    local color = SF.WOW_CLASSES[className].colorCode
    frame:SetBackdropColor(color.r, color.g, color.b, alpha or 0.9)
end
```

## Integration with Member Class

The Member class uses `SF.WOW_CLASSES` for validation and class information retrieval. See the [Member Class Documentation](../loot-helper/members-class.md) for details on:

- Constructor class parameter validation
- `GetClass()` method
- `GetClassColor()` method
- `GetClassTexture()` method

## Color Conversion Reference

WoW uses different color formats in different contexts:

**0-1 Range (SF.WOW_CLASSES format)**:

```lua
{r = 0.78, g = 0.61, b = 0.43}  -- Warrior tan
```

**0-255 Range (for hex conversion)**:

```lua
r = 0.78 * 255 = 199
g = 0.61 * 255 = 156
b = 0.43 * 255 = 110
```

**Hex String (for colored text)**:

```lua
"|cffc79b6e"  -- Hex: C7=199, 9B=156, 6E=110
```

**Conversion Functions**:

```lua
-- 0-1 to 0-255
local function ColorTo255(color01)
    return math.floor(color01 * 255 + 0.5)
end

-- 0-1 to hex string
local function ColorToHex(r, g, b)
    return string.format("%02x%02x%02x",
        ColorTo255(r),
        ColorTo255(g),
        ColorTo255(b)
    )
end
```

## Best Practices

**Validation**:

Always validate class keys before accessing `SF.WOW_CLASSES`:

```lua
if not className or not SF.WOW_CLASSES[className] then
    -- Handle invalid/missing class
end
```

**Nil-Safe Access**:

Use conditional checks when retrieving nested data:

```lua
local color = SF.WOW_CLASSES[className] and SF.WOW_CLASSES[className].colorCode
if color then
    -- Use color.r, color.g, color.b
end
```

**Immutability**:

Treat `SF.WOW_CLASSES` as read-only. Never modify the dictionary:

```lua
-- ❌ BAD: Don't modify the dictionary
SF.WOW_CLASSES.WARRIOR.colorCode.r = 0.5

-- ✅ GOOD: Copy values if you need to modify
local color = {
    r = SF.WOW_CLASSES.WARRIOR.colorCode.r,
    g = SF.WOW_CLASSES.WARRIOR.colorCode.g,
    b = SF.WOW_CLASSES.WARRIOR.colorCode.b
}
color.r = 0.5  -- Safe to modify copy
```

**Performance**:

Cache class data if using repeatedly in loops:

```lua
-- Cache for performance in tight loops
local classData = SF.WOW_CLASSES[className]
if classData then
    for i = 1, 100 do
        -- Use classData.colorCode and classData.textureFile
    end
end
```

## WoW API Integration

**Getting Player's Class**:

```lua
local _, className = UnitClass("player")  -- Returns localized name and UPPERCASE key
-- className will be "WARRIOR", "PALADIN", etc.
```

**Class-Colored Names in Chat**:

```lua
local name = UnitName("player")
local _, className = UnitClass("player")
local color = SF.WOW_CLASSES[className].colorCode

local coloredName = string.format(
    "|cff%02x%02x%02x%s|r",
    color.r * 255,
    color.g * 255,
    color.b * 255,
    name
)

print(coloredName)  -- Prints name in class color
```

**Raid/Party Member Classes**:

```lua
-- Query raid member classes
for i = 1, GetNumGroupMembers() do
    local unit = "raid" .. i
    local name = UnitName(unit)
    local _, className = UnitClass(unit)
    
    if className and SF.WOW_CLASSES[className] then
        local color = SF.WOW_CLASSES[className].colorCode
        -- Use color for UI display
    end
end
```

## Localization Notes

**Class Keys vs Display Names**:

- Dictionary uses **uppercase English keys** (e.g., `"WARRIOR"`)
- WoW API returns these same keys via `UnitClass()`
- For localized display names, use WoW's localization system

```lua
local localizedName, classKey = UnitClass("player")
-- localizedName = "Guerrier" (French client)
-- classKey = "WARRIOR" (always English uppercase)

-- Use classKey with SF.WOW_CLASSES
local classData = SF.WOW_CLASSES[classKey]
```

**Display Formatting**:

```lua
-- Get both localized name and class color
local localizedName, classKey = UnitClass("player")
local color = SF.WOW_CLASSES[classKey] and SF.WOW_CLASSES[classKey].colorCode

-- Display localized name with correct class color
if color then
    local coloredText = string.format("|cff%02x%02x%02x%s|r",
        color.r * 255, color.g * 255, color.b * 255,
        localizedName
    )
end
```

## Troubleshooting

**Nil Color or Texture**:

If you get nil values, check:

1. Class key is uppercase: `"WARRIOR"` not `"warrior"`
2. Class key is valid (matches dictionary keys)
3. `SF.WOW_CLASSES` is loaded (defined in Core.lua)

```lua
-- Debug helper
local function DebugClassData(className)
    if not SF.WOW_CLASSES then
        print("ERROR: SF.WOW_CLASSES not loaded!")
        return
    end
    
    if not SF.WOW_CLASSES[className] then
        print("ERROR: Unknown class:", className)
        print("Valid classes:", table.concat(tkeys(SF.WOW_CLASSES), ", "))
        return
    end
    
    local data = SF.WOW_CLASSES[className]
    print("Class:", className)
    print("Color:", data.colorCode.r, data.colorCode.g, data.colorCode.b)
    print("Texture:", data.textureFile)
end
```

**Texture Not Displaying**:

If class icons don't show:

1. Check texture path uses double backslashes: `Interface\\Icons\\`
2. Verify texture coordinates if using atlas
3. Ensure frame has proper size set
4. Check texture layer (ARTWORK, OVERLAY, etc.)

**Color Appears Wrong**:

- Verify using 0-1 range, not 0-255
- Check if alpha channel is set correctly
- Ensure hex conversion uses proper format (`|cffRRGGBB`)

## Related Documentation

- [Member Class Documentation](../loot-helper/members-class.md) - Integration with Member instances
- [Development Overview](index.md) - Getting started with addon development
- [Loot Logs](../loot-helper/loot-logs.md) - Event logging system
