# Cursed Surge Tracker

Spectrum Federation: Cursed Surge Tracker is a child addon that shows the five Curse Surge locations on The Coiled Isle World Map, with a ring that is red while a location is active and green while it counts down to the next start.

It ships in the same Spectrum Federation release archive. After install it appears as its own checkbox nested under Spectrum Federation in WoW's AddOns list. Disable the child to hide the tracker without affecting Loot Helper or other parent features. Disable Spectrum Federation and the child is dependency-disabled.

No extra in-addon toggle is required, and `/sf` cannot enable or disable the tracker.

When the child is installed, it also appears as an **Optional** category in the Spectrum Federation settings window:

- If it is enabled for this character and has no settings pages yet, opening the category shows a generic empty state. Future pages will replace that empty state.
- If it is disabled for this character, the category stays visible, grey, and not selectable. Hover the row for a reminder to enable it in WoW's AddOns list.

The tracker is not configured from `/sf` today. Map pins and countdowns are the feature; the settings category is only a discovered entry point.

## When it runs

The tracker only operates while your character is physically on The Coiled Isle (uiMapID `2512` or a subzone whose map ancestry resolves to `2512`). Opening that map from another zone does not show pins.

While you are on the isle and the World Map is showing map `2512`:

- exactly five pins appear, one per canonical Curse Surge location;
- icons stay visible whether the event is active or waiting;
- a complete red ring means that location is active;
- a draining green ring counts down to the next start;
- hovering a pin shows the localized event name and a live countdown.

Leaving the isle removes the pins and cancels tracker timers. Spectrum Federation continues normally.

## Tooltips

| State | Tooltip |
| --- | --- |
| Inactive | localized name, then `Starts in H:MM:SS` or `MM:SS` |
| Active | localized name, then `Active — Ends in ...` |
| Waiting for Blizzard schedule data | `Loading schedule...` |
| Schedule present but unusable | `Schedule unavailable` |

The countdown updates once per second while the cursor stays on the pin.

## Diagnostics

`/sfcst` (also `/sfcursedsurge` and `/sf cst`) prints an opt-in dump of the five locations, resolved timestamps, ring progress, and whether zone, map, boundary-timer, and tooltip-ticker systems are running. It is silent during normal use.
