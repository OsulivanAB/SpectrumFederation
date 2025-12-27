# Members Class

The **Members class** is the core data structure for individual raid members within a [Loot Profile](loot-profile-class.md) in the Spectrum Federation addon. Each Loot Profile contains a dictionary of Member instances that represent the current state of each member's loot profile.

**Purpose and Role**: Member instances serve as a computed, queryable representation of member data that is generated from the profile's [Loot Logs](loot-logs.md). The logs are the single source of truth, recording all point awards and gear assignments. Member instances are rebuilt from these logs using the [`UpdateFromLootLog()`](#updatefromlootlog) method, and then used to drive UI displays showing point balances, armor slot states, and other member information. This log-driven architecture enables easy syncing between multiple users editing the same profile - logs can be synchronized across users while each user rebuilds their local member instances from the shared log data. This ensures data consistency while providing efficient access for UI rendering.

The class uses Lua's metatable-based OOP pattern to provide instance methods for point management, equipment tracking, and role administration.

## Overview

Each member within a loot profile is represented by a `Member` instance that tracks:

- **Identity**: Character name and realm
- **Role**: Admin or member permissions
- **Point Balance**: Available loot points (can be positive or negative)
- **Armor Slots**: 16 equipment slots, each can be used once per member

### Data Flow

Member instances follow a **log-driven architecture**:

1. **Profile Loot Logs** are the **primary data source** - All point awards and gear assignments are recorded in logs
2. **Member instances are generated from logs** - The `UpdateFromLootLog()` method rebuilds member state from log history
3. **Member objects drive the UI** - The UI displays point balances and armor slot states from member instances

This ensures the logs remain the single source of truth, while member instances provide an efficient, queryable representation for UI rendering.

## Point System

The Members class implements a **one-point-per-slot** system:

- Each member has a point balance that can increase or decrease
- Each of the 16 armor slots can only be "used" **once per member**
- When a slot is marked as `true`, the member has spent their ONE point for that specific armor piece
- When a slot is `false`, the member has not yet used their point for that armor piece
- **Point debt is allowed**: Members can go into negative point balances for edge cases (e.g., accidental gear awards)

## Class Structure

### Constants

#### Member Roles
```lua
SF.MemberRoles = {
    ADMIN = "admin",
    MEMBER = "member"
}
```

Roles can be accessed via:

- `SF.MemberRoles.ADMIN` - Admin permissions
- `SF.MemberRoles.MEMBER` - Standard member permissions

#### Armor Slots
```lua
SF.ArmorSlots = {
    HEAD = "Head",
    SHOULDER = "Shoulder",
    NECK = "Neck",
    BACK = "Back",
    CHEST = "Chest",
    BRACERS = "Bracers",
    WEAPON = "Weapon",
    OFFHAND = "OffHand",
    HANDS = "Hands",
    BELT = "Belt",
    PANTS = "Pants",
    BOOTS = "Boots",
    RING1 = "Ring1",
    RING2 = "Ring2",
    TRINKET1 = "Trinket1",
    TRINKET2 = "Trinket2"
}
```

Access via:

- `SF.ArmorSlots.HEAD` - "Head"
- `SF.ArmorSlots.WEAPON` - "Weapon"
- etc.

### Properties

Each Member instance has the following properties:

| Property | Type | Description |
|----------|------|-------------|
| `name` | string | Character name (e.g., "Shadowbane") |
| `realm` | string | Realm name (e.g., "Garona") |
| `role` | string | Member role ("admin" or "member") |
| `class` | string\|nil | WoW class name (e.g., "WARRIOR") or nil if not set |
| `pointBalance` | number | Current loot points (can be negative) |
| `armor` | table | Dictionary of 16 armor slots (boolean values) |

## Creating Members

### Constructor

The Members class uses **dot notation** for the constructor (factory function pattern):

```lua
local member = SF.Member.new(name, realm, role, class)
```

**Parameters**:

- `name` (string, required) - Character name
- `realm` (string, required) - Realm name
- `role` (string, optional) - Member role, defaults to `"member"`
- `class` (string, optional) - WoW class name (e.g., "WARRIOR", "PALADIN"), must match `SF.WOW_CLASSES` keys

**Example**:

```lua
-- Create a standard member
local member = SF.Member.new("Shadowbane", "Garona")

-- Create an admin
local admin = SF.Member.new("Guildmaster", "Garona", SF.MemberRoles.ADMIN)

-- Create a member with class information
local warrior = SF.Member.new("Tanky", "Garona", SF.MemberRoles.MEMBER, "WARRIOR")

-- Create an admin with class
local paladinAdmin = SF.Member.new("Healz", "Garona", SF.MemberRoles.ADMIN, "PALADIN")
```

### Initial State

New members are created with:

- Point balance: `0`
- All armor slots: `false` (unused)
- Role: `"member"` (unless specified)
- Class: `nil` (unless specified and valid)

**Class Validation**: If a class parameter is provided but doesn't match a key in `SF.WOW_CLASSES`, the member's class will be set to `nil` and a warning will be logged (if debug enabled).

## Instance Methods

All instance methods use **colon notation** (`:`) which automatically passes `self`:

```lua
member:MethodName(parameters)
```

### Identity Methods

#### GetFullIdentifier()

Returns the member's full character identifier in `"Name-Realm"` format.

```lua
local identifier = member:GetFullIdentifier()
-- Returns: "Shadowbane-Garona"
```

**Use case**: Unique keys for member dictionaries, displaying character names.

#### GetClass()

Returns the member's WoW class name or `nil` if not set.

```lua
local className = member:GetClass()
-- Returns: "WARRIOR" or nil
```

**Use case**: Determine member's class for UI display, validation, or filtering.

#### GetClassColor()

Returns the RGB color table for the member's class, or `nil` if class is not set.

```lua
local color = member:GetClassColor()
if color then
    -- color.r, color.g, color.b are values from 0-1
    print(color.r, color.g, color.b)
end
```

**Returns**: `{r = 0.78, g = 0.61, b = 0.43}` (example for Warrior) or `nil`

**Use case**: Color-coding member names in UI, setting frame background colors.

#### GetClassTexture()

Returns the texture file path for the member's class icon, or `nil` if class is not set.

```lua
local texturePath = member:GetClassTexture()
-- Returns: "Interface\\Icons\\ClassIcon_Warrior" or nil

if texturePath then
    iconFrame:SetTexture(texturePath)
end
```

**Use case**: Displaying class icons next to member names in UI.

**Note**: See [WoW Classes Documentation](wow-classes.md) for complete information about class colors and textures.

#### GetPointBalance()
Returns the member's current point balance.

```lua
local points = member:GetPointBalance()
-- Returns: number (e.g., 5, 0, -2)
```

**Use case**: Displaying point balance in UI, checking if member has points before operations.

#### GetArmorStatuses()
Returns the entire armor dictionary with all 16 slots and their boolean values.

```lua
local armorDict = member:GetArmorStatuses()
-- Returns: { Head = false, Shoulder = true, ... }

-- Example: Check specific slot
if armorDict[SF.ArmorSlots.HEAD] then
    -- Head slot is used
end
```

**Use case**: Displaying armor slot status in UI, exporting member data, checking multiple slots.

#### IsAdmin()
Checks if the member has admin role.

```lua
local isAdmin = member:IsAdmin()
-- Returns: true if admin, false otherwise
```

**Use case**: Permission checks, UI access control, displaying admin badges.

### Role Management

#### SetRole(newRole)
Updates the member's role with validation and admin permission checks.

```lua
local success = member:SetRole(SF.MemberRoles.ADMIN)
```

**Parameters**:

- `newRole` (string) - New role (`SF.MemberRoles.ADMIN` or `SF.MemberRoles.MEMBER`)

**Returns**: `boolean` - `true` if successful, `false` otherwise

**Features**:

- Validates role against `MEMBER_ROLES` constants
- Logs the change
- Enforces admin permissions

### Point Management

#### IncrementPoints()
Increases the member's point balance by 1.

```lua
member:IncrementPoints()
```

**Use cases**:

- Awarding points for raid participation
- Returning points when removing armor slot usage
- Manual point adjustments

#### DecrementPoints()
Decreases the member's point balance by 1.

```lua
member:DecrementPoints()
```

**Features**:

- Allows negative balances (point debt)
- Logs the change
- No floor restriction

**Use cases**:

- Spending points on gear
- Manual point deductions

### Equipment Management

#### ToggleEquipment(slot)
Toggles an armor slot's usage state. This is the **primary method for UI interactions**.

```lua
local success = member:ToggleEquipment(SF.ArmorSlots.HEAD)
```

**Parameters**:

- `slot` (string) - Armor slot name (use `SF.ArmorSlots` constants)

**Returns**: `boolean` - `true` if successful, `false` if invalid slot

**Behavior**:

**When slot is `false` (not used) → Toggle to `true` (used)**:

1. Calls [`DecrementPoints()`](#decrementpoints)
2. Marks slot as `true`
3. Logs the change

**When slot is `true` (used) → Toggle to `false` (not used)**:

1. Calls [`IncrementPoints()`](#incrementpoints)
2. Marks slot as `false`
3. Logs the change

**Example UI integration**:
```lua
-- Button click handler for a specific armor slot button
local slotName = SF.ArmorSlots.HEAD  -- Use ARMOR_SLOTS constant
local member = GetCurrentMember()
local success = member:ToggleEquipment(slotName)

if success then
    -- Update button visual state
    UpdateButtonAppearance(slotName, member.armor[slotName])
end
```

#### UpdateFromLootLog()
Rebuilds the member's point balance and armor states from loot logs. Used to synchronize member state with historical log data.

```lua
member:UpdateFromLootLog()
```

**Process**:

1. Filters loot logs for this specific member
2. Updates each armor slot based on most recent log entry
3. Calculates point balance from point log entries

**Use cases**:

- Initial profile loading
- Recalculating after log imports
- Fixing desynced member states

## Usage Examples

### Creating and Managing a Member

```lua
-- Create a new member
local member = SF.Member.new("Shadowbane", "Garona")

-- Award initial points
member:IncrementPoints()
member:IncrementPoints()
member:IncrementPoints()
-- Point balance: 3

-- Member receives head piece
member:ToggleEquipment(SF.ArmorSlots.HEAD)
-- Point balance: 2, Head slot: true

-- Member receives shoulder piece
member:ToggleEquipment(SF.ArmorSlots.SHOULDER)
-- Point balance: 1, Shoulder slot: true

-- Accidentally award chest piece when they have no points
-- First, decrement point to get to 0
member:DecrementPoints()
-- Point balance: 0

member:ToggleEquipment(SF.ArmorSlots.CHEST)
-- Point balance: -1 (point debt), Chest slot: true

-- Remove incorrect chest award
member:ToggleEquipment(SF.ArmorSlots.CHEST)
-- Point balance: 0, Chest slot: false
```

## File Location

**Source**: `SpectrumFederation/modules/LootHelper/Members.lua`

**TOC Load Order**: Loaded early in the LootHelper module chain, before profile management.