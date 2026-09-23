# RC Loot Council Integration

The optional child addon `SpectrumFederation_RCLootCouncilIntegration` records finalized RC Loot Council awards in Spectrum Loot Logs while a Spectrum Loot Helper session is active.

It does not send RC messages, persist raw RC traffic, or keep its own SavedVariables.

## When it records

Recording requires all of the following:

- the child addon is enabled;
- a Spectrum Loot Helper session is active;
- the award belongs to the profile attached to that session;
- the local client is an admin of the session profile;
- that profile's RC integration settings allow that response.

The locally selected Loot Helper profile is not used for live recording. If the session `profileId` cannot be resolved locally, the award is ignored rather than written to another profile.

The Loot Log **Author** is the RC master looter who awarded the item. The Spectrum writer must still be an admin of the session profile. Any eligible Spectrum admin may create the canonical `RC_LOOT_COUNCIL` row. Those rows converge through the deterministic external id, so several observers still produce one award.

Automatic Spectrum-derived `BIS_OUTCOME` rows are different. During an active Loot Helper session, only the session coordinator appends one. Other admins store the canonical RC award and do not write an outcome of their own. Live `NEW_LOG` traffic for `BIS_OUTCOME` is accepted only from the current coordinator; older peers may still broadcast their own rows, and those live copies are ignored. A repair `AUTH_LOGS` batch also drops a non-coordinator `BIS_OUTCOME` whose timestamp is at or after the live `coordEpoch`, and remembers that author counter for the rest of the session so gap and integrity repair can finish without storing the row. Rows from before that epoch, rows with no timestamp, and direct snapshot or `MergeLogTables` import stay stored. That memory is not saved and is not advertised as a counter this client can serve. An author clock behind `coordEpoch` can still make a current-session row look historical. Bulk history import still keeps already-synchronized duplicates. If another admin observes the award first, the coordinator writes the outcome once that RC row arrives through normal sync. A follower who already stored the RC row and later becomes coordinator writes the missing outcome after admin convergence has merged the requested log repairs, or when the same award is offered again. An RC row that arrives while those repairs are still open does not get an automatic outcome until the requests finish. A local observation during that window waits the same way. A restored coordinator waits for admin convergence after reload, including the gap before world or roster events start that convergence, instead of freezing outcomes from the logs it already has. A yielded backfill pauses if a repair opens between batches, and `/reload` drops the in-memory batch timer so the scan is rebuilt after catch-up. That backfill indexes existing outcomes once and writes at most 25 missing outcomes per turn. A later turn indexes again so an outcome that arrived during the wait is not written a second time. Awards inserted while that batch is still running are added to it when the deferred scan runs. A backlog does not rescan the log per award, does not broadcast one sync message per historical outcome, and does not print a chat line per award. In-order outcomes update the cached projection from a reverse dependency index instead of walking every stored log once per outcome. Peers catch up through the normal author-counter repair. Takeover does not write that outcome before those repairs arrive. Before writing, the coordinator checks for an existing source-consistent outcome for the same `awardKey`, so coordinator takeover does not add a second row. Outside an active session, the recording admin remains the writer.

If the winner is not a member of the session profile, no Loot Log is created. Admins of the session profile see a local warning only. Replay and reload do not repeat that warning for the same award in the same session.

## Settings

Open `/sf` → **Loot Helper → RC Loot Council**. The page appears only when this child addon is enabled. It does not add a redundant **Optional** sidebar row.

While a Loot Helper session is active, the page shows and edits that session profile's RC settings, because those settings control live recording. With no session, it uses the currently selected Loot Helper profile.

Settings are profile-scoped and admin-editable:

- **Record RC Loot Council Awards in Loot Logs** (default on) — master switch for live RCLC recording and automatic BiS outcomes. When this is off, no future RC award is recorded or treated as BiS automation. Saved BiS-response configuration is kept so it can return when recording is turned back on, but the BiS UI is inactive.
- **Record all award types** (default on)
- **Allowed Award Types** when record-all is off
- **BiS-Qualifying Responses** for future automatic BiS outcomes

While recording is on, every active BiS-qualified response is always recorded; it cannot also be filtered out of the allow-list. Changing these lists never reinterprets historical `BIS_OUTCOME` rows.

When RC Loot Council is available, the BiS list is filled from configured RC responses using the same identity RCLC persists in loot history:

- normal responses: `isAwardReason = false`, `typeCode` from the RC button group (or `"default"`), and the actual `responseID`;
- award reasons: `isAwardReason = true` and `responseID = reason.sort - 400`. Item/session `typeCode` is not part of award-reason identity. Array position is not assumed to equal the persisted ID.

A configured contextual entry never falls back to label-only matching. Historical text-only entries (`text:need`) remain the compatibility path when RC is not loaded or when an admin types a label by hand.

These settings travel on the profile snapshot as `snapshot.rcLootCouncilIntegration` for trusted full-snapshot joiners (`NEED_PROFILE` / `PROFILE_SNAPSHOT`), using the same snapshot as Raid Check. Live in-session edits do not send that full snapshot. An authorized admin proposes only the RC integration table via `RC_CONFIG_REQ` to the coordinator; the coordinator accepts one proposal at a time, assigns a monotonic session `seq` (not a wall-clock), stamps accepted generation as `(rcConfigEpoch, seq)`, and RAID-broadcasts `RC_CONFIG_SET`. Live SET also carries the live session `coordEpoch` so control admission can accept the message; catch-up `replay=true` restates the stored accepted `(rcConfigEpoch, seq)` and must not rewrite that generation as `(liveCoordEpoch, seq)`. Peers apply a SET only when the accepted generation is newer, or when the local client is unpublished/dirty or already disagrees on contents at the same generation. A later coordinator epoch still wins if `seq` collides after takeover. A non-coordinator edit is a proposal until that SET arrives. Award recording, BiS qualification, advertised session descriptors, helper `PROFILE_SNAPSHOT` export, and `ADMIN_STATUS.rcLootCouncilIntegration` use the last accepted configuration only; an unaccepted local proposal cannot change `RC_LOOT_COUNCIL` / `BIS_OUTCOME` or leak through a trusted snapshot at the current seq. Out-of-session edits on a profile that already has a non-zero accepted generation stay unpublished (`_rcConfigDirty` plus a pending copy). `ADMIN_STATUS` may set `rcConfigDirty` so START convergence never treats that draft as the accepted blob for `(rcConfigEpoch, rcConfigSeq)`. If the starter themselves edited while no session was active, `BroadcastSessionStart` mints a new generation from that unpublished proposal. If a different admin starts the next raid, the starter's accepted blob wins: dirty followers apply the advertised accepted contents even when the generation number is unchanged. Silent same-generation divergence is never left in place after session establishment. An unaccepted in-session follower proposal belongs to that session's coordinator pipeline: `EndSession`, remote `SES_END`, and `session_changed` discard it instead of converting it into `_rcConfigDirty`. Settings and award-time must agree after that session is gone; a later session must not show the dead proposal as the editable/live configuration. If `RC_CONFIG_REQ` fails to send, the in-session proposal is discarded. Ordinary admins therefore have authority over RC integration configuration only: they cannot supply `meta._owner`, `adminUsers`, members, logs, loot mode, Reward Pot, Raid Check, or equipment snapshots through this path. The change still does not create a visible Loot Log row. Frozen `BIS_OUTCOME` rows do not reinterpret from later config; the first source-consistent outcome wins. Automatic BiS evaluation uses the recipient's stored `SPEC_CHANGE` spec only, not live inspect or local player spec. Older snapshots may still carry unused `snapshot.rcLootCouncil` metadata; that field remains compatibility-only and is not the live integration. Missing `rcConfigEpoch` on older snapshots is treated as `0`.

Defaults fill in for older profiles that have no stored RC configuration.

## Loot Log shape

Recorded awards use type `RC_LOOT_COUNCIL`:

- **Type of Change** — RC Loot Council
- **Member** — loot recipient
- **Action** — `[Item Link] (Response)` (hoverable and clickable in Loot Logs)
- **Author** — RC master looter / awarder
- persisted audit fields include the original RC response, `history.id`, and the deterministic award key

RCLC history with `responseID == "BONUS_ROLL"` is not an RC award. It is recorded as `BONUS_ROLL` instead:

- **Type of Change** — Bonus Roll
- **Member** — loot recipient
- **Action** — `[Item Link]` (hoverable and clickable in Loot Logs)
- **Author** — the history awarder, so every observer stores the same row
- persisted fields include the recipient, item link, item string, history id, and deterministic bonus-roll key

A bonus roll does not create an `RC_LOOT_COUNCIL` row and does not run automatic BiS evaluation. Classification uses the RCLC `responseID` field, not the displayed response text.

A 1.5.4 peer can still sync the same history as an `RC_LOOT_COUNCIL` row whose `responseId` is `BONUS_ROLL`. New clients keep that row, do not derive a `BIS_OUTCOME` from it, and add one local `BONUS_ROLL` row. Rows already stored from 1.5.4 are scanned on profile load, snapshot import, and session join, including followers, because merge dedupe does not insert them again. That scan inserts the missing bonus rolls together and sorts the profile once. A live copy that arrives while log repairs are open is still synthesized for followers. The synthesized row is not rebroadcast, so older clients are not asked to store an event type they reject. Loot Logs hides the legacy RC row only after that bonus roll exists. Replay ignores the legacy RC row and any `BIS_OUTCOME` whose source is that row, so a bonus roll does not consume a BiS slot.

`NOT_BIS` is still stored once per award when reconstruction needs a frozen non-BiS decision. Loot Logs hides that row. `ASSIGNED`, `OVERFLOW`, and `UNRESOLVED` stay visible. Older duplicate `BIS_OUTCOME` rows are left in saved history. The log view shows the replay `outcomeWinner` for that `awardKey` (an earlier source-consistent `ASSIGNED` can lose the slot to a later `OVERFLOW`) and hides that winner when it is `NOT_BIS`.

## Award identity

The primary finalized RC signal is the RC `history` payload. RCLootCouncil2 serializes `command` plus one `data` table (`Serialize(command, data)`). For `Send(..., "history", winner, history_table)` that is `command = "history"` and `data = { winner, history_table }`. Cross-realm wraps that as `command = "xrealm"` and `data = { target, "history", winner, history_table }`; Spectrum unwraps the inner command only when the target is the local player.

Remote `history` is accepted only when the AceComm sender is the current RC master looter for this client (`masterLooter` / `GetML()` / `IsMasterLooter()`). Unrelated guild `history` from another RC raid is ignored. The local master-looter path is AceEvent `RCMLLootHistorySend` and does not re-check the sender, because RC fires that message only on the ML client. Both paths normalize the same award into the same external identity and the same deterministic Loot Log contents.

Identity is derived from finalized history data available to every observer:

`RCLootCouncil|<normalizedAwarder>|<history.id>|<normalizedWinner>|<itemString>|<normalizedOwner or "">`

Bonus rolls use the same history fields with a distinct prefix:

`BonusRoll|<normalizedAwarder>|<history.id>|<normalizedWinner>|<itemString>|<normalizedOwner or "">`

The human-readable response label is audit data only and is not part of the key. Spectrum ignores RC `delete_history`; a new `history.id` is a new Spectrum event.

## Sync isolation

External IDs and sentinel counter `0` are a narrow exception for `RC_LOOT_COUNCIL` and `BONUS_ROLL`. Ordinary event types, including `BIS_OUTCOME`, must keep `_id == author:counter` with a positive sequential counter and must not carry `_externalId`.

Valid RC and Bonus Roll external rows require all of:

- `_externalId` is the canonical award key
- `_id` equals `_externalId`
- `_counter` is the sentinel `0`
- `_data.awardKey` is present and equals `_externalId`
- they do not allocate or advance ordinary author counters
- they do not enqueue gap, integrity, `AUTH_LOGS`, or convergence repair
- a same-id / different-fingerprint collision keeps the first stored row and does not request sequential repair

Ordinary sequential Loot Logs keep their existing repair and sync behavior.

Mixed-version clients that do not understand `_externalId` drop only the RC row. A snapshot is not invalidated by the presence of one RC log.

## Limits

- If RC has both history options off, or `reason.log` is false, there is no history object and Spectrum cannot record the award.
- If RC history is self-only or guild-only, other Spectrum admins may not observe the remote `history` message. The master looter still has `RCMLLootHistorySend`.
- The parent addon does nothing RC-specific when this child is absent or disabled.

## Double BiS roll protection

While a Spectrum Loot Helper session is active and live BiS automation is on (`recordAwards` plus at least one BiS response), the child addon also watches RC candidate `response` traffic and Master Looter `change_response` traffic. A response is BiS-qualified only when it matches the profile's configured **BiS-Qualifying Responses**, using the same identity as automatic BiS awards. A numeric RC response also carries the button label from `GetResponse`, so a historical text-only entry such as `text:need` can match. Response id `1`, the label `BiS`, and the label `Need` are not special. The responder must be a candidate on that live RC session.

The check is read-only. It uses `LootProfile:EvaluateRCBisConflict`, which calls the existing occupancy, specialization, weapon, ring, trinket, and linked-character rules. Selecting or changing a response does not consume an opportunity, write a `BIS_OUTCOME`, or write a loot log.

When that evaluation is confident the opportunity is already consumed, each Spectrum admin shows one local warning. Non-admins do not. Unresolved cases (unknown item, missing stored spec, unknown member, missing RC session) do not warn. The warning names the configured response and a friendly opportunity (`Head`, `Ring`, `Trinket`, `Weapon/Off-Hand`), not an internal slot id.

Repeated RC traffic for the same player, item, and response is deduplicated. `session_end` from the current Master Looter, and the end of the Spectrum session, clear that transient memory.

`history` and `change_response` stay Master-Looter-authoritative. Their payloads are inflated only when the AceComm sender is the current Master Looter. A direct candidate `response` is a whisper to that Master Looter from a member of the session profile; only the Master Looter client inflates it, and only a `response` command is handled afterward. Group or guild traffic from anyone else is rejected before decode. A Master Looter group forward is accepted because that sender is the Master Looter, and the named candidate must still match the live session. Payload size and decode limits are unchanged.

On `RCMLAwardSuccess`, the Master Looter client may show an informational popup if the awarded response was BiS-qualified and the opportunity was already consumed before that award. The popup does not cancel the award or change BiS tracking. A win is not compared against the occupancy created by that same award. Other clients do not show the popup. The existing `history` path remains the only writer of `RC_LOOT_COUNCIL` rows and, on the active session coordinator, of automatic `BIS_OUTCOME` rows. Bonus-roll history is classified before that path and never becomes either row.
