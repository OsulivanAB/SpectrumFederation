# Loot Helper Internals

Loot Helper is split into domain models, synchronization, UI, and Raid Check. This page documents the contracts between them rather than every method.

## Domain model

### LootProfile

`modules/LootHelper/Profiles.lua` owns profile identity, metadata, members, admins, logs, per-author counters, Raid Check consequence configuration, inert legacy equipment snapshots, serialization, and mutation permissions.

Profile IDs are stable across renames. The creator becomes author, owner, first admin, and first member. Admin and member identifiers are normalized `Name-Realm` strings.

Use the highest-level Store or domain method available for mutations so validation, logging, and refresh behavior stay together. Low-level profile mutators are not uniformly permission-guarded and some do not create logs; callers must enforce authorization and choose the log-producing path. Directly changing private fields bypasses all of those contracts.

`SF.LootHelperImpersonation` is the runtime-only Preview as Non-Admin overlay. Keep `IsCurrentUserAdmin` / `IsCurrentUserOwner` canonical. Local UI and mutators that a player can trigger should use effective local admin/owner. Do not persist impersonation, do not put it in snapshots or sync payloads, and do not let it change sender authorization, `CanSelfCoordinate`, takeover, heartbeat, restore, or inbound validation.

### Member

`modules/LootHelper/Members.lua` is the derived representation of one member. It exposes identity/class data, point balance, admin role, equipment-category state, and Raid Check whisper timestamps.

Getters read cached projected values only. They must not scan logs or resolve a globally active profile. Mutators require an explicit owning `LootProfile` and fail closed when it is missing.

Point and equipment methods append logs through that owning profile. Point changes support fractional amounts; the current roster UI uses `0.5` for manual adjustments and Raid Check permits `0`, `0.5`, or `1`.

Member caches are written by identity projection on the profile. Do not treat the saved object fields as independently authoritative.

### LootLog

`modules/LootHelper/LootLogs.lua` defines append-only events:

- `PROFILE_CREATION`
- `POINT_CHANGE`
- `ARMOR_CHANGE`
- `ROLE_CHANGE`
- `POINT_NAME_CHANGE`
- `PROFILE_NAME_CHANGE`
- `SAFEMODE_CHANGE`
- `SAFEMODE_ON_COMBAT_CHANGE`
- `ADMIN_ADDED`
- `ADMIN_REMOVED`
- `MAIN_SWAP` (legacy lineage only)
- `CHARACTER_LINK`
- `CHARACTER_UNLINK`

Each ID is `author:counter`, where the counter is allocated per profile and author. Serialization uses versioned CBOR encoded as Base64. Validation lives in `LootLogValidators.lua`.

When adding an event:

1. add its constant and data template;
2. add validation;
3. include deterministic replay behavior where it affects member/profile state;
4. include it in snapshot/log serialization;
5. add readable Loot Logs UI formatting;
6. verify sync deduplication and counter behavior.

### Linked character identities

`modules/LootHelper/Identity.lua` reconstructs profile-scoped linked identities from append-only history. Characters remain distinct members. There is no Main/Primary, no synthetic roster collapse, and no live Main Swap rewrite.

`CHARACTER_LINK` stores `memberA`, `memberB`, `adminMembersAtLink` (canonical admins in either pre-link component at that event), and `preOpAuthorMax` (the writer's observed per-author heads before this event allocated a counter). Admin evidence applies only at that LINK, is never recomputed, and is ignored when an id is outside the two components being joined. `preOpAuthorMax` is live catch-up evidence only; Replay authorization does not trust the writer's heads. `CHARACTER_UNLINK` splits one character. Historical `MAIN_SWAP` unions lineage only and does not grant admin.

Identity-wide points and Attendance are sums of retained character logs. Unmarked `ARMOR_CHANGE` stays character-local forever; new shared corrections use `scope = "identity"` and `identityMembers`. Identity-scoped corrections apply only while their recorded original members are together, and only when a later character-local action on that slot (ordinary) or family (ring/trinket) has not superseded them. Singleton identities keep original local Ring1/Ring2 and Trinket1/Trinket2. Linked identities pack currently-active local ring and trinket usages chronologically onto projected Slot 1, then Slot 2, then overflow. Manual identity-scoped clicks still target the displayed projected slot. Do not implement BiS opportunity state from issue #275 here; this projection is the foundation that work should reuse.

`LootProfile` owns a cached identity projection. Rebuild it when identity-affecting history changes. Profile helpers such as `GetIdentityMembers`, `AreSameIdentity`, `GetIdentityPoints`, `GetIdentityAttendance`, and `GetIdentityArmor` read that cache. Live point and Attendance writes may fan out across the current identity instead of replaying all logs. Full replay remains the convergence path for relationship changes, migration, import, and sync rebuild.

Admin missing-grant reconciliation is coordinator-only, outside silent rebuild, and writes normal `ADMIN_ADDED` history. It must wait until contiguous author history matches known advertised maxima and no integrity repair or missing-range work remains. Convergence timeout does not forget a higher advertised frontier. Live LINK canonical-admin implication crosses only the pre-link boundary: members joining from a non-admin side receive implied admin, and a later LINK must not blanket-grant a MAIN_SWAP-restored non-admin already on the admin side. Overflow warnings compare per-slot/family conflict counts and fire once when a live LINK increases any count. Effective owner follows the canonical owner's current identity for LINK/UNLINK and loot-mode authorization. `IsCurrentUserOwner` remains canonical. Local `CHARACTER_LINK` / `CHARACTER_UNLINK` creation still requires canonical admin, plus effective owner when the operation touches the owner's identity. Remote live receipt inserts a baseline-authorized relationship log; `Identity.Replay` then applies or skips it from the ordered prefix so live receipt, bulk/`AUTH_LOGS` repair, and reload converge. Deferred live relationship work is scoped to the session that queued it and is discarded on EndSession, group leave, new session, and persisted-session restore. Same-session coordinator failover may flush that pending work.

Fingerprint repair may normalize a sequential log only when a batch/import/snapshot/`AUTH_LOGS` caller opts in and MAIN_SWAP lineage plus ancestor substitution proves the known rewrite bug. Incoming single `NEW_LOG` validation stays strict.

## Persistence and restoration

`modules/LootHelper/LootHelper.lua` initializes `SpectrumFederationDB.lootHelper`, fills local defaults, restores model metatables, and reconnects active-profile references.

Profiles are keyed by stable ID and `activeProfileId` stores the local selection. Snapshot import/export on `LootProfile` is the boundary used by sync; it validates metadata, logs, Raid Check config, and equipment snapshots before applying data.

## UI flow

`UI/LootHelper/Controller.lua` decides window visibility, observes settings/profile/session changes, builds roster models, and connects row actions.

`UI/LootHelper/Window.lua` owns the roster window frame. Minimize and restore re-anchor the frame to its current top-left so height changes expand downward from the title bar instead of growing around a CENTER point.

`RosterModel.lua` merges:

- members from the active profile;
- live group membership and unit tokens;
- class/spec display data;
- current user's admin permission;
- the **Show Members not in raid** preference.

`RosterView.lua` renders rows and delegates point, add-member, and equipment actions to model/domain methods. `EquipmentWindow.lua` renders the profile's loot-category state and optionally overlays current Raid Check issues.

Feature updates should fire or reuse `LootHelperEvents` so views refresh without polling.

## Sync protocol

`modules/LootHelperSync/` is intentionally ordered by numeric filename. Its major stages are:

1. namespace, constants, state, metrics, safe mode, and scheduling;
2. peer tracking, validation, and requests;
3. admin convergence, handshake, and heartbeat;
4. live updates and message routing;
5. control/bulk handlers and profile integration;
6. debug commands and public API.

Control messages use the small `SF_LH` traffic class; snapshots and log batches use `SF_LHB`. `modules/LootHelper/Comm.lua` is the current AceComm/ChatThrottleLib transport adapter.

The current protocol version is **2**. Clients on protocol 1 cannot participate in a linked-identity session; mixed Main Swap and Linked Character interpretation of the same profile is unsafe. `PROTO_MIN`, `PROTO_MAX`, `PROTO_CURRENT`, and `Sync.PROTO_VERSION` must stay aligned.

### Session lifecycle

The starting profile admin becomes coordinator. `StartSession` is a user-facing entry point: it denies Preview as Non-Admin before `CanSelfCoordinate`. `CanSelfCoordinate`, takeover, restore, heartbeat/election, admin convergence, sender authorization, and inbound protocol logic stay canonical. `EndSession` remains available for internal/automatic cleanup; slash `/sf loot session end` and the play-button Stop confirmation re-check effective local admin so a stale dialog cannot end a session after impersonation starts.

Admins exchange per-author log summaries. The coordinator requests missing ranges before selecting helpers and announcing the session. Members respond with `HAVE_PROFILE`, `NEED_PROFILE`, or `NEED_LOGS`; helpers are preferred for bulk responses with coordinator fallback.

New logs are broadcast during the session. Receivers validate the session envelope, then strictly deserialize relationship `NEW_LOG` payloads (fingerprint required) and reject non-admin senders before pending/repair state. Remaining gaps trigger range requests rather than applying incomplete history blindly. Replay, not network arrival order, decides whether a stored relationship event is applied.

The coordinator heartbeat supports late joiners and takeover. Control messages include a monotonically increasing coordinator epoch so messages from an older coordinator cannot regain authority.

### Trust boundaries

Do not weaken:

- group-membership checks;
- sender/coordinator identity checks;
- profile-admin authorization;
- helper/coordinator restrictions for bulk data;
- session/profile ID matching;
- log validation and deduplication.

UI admin gating is not sufficient for network input.

### Safe mode

Local and session safe mode pause snapshots, log batches, and live-log transfer while preserving control traffic. Session safe-mode requests are validated and coordinated. The current settings keys for local and raid-wide safe mode are not bridged to these runtime APIs; treat that integration as incomplete.

When adding a new message type, update constants, routing, validation, handler registration, metrics/debug output, safe-mode policy, and retry/timeout behavior together.

## Raid Check integration

`modules/RaidEquipment/Policy.lua` owns current-Retail completeness and Prepared/Unprepared rules. `modules/RaidEquipment/CheckRun.lua` owns frozen run identity, pause clocks, scaled inspect bounds, inspect-generation tokens, classification, session preflight, and the session-announce gate for consequences. `modules/RaidCheck.lua` owns the shared serial `NotifyInspect` queue, runtime last-good observations, the standalone audit snapshot, and Pre-Raid / Raid Check entry. Consequence application is fail-closed on effective local admin: if Preview as Non-Admin becomes active during an in-flight run, awards, Reward Pot writes, logs, and admin whispers abort as a unit and the run is marked settled so it cannot replay.

Acquisition, policy, and consequences are separate:

- Acquisition is local to the initiating client. There is no peer-assisted scan and no equipment addon-message protocol.
- Only complete trustworthy observations enter runtime last-good storage. `/reload` blanks them. Legacy `_raidCheckEquipmentSnapshots` remain inert: they are not written, not consumed, and not wiped.
- Combat and Blizzard Inspect are paused states. Paused time does not consume active acquisition bounds.
- Target membership is `profile membership ∩ current group` at run start. Roster updates only re-resolve frozen members.
- Local `StartSession()` may begin inspecting immediately. Session-backed consequences wait until the local CONTROL/ALERT `SES_START` send is accepted (`HasAnnouncedCurrentSession`). If that send is not accepted, the never-announced session is reset locally (no `SES_END`), Raid Check consequences apply once to the frozen profile with `skipBroadcast`, and the session is no longer treated as active.
- Mismatched sessions apply frozen-profile consequences locally (`skipBroadcast`) and do not send logs through an unrelated session.

The standalone **Raid Equipment** settings page consumes versioned troubleshooting snapshots through listener callbacks. Avoid rebuilding it from raw WoW APIs independently; use `GetTroubleshootingSnapshot` or `GetTroubleshootingSlotsForUnit`. The page does not require a Loot Helper profile or session. Auto Refresh remains `lootHelper.raidCheckAuditAutoRefresh`.

## Testing changes

For domain changes, test replay from logs and `/reload` metatable restoration. For sync changes, use multiple clients and cover missing-profile, missing-range, duplicate, late-join, coordinator loss, and safe-mode cases. For Raid Check, cover session preflight, announce vs consequence apply, frozen joiners/leavers, combat pause, range-only recent-good, Inspection Failed, and incomplete item data. Production-Lua policy and CheckRun coverage is `python -m pytest tests/test_raid_equipment.py`. Item-link parsing remains `python -m pytest tests/test_raid_check_item_links.py`. Settings navigation for the standalone Raid Equipment category is `python -m pytest tests/test_settings_navigation.py`. Minimize/expand anchoring for the roster window is covered by `python -m pytest tests/test_loot_helper_window.py`.
