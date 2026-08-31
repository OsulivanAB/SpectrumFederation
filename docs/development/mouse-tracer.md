# Mouse Tracer

Mouse Tracer is an optional per-character cursor trail. User-facing control descriptions belong on [Settings](../settings-ui.md). This page is the maintainership contract for the runtime.

## Files

| File | Role |
| --- | --- |
| `modules/MouseTracer/Constants.lua` | Spacing, cadence, pool bounds, slider ranges, and setting keys. |
| `modules/MouseTracer/TrailEngine.lua` | Pure sampling, interpolation, ring buffer, fade/trim, and HSV color. No frames. |
| `modules/MouseTracer/MouseTracer.lua` | Host frame, line pool, cached settings, snapshot debounce, copy helpers, and event resets. |
| `modules/UI/Settings/Pages/NicheFeatures.lua` | Gameplay category plus the UI Enhancements page. |
| `modules/Settings/Schema.lua` | `CHARACTER_DEFAULTS.mouseTracer` and account-wide `mouseTracerCopies`. |

`Init.lua` starts Mouse Tracer after `SettingsStore` and `SettingsApply`. Live values live in `SpectrumFederationCharDB`. Account-wide `mouseTracerCopies` exist only so **Copy From Character** can read another character's last saved settings. WoW cannot read another character's per-character SavedVariables.

Do not bump `SettingsSchema.VERSION` for these defaults. `MergeDefaults` fills missing character and account keys.

## Performance contract

These bounds are intentional. Do not grow the pool, add interpolation backlog, or put Store access on the sample/fade path for convenience.

### Disabled

No `OnUpdate`, no cursor polling, no visible regions, and no Mouse Tracer runtime processing.

### Enabled, idle, and fully faded

Bounded 60 Hz cursor polling. O(1) work. No segment traversal, no Store access, and no allocations.

### Moving

Bounded 60 Hz sample/emission, independent of rendered FPS. Every accepted movement reaches the current cursor this tick. At most 12 emitted points per sample. No interpolation backlog and no trail gaps. After initialization the hot path must not allocate. Settings and UI scale are cached.

Dynamic spacing for a move of distance `dist`:

```text
n = min(12, max(1, floor(dist / MIN_SPACING)))
spacing = dist / n
```

Interpolated timestamps use `t(i) = prevT + (now - prevT) * (i / n)`.

### Stationary and fading

No geometry generation. Bounded 30 Hz fade processing. No allocations. Return to idle when the final segment expires.

### Resources

`MAX_POINTS = 69` and `MAX_SEGMENTS = 68` (`ceil(400 / 6) + 2` and one less). The line pool is fixed at those sizes and must not grow at runtime.

Cadence constants:

```text
ACTIVE_SAMPLE_INTERVAL = 1/60
FADE_INTERVAL = 1/30
IDLE_POLL_INTERVAL = 1/60
```

## Baseline safety

Invalidate the sampling baseline, and do not emit a segment from stale coordinates, on:

- initial enable;
- `PLAYER_ENTERING_WORLD`;
- UI scale changes;
- mouselook transitions;
- teleport or other discontinuity resets.

The first valid cursor sample after a reset establishes position only. Rejected small movements must keep the last **accepted** trail point as the spacing baseline. Do not slide that baseline on every rejected sample.

`PLAYER_ENTERING_WORLD` and `UI_SCALE_CHANGED` also clear the visible trail. Scale changes recache `GetEffectiveScale()` before the next sample.

Cursor coordinates come from `GetCursorPosition()` divided by the host's effective scale. `GetScaledCursorPosition` is not used.

## Settings and snapshots

Sliders write character settings immediately so the visible trail updates while dragging. Account-wide copy snapshots are debounced (~0.35s) with one reusable ticker. Enable/disable, Copy From Character, login, and logout flush immediately.

Copy From Character applies the six character keys under `applySuspended` so the runtime reconfigures once, writes one snapshot, and refreshes the page once.

Identity keys for snapshots use `NameUtil.GetSelfId()` (`Name-Realm`). Compare identities with `NameUtil.SamePlayer`.

## Tests

Production Lua tests load `Constants.lua` and `TrailEngine.lua`:

```bash
python -m pytest tests/test_mouse_tracer.py
```

PR validation on `beta` and `main` runs that file beside the Settings navigation and Cursed Surge Tracker tests.

In-game profiler checks must use isolated `C_AddOnProfiler.MeasureCall` around Mouse Tracer work. Addon-wide LastTime is not a Mouse Tracer pass/fail signal.
