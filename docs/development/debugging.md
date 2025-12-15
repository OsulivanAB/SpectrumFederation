# Debugging

SpectrumFederation includes a built-in debug logging system that helps developers track addon behavior, diagnose issues, and understand the flow of execution during development and testing.

## Overview

The debug system provides:

- **Persistent logging** - Debug logs are saved to `SpectrumFederationDebugDB` and persist across game sessions
- **Multiple log levels** - VERBOSE, INFO, WARN, and ERROR for categorizing messages
- **Automatic log rotation** - Keeps the most recent 500 entries to prevent memory bloat
- **In-game commands** - Toggle debugging and view logs without reloading
- **Categorized entries** - Each log includes a category/context for easier filtering

## In-Game Debug Commands

### `/sfdebug` - Main Debug Command

The debug system is controlled through the `/sfdebug` slash command with the following subcommands:

#### Enable Debug Logging

```
/sfdebug on
```

Enables debug logging. All subsequent debug calls throughout the addon will be recorded to the SavedVariables.

**Output:**
```
[Spectrum Federation] Debug logging enabled
```

#### Disable Debug Logging

```
/sfdebug off
```

Disables debug logging. Debug calls will be ignored (no performance impact).

**Output:**
```
[Spectrum Federation] Debug logging disabled
```

#### View Recent Logs

```
/sfdebug show
```

Displays the 10 most recent debug log entries in your chat window with color-coded formatting:

- **🔴 ERROR** - Red
- **🟡 WARN** - Yellow  
- **🟢 INFO** - Green
- **⚪ VERBOSE** - White

**Example Output:**
```
[Spectrum Federation] Recent debug logs:
14:23:45 [INFO] ADDON_INIT: SpectrumFederation initializing...
14:23:45 [INFO] PLAYER_LOGIN: SpectrumFederation loaded
14:23:52 [INFO] DEBUG_CMD: Debug logging enabled via slash command
```

#### Show Help

```
/sfdebug
```

Running the command without arguments displays available subcommands.

## Using Debug Logging in Code

### Basic Usage

The debug system is available through `ns.Debug` in any module that has access to the namespace.

```lua
local addonName, ns = ...

-- Check if debugging is enabled
if ns.Debug:IsEnabled() then
    -- Debug code here
end

-- Log an info message
ns.Debug:Info("CATEGORY", "Something happened")

-- Log with formatting
ns.Debug:Info("POINTS", "Player %s gained %d points", playerName, points)
```

### Log Levels

#### VERBOSE - Detailed Trace Information

Use for very detailed execution flow that would be too noisy in normal debugging:

```lua
ns.Debug:Verbose("ROSTER", "Checking unit %s in group", unitId)
```

#### INFO - General Information

Use for significant events and state changes:

```lua
ns.Debug:Info("DATABASE", "Initialized tier %s", tierKey)
ns.Debug:Info("UI", "Loot Point frame created")
```

#### WARN - Warning Messages

Use for unexpected but recoverable situations:

```lua
ns.Debug:Warn("POINTS", "Character %s not found in roster", charKey)
```

#### ERROR - Error Messages

Use for errors and exceptional conditions:

```lua
ns.Debug:Error("DATABASE", "Failed to write log entry: %s", errorMsg)
```

### Log Function Signature

```lua
Debug:Log(level, category, message, ...)
```

- **level** - One of: `Debug.LEVELS.VERBOSE`, `Debug.LEVELS.INFO`, `Debug.LEVELS.WARN`, `Debug.LEVELS.ERROR`
- **category** - A short string identifying the context (e.g., "ADDON_INIT", "PLAYER_LOGIN", "POINTS_UPDATE")
- **message** - The message string (supports `string.format` patterns)
- **...** - Optional arguments for `string.format`

### Helper Methods

Instead of calling `Debug:Log()` directly, use the convenience methods:

```lua
-- These are equivalent:
ns.Debug:Log(ns.Debug.LEVELS.INFO, "CATEGORY", "Message")
ns.Debug:Info("CATEGORY", "Message")
```

Available helpers:
- `Debug:Verbose(category, message, ...)`
- `Debug:Info(category, message, ...)`
- `Debug:Warn(category, message, ...)`
- `Debug:Error(category, message, ...)` 

## Performance Considerations

The debug system is designed to have minimal performance impact when disabled:

- When `Debug:IsEnabled()` returns `false`, all logging calls return immediately without processing
- Log formatting only occurs if debugging is enabled
- Automatic log trimming prevents unbounded memory growth

### Best Practices

1. **Use guards for expensive operations:**
   ```lua
   if ns.Debug:IsEnabled() then
       local expensiveData = BuildComplexDebugInfo()
       ns.Debug:Verbose("CATEGORY", "Data: %s", expensiveData)
   end
   ```

2. **Choose appropriate log levels** - Don't log everything as ERROR or INFO
3. **Use descriptive categories** - Makes filtering and searching logs easier
4. **Include context** - Add relevant data (player names, counts, etc.)

## Debug Categories

The following categories are used throughout the addon:

| Category | Purpose |
|----------|---------|
| `ADDON_INIT` | Addon initialization and startup |
| `PLAYER_LOGIN` | Player login events |
| `DEBUG_CMD` | Debug command usage |
| `DATABASE` | Database operations (future) |
| `POINTS_UPDATE` | Point changes (future) |
| `ROSTER` | Roster tracking (future) |
| `UI` | UI frame creation and interaction (future) |
| `SYNC` | Data synchronization (future) |

!!! tip
    When adding new features, create a new category that clearly identifies the subsystem. This makes it easier to filter logs when debugging specific issues.

## Accessing SavedVariables

Debug logs are stored in:

```
<WoW Folder>/_retail_/WTF/Account/<Account>/SavedVariables/SpectrumFederation.lua
```

The `SpectrumFederationDebugDB` table contains:

```lua
SpectrumFederationDebugDB = {
    enabled = true,
    maxEntries = 500,
    logs = {
        [1] = {
            timestamp = 1702650225,
            level = "INFO",
            category = "ADDON_INIT",
            message = "SpectrumFederation initializing..."
        },
        -- ... more entries
    }
}
```

You can inspect this file directly for troubleshooting or export data for bug reports.

## Future Enhancements

Planned improvements to the debug system:

- **Log export** - `/sfdebug export` command to copy logs to clipboard
- **Category filtering** - Show logs from specific categories only
- **Log levels in UI** - Toggle which log levels are recorded
- **In-game log viewer** - Dedicated frame for browsing logs with search/filter

## Troubleshooting

### Debug logs not appearing

1. Ensure debug logging is enabled: `/sfdebug on`
2. Check that you've reloaded after making code changes: `/reload`
3. Verify the log category and level are being used correctly

### "No debug logs to display"

This means the logs table is empty. Either:
- Debug logging was never enabled
- Logs were cleared (by deleting SavedVariables)
- No debug calls have been executed yet

### SavedVariables not persisting

- Ensure you exit the game normally (not alt-F4 or task kill)
- Check file permissions on your WTF folder
- Verify `SpectrumFederationDebugDB` is listed in the TOC file's `## SavedVariables` line
