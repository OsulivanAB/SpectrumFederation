# Loot Logs Class

The **LootLog class** is the event logging system for [Loot Profiles](loot-profile-class.md) in the Spectrum Federation addon. Each LootLog instance represents a single immutable event that occurred within a profile, such as point awards, gear assignments, or role changes. Loot Profiles contain an array of LootLog instances that serve as the **single source of truth** for all profile activity.

**Purpose and Role**: Loot Logs are the authoritative record of all changes within a loot profile. [Member instances](members-class.md) are computed representations that are rebuilt from these logs using the `UpdateFromLootLog()` method. This log-driven architecture enables:

- **Data integrity**: Logs are immutable once created - they cannot be edited or deleted
- **Multi-user synchronization**: Logs can be synchronized across multiple users editing the same profile
- **Audit trail**: Complete history of all profile changes with timestamps and authors
- **State reconstruction**: Member states can be rebuilt from scratch at any time from the log history

The class uses Lua's metatable-based OOP pattern with validation to ensure data consistency.

## Overview

Each log entry within a loot profile is represented by a `LootLog` instance that tracks:

- **Identity**: Unique ID combining timestamp, author, event type, and counter
- **Event Type**: Type of event (profile creation, point change, armor change, role change)
- **Event Data**: Structured data specific to the event type
- **Metadata**: Timestamp, author (who created the log)

### Data Flow

Loot Logs follow an **immutable, append-only architecture**:

1. **Events occur** - Admin awards points, assigns gear, changes roles
2. **Logs are created** - Each event generates a new immutable log entry
3. **Logs are stored** - Appended to the profile's log array
4. **Members are rebuilt** - Member instances are updated from the complete log history

This ensures all profile data can be reconstructed from the log history at any time.

## Event System

The LootLog class supports four types of events:

### Event Types

| Event Type | Purpose | When Used |
|------------|---------|-----------|
| `PROFILE_CREATION` | Records profile initialization | Once when profile is created |
| `POINT_CHANGE` | Records point awards/deductions | When member points increase or decrease |
| `ARMOR_CHANGE` | Records gear assignments | When armor slot is marked as used or available |
| `ROLE_CHANGE` | Records role modifications | When member role changes between admin/member |

### Event Data Requirements

Each event type requires specific data fields:

**PROFILE_CREATION**:

- No additional data needed (timestamp and author are sufficient)

**POINT_CHANGE**:

- `member` (string) - Full identifier "Name-Realm"
- `change` (string) - SF.LootLogPointChangeTypes constant (INCREMENT or DECREMENT)

**ARMOR_CHANGE**:

- `member` (string) - Full identifier "Name-Realm"
- `slot` (string) - SF.ArmorSlots constant (e.g., HEAD, SHOULDER)
- `action` (string) - SF.LootLogArmorActions constant (USED or AVAILABLE)

**ROLE_CHANGE**:

- `member` (string) - Full identifier "Name-Realm"
- `newRole` (string) - SF.MemberRoles constant (ADMIN or MEMBER)

## Class Structure

### Constants

#### Event Types

```lua
SF.LootLogEventTypes = {
    PROFILE_CREATION = "PROFILE_CREATION",
    POINT_CHANGE = "POINT_CHANGE",
    ARMOR_CHANGE = "ARMOR_CHANGE",
    ROLE_CHANGE = "ROLE_CHANGE"
}
```

Access via:

- `SF.LootLogEventTypes.PROFILE_CREATION`
- `SF.LootLogEventTypes.POINT_CHANGE`
- `SF.LootLogEventTypes.ARMOR_CHANGE`
- `SF.LootLogEventTypes.ROLE_CHANGE`

#### Point Change Types

```lua
SF.LootLogPointChangeTypes = {
    INCREMENT = "INCREMENT",
    DECREMENT = "DECREMENT"
}
```

Access via:

- `SF.LootLogPointChangeTypes.INCREMENT` - Points awarded
- `SF.LootLogPointChangeTypes.DECREMENT` - Points spent

#### Armor Actions

```lua
SF.LootLogArmorActions = {
    USED = "USED",
    AVAILABLE = "AVAILABLE"
}
```

Access via:

- `SF.LootLogArmorActions.USED` - Armor slot marked as used (gear assigned)
- `SF.LootLogArmorActions.AVAILABLE` - Armor slot marked as available (gear removed)

### Properties

Each LootLog instance has the following properties:

| Property | Type | Description |
|----------|------|-------------|
| `id` | string | Unique identifier (timestamp-author-eventType-counter) |
| `timestamp` | number | Unix timestamp when log was created |
| `author` | string | Who created the log (e.g., "Shadowbane-Garona") |
| `eventType` | string | Type of event (from SF.LootLogEventTypes) |
| `data` | table | Event-specific data (structure varies by event type) |

## Creating Logs

### Constructor

The LootLog class uses **dot notation** for the constructor (factory function pattern):

```lua
local log = SF.LootLog.new(eventType, eventData)
```

**Parameters**:

- `eventType` (string, required) - Event type from `SF.LootLogEventTypes`
- `eventData` (table, required) - Event-specific data matching the template for that event type

**Returns**:

- `LootLog` instance if successful
- `nil` if validation fails

**Validation**:

The constructor performs extensive validation:

1. Event type must be valid
2. Event data must contain all required fields
3. Event-specific validation (member exists, valid constants, etc.)

### Getting Event Data Templates

Before creating a log, get an empty template for the event type:

```lua
local template = SF.LootLog.GetEventDataTemplate(eventType)
```

**Parameters**:

- `eventType` (string, required) - Event type from `SF.LootLogEventTypes`

**Returns**:

- Empty template table (copy) with required fields
- `nil` if event type is invalid

**Important**: This returns a **copy** of the template to prevent accidental corruption of the original template definition.

### Example Log Creation

**Point Change Log**:

```lua
-- Get template for point change event
local eventType = SF.LootLogEventTypes.POINT_CHANGE
local eventData = SF.LootLog.GetEventDataTemplate(eventType)

-- Fill in required fields
eventData.member = "Shadowbane-Garona"
eventData.change = SF.LootLogPointChangeTypes.INCREMENT

-- Create the log
local log = SF.LootLog.new(eventType, eventData)

if log then
    -- Log created successfully
    -- TODO: Add to profile's log array
else
    -- Validation failed, log not created
    print("Failed to create log entry")
end
```

## Instance Methods

All instance methods use **colon notation** (`:`) which automatically passes `self`:

```lua
log:MethodName(parameters)
```

### Getter Methods

#### GetID()

Returns the log's unique identifier.

```lua
local id = log:GetID()
-- Returns: "1703721234_Shadowbane-Garona_POINT_CHANGE_1"
```

**ID Format**: `timestamp_author_eventType_counter`

**Use case**: Unique keys for log storage, debugging, log deduplication.

#### GetTimestamp()

Returns the Unix timestamp when the log was created.

```lua
local timestamp = log:GetTimestamp()
-- Returns: number (e.g., 1703721234)
```

**Use case**: Sorting logs chronologically, displaying log times, filtering by date range.

#### GetAuthor()

Returns who created the log in "Name-Realm" format.

```lua
local author = log:GetAuthor()
-- Returns: "Shadowbane-Garona"
```

**Use case**: Displaying who made changes, filtering logs by author, audit trail.

#### GetEventType()

Returns the type of event this log represents.

```lua
local eventType = log:GetEventType()
-- Returns: "POINT_CHANGE", "ARMOR_CHANGE", etc.
```

**Use case**: Filtering logs by type, conditional processing, UI display.

#### GetEventData()

Returns the event-specific data table.

```lua
local data = log:GetEventData()
-- Returns: { member = "Bob-Garona", change = "INCREMENT" }

-- Access specific fields
local memberName = data.member
local changeType = data.change
```

**Use case**: Extracting log details, rebuilding member states, displaying log details in UI.

## Static Methods

Static methods use **dot notation** (`.`) and can be called without an instance:

### GetEventDataTemplate(eventType)

Returns an empty template for the specified event type (see [Getting Event Data Templates](#getting-event-data-templates) above).

## Validation System

The LootLog class uses a separate validation module (`LootLogValidators.lua`) to ensure data integrity:

### Validation Process

1. **Event Type Validation**: Ensures event type is valid
2. **Template Validation**: Checks all required fields are present
3. **Event-Specific Validation**: Validates field values based on event type

### Event-Specific Validators

**POINT_CHANGE Validation**:

- Member exists in profiles
- Change type is valid (INCREMENT or DECREMENT)

**ARMOR_CHANGE Validation**:

- Member exists in profiles
- Armor slot is valid (from SF.ArmorSlots)
- Action is valid (USED or AVAILABLE)

**ROLE_CHANGE Validation**:

- Member exists in profiles
- New role is valid (from SF.MemberRoles)

## Usage Examples

### Creating a Profile Creation Log

```lua
-- Profile creation requires no additional data
local eventType = SF.LootLogEventTypes.PROFILE_CREATION
local eventData = SF.LootLog.GetEventDataTemplate(eventType)

local log = SF.LootLog.new(eventType, eventData)
-- Log records: timestamp, author (current player), event type
```

### Awarding Points to a Member

```lua
-- Member receives points for raid participation
local eventType = SF.LootLogEventTypes.POINT_CHANGE
local eventData = SF.LootLog.GetEventDataTemplate(eventType)

eventData.member = "Healer-Garona"
eventData.change = SF.LootLogPointChangeTypes.INCREMENT

local log = SF.LootLog.new(eventType, eventData)
-- TODO: table.insert(profile.logs, log)
```

### Recording Gear Assignment

```lua
-- Member receives a head piece
local eventType = SF.LootLogEventTypes.ARMOR_CHANGE
local eventData = SF.LootLog.GetEventDataTemplate(eventType)

eventData.member = "Tank-Garona"
eventData.slot = SF.ArmorSlots.HEAD
eventData.action = SF.LootLogArmorActions.USED

local log = SF.LootLog.new(eventType, eventData)
-- TODO: table.insert(profile.logs, log)
```

## Best Practices

**Always use templates**:

```lua
-- ✅ Good: Get template first
local eventData = SF.LootLog.GetEventDataTemplate(eventType)
eventData.member = "Name-Realm"

-- ❌ Bad: Manual table construction
local eventData = { member = "Name-Realm" }  -- Missing required fields!
```

**Always use constants**:

```lua
-- ✅ Good: Use exported constants
eventData.change = SF.LootLogPointChangeTypes.INCREMENT

-- ❌ Bad: String literals
eventData.change = "INCREMENT"  -- Typos won't be caught!
```

**Always validate log creation**:

```lua
-- ✅ Good: Check if log was created
local log = SF.LootLog.new(eventType, eventData)
if not log then
    SF:PrintError("Failed to create log entry")
    return
end

-- ❌ Bad: Assume success
local log = SF.LootLog.new(eventType, eventData)
table.insert(profile.logs, log)  -- Could be nil!
```

**Never modify logs after creation**:

```lua
-- ❌ Bad: Modifying log data
local log = SF.LootLog.new(eventType, eventData)
log.data.member = "DifferentMember"  -- Breaks immutability!

-- ✅ Good: Create a new log for corrections
local correctionLog = SF.LootLog.new(eventType, correctedEventData)
```

## File Locations

**Source Files**:

- `SpectrumFederation/modules/LootHelper/LootLogs.lua` - LootLog class definition
- `SpectrumFederation/modules/LootHelper/LootLogValidators.lua` - Validation functions

**TOC Load Order**: LootLogValidators.lua loads before LootLogs.lua to ensure validators are available during log creation.