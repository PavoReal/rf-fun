# Plan: Frequency Band Overlay on FFT Plot

## Overview

Add labeled, color-coded frequency band regions to the FFT spectrum plot so the
user can see at a glance which allocation (ham, aviation, ISM, etc.) a signal
falls in. Bands are rendered as semi-transparent vertical rectangles behind the
FFT trace, with short labels. A toggle panel lets the user show/hide categories.

---

## 1. Band Database (`src/bands.zig` — new file)

### Data model

```zig
pub const BandCategory = enum(u8) {
    ham,
    aviation,
    marine,
    public_safety,
    frs_gmrs_murs,
    broadcast,
    ism,
    cellular,
    gps,
    weather,
    satellite,
    wifi_bt,
    misc,
    cb,
    railroad,
};

pub const Band = struct {
    start_mhz: f32,
    end_mhz: f32,
    label: [:0]const u8,      // null-terminated for ImGui/ImPlot
    category: BandCategory,
};
```

### Static band table

A `comptime` const array of ~60 `Band` entries covering all the researched
allocations. Grouped by category in source order for readability.
Single-frequency entries (ADS-B 1090, TPMS 315, 433 remotes) are given an
explicit ±0.5 MHz width in the data itself — no special-case renderer logic.

### Helper functions

- `categoryName(cat) -> [:0]const u8` — display name for each category
- `categoryColor(cat) -> [4]f32` — unique RGBA color per category (full alpha;
  caller controls fill alpha)
- `categoryCount() -> comptime_int` — number of categories (for sizing arrays)

No `bandsInRange` function — with ~60 bands, a simple `if` skip in the render
loop is sufficient and avoids premature abstraction.

### Curated band list (California / US focus)

**Ham Radio** (18 entries):
| Start | End | Label |
|-------|-----|-------|
| 1.8 | 2.0 | 160m |
| 3.5 | 4.0 | 80m |
| 7.0 | 7.3 | 40m |
| 10.1 | 10.15 | 30m |
| 14.0 | 14.35 | 20m |
| 18.068 | 18.168 | 17m |
| 21.0 | 21.45 | 15m |
| 24.89 | 24.99 | 12m |
| 28.0 | 29.7 | 10m |
| 50.0 | 54.0 | 6m |
| 144.0 | 148.0 | 2m |
| 222.0 | 225.0 | 1.25m |
| 420.0 | 450.0 | 70cm |
| 902.0 | 928.0 | 33cm |
| 1240.0 | 1300.0 | 23cm |
| 2300.0 | 2450.0 | 13cm |
| 3300.0 | 3450.0 | 9cm |
| 5650.0 | 5925.0 | 5cm |

**Aviation** (5 entries):
| Start | End | Label |
|-------|-----|-------|
| 108.0 | 117.95 | VOR/ILS |
| 118.0 | 137.0 | Air Band |
| 225.0 | 400.0 | Mil Air |
| 960.0 | 1215.0 | DME/TACAN |
| 1089.5 | 1090.5 | ADS-B |

**Marine:**
| Start | End | Label |
|-------|-----|-------|
| 156.0 | 162.025 | Marine VHF |

**Public Safety:**
| Start | End | Label |
|-------|-----|-------|
| 138.0 | 174.0 | PS VHF |
| 450.0 | 470.0 | PS UHF |
| 758.0 | 805.0 | 700 PS |
| 806.0 | 869.0 | 800 PS |

**FRS/GMRS/MURS:**
| Start | End | Label |
|-------|-----|-------|
| 151.82 | 154.6 | MURS |
| 462.5 | 467.75 | FRS/GMRS |

**Broadcast:**
| Start | End | Label |
|-------|-----|-------|
| 0.535 | 1.705 | AM Radio |
| 54.0 | 88.0 | TV VHF-Lo |
| 88.0 | 108.0 | FM Radio |
| 174.0 | 216.0 | TV VHF-Hi |
| 470.0 | 608.0 | TV UHF |

**ISM:**
| Start | End | Label |
|-------|-----|-------|
| 902.0 | 928.0 | 915 ISM |
| 2400.0 | 2483.5 | 2.4G ISM |
| 5725.0 | 5850.0 | 5.8G ISM |

**Cellular (key US LTE):**
| Start | End | Label |
|-------|-----|-------|
| 617.0 | 698.0 | LTE 600 |
| 698.0 | 756.0 | LTE 700 |
| 824.0 | 894.0 | LTE 850 |
| 1710.0 | 1755.0 | AWS UL |
| 1850.0 | 1990.0 | PCS |
| 2110.0 | 2200.0 | AWS DL |

**GPS:**
| Start | End | Label |
|-------|-----|-------|
| 1166.0 | 1186.0 | GPS L5 |
| 1217.0 | 1237.0 | GPS L2 |
| 1565.0 | 1585.0 | GPS L1 |

**Weather:**
| Start | End | Label |
|-------|-----|-------|
| 162.4 | 162.55 | NOAA WX |

**Satellite:**
| Start | End | Label |
|-------|-----|-------|
| 137.0 | 138.0 | WX Sat |
| 1616.0 | 1626.5 | Iridium |
| 1694.0 | 1710.0 | GOES/HRPT |

**WiFi/Bluetooth:**
| Start | End | Label |
|-------|-----|-------|
| 2400.0 | 2483.5 | WiFi 2.4G |
| 5150.0 | 5850.0 | WiFi 5G |

**Misc:**
| Start | End | Label |
|-------|-----|-------|
| 314.5 | 315.5 | TPMS |
| 433.42 | 434.42 | 433 Remotes |

**CB Radio:**
| Start | End | Label |
|-------|-----|-------|
| 26.965 | 27.405 | CB |

**Railroad:**
| Start | End | Label |
|-------|-----|-------|
| 160.215 | 161.565 | Railroad |

---

## 2. GUI Design

### Band overlay rendering (inside the ImPlot plot area)

Each visible band is drawn as:
1. **Shaded vertical rectangle** from `band.start_mhz` to `band.end_mhz`,
   spanning the full Y-axis (-120 to 0 dB). Color is category-specific with
   low alpha (~0.10) so the FFT trace remains clearly visible. Note: some bands
   overlap (e.g. 33cm ham = 915 ISM), so alpha must be low enough that double-
   stacking is still readable.
2. **Label text** at the top of the band rectangle, centered horizontally within
   the band. Only shown if the band is wide enough in pixels to fit the text
   (avoids label clutter at wide zoom). Use `zgui.plot.plotText()`.

### Rendering approach

Use `zgui.plot.plotShaded()` (confirmed available in zgui) for each band:
```zig
zgui.plot.pushStyleColor4f(.{ .idx = .fill, .c = .{ r, g, b, 0.10 } });
zgui.plot.plotShaded("##band_N", f32, .{
    .xv = &[_]f32{ start_mhz, end_mhz },
    .yv = &[_]f32{ 0.0, 0.0 },
    .yref = -120.0,
});
zgui.plot.popStyleColor(.{ .count = 1 });
```

Key details:
- Use `"##band_N"` hidden labels to **suppress legend entries** (otherwise 60+
  bands would flood the ImPlot legend alongside "Magnitude" and "Peak Hold")
- Push `.fill` style color (not `.line`) for the shaded region color
- Draw bands **before** the FFT line series so they render behind the trace
- Label via `zgui.plot.plotText()` at `((start+end)/2, -5.0)` near the top

For pixel-width gating of labels, compute from existing helpers:
```
pixel_width = (band_end - band_start) / (x_max - x_min) * plot_pixel_width
```
using `rfFunGetPlotLimits()` and `rfFunGetPlotSize()` already exposed in
`implot_extras.cpp`. Only show label text if `pixel_width > 30`.

### Band visibility controls (in the Config Panel)

Add a new collapsible section **"Band Overlay"** in the existing config panel
(after the DSP section), containing:

- **Master toggle**: "Show Bands" checkbox — enables/disables all band overlays
- **Category toggles**: One checkbox per `BandCategory`, labeled with the
  category display name and colored with the category color. Arranged in a
  2-column layout to save vertical space.

### Color palette (one distinct color per category)

| Category | Color (RGB approx) | Rationale |
|----------|-------------------|-----------|
| Ham | Yellow (1.0, 0.9, 0.0) | Classic amateur radio association |
| Aviation | Cyan (0.0, 0.8, 1.0) | "Sky" color |
| Marine | Blue (0.0, 0.4, 1.0) | "Water" |
| Public Safety | Red (1.0, 0.2, 0.2) | Emergency |
| FRS/GMRS/MURS | Orange (1.0, 0.6, 0.0) | Consumer |
| Broadcast | Green (0.2, 0.8, 0.2) | Common/public |
| ISM | Magenta (0.8, 0.2, 0.8) | Industrial |
| Cellular | Pink (1.0, 0.4, 0.6) | Telco |
| GPS | Gold (1.0, 0.84, 0.0) | Navigation |
| Weather | Teal (0.0, 0.7, 0.5) | Weather |
| Satellite | Purple (0.6, 0.3, 1.0) | Space |
| WiFi/BT | Light green (0.4, 1.0, 0.4) | Tech |
| Misc | Gray (0.6, 0.6, 0.6) | Catch-all |
| CB | Brown (0.7, 0.5, 0.2) | Retro |
| Railroad | Dark orange (0.8, 0.4, 0.0) | Industrial |

(GPS changed from white to gold per review — white is near-invisible at low
alpha on a dark background.)

---

## 3. Implementation Plan

### File changes

| File | Change |
|------|--------|
| `src/bands.zig` | **NEW** — Band struct, category enum, static data, helpers |
| `src/plot.zig` | Add band overlay rendering inside the plot |
| `src/main.zig` | Add band toggle state, pass to plot, add config UI section |

### Step-by-step

#### Step 1: Create `src/bands.zig`

1. Define `BandCategory` enum with all 15 categories
2. Define `Band` struct with `start_mhz`, `end_mhz`, `label`, `category`
3. Create `pub const all_bands` comptime slice with all ~60 entries
4. Implement `categoryName()` returning `[:0]const u8` display name
5. Implement `categoryColor()` returning `[4]f32` RGBA (full alpha)
6. Add `pub const category_count` derived from enum

#### Step 2: Add rendering in `src/plot.zig`

Add a new parameter to `render()` — a pre-filtered slice of band render info:

```zig
pub const BandRenderEntry = struct {
    start_mhz: f32,
    end_mhz: f32,
    label: [:0]const u8,
    color: [4]f32,
};
```

`main.zig` pre-filters bands (in-view + enabled category) and builds this flat
slice. `plot.zig` just draws what it's given — no awareness of categories or
toggle state. This keeps the renderer dumb and `main.zig` in control.

In `render()`, after `setupFinish()` and **before** the series loop:
1. For each `BandRenderEntry`, push fill color with alpha=0.10, call
   `plotShaded` with `"##band_N"`, pop color
2. Compute pixel width; if > 30px, call `plotText` with band label

#### Step 3: Add state & UI in `src/main.zig`

1. Add state variables:
   - `show_bands: bool = true`
   - `band_categories_enabled: [bands.category_count]bool` initialized all true

2. In the config panel (after the DSP section ~line 576), add collapsible
   `collapsingHeader("Band Overlay")` with:
   - `checkbox("Show Bands", &show_bands)`
   - Per-category checkboxes with `colorEdit` swatches or `textColored` labels

3. Before calling `plot.render()`, iterate `bands.all_bands`, skip bands where:
   - `!show_bands`
   - `!band_categories_enabled[@intFromEnum(band.category)]`
   - band is fully outside the current x-axis range

   Build a stack-allocated `BandRenderEntry` array (max 64 entries) and pass to
   `plot.render()`.

---

## 4. Parallel work streams

| Stream | Task | Dependencies |
|--------|------|-------------|
| A | Create `bands.zig` (data + helpers) | None |
| B | Modify `plot.zig` (rendering) | Needs A's struct defs |
| C | Modify `main.zig` (state + UI) | Needs A's struct defs + B's API |

Execution order:
1. Build `bands.zig` first (standalone, no dependencies)
2. Then `plot.zig` and `main.zig` in parallel (different files, both import bands)

---

## 5. Validation plan

- `zig build` compiles cleanly
- Tune to known frequencies (e.g. 100 MHz → FM broadcast band visible,
  144 MHz → 2m ham band visible) and verify overlays appear
- Toggle categories on/off and verify bands appear/disappear
- Zoom in — labels appear when bands are wide enough in pixels
- Zoom out — labels hide to avoid clutter
- Pan across the spectrum — bands scroll correctly with the FFT plot
- Verify overlapping bands (33cm ham + 915 ISM) are both visible and
  not excessively opaque

---

## 6. Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| `plotShaded` call doesn't render as expected | Start with one hardcoded band (FM 88-108) to validate before adding all bands |
| Legend pollution from band entries | Use `"##band_N"` hidden ImGui IDs to suppress legend items |
| Too many overlapping labels at wide zoom | Only show label if band pixel width > 30px threshold |
| Band rectangles obscure FFT trace | Keep fill alpha at 0.10; draw bands before FFT series |
| Overlapping bands double alpha | Alpha of 0.10 means double = 0.20, still readable |
| `.fill` style color not available in zgui | Check enum; add to implot_extras.cpp if needed |
