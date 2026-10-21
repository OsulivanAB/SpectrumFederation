# Changelog

All notable changes to SpectrumFederation will be documented in this file.

## [1.5.12] - 2026-10-21

### Added
- Add a shared guild officer rank for Guild Info, Guild Supplies, and Loot Helper
- Guild Info: guild-wide Main/Alt Assignments (#402) — versioned current-state membership/group records (no append-only op log)

### Changed
- Guild Info: Option B cleanup reclaims missing-group orphan memberships while still failing closed on ambiguous hidden assignments; Settings confirm lists orphan discards (#402)
- Guild Info: document deferred residual that a trusted rank 1–3 editor can publish terminal `MAX_SYNC_GEN_N - 1` / `sealRev` values that exhaust ordinary cleanup advancement (#402)
- Guild Supplies 3B: donation ledger gossip (#388)
- Guild Supplies 3A: Staged Configuration Gossip (#387)
- Guild Supplies Part 2A: dormant staged foundation (#385)
- Phase 1: Decentralized Guild Gossip infrastructure (#378)
- Improve Guild Supplies Configuration status UX hierarchy
- Guild Supplies 3C: Guarded Activation and Legacy Cutover (#389)

### Fixed
- Fix Reward Pot header width and Raid Check inspection failures (#406)
- Guild Info: forward-alias resolution walks up to `MAX_GROUPS` so long valid chains keep late members visible (#402)
- Guild Info: Option B cleanup discards wholly unreferenced forward cycles to reclaim capacity while still failing closed on cycles reachable from assigned memberships (#402)
- Guild Info: Change Main confirmation revalidates the guild roster so departed candidates are rejected (#402)
- Guild Info: `CountHiddenAssignedMembers` rebuilds via `GI.RebuildDerived` when `graph.byGuid` is absent (#402)
- Guild Info: `TrySealBaseline` skips fingerprint work when tip member/group counts already mismatch (#402)
- Guild Info: Gossip provider notifies on incomplete→complete baseline transitions even when the triggering admit is duplicate/stale, so peers discover sealed relationships without a later local mutation (#402)
- Guild Info: same-gen tip windows keep per-admit record bodies so overlapping GUID versions (e.g. advanced main membership) still match an advertised tip fingerprint before reapplying winning rows (#402)
- Guild Info: same-generation catch-up seals via exact tip match or bounded chronological tip windows from `_sameGenHold` (global + per-sender; no combinatorial subset search); three or more concurrent extras converge and relay (#402)
- Guild Info: same-generation higher `sealRev` tips park already-accepted rows and re-merge them after exact tip seal (or a bounded tip-subset witness); count supersets alone no longer complete baselines (#402)
- Guild Info: `syncGen` / `sealRev` share canonical writer + exclusive numeric ceiling validation; seal refresh fails closed when the revision cannot advance (#402)
- Guild Info: reciprocal `forwardTo` cycles resolve onto a deterministic cycle-break sink so concurrent Alice↔Bob assignments stay visible; cleanup fails closed if assigned members would still be hidden (#402)
- Guild Info: same-generation baseline catch-up follows `sealRev` tip order (not last-arrival fingerprints) and can seal merged supersets so dual-writer fresh peers converge and relay (#402)
- Guild Info: cleanup confirmation binds guild key / handle generation / actor GUID; capacity-blocked cleanup returns `cleanup_no_capacity` instead of `cleanup_noop` (#402)
- Guild Info: sync generations reject noncanonical writers and unsafe counters; unknown future SavedVariables schemas fail closed without mutation (#402)
- Guild Info: concurrent same-main groups use derived-view absorption (no synthetic versions / loser dissolve) so genuine offline moves and late member records survive (#402)
- Guild Info: Unassign / Change Main operate on the logical absorbed group so unrelated concurrent alts are not dropped (#402)
- Guild Info: incomplete concurrent group shells survive Change Main / Unassign via `forwardTo` aliases and sibling-shell guards so late members are not orphaned (#402)
- Guild Info: forward aliases and their destinations are retained through ordinary Unassign and capacity reclaim so late Gossip memberships stay resolvable (#402)
- Guild Info: moving a solo main with unresolved inbound `forwardTo` aliases retargets those aliases onto the new group so late members stay visible (#402)
- Guild Info: Unassign keeps reusable solo-main shells; demotion repurposes the shell or retires it as `forwardTo` so offline independent edits are not erased (#402)
- Guild Info: officer **Clean up retained Guild Info history** rebuilds a compact baseline under a guild-scoped sync generation so obsolete shells, tombstones, and aliases no longer permanently exhaust capacity (#402 Option B)
- Guild Info: schema/provider 3 adds `guildinfo-epoch` Gossip meta; older-generation records are rejected; incomplete new baselines fail closed (`generation_syncing`) (#402)
- Guild Info: history cleanup rebuilds onto canonical derived group ids so absorbed/forwarded alts are preserved; completed baselines refresh seal metadata after ordinary edits (#402)
- Guild Info: coalesce remote Gossip export rebuild/index resets; reuse validated record in assignment display; preserve merge rejection details; fix move-confirm character names (#402)

## [1.5.11] - 2026-10-16

### Changed
- Temporarily hide Loot Helper Att./Prep. roster columns
- Updated Retail game compatibility to Interface 120105 (12.1.5).

## [1.5.10] - 2026-10-13

### Changed
- Updated Retail game compatibility to Interface 120105 (12.1.5).

## [1.5.9] - 2026-10-13

### Added
- Silence remaining chat noise and add chat-output regression guards

### Changed
- Loot Helper Consumable Logs: character class colors (#348)
- Silence unnecessary raid-supply deposit chat messages

## [1.5.8] - 2026-10-10

### Added
- Add admin manual adjustments for Raid Consumables (#370)
- Enhance Raid Supplies Guild Bank donation helper with goal progress, smart suggestions, and bank alignment (#352)
- Add per-item Raid Consumables donation goals (protocol 8)
- Add minimized Loot Helper window opacity slider (#313)

### Changed
- Raid Consumables: verification, sync, and Guild Bank accounting (#366 PR2)
- Raid Consumables: Guild Bank observation and reconciliation foundation (#366 PR1)
- Simplify Raid Supplies banner to compact Mobile Banking flow (#354)
- Restore Raid Supply reminder for Mobile Banking (#341)
- Reduce Spectrum chat noise per #331 classifications
- Consumables: validate event ordering and preserve deposit evidence; snapshot cache, CI, and version bumps
- Stabilize Guild-Bank consumables: preserve confirmed deposits, snapshot cache revisions, and bounded order validation

### Fixed
- Fix Consumables Requested Items layout and control order (#362)
- Fix Raid Supplies Guild Bank window lifecycle (#344)
- Fixes

## [1.5.7] - 2026-10-03

### Changed
- Update Cursed Surge cadence to 30 minutes

## [1.5.6] - 2026-09-27

### Added
- Add a read-only TradeSkillMaster adapter

### Changed
- Keep recoverable sync diagnostics out of chat

### Fixed
- Fix ranged hunter weapons flagged as missing an off hand
- Fix RC Loot Council BiS response labels and list rows

## [1.5.5] - 2026-09-24

### Changed
- Dedupe Loot Log BiS outcomes and record bonus rolls separately

### Fixed
- Fix stale Loot Helper sync roles after admin changes
- Fix tier-token BiS classification and Gear Override repair

## [1.5.4] - 2026-09-22

### Added
- Add optional minimum item level to Raid Check

### Changed
- Keep Mouse Tracer aligned after display size changes

## [1.5.3] - 2026-09-22

### Added
- Add Loot Helper window close without disabling the feature

### Changed
- Warn when an RC BiS response repeats a used opportunity

## [1.5.2] - 2026-09-11

### Changed
- Stop Raid Equipment freeze and idle refresh-cycle risks

## [1.5.1] - 2026-09-11

### Fixed
- Sync protocol incompatibility warnings print once per peer instead of repeating for every mixed-version raid message

## [1.5.0] - 2026-09-11

### Added
- Linked Characters for Loot Helper profiles: admins can link and unlink characters so they share identity-wide points, Attendance, and equipment opportunity state while remaining separate roster members
- `CHARACTER_LINK` and `CHARACTER_UNLINK` loot-log events, including per-LINK contemporaneous admin evidence and `preOpAuthorMax` writer-observed heads
- Identity-scoped equipment corrections that record `identityMembers` at write time
- Optional `sourceLogId` on auto-generated `ADMIN_ADDED` grants so Replay can drop a grant whose source LINK is skipped

### Changed
- Replace live Main Swap / Transfer Main with Linked Characters
- Points, Attendance, and equipment opportunity state are projected from the linked identity instead of a single character cache

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
- Exact raw-author repair (`exactAuthor`) is distinct from logical SameAuthor catch-up through discovery, routing, NEED_LOGS/LOG_REQ serving, AUTH_LOGS validation, and request satisfaction; a helper that only has a sibling alias cannot complete `owner-Garona:1`
- Exact-author and integrity satisfaction require the advertiser's raw-window count/checksum/maxCounter; a later retained row, empty payload, or helper subset cannot complete an earlier window
- Exact missing requests do not suppress overlapping exact integrity repairs that may need trusted fingerprint replacement

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
