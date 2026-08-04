# Waterfall UI — next work plan

Status: **built in 0.2.21** (unstick ALL, channel X axis, ALL=survey / no IBSS hop).

## 1. Unstick Channel / BW when leaving ALL

### Problem
Today Channel ALL ↔ BW ALL are forced both ways with no memory of prior values. Leaving ALL (e.g. BW → 20) leaves Channel = ALL, which immediately forces BW back to ALL (and vice versa).

### Behavior to implement

**Per radio, this browser tab only** (`sessionStorage` + in-memory):

| Key | Meaning |
|-----|---------|
| Current Channel / BW | What the pickers show now (may be `all`) |
| `lastChannel` | Last non-ALL channel before entering ALL |
| `lastBandwidth` | Last non-ALL BW before entering ALL |

Defaults when no prior non-ALL: radio’s live `current_channel` / `current_bandwidth`.

| User action | Result |
|-------------|--------|
| BW → ALL | Save current channel (if not ALL) as `lastChannel`; set Channel = ALL, BW = ALL |
| Channel → ALL | Save current BW (if not ALL) as `lastBandwidth`; set both ALL |
| BW ALL → e.g. 20 | BW = 20; Channel = `lastChannel` if valid for that BW list, else radio current if valid, else first channel in list |
| Channel ALL → e.g. 149 | Channel = 149; **BW = radio configured BW** (not `lastBandwidth`); rebuild channel list for that BW; keep 149 selected if present |
| BW 10 → 20 (neither ALL) | Keep channel if valid for 20; else same fallback chain |
| Channel 149 → 153 (neither ALL) | Channel only; BW unchanged |

**Highlight:** in the channel list, mark the radio’s live channel (e.g. `149 (5745) · radio` or distinct option styling) so the mesh setting is obvious.

### Fallbacks / anti-stuck cases

1. Restored channel not in new BW list → radio current → else first in list (never leave Channel = ALL after an intentional leave).
2. Never had a non-ALL value → use radio current ch/BW on first exit from ALL.
3. Prefs stay per-iface (`waterfall.*.wlan0` vs `wlan1`).
4. While a scan runs, controls stay disabled (locked, not stuck).
5. **Asymmetric restore (intentional):** leave ALL via **BW** → restore previous channel; leave ALL via **Channel** → BW resets to **radio BW**, not previous GUI BW.

### Files
- `contrib/waterfall/src/www/waterfall/waterfall-ui.js` — `fillScanControls`, BW/Channel change handlers, pref keys for `lastChannel` / `lastBandwidth`

---

## 2. Second X axis: channel numbers + center grid

### Goal
Keep **frequency start/stop** labels on the **bottom** (as now). Add a **second horizontal axis** (prefer **top** of the plot, under the title) showing **channel numbers**, with a **vertical grid line at each channel center**.

### Layout sketch

```
        Waterfall History
   36        40        …        149       153
   |         |                   |         |     ← channel centers (grid)
   [=========== heatmap ===========]
5740 MHz              Frequency           5750 MHz   ← keep bottom freq start/stop
```

For a single-channel / narrow BW capture (e.g. 5740–5750 @ ch 149 / 10 MHz), the top axis may show **one** channel tick at center. For ALL / wide span, show ticks for channels whose centers fall inside `meta.f_start`–`meta.f_stop`.

### Data

- Prefer channels from status `scan.channels_by_bw[bw]` (or densest list for ALL) with `{ number, frequency }`.
- Map `frequency` → plot X the same way bins map today:  
  `x = padL + (freq - f_start) / (f_stop - f_start) * plotW`
- Draw vertical guide at each in-range channel center (lighter than existing coarse grid, or replace freq-only verticals with channel-centered ones when channel list is known).
- Label channel numbers above the plot (or just inside top padding); avoid overcrowding: if too many ticks, thin (e.g. every Nth, or prefer 20 MHz centers when span is huge).

### Edge cases

1. Unknown / missing channel list → skip top axis; keep bottom freq labels only.
2. Survey / odd spans → only label channels with centers inside `[f_start, f_stop]`.
3. Modal vs full page — same `drawHeatmap` path so both stay consistent.
4. Do not remove bottom “Start/Stop MHz” or “Frequency” label.

### Files
- `contrib/waterfall/src/www/waterfall/waterfall-ui.js` — `drawHeatmap` (padding, ticks, grid)
- Optionally pass channel list into draw via cache meta or last `status.scan` held by `mount` (e.g. `meta.channels` stamped at session end, or UI keeps `lastScan`)

**Recommendation:** stamp a compact `meta.axis_channels: [{number, frequency}, …]` into the cache when the session finishes (from the scan plan), so the heatmap redraws correctly after reload without needing a live status call.

---

## 3. Build / ship (after both above)

1. Bump package version (`build.sh`, `packageVersion()`, README, regen hardware support report).
2. Build APK, install on test hAP, hard-refresh UI.
3. Manual checks:
   - ALL → BW 20 restores prior channel; not stuck on ALL
   - ALL → Channel 149 sets BW to radio BW; channel list highlights radio channel
   - 60s run Y axis 0→60
   - Single-channel plot: one top channel tick + bottom MHz
   - ALL / wide span: multiple channel ticks + verticals at centers
4. Commit / push on `waterfall` when asked

---

## Out of scope for this slice

- Changing mesh UCI permanently (retune remains temporary for the scan window)
- Idle multi-browser live lockout polling
- Native compiled FFT helper
