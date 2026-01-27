# Slash Commands

SpectrumFederation uses a flexible slash command system that allows modules to register custom commands. All commands are accessed via the `/sf` prefix.

## System Architecture

The slash command system is implemented in `modules/SlashCommands.lua` and provides a registration API for other modules to add their own commands.

### Core Functions

#### `SF:RegisterSlashCommand(command, handler, description)`

Registers a new slash command with the addon.

**Parameters**:

- `command` (string) - The command keyword (e.g., "debug", "loot")
- `handler` (function) - Function to execute when the command is called. Receives `args` as a parameter.
- `description` (string) - Help text describing what the command does

**Returns**:

- `boolean` - `true` if registration succeeded, `false` if validation failed

**Example**:

```lua
SF:RegisterSlashCommand("example", function(args)
    SF:PrintInfo("Example command executed with args: " .. args)
end, "An example command")
```

#### `SF:InitializeSlashCommands()`

Initializes the slash command system. Called automatically during addon initialization.

**Process**:

1. Registers the main `/sf` command handler
2. Registers the built-in `help` command
3. Logs initialization to debug system

## Available Commands

### Base Command

#### `/sf` (no arguments)

Opens the addon settings panel.

**Example**:

```
/sf
```

### Help System

#### `/sf help`

Displays a list of all registered commands with their descriptions.

**Example**:

```
/sf help
```

**Output**:

- Shows `/sf` - Open settings panel
- Shows `/sf help` - Show this help message
- Lists all registered commands alphabetically with descriptions

### Debug Commands

#### `/sf debug <subcommand>`

Controls the debug logging system. The debug system tracks internal addon operations for troubleshooting.

**Subcommands**:

- `on` or `enable` - Enable debug logging
- `off` or `disable` - Disable debug logging
- `show` or `logs` or (empty) - Open debug log viewer window
- `clear` - Clear all debug logs

**Examples**:

```
/sf debug on          # Enable debug logging
/sf debug show        # View logs in a window
/sf debug clear       # Clear all logs
/sf debug off         # Disable debug logging
```

**Debug Viewer**:

The debug viewer displays the last 100 log entries in a scrollable window:

- Each entry shows: `[timestamp] [level] category: message`
- Use Ctrl+A to select all text
- Use Ctrl+C to copy logs for bug reports
- Press ESC or click the X button to close
- Window can be dragged to reposition

**Log Levels**:

- `VERBOSE` - Detailed operational information
- `INFO` - General informational messages
- `WARN` - Warning messages about potential issues
- `ERROR` - Error messages when something fails

## Command Structure

All slash commands follow this structure:

```
/sf <command> [arguments]
```

**Parsing**:

1. Input is trimmed and converted to lowercase
2. First word is the command, remaining text is arguments
3. Command is looked up in the registry
4. If found, the handler function is called with arguments
5. If not found, an error message is shown

**Error Handling**:

- Unknown commands display: "Unknown command 'X'. Type /sf help for a list of commands."
- Command execution errors are caught and displayed with details
- All errors are logged to the debug system if enabled

## Adding New Commands

To add a new slash command in your module:

**Step 1**: Create your command handler function:

```lua
local function MyCommandHandler(args)
    -- Process arguments
    if args == "" then
        SF:PrintInfo("No arguments provided")
        return
    end
    
    -- Your command logic here
    SF:PrintSuccess("Command executed successfully!")
end
```

**Step 2**: Register the command during initialization:

```lua
-- In ADDON_LOADED or PLAYER_LOGIN event
SF:RegisterSlashCommand("mycommand", MyCommandHandler, "Description of my command")
```

**Step 3**: Your command is now available:

```
/sf mycommand some arguments
```

## Best Practices

**Command Naming**:

- Use lowercase names without spaces
- Keep names short and descriptive
- Avoid conflicts with WoW's built-in commands

**Handler Functions**:

- Always validate arguments before processing
- Use the MessageHelpers functions for user feedback:
  - `SF:PrintSuccess()` - Green success messages
  - `SF:PrintError()` - Red error messages
  - `SF:PrintWarning()` - Orange warning messages
  - `SF:PrintInfo()` - White informational messages
- Log actions to the debug system:
  - `SF.Debug:Info("CATEGORY", "message")`
  - `SF.Debug:Warn("CATEGORY", "message")`
  - `SF.Debug:Error("CATEGORY", "message")`

**Descriptions**:

- Write clear, concise descriptions
- Describe what the command does, not how to use it
- Keep descriptions under 80 characters if possible

**Arguments**:

- Trim and lowercase argument strings for consistency
- Support multiple formats where reasonable (e.g., "on"/"enable")
- Provide helpful error messages for invalid arguments

## Registry Structure

Commands are stored in `SF.SlashCommands` as a table:

```lua
SF.SlashCommands = {
    ["command"] = {
        handler = function,
        description = "Command description"
    }
}
```

**Internal Implementation**:

- Command names are stored in lowercase for case-insensitive matching
- Handlers are executed via `pcall` for error protection
- The help command iterates the registry to build its output
- Unknown commands check the registry before showing an error

## Testing Commands

**In-Game Testing**:

1. Enable debug logging: `/sf debug on`
2. Execute your command: `/sf mycommand test`
3. Check debug logs: `/sf debug show`
4. Verify output and behavior
5. Test error cases and edge cases

**Luacheck**:

The slash command system respects WoW's global functions:

- `SLASH_SPECFED1` - WoW global for slash command registration
- `SlashCmdList` - WoW table for command handlers

These are declared in `.luacheckrc` to avoid lint errors.

## Related Documentation

- [Development Overview](index.md) - Getting started with addon development
- [Loot Helper](../loot-helper/loot-helper.md) - Core loot helper functionality
