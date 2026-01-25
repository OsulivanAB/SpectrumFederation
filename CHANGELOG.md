# Changelog

All notable changes to SpectrumFederation will be documented in this file.













## [0.4.0-beta.7] - 2026-01-25

### Fixed
- Corrected inconsistencies in variable naming for settings storage, ensuring proper retrieval of configuration values.
- Fixed an issue where the Loot Helper window lock setting was not being read or applied correctly.
- Resolved minor layout and state-saving bugs in the Loot Helper window.

## [0.3.1-beta.21] - 2026-01-23

### Added
- Introduced functionality to create, delete, rename, and manage loot profiles directly from the UI.
- Added support for rehydrating saved loot profile data, ensuring proper restoration of methods and metadata after reloads.
- Implemented new dropdown options for selecting active loot profiles in the UI.
- Added the ability to reset all Loot Helper settings and profiles.

### Changed
- Improved handling of active loot profiles by maintaining both legacy pointers and new profile ID references for compatibility.
- Enhanced validation for member existence within active loot profiles.
- Updated the `GetActiveProfile` function to return the active profile object directly.

### Fixed
- Resolved issues with active profile pointers not being restored correctly after schema migrations or reloads.
- Fixed bugs related to member and loot log validation within profiles.

## [0.3.1-beta.1] - 2026-01-23

### Added
- Introduced a new modular Settings UI with enhanced customization options, including support for window style, font style, and font size adjustments.
- Added support for managing Loot Helper settings, including enabling/disabling the module, active profile selection, and safe mode configuration.
- Implemented a new initialization system to streamline module loading and improve performance.

### Changed
- Updated file structure for better organization, including new directories for settings and UI-related modules.
- Adjusted the interface version in the TOC file to ensure compatibility with the latest game client.

### Removed
- Deprecated the old Settings UI implementation in favor of the new modular design.

## [0.3.0-beta.1] - 2026-01-06

### Added
- Implemented a new communication system using AceComm-3.0 and ChatThrottleLib to support efficient and reliable message handling between addons.

## [0.2.0-beta.3] - 2026-01-02

### Changed
- Merged updates from the main branch into the beta branch to include the latest features and fixes.

## [0.1.1] - 2025-12-26

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.1.1-beta.2] - Unreleased

### Added
- Introduced issue templates for bug reports and feature requests to streamline user feedback.

## [0.1.1-beta.1] - Unreleased

### Added
- Introduced a debug logging system with commands to enable, disable, view, and clear logs (`/sf debug`).
- Added a Debug Viewer UI for viewing and copying debug logs.
- Enhanced Loot Helper module with new slash commands for toggling test mode, checking status, and force-enabling the Loot Helper UI.
- Implemented a toggleable Loot Helper UI window with dynamic content updates and improved visibility controls.

### Changed
- Improved error and success messaging across the addon for better user feedback.
- Updated Loot Helper database structure to support enhanced functionality.
- Refactored profile management to use the updated database structure and provide clearer feedback during operations.

## [0.1.0] - 2025-12-24

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.0.19] - 2025-12-23

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.0.18] - 2025-12-23

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.1.0-beta.1] - Unreleased

### Added
- Introduced a new Loot Helper module for managing loot profiles and settings.
- Added the ability to create, update, delete, and manage loot profiles within the new Loot Helper module.
- Implemented a new Loot Helper UI window with customizable settings, including position, size, and visibility.
- Added a checkbox in the settings UI to enable or disable the Loot Helper module.
- Added slash commands for toggling the Loot Helper UI (`/sf loot`).

### Changed
- Updated database structure to include a dedicated `lootHelper` section for managing loot profiles and settings.
- Refactored settings and loot profile management to integrate with the new Loot Helper database.
- Updated UI elements to reflect changes in the Loot Helper module.

## [0.0.14-beta.1] - Unknown

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
