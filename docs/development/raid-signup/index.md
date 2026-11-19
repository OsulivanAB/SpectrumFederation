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
- Sheets have an **Active / Inactive** state carried by the existing `archived`
  flag (`Active = not archived`). Inactive sheets stay fully viewable — entries,
  summaries, notes, and tooltips — but are read-only for everyone, officers
  included, until reactivated. The lock is enforced by mutation checks
  (`UpsertEntry`, `DeleteEntry`, `RemoveAlternative`, `RenamePlan` all reject
  inactive plans), not just by hidden controls; deactivating a sheet that is
  being viewed promptly discards its unsaved drafts without touching saved
  entries. Remote Gossip may still catch up already-saved historical roster
  contents/metadata onto inactive sheets.
- On the **Manage** tab, officers toggle a sheet's Active state; the toggle
  stays usable while the selected sheet is inactive, and changing one sheet
  never changes another's. Newly created sheets start active and become
  selected for their creator. There is no second persisted active flag and no
  guild-wide `activePlanId`.
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
- `MAX_PLANS = 32` is a lifetime creation cap that includes inactive history. There is no
  automatic plan deletion/compaction; overflow returns `plans_overflow`. Revisit
  reclamation only when real usage approaches the cap or the owner requests it.
- Coverage summary uses ability/utility category icons (not class-icon stand-ins) with
  greyed missing state; the selected main-spec icon sits next to the nickname (notes do
  not separate them).
- Collapsed rows use fixed Nickname / Main / Alt / Notes columns. The column headings
  read "Main / Alt" — the slash appears only in the heading, never on rows, and the
  shared "Main"/"Alt" tooltip labels are unchanged. Standard board and summary icons
  render at about 24px; the compact role-total icons at about 16px.
- Typing does not rebuild the settings page; durable board hosts and pooled controls are
  reused so allocations plateau after warm-up. Control callbacks read live selected plan /
  permissions. Idle visible page does not poll or broadcast.

### Sheet selection and creation time

Multiple sheets can be active at once; which sheet is being viewed is a **local**
selection (`selectedPlanId`, never gossiped). Whenever Raid Signup is genuinely
opened, the page selects a default: the most recently **created** active sheet,
or — when none are active — the most recently created inactive sheet (shown
read-only with a "No active signups" notice), or the empty state when no sheets
exist. The default is applied once per opening: refreshes, resizes/rebuilds,
tab switches, and Gossip updates never reset a valid selection, and a newer
sheet arriving mid-visit only becomes the default on the next opening. If the
viewed sheet turns inactive, the page keeps showing it and transitions to
read-only. When guild data or the plan list arrives after the page first
opens, the pending default is applied once without overriding an explicit
user selection.

Plans carry an immutable `createdAt` (server time at creation), distinct from
`at` (last mutation, which rename/archive/edits update). `createdAt` flows
through clone, validation, merge, persistence, and Gossip export; merge never
erases a known creation time, so rename, activation changes, entry edits,
reload, and synchronization preserve it. New plans get `createdAt = at =
creation time`. Plans saved before this field existed (and older clients'
payloads) have `createdAt = 0`; default ordering then falls back to
deterministic plan-ID order as a stable approximation — original creation
times for legacy plans are unknowable and are not invented.

### Summary sidebar order and guidance palette

The Summary sidebar stacks, top to bottom: **role totals** → **Classes** → **Tier Tokens** → **Major Buffs/Debuffs** → **Utility**. All four groups share one content width with consistent left and right boundaries; the icon-only Major/Utility grids derive their column count from the actual sidebar width (no fixed cap), keeping full rows within the shared span and partial final rows left-aligned, while Classes and Tier Tokens keep wider count-labelled cells. The role totals (small Tank / Healer / Ranged DPS / Melee DPS icon-and-count groups) are the first content immediately beneath the Summary heading/divider; Classes starts below their actual bottom with a clear gap, and whole groups wrap onto extra lines at tight widths. Only the **numbers** use the guidance palette — **white** for good/default, **orange** for caution, **red** for bad — shared by the role totals and the tier-token counts. Class counts and the utility provider-count overlays are always white. The palette does not alter icon artwork, spacing, hover regions, gold section headings, or the missing-icon greying. Hovering a role group shows the full localized role name plus a one-line assessment of the current totals.

Colors are **roster-planning guidance**, not Blizzard requirements and not a guarantee that a composition can complete an encounter. The thresholds below are owner-selected advisory values; encounter-specific needs (mechanics, assignments, enrage timers) always take precedence. The heuristics do not model every difficulty, special raid format, player skill, gear level, or bench arrangement, and the guidance never restricts roster size, saving, or signup permissions.

### Counting rules

Totals reuse the main-only aggregation (`RS.BuildRoleTotals`): only **completed main specs** count. Alternatives and incomplete drafts are excluded. From the four role counts:

- `T` = tanks, `H` = healers, `M` = melee DPS, `R` = ranged DPS
- `D = M + R` (combined DPS)
- `N = T + H + M + R` (total signups)

Colors and tooltip text are recomputed on every totals refresh (plan switches, main-spec changes, deletions, remote updates) and reset when a count returns to its normal range. No assessment state is persisted or synchronized; everything derives from the existing signup data.

### Tanks

- Exactly **2** tanks: white.
- Any other count: red.
- Tooltip states the two-tank planning target.

### Healers

- Fewer than **2** healers: red, at any roster size.
- For rosters with **10–30** total signups (`N`), the typical band is:
  - Lower bound: `max(2, floor(N / 5 + 0.5))`
  - Upper bound: `max(lowerBound, floor(N / 4))`
- **White:** `H` inside the inclusive band. **Orange:** `H` exactly one below or one above the band, provided `H >= 2`. **Red:** anything else.
- Representative bands: N=10 → white {2}; N=14–15 → white {3}; N=20 → white 4–5; N=25 → white 5–6; N=30 → white 6–7.
- Outside 10–30 signups, the raid-size-based balance assessment is **not applied**: with 2+ healers the number stays its normal white and the tooltip explicitly says the balance assessment is not applied at this size (it is not described as optimal). Fewer than 2 healers is still red.

### Melee / ranged DPS

- If `D < 9`, **both** DPS numbers are red. This overrides the split assessment. Nine is the owner's preferred roster target, not the game's minimum raid-entry requirement — a 2/2/6 composition has six DPS and ten total players.
- When `D >= 9`, the melee share of combined DPS (`M / D`) is graded with exact integer comparisons (no display rounding at the boundaries):
  - **White:** 20% through 65% melee, inclusive.
  - **Orange:** below 20%, or above 65% through 85%.
  - **Red:** above 85% melee.
- Both DPS numbers always share the same balance color.
- The asymmetry is deliberate: a **ranged-heavy** composition receives at worst orange unless the combined-DPS minimum fails, while a heavily melee-skewed one turns red above 85%.
- For `D = 14`: 6/8 white, 9/5 white, 10/4 orange, 12/2 red, 2/12 orange, 0/14 orange.

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

- `fairMax = ceil(N / 4)` (the rounded even share — with 14 signups a balanced 4/4/3/3 roster is all white)
- `wiggle = max(1, floor(N * 0.05 + 0.5))`
- **White:** `C <= fairMax`
- **Orange:** `fairMax < C <= fairMax + wiggle`
- **Red:** `C > fairMax + wiggle`

Representative boundaries: N=14 → white 0–4, orange 5, red 6+; N=20 → white 0–5, orange 6, red 7+; N=25 → white 0–7, orange 8, red 9+; N=30 → white 0–8, orange 9–10, red 11+; N=40 → white 0–10, orange 11–12, red 13+.

For `N = 0` all four icons are grey with white zero counts, and the tooltip explains there are no completed signups (no division by zero, no misleading percentages). Percentages in tooltips are rounded for display only; colors come from the integer rules above.

**Tooltips.** Hovering an icon or count shows the armor type and token family, the eligible classes, the current count/total/percentage, the even-share target, and the crowding assessment ("Slightly crowded." / "Outside the usual range." / "Within the even-share range."). Counts, colors, greying, and tooltip data refresh on every summary repaint (plan switches, main-spec changes, deletions, remote updates) and reset when crowding decreases. Everything derives from existing signup data — no persisted counters, sync fields, polling, or idle work.

### Coverage categories and provider-count overlays

Coverage categories are planned-capability booleans derived from completed main selections only; alternatives, incomplete drafts, and deleted entries never contribute. Recent category decisions:

- **Heroism** (internal id `bloodlust`): visible name is Heroism with the current Retail Heroism spell artwork; equivalent abilities (Bloodlust, Time Warp, Primal Rage, Fury of the Aspects) keep coverage through the same providers (Shaman, Mage, Hunter, Evoker).
- **Warlock utilities are separate entries**: Ritual of Summoning, Healthstone, and Demonic Gateway each have their own icon, name, tooltip, and coverage state (any warlock main). The old combined "Lock Stuff" category is gone.
- **Innervate** is eligible for **all druid specializations** as talent-dependent healer mana support (per Blizzard's Midnight class-tree notes), not Restoration only.
- **Skyfury** and **Blessing of the Bronze** sit in **Major Buffs/Debuffs** alongside the other persistent raid buffs, each exactly once. Skyfury uses the numeric FileDataID `4630367`; `RS.CategoryIconTexture` accepts numeric FileDataIDs as well as texture paths, and `iconSpell` spell IDs resolve live Retail spell artwork with the path as fallback.
- **Attack Speed Reduction** uses the actual Retail Numbing Poison artwork (spell 5760), and its title/tooltip/provider mapping all describe that same capability.

**Provider-count overlays.** Three Utility icons — **Combat Res**, **Burst Move Speed**, and **Death Grip/AMZ** — show a small white outlined number at the bottom-right counting **eligible signed-up mains** for that category. Each overlay is parented to its icon button (not the grid host) so it renders above the button artwork, uses a dark shadow for legibility, shows multi-digit counts without clipping, and shows zero explicitly; zero-provider icons keep the existing grey missing-coverage treatment while present-provider icons stay in their normal state. Font, draw layer, and shadow are reapplied on pooled reuse, and overlays are cleared when an icon is reused for a category without a count. Hovering the icon also lists the current provider count and what it means (potential providers, not cooldown charges or remaining battle-res uses). These counts represent mains, not charges, casts, cooldown readiness, or shared battle-res resources. They extend `RS.BuildSummary` (`providerCounts`) using the same completed-main-only aggregation as the coverage booleans: each main counts once per category even when several provider rules match. For Death Grip/AMZ the overlay counts Death Grip-capable Death Knight mains — Blood, Frost, and Unholy each count once — so Grip and AMZ never double-count one DK; coverage itself remains any Death Knight.

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
      plans = { -- [planId] = { planId, name, archived, createdBy, ver={n,w}, at, createdAt } },
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
