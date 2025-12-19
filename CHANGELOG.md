# Changelog

All notable changes to SpectrumFederation will be documented in this file.

## [0.0.15-beta.1] - 2025-12-19

### Added
- **Tabbed Settings Window**: New `/sf` command opens comprehensive settings interface
  - **Main Tab**: Roster display showing all characters and points, version info, window style selector
  - **Loot Tab**: Complete loot log viewer with filtering, profile management, and sync controls
  - **Debug Tab**: Debug log viewer with filtering, enable/disable controls, and clear logs button
- **Loot Log Viewer**: Scrollable display with filtering
  - 5 columns: Timestamp, Character, Change, Reason, Profile
  - Filter by character name (substring search)
  - Filter by profile (Current or All Profiles)
  - Newest entries displayed first
  - Color-coded point changes (green for positive, red for negative)
- **Debug Log Viewer**: Enhanced debug interface
  - Scrollable text box displaying up to 500 log entries
  - Filter by log level (All, VERBOSE, INFO, WARN, ERROR)
  - Filter by category (substring search)
  - Enable/disable debug logging toggle
  - Clear logs button with confirmation
  - Refresh button
- **Profile Management UI**:
  - Dropdown to switch between profiles
  - Create new profiles with dialog
  - Delete profiles with confirmation
  - Profile changes update all displays instantly
- **Backdrop System**: 5 window style presets
  - Default, Dark, Light, Transparent, Solid
  - Applies to all addon windows (settings and loot windows)
  - Preference saved per character
- **Loot Window Controls**:
  - Show/hide loot window checkbox in settings
  - Manual sync button (placeholder for Phase 2 sync implementation)
- **Enhanced Slash Commands**:
  - `/sf` - Opens settings window (replaces old loot window toggle)
  - `/sf loot` - Toggles loot window visibility
  - `/sf debug` - Toggles debug logging on/off
  - `/sf help` - Shows command help
  - `/sfdebug` - Legacy debug commands still supported

### Changed
- **Breaking**: `/sf` now opens settings window instead of toggling loot window
  - Use `/sf loot` to toggle the loot window
- Improved UI organization with tabbed interface
- Settings and state now persist across sessions
- All windows support configurable backdrop styles

### Fixed
- Database schema properly initializes for fresh installs
- Settings structure properly migrates from older versions
- UI state persistence for window positions and active tab

## [0.0.14-beta.1] - 2025-12-XX

### Added
- Profile-based system replacing tier-based system
- Profile management functions (Create, Delete, Switch)
- Database migration from schema v1 to v2
- Updated sync system to use profiles

### Changed
- Refactored loot log system for profile support
- Updated sync messages to include profile names

## [Earlier Versions]

See git history for earlier version changes.
