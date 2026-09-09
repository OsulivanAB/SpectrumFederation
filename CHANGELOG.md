# Changelog

All notable changes to SpectrumFederation will be documented in this file.

## [1.5.0-beta.2] - 2026-09-09

### Added
- Linked Characters for Loot Helper profiles: admins can link and unlink characters so they share identity-wide points, Attendance, and equipment opportunity state while remaining separate roster members
- `CHARACTER_LINK` and `CHARACTER_UNLINK` loot-log events, including per-LINK contemporaneous admin evidence
- Identity-scoped equipment corrections that record `identityMembers` at write time

### Changed
- Replace live Main Swap / Transfer Main with Linked Characters
- Points, Attendance, and equipment opportunity state are projected from the linked identity instead of a single character cache
- Loot Helper sync protocol version is now 2 so older Main Swap clients cannot share a session

### Fixed
- Guarded repair for the historical Main Swap stale-fingerprint rewrite, without blessing unrelated mismatches
- Non-owner admins can link and unlink identities that do not include the canonical owner
- Live `NEW_LOG` relationship events that modify the owner's identity require the effective owner, including when the sender is a canonical admin
- Live relationship `NEW_LOG` payloads are domain-validated at the receiving trust boundary; bulk/snapshot/`AUTH_LOGS` repair can still reconstruct authoritative legacy history
- Effective-owner alts can create and sync loot-mode changes without becoming general admins
- Coordinator identity-admin reconciliation waits until contiguous history, known author maxima, `_adminConvergence`, and repair work are complete, then resumes when those blockers finish
- Live `CHARACTER_LINK` / `CHARACTER_UNLINK` creation (`LootLog.new`, profile APIs, and `NEW_LOG`) requires canonical admin authorization, plus effective owner when the relationship touches the owner identity
- Lone live `NEW_LOG` fingerprint mismatches stay strict; MAIN_SWAP fingerprint repair is opt-in for batch import, snapshot, and `AUTH_LOGS`
- Linked identities pack active ring and trinket usages chronologically; singletons keep original local slots
- Linked Character and admin Name-Realm fields accept hyphenated realms and use `NameUtil` equality
- Canonical admin add/remove fails closed when the required log cannot be written
- Eager admin grants after a live LINK apply only to that LINK's resulting identity
- Overflow warnings fire only when a live LINK introduces a new identifiable conflict
- Linked Characters dialog uses Character 1 / Character 2 labels, and unlink asks for confirmation
- Identity projection is cached per profile and reused for helpers, UI reads, and live point/Attendance fan-out
- Out-of-order point or Attendance inserts replay identity totals instead of fan-out through the Attendance zero floor
- In-order remote Raid Check `NEW_LOG` point/Attendance updates use the same incremental fan-out as local writes
- Live relationship authorization uses deterministic pre-operation history and defers when predecessor logs are missing

## [1.4.1] - 2026-09-07

### Added
- Add v2 guild banner and crest and restyle docs dark-first

## [1.4.0] - 2026-09-07

### Added
- Add a temporary RC Loot Council capture child addon that records RC communications during Spectrum Loot Helper sessions
- Preview as Non-Admin (impersonation) for Loot Helper admins: local, runtime-only downgrade that never grants privileges and never changes sync identity

### Changed
- Replace RC capture with permanent Loot Council Integration
- Settings pages no longer render blank: the impersonation banner is not used as a layout parent while hidden
- Raid Equipment standalone page and async Raid Check

### Fixed
- Reset Current Profile is admin-only, including while Preview as Non-Admin is active

## [1.3.0] - 2026-08-31

### Added
- Add optional Mouse Tracer on Gameplay → UI Enhancements
- Add Spectrum Federation: Cursed Surge Tracker child addon

### Changed
- Gameplay settings category is retained as an empty placeholder

### Fixed
- Loot Helper window now expands and collapses from the title bar instead of growing from its center

### Removed
- Press and Hold Casting per-specialization automation

## [1.2.0] - 2026-08-26

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [1.1.0] - 2026-08-21

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [1.0.2] - 2026-08-19

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [1.0.1] - 2026-08-12

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [1.0.0] - 2026-08-11

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.22] - 2026-08-11

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.21] - 2026-05-27

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.20] - 2026-05-20

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.19] - 2026-04-22

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.18] - 2026-04-21

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.16] - 2026-03-25

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.15] - 2026-03-17

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.14] - 2026-03-11

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.13] - 2026-03-09

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.12] - 2026-03-09

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.11] - 2026-03-06

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.10] - 2026-03-06

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.9] - 2026-03-05

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.8] - 2026-03-04

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.7] - 2026-03-03

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.5] - 2026-02-11

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.4] - 2026-02-11

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.3] - 2026-02-09

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.5.1] - 2026-02-06

### Changed
- Updated documentation in `AGENTS.md` with branch policy reminders.

## [0.5.2] - 2026-02-05

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.4.3] - 2026-01-27

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.4.2] - 2026-01-27

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.4.1] - 2026-01-27

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.4.0] - 2026-01-27

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.1.1] - 2025-12-26

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.1.0] - 2025-12-24

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.0.19] - 2025-12-23

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [0.0.18] - 2025-12-23

### Changed
- Infrastructure and tooling updates (no addon code changes)

## [Earlier Versions]

See git history for earlier version changes.
