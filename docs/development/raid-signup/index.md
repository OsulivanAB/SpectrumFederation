# Raid Signup

Raid Signup is a **guild-owned** season/tier roster planner under **Raid Tools**. It is independent of Loot Helper profiles and sessions. Issue contract: [#404](https://github.com/OsulivanAB/SpectrumFederation/issues/404).

Transport dependency: Guild Gossip ([#378](https://github.com/OsulivanAB/SpectrumFederation/issues/378)). Officer plan management uses the shared guild officer threshold ([#405](https://github.com/OsulivanAB/SpectrumFederation/issues/405)).

## Change contract

| Concern | Owner |
| --- | --- |
| Durable plans + entries | `SF.RaidSignup` State (`SpectrumFederationDB.raidSignup`) |
| Officer / creator authorization | Authority via `SF.GuildOfficer` + `creatorGuid` |
| Local mutations | Operations |
| Authenticated Gossip provider | Gossip (`sf.raidsignup.roster`) |
| Planned coverage | Coverage (mains only) |
| Settings UI | `UI/Settings/Pages/RaidSignup.lua` |

### Guarantees

- Free-text nicknames; no roster autocomplete or main/alt integration.
- Drafts are local UI state only. Nickname typing uses an Enter / focus-loss commit
  boundary so class/spec-first flows do not persist on the first nickname character.
  Persist/sync only when nickname (committed) + class + valid spec are complete;
  abandoned incomplete drafts are discarded.
- Creators and officers can edit saved nicknames with `expectedVer` stale-edit protection.
- At most one alternative; never identical main/alt class+spec.
- Local mutations against archived plans are rejected (including rename). Remote Gossip may
  still catch up already-saved historical roster contents/metadata onto archived plans;
  the UI stays read-only.
- Deletions use versioned tombstones. There is no restore: live never overwrites a
  tombstone, and an authorized incoming tombstone wins over live for the same entry even
  when its `(n, w)` tuple is equal or lower. New Add Row uses new IDs.
- `planId` is immutable for an existing `entryId` (no move). `MergeEntry` rejects
  plan-ID changes before tombstone/mutation paths; local `UpsertEntry` returns
  `plan_immutable` for clear failure feedback.
- Concurrent live edits converge by `(n, w)` version tuples; deletion finality overrides
  that ordering for live↔tombstone conflicts.
- First-seen retention (including tombstones) is bounded by `MAX_ENTRIES` /
  `MAX_ENTRIES_PER_PLAN`. Deleting an already-retained live entry at capacity remains
  allowed. Remote revisions must stay advanceable (`n < MAX_REV`) and within
  `MAX_REV_CATCHUP` of the local revision.
- `MAX_PLANS = 32` is a lifetime creation cap that includes archived history. There is no
  automatic plan deletion/compaction; overflow returns `plans_overflow`. Revisit
  reclamation only when real usage approaches the cap or the owner requests it.
- Coverage summary uses ability/utility category icons (not class-icon stand-ins) with
  greyed missing state; the selected main-spec icon sits next to the nickname (notes do
  not separate them).
- Typing does not rebuild the settings page; durable board hosts and pooled controls are
  reused so allocations plateau after warm-up. Control callbacks read live selected plan /
  permissions. Idle visible page does not poll or broadcast.

### Role-total guidance colors

The Signups tab shows four compact role totals beneath the plan list: **Tanks**, **Healers**, **Ranged DPS**, and **Melee DPS**. Each is a small role icon plus a count. Only the **number** changes color; icons, sizing, spacing, and hover regions are fixed. Hovering a group shows the full localized role name plus a one-line assessment of the current totals.

Colors are **roster-planning guidance**, not Blizzard requirements and not a guarantee that a composition can complete an encounter. The thresholds below are owner-selected advisory values; encounter-specific needs (mechanics, assignments, enrage timers) always take precedence. The heuristics do not model every difficulty, special raid format, player skill, gear level, or bench arrangement, and the guidance never restricts roster size, saving, or signup permissions.

### Counting rules

Totals reuse the main-only aggregation (`RS.BuildRoleTotals`): only **completed main specs** count. Alternatives and incomplete drafts are excluded. From the four role counts:

- `T` = tanks, `H` = healers, `M` = melee DPS, `R` = ranged DPS
- `D = M + R` (combined DPS)
- `N = T + H + M + R` (total signups)

Colors and tooltip text are recomputed on every totals refresh (plan switches, main-spec changes, deletions, remote updates) and reset when a count returns to its normal range. No assessment state is persisted or synchronized; everything derives from the existing signup data.

### Tanks

- Exactly **2** tanks: yellow.
- Any other count: red.
- Tooltip states the two-tank planning target.

### Healers

- Fewer than **2** healers: red, at any roster size.
- For rosters with **10–30** total signups (`N`), the typical band is:
  - Lower bound: `max(2, floor(N / 5 + 0.5))`
  - Upper bound: `max(lowerBound, floor(N / 4))`
- **Yellow:** `H` inside the inclusive band. **Orange:** `H` exactly one below or one above the band, provided `H >= 2`. **Red:** anything else.
- Representative bands: N=10 → yellow {2}; N=14–15 → yellow {3}; N=20 → yellow 4–5; N=25 → yellow 5–6; N=30 → yellow 6–7.
- Outside 10–30 signups, the raid-size-based balance assessment is **not applied**: with 2+ healers the number stays its normal yellow and the tooltip explicitly says the balance assessment is not applied at this size (it is not described as optimal). Fewer than 2 healers is still red.

### Melee / ranged DPS

- If `D < 9`, **both** DPS numbers are red. This overrides the split assessment. Nine is the owner's preferred roster target, not the game's minimum raid-entry requirement — a 2/2/6 composition has six DPS and ten total players.
- When `D >= 9`, the melee share of combined DPS (`M / D`) is graded with exact integer comparisons (no display rounding at the boundaries):
  - **Yellow:** 20% through 65% melee, inclusive.
  - **Orange:** below 20%, or above 65% through 85%.
  - **Red:** above 85% melee.
- Both DPS numbers always share the same balance color.
- The asymmetry is deliberate: a **ranged-heavy** composition receives at worst orange unless the combined-DPS minimum fails, while a heavily melee-skewed one turns red above 85%.
- For `D = 14`: 6/8 yellow, 9/5 yellow, 10/4 orange, 12/2 red, 2/12 orange, 0/14 orange.

### Tooltip wording

Each hover keeps the full localized role name and adds the current assessment, e.g. "3 healers for 20 signups. Typical range: 4–5. Slightly below the usual range.", "8 total DPS. Roster target: at least 9.", or "10 melee / 4 ranged. Melee-heavy; fewer ranged options for encounter assignments." Wording uses terms like "Typical balance", "Encounter-dependent", and "Outside the usual range" rather than claiming a composition is objectively optimal or impossible.

### Tier Tokens (Summary sidebar)

Between **Classes** and **Major Buffs/Debuffs**, the Summary sidebar shows a **Tier Tokens** group: four armor icons with adjacent counts in a compact responsive grid — **Cloth / Woven**, **Leather / Cured**, **Mail / Cast**, **Plate / Forged**. Only the number changes color; icons, sizing, and spacing match the Classes grid, and zero-count icons take the same grey treatment as zero-count classes.

**Counting.** Token counts reuse the main-only class counts (`summary.classCounts`): only completed main selections contribute, grouped by armor family. Alternatives, incomplete drafts, and deleted entries contribute nothing, and the four group counts always sum to the total eligible mains `N`:

- Cloth / Woven: Mage, Priest, Warlock
- Leather / Cured: Demon Hunter, Druid, Monk, Rogue
- Mail / Cast: Evoker, Hunter, Shaman
- Plate / Forged: Death Knight, Paladin, Warrior

This is Midnight's armor-based class-set grouping (see the [Midnight Season 1 class sets guide](https://www.icy-veins.com/wow/midnight-season-1-class-sets-guide) as background); it does not claim to apply to past or future expansions.

**Crowding assessment.** Unlike the healer heuristic, this applies at any roster size and measures **roster competition**, not actual gear need or drop probability. The assessment is deliberately asymmetric: underrepresentation is never a problem and never receives orange or red. For a category with `C` participants out of `N` total eligible mains (`N > 0`):

- `fairMax = ceil(N / 4)` (the rounded even share — with 14 signups a balanced 4/4/3/3 roster is all yellow)
- `wiggle = max(1, floor(N * 0.05 + 0.5))`
- **Yellow:** `C <= fairMax`
- **Orange:** `fairMax < C <= fairMax + wiggle`
- **Red:** `C > fairMax + wiggle`

Representative boundaries: N=14 → yellow 0–4, orange 5, red 6+; N=20 → yellow 0–5, orange 6, red 7+; N=25 → yellow 0–7, orange 8, red 9+; N=30 → yellow 0–8, orange 9–10, red 11+; N=40 → yellow 0–10, orange 11–12, red 13+.

For `N = 0` all four icons are grey with yellow zero counts, and the tooltip explains there are no completed signups (no division by zero, no misleading percentages). Percentages in tooltips are rounded for display only; colors come from the integer rules above.

**Tooltips.** Hovering an icon or count shows the armor type and token family, the eligible classes, the current count/total/percentage, the even-share target, and the crowding assessment ("Slightly crowded." / "Outside the usual range." / "Within the even-share range."). Counts, colors, greying, and tooltip data refresh on every summary repaint (plan switches, main-spec changes, deletions, remote updates) and reset when crowding decreases. Everything derives from existing signup data — no persisted counters, sync fields, polling, or idle work.

### Background references

The thresholds are the owner's chosen planning heuristics. Public guides illustrate that real encounter requirements vary; they informed the general shape of the bands but are **not** the source of the color policy:

- [Method.gg — March on Quel'Danas: Midnight Falls](https://www.method.gg/guides/march-on-queldanas/midnight-falls)
- [Method.gg — Nerub-ar Palace: Rashanan](https://www.method.gg/guides/nerubar-palace/rashanan)
- [Method.gg — Liberation of Undermine: Sprocketmonger Lockenstock](https://www.method.gg/guides/liberation-of-undermine/sprocketmonger-lockenstock)

## Gossip multi-hop note

Phase 1 Guild Gossip authenticates the current hop sender. Member-authored entries admit when the transport sender is the creator or an officer. Non-officer relays of someone else's newer entry return `relay_lacks_authority`. Peers still converge when they pull from the author or through an officer hub.

**Repair finding 7 (paused):** ordinary members holding saved data still cannot relay newer third-party entries when authors/officers are offline. Resolving that without weakening creator/officer **edit** rights requires an explicit trust-model choice (Guild Supplies–style membership replica catch-up vs keeping the limitation). See the repair decision note; do not silently weaken admission gates.

## Saved schema (`schemaVersion = 1`)

```lua
SpectrumFederationDB.raidSignup = {
  schemaVersion = 1,
  localWriter = { nonce = "<24 hex>", nextSeq = 1 },
  guilds = {
    ["club:<id>"] = {
      schemaVersion = 1,
      guildKey = "club:<id>",
      clubId = "<id>",
      selectedPlanId = "<planId>" | nil, -- local UI preference; not gossiped
      plans = { -- [planId] = { planId, name, archived, createdBy, ver={n,w}, at } },
      entries = { -- [entryId] = { entryId, planId, nickname, mainClass, mainSpec,
                  --   altClass?, altSpec?, notes, creatorGuid, deleted?, ver, at } },
    },
  },
}
```

Wire kinds: `raidsignup-plan`, `raidsignup-entry`. Record IDs: `rs-p:<planId>`, `rs-e:<entryId>`.

## Validation

- `python -m pytest tests/test_raid_signup.py`
- `python3 .github/scripts/lint_all.py`
- `python3 .github/scripts/validate_packaging.py`
- Docs: `python3 .github/scripts/validate_docs.py`
- Human Retail QA after review (plan CRUD, draft/alt flows, sync with two clients)
