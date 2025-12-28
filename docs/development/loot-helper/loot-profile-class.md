# Loot Profile Class

The **LootProfile class** is the primary data structure for managing loot distribution in the Spectrum Federation addon. Each LootProfile instance represents a named profile containing [Members](members-class.md), [Loot Logs](loot-logs.md), and administrative metadata. Profiles can be created, managed, and synchronized across multiple users for guild loot coordination. You can have multiple classes but only one can be active at a time.

**Purpose and Role**: LootProfile instances serve as containers for all loot-related data within a specific context (e.g., a raid tier, guild group, or loot council). Each profile maintains:

- **Member roster**: A list of [LootProfileMember](members-class.md) instances representing raid participants
- **Event history**: An array of [LootLog](loot-logs.md) instances recording all profile activity
- **Administrative control**: Author, owner, and admin user lists for permission management
- **State tracking**: Active/inactive status for managing multiple concurrent profiles

The class uses Lua's metatable-based OOP pattern to provide instance methods for profile management, member administration, and log tracking.

## Overview

Each loot profile is represented by a `LootProfile` instance that tracks:

- **Identity**: Profile name (unique identifier)
- **Ownership**: Author (creator) and owner (current controller)
- **Member Roster**: Array of LootProfileMember instances
- **Event History**: Array of LootLog instances (append-only, chronologically sorted)
- **Admin Control**: List of admin user identifiers
- **State**: Active/inactive status.

### Data Flow

Loot Profiles follow a **log-driven, permission-controlled architecture**:

1. **Profile Creation** - User creates a new profile, becoming the initial author and owner
2. **Member Management** - Admins add members to the profile roster
3. **Event Logging** - All changes are recorded as immutable LootLog entries
4. **State Updates** - Member instances are rebuilt from log history
5. **Synchronization** - Profiles can be shared across users (future feature)

This ensures administrative control while maintaining data integrity through the log system.

## Permission System

The LootProfile class implements an **admin-based permission model**:

- **Author**: Original creator of the profile (immutable)
- **Owner**: Current controller of the profile (transferable)
- **Admin Users**: List of users with administrative permissions
- **Standard Users**: Read-only access (future feature)

**Admin Permissions**:

- Add/remove members
- Award points and assign gear
- Create loot log entries
- Modify profile settings

**Current User Validation**:

- The `IsCurrentUserAdmin()` method checks if the active player is in the admin list
- Methods that modify profile data enforce admin permissions
- Non-admin users cannot make changes (returns `false` with debug warning)

## Class Structure

### Properties

Each LootProfile instance has the following private properties:

| Property | Type | Description | Getter Method | Setter Method |
|----------|------|-------------|---------------|---------------|
| `_profileName` | string | Unique name of the profile | [`GetProfileName()`](#getprofilename) | [`SetProfileName()`](#setprofilenamenewname) |
| `_author` | string | Original creator ("Name-Realm" format) | [`GetAuthor()`](#getauthor) | N/A (immutable) |
| `_owner` | string | Current owner ("Name-Realm" format) | [`GetOwner()`](#getowner) | [`SetOwner()`](#setownernewowner) |
| `_members` | table | Array of LootProfileMember instances | [`GetMemberList()`](#getmemberlist) | [`AddMember()`](#addmembermember) |
| `_lootLogs` | table | Array of LootLog instances (chronologically sorted) | [`GetLootLogs()`](#getlootlogs) | [`AddLootLog()`](#addlootloglootlog) |
| `_adminUsers` | table | Array of admin user identifiers ("Name-Realm" format) | [`GetAdminList()`](#getadminlist), [`IsCurrentUserAdmin()`](#iscurrentuseradmin) | [`AddAdminUser()`](#addadminusermember) |
| `_activeProfile` | boolean | Active/inactive status | [`IsActive()`](#isactive) | [`SetActive()`](#setactiveisactive) |

## Creating Profiles

### Constructor

The LootProfile class uses **dot notation** for the constructor (factory function pattern):

```lua
local profile = SF.LootProfile.new(profileName)
```

**Parameters**:

- `profileName` (string, required) - Unique name for the profile

**Validation**:

- Profile name must be a non-empty string
- Automatically creates a profile creation log entry
- Automatically adds the current player as author, owner, and first admin
- Creates an initial LootProfileMember instance for the author

**Example**:

```lua
-- Create a new profile
local raidProfile = SF.LootProfile.new("Mythic Raid Team 1")

-- Profile is automatically initialized with:
-- - Author: Current player
-- - Owner: Current player
-- - Admin users: [Current player]
-- - Members: [Current player as admin member]
-- - Loot logs: [Profile creation event]
-- - Active: false
```

**Error Handling**:

- Returns `nil` if profile name validation fails
- Returns `nil` if log entry creation fails
- Returns `nil` if author member creation fails
- Logs warnings to debug system on failure

### Initial State

New profiles are created with:

- **Author/Owner**: Current player's full identifier
- **Admin Users**: Author added to admin list
- **Members**: Author added as first member with admin role
- **Loot Logs**: Profile creation event logged
- **Active Status**: `false` (inactive by default)

## Instance Methods

All instance methods use **colon notation** (`:`) which automatically passes `self`:

```lua
profile:MethodName(parameters)
```

### Identity Methods

#### GetProfileName()

Returns the profile's unique name.

**Returns**:

- `string` - Profile name

**Example**:

```lua
local name = profile:GetProfileName()
print("Profile name:", name)  -- "Mythic Raid Team 1"
```

#### GetAuthor()

Returns the profile's original author (creator) identifier.

**Returns**:

- `string` - Author identifier in "Name-Realm" format

**Example**:

```lua
local author = profile:GetAuthor()
print("Created by:", author)  -- "Shadowbane-Garona"
```

#### GetOwner()

Returns the profile's current owner identifier.

**Returns**:

- `string` - Owner identifier in "Name-Realm" format

**Example**:

```lua
local owner = profile:GetOwner()
print("Owned by:", owner)  -- "Guildmaster-Garona"
```

**Usage Note**: The owner can be different from the author if ownership has been transferred via `SetOwner()`.

### State Management

#### IsActive()

Checks if the profile is currently active.

**Returns**:

- `boolean` - `true` if active, `false` if inactive

**Example**:

```lua
if profile:IsActive() then
    print("Profile is currently active")
else
    print("Profile is inactive")
end
```

#### SetActive(isActive)

Sets the profile's active/inactive status.

**Parameters**:

- `isActive` (boolean) - `true` to activate, `false` to deactivate

**Example**:

```lua
-- Activate the profile
profile:SetActive(true)

-- Deactivate the profile
profile:SetActive(false)
```

**Usage Note**: Only one profile should be active at a time in the UI. The active profile is used for loot helper operations.

### Timestamp Methods

#### GetCreationTime()

Retrieves the profile's creation timestamp from the first PROFILE_CREATION log entry.

**Returns**:

- `number` - Creation timestamp (Unix epoch time)
- `nil` - If no creation log found

**Example**:

```lua
local created = profile:GetCreationTime()
if created then
    local formattedTime = SF:FormatTimestampForUser(created)
    print("Profile created:", formattedTime)
end
```

#### GetLastModifiedTime()

Finds the most recent timestamp across all loot log entries.

**Returns**:

- `number` - Most recent log timestamp
- `nil` - If no logs exist

**Example**:

```lua
local modified = profile:GetLastModifiedTime()
if modified then
    local formattedTime = SF:FormatTimestampForUser(modified)
    print("Last modified:", formattedTime)
end
```

**Usage Note**: This iterates through all log entries to find the maximum timestamp. Logs are kept sorted chronologically for efficiency.

### Permission Methods

#### IsCurrentUserAdmin()

Checks if the currently logged-in player is an admin of this profile.

**Returns**:

- `boolean` - `true` if current user is admin, `false` otherwise

**Example**:

```lua
if profile:IsCurrentUserAdmin() then
    print("You have admin permissions for this profile")
    -- Show admin UI controls
else
    print("You do not have admin permissions")
    -- Hide admin UI controls
end
```

**Usage Note**: This method is critical for enforcing permissions. Many profile modification methods check this internally before allowing changes.

### Member Management

#### GetMemberList()

Retrieves a list of all member identifiers in the profile.

**Returns**:

- `table` - Array of member full identifiers ("Name-Realm" format)

**Example**:

```lua
local members = profile:GetMemberList()
for i, memberID in ipairs(members) do
    print(i, memberID)
end
-- Output:
-- 1 Shadowbane-Garona
-- 2 Tanky-Garona
-- 3 Healz-Garona
```

**Usage Note**: Returns identifiers only. To access member objects, iterate through the `_members` property directly (internal use).

#### GetLootLogs()

Retrieves the complete array of loot log entries for the profile.

**Returns**:

- `table` - Array of LootLog instances (chronologically sorted by timestamp)

**Example**:

```lua
local logs = profile:GetLootLogs()
print("Total log entries:", #logs)

-- Iterate through logs
for i, log in ipairs(logs) do
    local timestamp = SF:FormatTimestampForUser(log:GetTimestamp())
    local eventType = log:GetEventType()
    print(string.format("[%s] %s", timestamp, eventType))
end
```

**Usage Note**: Returns the internal `_lootLogs` array. Logs are automatically kept sorted by timestamp. Used by Member instances to rebuild state via `UpdateFromLootLog()`.

#### GetAdminList()

Retrieves a list of all admin user identifiers in the profile.

**Returns**:

- `table` - Array of admin user full identifiers ("Name-Realm" format)

**Example**:

```lua
local admins = profile:GetAdminList()
print("Profile admins:")
for i, adminID in ipairs(admins) do
    print(i, adminID)
end
-- Output:
-- Profile admins:
-- 1 Shadowbane-Garona
-- 2 Guildmaster-Garona
```

**Usage Note**: Returns the internal `_adminUsers` array. This lists all users who have administrative permissions on the profile. Use with `IsCurrentUserAdmin()` to check if the active player has admin rights.

#### AddMember(member)

Adds a LootProfileMember instance to the profile's member roster.

**Parameters**:

- `member` (LootProfileMember) - Instance to add

**Returns**:

- `boolean` - `true` if added successfully, `false` if validation fails

**Validation**:

- Must be a valid LootProfileMember instance (metatable check)
- Logs warning if invalid instance provided

**Example**:

```lua
-- Create a new member
local newMember = SF.LootProfileMember.new("Tanky", "Garona", SF.LootProfileMemberRoles.MEMBER, "WARRIOR")

-- Add to profile
if profile:AddMember(newMember) then
    SF:PrintSuccess("Member added successfully")
else
    SF:PrintError("Failed to add member")
end
```

**Usage Note**: This adds the member to the roster but does not create a log entry. Consider creating a corresponding log entry for audit purposes.

#### AddAdminUser(member)

Adds a LootProfileMember instance to the profile's admin user list.

**Parameters**:

- `member` (LootProfileMember) - Instance to promote to admin

**Returns**:

- `boolean` - `true` if added successfully, `false` if validation fails

**Validation**:

- Must be a valid LootProfileMember instance (metatable check)
- Extracts full identifier from member and adds to admin list
- Logs warning if invalid instance provided

**Example**:

```lua
-- Get or create member
local member = SF.LootProfileMember.new("Healz", "Garona", SF.LootProfileMemberRoles.ADMIN, "PALADIN")

-- Add as admin
if profile:AddAdminUser(member) then
    SF:PrintSuccess("Admin user added successfully")
else
    SF:PrintError("Failed to add admin user")
end
```

**Usage Note**: This grants admin permissions to the member. Consider logging this action with a ROLE_CHANGE log entry.

### Profile Settings

#### SetProfileName(newName)

Updates the profile's name.

**Parameters**:

- `newName` (string) - New profile name (must be non-empty)

**Validation**:

- Must be a non-empty string
- Logs warning if invalid name provided
- Does not update if validation fails

**Example**:

```lua
-- Rename profile
profile:SetProfileName("Season 1 Raid Team")

-- Invalid attempts (no change, warning logged)
profile:SetProfileName("")       -- Empty string
profile:SetProfileName(nil)      -- Not a string
profile:SetProfileName(123)      -- Not a string
```

**Usage Note**: Consider creating a log entry to track profile renames for audit purposes.

#### SetOwner(newOwner)

Transfers profile ownership to a different user.

**Parameters**:

- `newOwner` (string) - New owner identifier in "Name-Realm" format

**Validation**:

- Must match "Name-Realm" format (regex: `^[^%-]+%-[^%-]+$`)
- Logs warning if invalid format provided
- Does not update if validation fails

**Example**:

```lua
-- Transfer ownership
profile:SetOwner("Guildmaster-Garona")

-- Invalid attempts (no change, warning logged)
profile:SetOwner("InvalidFormat")         -- No realm
profile:SetOwner("Name-Realm-Extra")      -- Too many parts
profile:SetOwner("")                      -- Empty string
```

**Usage Note**: Ownership transfer does not automatically grant admin permissions. Add the new owner to the admin list separately if needed.

### Loot Log Management

#### AddLootLog(lootLog)

Appends a LootLog entry to the profile's event history.

**Parameters**:

- `lootLog` (LootLog) - LootLog instance to add

**Returns**:

- `boolean` - `true` if added successfully, `false` if permission denied or validation fails

**Permission Requirements**:

- Current user must be an admin (checked via `IsCurrentUserAdmin()`)
- Returns `false` with debug warning if non-admin attempts to add logs

**Validation**:

- Must be a valid LootLog instance (metatable check)
- Logs warning if invalid instance provided

**Behavior**:

- Appends log to the `_lootLogs` array
- Automatically re-sorts logs by timestamp to maintain chronological order
- Ensures log history remains consistent

**Example**:

```lua
-- Create a point change log
local pointChange = SF.LootLog.new(
    SF.LootLogEventTypes.POINT_CHANGE,
    {
        member = "Tanky-Garona",
        change = SF.LootLogPointChangeTypes.INCREMENT
    }
)

-- Add to profile
if profile:AddLootLog(pointChange) then
    SF:PrintSuccess("Log entry added")
else
    SF:PrintError("Failed to add log entry")
end
```

**Error Cases**:

- Non-admin user: Returns `false`, logs "Current user is not an admin"
- Invalid log instance: Returns `false`, logs "Attempted to add invalid LootLog instance"

**Usage Note**: Logs are automatically sorted by timestamp after insertion, so insertion order doesn't matter. This ensures the log history always reflects chronological order.

## Usage Examples

### Creating a New Profile

```lua
-- Create profile
local profile = SF.LootProfile.new("Mythic Raid Team 1")

if not profile then
    SF:PrintError("Failed to create profile")
    return
end

-- Profile is now ready to use
SF:PrintSuccess("Profile created: " .. profile:GetProfileName())
```

### Adding Members

```lua
-- Create members
local tank = SF.LootProfileMember.new("Tanky", "Garona", SF.LootProfileMemberRoles.MEMBER, "WARRIOR")
local healer = SF.LootProfileMember.new("Healz", "Garona", SF.LootProfileMemberRoles.MEMBER, "PALADIN")
local dps = SF.LootProfileMember.new("Pewpew", "Garona", SF.LootProfileMemberRoles.MEMBER, "MAGE")

-- Add to profile
profile:AddMember(tank)
profile:AddMember(healer)
profile:AddMember(dps)

-- Promote healer to admin
profile:AddAdminUser(healer)

SF:PrintSuccess("Added 3 members to profile")
```

### Logging Profile Activity

```lua
-- Award points to a member
local pointLog = SF.LootLog.new(
    SF.LootLogEventTypes.POINT_CHANGE,
    {
        member = "Tanky-Garona",
        change = SF.LootLogPointChangeTypes.INCREMENT
    }
)

if profile:AddLootLog(pointLog) then
    SF:PrintSuccess("Point awarded and logged")
end

-- Assign gear to a member
local armorLog = SF.LootLog.new(
    SF.LootLogEventTypes.ARMOR_CHANGE,
    {
        member = "Tanky-Garona",
        slot = SF.ArmorSlots.HEAD,
        action = SF.LootLogArmorActions.USED
    }
)

if profile:AddLootLog(armorLog) then
    SF:PrintSuccess("Gear assigned and logged")
end
```

### Permission Checking

```lua
-- Check if current user can modify profile
if not profile:IsCurrentUserAdmin() then
    SF:PrintError("You don't have permission to modify this profile")
    return
end

-- User is admin, proceed with modifications
profile:SetProfileName("Updated Profile Name")
SF:PrintSuccess("Profile renamed")
```

### Activating Profiles

```lua
-- Deactivate all profiles first (application logic)
for _, prof in pairs(SF.lootHelperDB.profiles) do
    prof:SetActive(false)
end

-- Activate the selected profile
profile:SetActive(true)
SF:PrintSuccess("Profile activated: " .. profile:GetProfileName())
```

### Displaying Profile Info

```lua
-- Get profile metadata
local name = profile:GetProfileName()
local author = profile:GetAuthor()
local created = profile:GetCreationTime()
local modified = profile:GetLastModifiedTime()
local isActive = profile:IsActive()
local members = profile:GetMemberList()

-- Format timestamps
local createdStr = SF:FormatTimestampForUser(created)
local modifiedStr = SF:FormatTimestampForUser(modified)

-- Display info
print("Profile:", name)
print("Created by:", author, "on", createdStr)
print("Last modified:", modifiedStr)
print("Active:", isActive and "Yes" or "No")
print("Members:", #members)
```

## Integration with Other Classes

### LootProfileMember

The LootProfile class stores an array of [LootProfileMember](members-class.md) instances:

- Each member represents a raid participant
- Members track point balances and armor slot states
- Member instances are rebuilt from LootLog history

**Relationship**:

- Profile contains members (`_members` array)
- Members reference their parent profile (future enhancement)
- Admin status stored in profile's `_adminUsers` list

### LootLog

The LootProfile class maintains an append-only array of [LootLog](loot-logs.md) entries:

- Each log records a single immutable event
- Logs are sorted chronologically by timestamp
- Logs serve as the single source of truth

**Relationship**:

- Profile contains logs (`_lootLogs` array)
- Logs are created for profile events
- Member states are computed from logs

### SavedVariables Integration

Profiles are stored in the `SpectrumFederationDB` SavedVariable:

```lua
-- Database structure
SF.lootHelperDB = {
    profiles = {
        ["ProfileName"] = LootProfile instance,
        ["Another Profile"] = LootProfile instance,
        -- ...
    },
    activeProfile = "ProfileName"  -- Currently active profile name
}
```

**Access Pattern**:

```lua
-- Get active profile
local activeName = SF.lootHelperDB.activeProfile
local activeProfile = SF.lootHelperDB.profiles[activeName]

-- Iterate all profiles
for profileName, profile in pairs(SF.lootHelperDB.profiles) do
    print(profileName, profile:GetCreationTime())
end
```

## Best Practices

### Profile Creation

**Naming**:

- Use descriptive, unique names
- Include tier/season information
- Consider raid group or team names
- Example: "Mythic Vault of the Incarnates - Team 1"

**Initialization**:

- Always check for `nil` return from `new()`
- Create initial members immediately after creation
- Set appropriate admin users during setup

### Member Management

**Adding Members**:

- Create LootProfileMember instances first
- Add members to roster with `AddMember()`
- Promote admins with `AddAdminUser()`
- Consider logging member additions

**Validation**:

- Always check return values from add methods
- Handle failures gracefully with user feedback
- Log errors for debugging

### Event Logging

**Log Everything**:

- Create logs for all profile modifications
- Include point awards, gear assignments, role changes
- Use appropriate event types and data structures

**Sort Order**:

- Don't worry about insertion order
- Logs are automatically sorted by timestamp
- Query logs chronologically for state reconstruction

### Permission Management

**Admin Checks**:

- Always call `IsCurrentUserAdmin()` before UI displays
- Disable admin controls for non-admin users
- Show appropriate error messages for permission denials

**Ownership Transfer**:

- Validate new owner identifier format
- Update admin list if needed
- Consider logging ownership changes

### State Management

**Active Profiles**:

- Only activate one profile at a time
- Deactivate others before activating new one
- Update UI to reflect active profile changes

**Profile Selection**:

- Store active profile name in `SF.lootHelperDB.activeProfile`
- Retrieve profile object from `SF.lootHelperDB.profiles`
- Handle case where active profile doesn't exist

## Error Handling

### Constructor Failures

The `new()` constructor can return `nil` in several cases:

1. **Invalid Profile Name**: Empty string or non-string type
2. **Log Creation Failed**: LootLog.new() returned nil
3. **Member Creation Failed**: LootProfileMember.new() returned nil

**Example**:

```lua
local profile = SF.LootProfile.new(profileName)
if not profile then
    SF:PrintError("Failed to create profile. Check debug logs.")
    if SF.Debug then SF.Debug:Show() end
    return
end
```

### Method Failures

Most methods return `boolean` to indicate success/failure:

- `AddMember()` - Returns `false` if invalid member instance
- `AddAdminUser()` - Returns `false` if invalid member instance
- `AddLootLog()` - Returns `false` if permission denied or invalid log

**Example**:

```lua
local success = profile:AddMember(newMember)
if not success then
    SF:PrintError("Failed to add member")
    -- Check debug logs for details
end
```

### Debug Logging

All validation failures and errors are logged to the debug system:

```lua
if SF.Debug then
    SF.Debug:Warn("LOOTPROFILE", "Invalid profile name provided: %s", tostring(profileName))
end
```

**Enable Debug Logging**:

```
/sf debug on
/sf debug show
```

## Related Documentation

- [Members Class](members-class.md) - LootProfileMember class documentation
- [Loot Logs Class](loot-logs.md) - LootLog event logging system
- [Loot Helper](loot-helper.md) - Core loot helper functionality and database