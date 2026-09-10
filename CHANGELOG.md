# Changelog

All notable changes to SpectrumFederation will be documented in this file.

## [1.5.0-beta.2] - 2026-09-09

### Added
- Linked Characters for Loot Helper profiles: admins can link and unlink characters so they share identity-wide points, Attendance, and equipment opportunity state while remaining separate roster members
- `CHARACTER_LINK` and `CHARACTER_UNLINK` loot-log events, including per-LINK contemporaneous admin evidence and `preOpAuthorMax` writer-observed heads
- Identity-scoped equipment corrections that record `identityMembers` at write time
- Optional `sourceLogId` on auto-generated `ADMIN_ADDED` grants so Replay can drop a grant whose source LINK is skipped

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
- `Identity.Replay` is the relationship authorization source of truth: live receipt, bulk/`AUTH_LOGS` repair, and reload skip unauthorized `CHARACTER_LINK` / `CHARACTER_UNLINK` events instead of permanently accepting an unadvertised-predecessor race
- Live `NEW_LOG` rebuilds do not persist implied `ADMIN_ADDED` grants, so a coordinator cannot lock in admin side effects from a relationship that Replay later skips
- Live relationship `NEW_LOG` is strictly deserialized and baseline-admin authorized before it can enter pending or repair state
- Deferred live relationship work is scoped to the originating session and discarded across session reset, new session, and persisted restore
- Admin-convergence target maxima survive AUTH_LOGS timeout so identity-admin reconciliation cannot run against incomplete advertised history
- Later live LINK does not retroactively grant MAIN_SWAP-restored non-admin sources; canonical admin implication crosses only the pre-link boundary
- Identity-scoped equipment corrections no longer erase later character-local actions after unlink/relink
- Overflow warnings detect increased conflict multiplicity per slot/family, not only new conflict keys
- Live relationship `NEW_LOG` requires the network sender to match the relationship log author
- Auto-admin grants from `LinkCharacters` / reconcile are causally bound to the source LINK via `sourceLogId`
- Replay uses writer-observed `preOpAuthorMax` as causal predecessors so same-timestamp admin grants authorize the LINK that observed them
- Frozen `_legacyCanonicalAdmins` preserve Main Swap / snapshot admins that have no grant log, without letting a later `ADMIN_ADDED` authorize older relationships
- Identity-scoped equipment corrections apply to contributions from their recorded `identityMembers`; AVAILABLE suppresses that scope without clearing another identity's scoped USED, and later joiners do not resurrect suppressed insider locals
- Identity-scoped equipment corrections expire permanently after any original-scope split; later relink does not resurrect them
- A later current-identity equipment correction supersedes earlier overlapping subset-scope state for that slot or ring/trinket family
- A later current-identity correction on a different slot does not collapse disjoint same-slot contributions into latest-wins
- Independent scoped ring and trinket usages pack into opportunity 1 then 2 before overflow when identities merge
- Equipment chronology uses `OrderLogs` causal rank rather than the raw `CompareLogs` tie-break
- `ADMIN_ADDED.sourceLogId` is a causal predecessor of the sourced grant
- A skipped sourced `ADMIN_ADDED` is rejected provenance, not missing evidence, so later `adminMembersAtLink` cannot resurrect that grant
- `Identity.OrderLogs` uses a ready min-heap, O(1) successor-edge dedup, and canonical author keys; `SnapshotPreOpAuthorMax` deduplicates SamePlayer aliases
- SamePlayer-equivalent authors share one counter stream for new writes, contiguous catch-up, and LOG_REQ serving
- `HandleNeedLogs` serving and `HandleAuthLogs` log-row checks use the same SameAuthor match as `HandleLogRequest`, without rewriting historical IDs, authors, or fingerprints
- In-place integrity `_ReplaceLogById` rebuilds from current log contents; OrderLogs is not cached across rebuilds by table identity
- MAIN_SWAP-less stale fingerprints can be repaired when a unique attributed source candidate reproduces the stored checksum; unrelated mismatches stay rejected
- Re-using a displayed equipment opportunity (`AVAILABLE` then `USED`) does not pack historical locals as phantom overflow; independent uses still overflow
- In-order Attendance fan-out and Replay keep raw identity totals so `1 - 1 - 1 + 1` stays 0 after a force Replay; displayed Attendance still floors at zero
- Identity-scoped `ARMOR_CHANGE` snapshots `preOpAuthorMax` in `LootLog.new`; Replay ignores identity equipment written while those members were not actually unified
- Redundant concurrent LINKs remain valid history but do not propagate admin across an already-unified component
- Characters named only in historical awards with no `MAIN_SWAP` lineage restore as unlinked shells with an admin warning
- `MAIN_SWAP` validation accepts hyphenated realms through `NameUtil`
- Overlapping historical SameAuthor rows at one logical counter are discovered by normal missing-range and partial-window integrity repair without rewriting `_author`, `_id`, or fingerprints
- `Identity.OrderLogs` keeps every immutable row at a logical author counter so `preOpAuthorMax` and logical `N+1` wait for all retained alias rows at frontier `N`
- Session `authorMax` stays a raw `_author` -> retained-counter map; SameAuthor merge no longer advertises phantom historical maxima such as `owner-Garona:7`
- `BuildAdminStatus.hasGaps` scores logical sequential presence so alias continuation is not treated as a gappy raw stream

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
