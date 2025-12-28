# Changelog

All notable changes to SpectrumFederation will be documented in this file.









## [Unreleased - Beta]

### Added
- Overhauled loot profile management system with new features for creating, managing, and activating loot profiles.
- Added the ability to set and switch active loot profiles.
- Implemented functionality to validate if members exist within active loot profiles.
- Introduced new methods for adding, updating, and managing loot profiles in the database.

### Changed
- Updated timestamp formatting for debug logs to improve readability.
- Refined loot log validation to ensure member checks are performed against the active loot profile.

### Removed
- Deprecated and removed legacy loot profile database and UI-related functions.

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
