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

- `profileId` (string) - Unique identifier of the profile being created

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

Each LootLog instance has the following **private** properties (prefixed with `_`):

| Property | Type | Description |
|----------|------|-------------|
| `_id` | string | Unique identifier (author:counter format) |
| `_timestamp` | number | Unix timestamp when log was created |
| `_author` | string | Who created the log (e.g., "Shadowbane-Garona") |
| `_counter` | number | Per-author counter for uniqueness |
| `_eventType` | string | Type of event (from SF.LootLogEventTypes) |
| `_data` | table | Event-specific data (structure varies by event type) |

**Important**: All properties are private and must be accessed via getter methods. Direct property access is not supported.

## Creating Logs

### Constructor

The LootLog class uses **dot notation** for the constructor (factory function pattern):

```lua
local log = SF.LootLog.new(eventType, eventData, opts)
```

**Parameters**:

- `eventType` (string, required) - Event type from `SF.LootLogEventTypes`
- `eventData` (table, required) - Event-specific data matching the template for that event type
- `opts` (table, optional) - Optional parameters:
    - `author` (string) - Override author (used for imports/special cases)
    - `counter` (number) - Override counter (used for imports/special cases)
    - `timestamp` (number) - Override timestamp (used for imports)
    - `skipPermission` (boolean) - Bypass admin check (used for profile creation/import)

**Returns**:

- `LootLog` instance if successful
- `nil` if validation fails

**Permission Enforcement**:

- By default, only admins can create logs (checked via `activeProfile:IsCurrentUserAdmin()`)
- Use `opts.skipPermission = true` to bypass this check (for profile creation or imports)

**Validation**:

The constructor performs extensive validation:

1. Permission check (unless `skipPermission` is true)
2. Event type must be valid
3. Event data must contain all required fields
4. Event-specific validation (member exists, valid constants, etc.)
5. Counter allocation from active profile (or use `opts.counter` override)

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
-- Returns: "Shadowbane-Garona:1"
```

**ID Format**: `author:counter` (e.g., "PlayerName-RealmName:123")

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

#### GetCounter()

Returns the per-author counter value for this log.

```lua
local counter = log:GetCounter()
-- Returns: number (e.g., 1, 2, 3...)
```

**Use case**: Ensuring log uniqueness within author's logs, debugging log ID generation.

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

#### GetSerializedData()

Returns a serialized string representation of the log using CBOR (Concise Binary Object Representation) encoding with Base64 encoding for text transmission.

```lua
local serialized = log:GetSerializedData()
-- Returns: Base64-encoded CBOR string or nil on failure
```

**Serialization Format**: The method creates a versioned data structure containing all log properties:

```lua
{
    version = 2,            -- Format version (current)
    _id = "Name-Realm:1",   -- Log unique identifier
    _timestamp = 1703721234, -- Unix timestamp
    _author = "Name-Realm", -- Log creator
    _counter = 1,           -- Per-author counter
    _eventType = "...",     -- Event type constant
    _data = {...}           -- Event-specific data table
}
```

**Use case**: Synchronizing logs between clients via addon communication system, storing logs in external systems, creating log backups.

**Important Notes**:

- Returns `nil` if serialization fails (with debug error logging)
- Uses WoW's `C_EncodingUtil.SerializeCBOR()` and `C_EncodingUtil.EncodeBase64()` APIs
- Includes version field for backward compatibility with future format changes
- Compact binary format suitable for network transmission

## Serialization Methods

Serialization methods enable logs to be transmitted between clients for multi-user profile synchronization.

### newFromSerialized(serializedData)

Static constructor that creates a LootLog instance from serialized data. This is the counterpart to `GetSerializedData()` and is used to reconstruct logs received from other clients.

```lua
local serializedString = "..."  -- Received from another client
local log = SF.LootLog.newFromSerialized(serializedString)

if log then
    -- Successfully deserialized
    print("Received log:", log:GetEventType())
else
    -- Deserialization failed
    print("Invalid log data received")
end
```

**Parameters**:

- `serializedData` (string) - Base64-encoded CBOR string from `GetSerializedData()`

**Returns**:

- LootLog instance with exact values from serialized data, or `nil` if deserialization failed

**Validation Process**:

1. Validates input is a non-empty string
2. Decodes Base64 to binary CBOR data
3. Deserializes CBOR to Lua table
4. Validates format version is 2 (current LOG_FORMAT_VERSION)
5. Validates all required fields are present (_id, _timestamp, _author, _counter, _eventType, _data)
6. Creates instance directly without re-validation

**Important Characteristics**:

- **Preserves exact data**: Uses all values from serialized data (id, timestamp, author, etc.)
- **No validation**: Skips event type and data validation (assumes source already validated)
- **No counter increment**: Does not increment session log counter (preserves original ID)
- **Identical logs**: Ensures all clients have identical log entries after synchronization

**Error Handling**:

- Returns `nil` on any deserialization error
- Logs warnings via `SF.Debug:Warn()` for debugging
- Safe to use in production (won't throw errors)

### Serialization Round-Trip Example

Complete example showing log creation, serialization, and deserialization:

```lua
-- Client A: Create and serialize a log
local eventType = SF.LootLogEventTypes.POINT_CHANGE
local eventData = SF.LootLog.GetEventDataTemplate(eventType)
eventData.member = "Healer-Garona"
eventData.change = SF.LootLogPointChangeTypes.INCREMENT

local originalLog = SF.LootLog.new(eventType, eventData)
if not originalLog then
    print("Failed to create log")
    return
end

-- Serialize for transmission
local serialized = originalLog:GetSerializedData()
if not serialized then
    print("Failed to serialize log")
    return
end

-- Simulate sending via addon communication
-- SendAddonMessage("SpectrumFed_LogSync", serialized, "RAID")

-- Client B: Receive and deserialize
-- local serialized = ... (received from SendAddonMessage)
local receivedLog = SF.LootLog.newFromSerialized(serialized)
if not receivedLog then
    print("Failed to deserialize log")
    return
end

-- Verify logs are identical
print("Original ID:", originalLog:GetID())
print("Received ID:", receivedLog:GetID())
print("IDs match:", originalLog:GetID() == receivedLog:GetID())

-- Both logs will have identical properties:
-- - Same ID (author:counter format, e.g., "Healer-Garona:1")
-- - Same timestamp
-- - Same author
-- - Same counter
-- - Same event type
-- - Same event data
```

**Why CBOR Format?**

The addon uses CBOR (Concise Binary Object Representation) for serialization because:

- **WoW Standard**: WoW provides native `C_EncodingUtil.SerializeCBOR()` API
- **Compact**: Binary format is smaller than JSON for network transmission
- **Type-Safe**: Preserves Lua types (numbers, strings, tables) accurately
- **Reliable**: Well-tested for addon communication in WoW

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
-- Profile creation requires profileId
local eventType = SF.LootLogEventTypes.PROFILE_CREATION
local eventData = SF.LootLog.GetEventDataTemplate(eventType)

eventData.profileId = "MyProfile-UniqueID"

-- Skip permission check since profile might not exist yet
local log = SF.LootLog.new(eventType, eventData, { skipPermission = true })
-- Log records: timestamp, author (current player), event type, profileId
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