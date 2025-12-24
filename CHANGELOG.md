# Changelog

All notable changes to SpectrumFederation will be documented in this file.





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
