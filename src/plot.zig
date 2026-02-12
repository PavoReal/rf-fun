const std = @import("std");
pub const rl = @cImport({
    @cInclude("raylib.h");
});

const Plot = @This();

// ── Public types ─────────────────────────────────────────

pub const LegendPos = enum { top_left, top_right, bottom_left, bottom_right };

pub const Config = struct {
    title: ?[*:0]const u8 = null,
    x_label: ?[*:0]const u8 = null,
    y_label: ?[*:0]const u8 = null,
    rect: rl.Rectangle = .{ .x = 10, .y = 50, .width = 780, .height = 400 },
    x_range: ?[2]f32 = null, // null = auto-fit
    y_range: ?[2]f32 = null, // null = auto-scale
    bg_color: rl.Color = rl.DARKGRAY,
    grid: bool = true,
    grid_color: rl.Color = .{ .r = 80, .g = 80, .b = 80, .a = 255 },
    legend: bool = true,
    legend_pos: LegendPos = .top_right,
};

pub const Style = struct {
    color: rl.Color = rl.GREEN,
    thickness: f32 = 1.0,
    point_radius: f32 = 0, // 0 = no markers
    label: ?[*:0]const u8 = null,
    fill: bool = false,
};

const Series = struct {
    x_data: ?[]const f32, // null = auto-index
    y_data: []const f32,
    style: Style,
};

const max_series = 8;

// ── Plot state ───────────────────────────────────────────

config: Config,
series: [max_series]Series = undefined,
series_count: usize = 0,

// View ranges (zoom/pan state)
view_x: [2]f32,
view_y: [2]f32,

// Original ranges for reset
orig_x: [2]f32,
orig_y: [2]f32,

// Drag state
dragging: bool = false,
drag_start: rl.Vector2 = .{ .x = 0, .y = 0 },
drag_view_x_start: [2]f32 = .{ 0, 0 },
drag_view_y_start: [2]f32 = .{ 0, 0 },

// ── Lifecycle ────────────────────────────────────────────

pub fn init(cfg: Config) Plot {
    const vx = cfg.x_range orelse .{ 0, 1 };
    const vy = cfg.y_range orelse .{ 0, 1 };
    return .{
        .config = cfg,
        .view_x = vx,
        .view_y = vy,
        .orig_x = vx,
        .orig_y = vy,
    };
}

pub fn plotY(self: *Plot, y_data: []const f32, style: Style) void {
    if (self.series_count >= max_series) return;
    self.series[self.series_count] = .{
        .x_data = null,
        .y_data = y_data,
        .style = style,
    };
    self.series_count += 1;
}

pub fn plotXY(self: *Plot, x_data: []const f32, y_data: []const f32, style: Style) void {
    if (self.series_count >= max_series) return;
    self.series[self.series_count] = .{
        .x_data = x_data,
        .y_data = y_data,
        .style = style,
    };
    self.series_count += 1;
}

pub fn clear(self: *Plot) void {
    self.series_count = 0;
}

pub fn setRect(self: *Plot, rect: rl.Rectangle) void {
    self.config.rect = rect;
}

// ── Input handling ───────────────────────────────────────

pub fn update(self: *Plot) void {
    const mx = @as(f32, @floatFromInt(rl.GetMouseX()));
    const my = @as(f32, @floatFromInt(rl.GetMouseY()));
    const r = self.config.rect;

    const in_rect = mx >= r.x and mx <= r.x + r.width and
        my >= r.y and my <= r.y + r.height;

    // Auto-scale when ranges are null
    self.autoScale();

    // Zoom with mouse wheel
    if (in_rect) {
        const wheel = rl.GetMouseWheelMove();
        if (wheel != 0) {
            const zoom_factor: f32 = if (wheel > 0) 0.9 else 1.0 / 0.9;

            // Zoom around cursor position
            const frac_x = (mx - r.x) / r.width;
            const frac_y = (my - r.y) / r.height;

            const cx = self.view_x[0] + frac_x * (self.view_x[1] - self.view_x[0]);
            const cy = self.view_y[1] - frac_y * (self.view_y[1] - self.view_y[0]);

            const half_w = (self.view_x[1] - self.view_x[0]) * 0.5 * zoom_factor;
            const half_h = (self.view_y[1] - self.view_y[0]) * 0.5 * zoom_factor;

            self.view_x = .{ cx - half_w, cx + half_w };
            self.view_y = .{ cy - half_h, cy + half_h };
        }
    }

    // Pan with click-drag
    if (in_rect and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
        self.dragging = true;
        self.drag_start = .{ .x = mx, .y = my };
        self.drag_view_x_start = self.view_x;
        self.drag_view_y_start = self.view_y;
    }

    if (self.dragging) {
        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            const dx = mx - self.drag_start.x;
            const dy = my - self.drag_start.y;

            const data_dx = -dx / r.width * (self.drag_view_x_start[1] - self.drag_view_x_start[0]);
            const data_dy = dy / r.height * (self.drag_view_y_start[1] - self.drag_view_y_start[0]);

            self.view_x = .{
                self.drag_view_x_start[0] + data_dx,
                self.drag_view_x_start[1] + data_dx,
            };
            self.view_y = .{
                self.drag_view_y_start[0] + data_dy,
                self.drag_view_y_start[1] + data_dy,
            };
        } else {
            self.dragging = false;
        }
    }

    // Double-click to reset
    if (in_rect and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
        // Raylib doesn't have native double-click; use right-click as reset
    }
    if (in_rect and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_RIGHT)) {
        self.view_x = self.orig_x;
        self.view_y = self.orig_y;
    }
}

// ── Rendering ────────────────────────────────────────────

pub fn render(self: *Plot) void {
    const r = self.config.rect;

    // Background
    rl.DrawRectangleRec(r, self.config.bg_color);

    // Grid
    if (self.config.grid) {
        self.drawGrid();
    }

    // Scissor clip for data
    rl.BeginScissorMode(
        @intFromFloat(r.x),
        @intFromFloat(r.y),
        @intFromFloat(r.width),
        @intFromFloat(r.height),
    );

    // Draw each series
    for (0..self.series_count) |i| {
        self.drawSeries(self.series[i]);
    }

    rl.EndScissorMode();

    // Border
    rl.DrawRectangleLinesEx(r, 1, rl.WHITE);

    // Title
    if (self.config.title) |title| {
        const tw = rl.MeasureText(title, 16);
        rl.DrawText(
            title,
            @intFromFloat(r.x + r.width / 2 - @as(f32, @floatFromInt(tw)) / 2),
            @intFromFloat(r.y - 20),
            16,
            rl.WHITE,
        );
    }

    // X label
    if (self.config.x_label) |xlabel| {
        const tw = rl.MeasureText(xlabel, 14);
        rl.DrawText(
            xlabel,
            @intFromFloat(r.x + r.width / 2 - @as(f32, @floatFromInt(tw)) / 2),
            @intFromFloat(r.y + r.height + 5),
            14,
            rl.LIGHTGRAY,
        );
    }

    // Y label (drawn vertically to the left)
    if (self.config.y_label) |ylabel| {
        rl.DrawText(
            ylabel,
            @intFromFloat(r.x - 45),
            @intFromFloat(r.y + r.height / 2 - 7),
            14,
            rl.LIGHTGRAY,
        );
    }

    // Legend
    if (self.config.legend) {
        self.drawLegend();
    }

    // Cursor readout
    self.drawCursor();
}

// ── Internal: coordinate mapping ─────────────────────────

fn mapX(self: *const Plot, data_x: f32) f32 {
    const r = self.config.rect;
    return r.x + (data_x - self.view_x[0]) / (self.view_x[1] - self.view_x[0]) * r.width;
}

fn mapY(self: *const Plot, data_y: f32) f32 {
    const r = self.config.rect;
    return r.y + r.height - (data_y - self.view_y[0]) / (self.view_y[1] - self.view_y[0]) * r.height;
}

// ── Internal: nice tick computation ──────────────────────

fn niceTick(range: f32, target_count: f32) f32 {
    if (range <= 0) return 1;
    const rough = range / target_count;
    const mag = std.math.pow(f32, 10, @floor(std.math.log10(rough)));
    const norm = rough / mag;
    const nice: f32 = if (norm < 1.5)
        1
    else if (norm < 3.5)
        2
    else if (norm < 7.5)
        5
    else
        10;
    return nice * mag;
}

// ── Internal: grid ───────────────────────────────────────

fn drawGrid(self: *Plot) void {
    const r = self.config.rect;
    const gc = self.config.grid_color;

    // Vertical grid lines (X axis ticks)
    const x_range = self.view_x[1] - self.view_x[0];
    const x_tick = niceTick(x_range, 8);
    if (x_tick > 0) {
        const x_start = @ceil(self.view_x[0] / x_tick) * x_tick;
        var x = x_start;
        while (x < self.view_x[1]) : (x += x_tick) {
            const sx = self.mapX(x);
            if (sx >= r.x and sx <= r.x + r.width) {
                rl.DrawLineV(
                    .{ .x = sx, .y = r.y },
                    .{ .x = sx, .y = r.y + r.height },
                    gc,
                );
                // Tick label
                var buf: [32]u8 = undefined;
                const label = formatTickLabel(&buf, x, x_tick);
                const tw = rl.MeasureText(label, 10);
                rl.DrawText(
                    label,
                    @intFromFloat(sx - @as(f32, @floatFromInt(tw)) / 2),
                    @intFromFloat(r.y + r.height + 2),
                    10,
                    rl.LIGHTGRAY,
                );
            }
        }
    }

    // Horizontal grid lines (Y axis ticks)
    const y_range = self.view_y[1] - self.view_y[0];
    const y_tick = niceTick(y_range, 6);
    if (y_tick > 0) {
        const y_start = @ceil(self.view_y[0] / y_tick) * y_tick;
        var y = y_start;
        while (y < self.view_y[1]) : (y += y_tick) {
            const sy = self.mapY(y);
            if (sy >= r.y and sy <= r.y + r.height) {
                rl.DrawLineV(
                    .{ .x = r.x, .y = sy },
                    .{ .x = r.x + r.width, .y = sy },
                    gc,
                );
                // Tick label
                var buf: [32]u8 = undefined;
                const label = formatTickLabel(&buf, y, y_tick);
                rl.DrawText(
                    label,
                    @intFromFloat(r.x - 40),
                    @intFromFloat(sy - 5),
                    10,
                    rl.LIGHTGRAY,
                );
            }
        }
    }
}

fn formatTickLabel(buf: *[32]u8, value: f32, tick: f32) [*:0]const u8 {
    // Choose decimal places based on tick size
    const abs_tick = @abs(tick);
    const result = if (abs_tick >= 1.0)
        std.fmt.bufPrintZ(buf, "{d:.0}", .{value}) catch buf[0..0 :0]
    else if (abs_tick >= 0.1)
        std.fmt.bufPrintZ(buf, "{d:.1}", .{value}) catch buf[0..0 :0]
    else if (abs_tick >= 0.01)
        std.fmt.bufPrintZ(buf, "{d:.2}", .{value}) catch buf[0..0 :0]
    else
        std.fmt.bufPrintZ(buf, "{d:.3}", .{value}) catch buf[0..0 :0];
    return result.ptr;
}

// ── Internal: data drawing ───────────────────────────────

fn drawSeries(self: *Plot, s: Series) void {
    const n = s.y_data.len;
    if (n < 2) return;

    const r = self.config.rect;
    const bottom_y = r.y + r.height;

    // Draw line segments (and optional fill) point by point
    var prev_sx = self.getSeriesScreenX(s, 0);
    var prev_sy = self.mapY(s.y_data[0]);

    var i: usize = 1;
    while (i < n) : (i += 1) {
        const sx = self.getSeriesScreenX(s, i);
        const sy = self.mapY(s.y_data[i]);

        if (s.style.fill) {
            // Draw filled quad as two triangles from line to bottom
            rl.DrawTriangle(
                .{ .x = prev_sx, .y = bottom_y },
                .{ .x = prev_sx, .y = prev_sy },
                .{ .x = sx, .y = sy },
                fadeColor(s.style.color, 100),
            );
            rl.DrawTriangle(
                .{ .x = prev_sx, .y = bottom_y },
                .{ .x = sx, .y = sy },
                .{ .x = sx, .y = bottom_y },
                fadeColor(s.style.color, 100),
            );
        }

        // Draw line segment
        if (s.style.thickness <= 1.0) {
            rl.DrawLineV(
                .{ .x = prev_sx, .y = prev_sy },
                .{ .x = sx, .y = sy },
                s.style.color,
            );
        } else {
            rl.DrawLineEx(
                .{ .x = prev_sx, .y = prev_sy },
                .{ .x = sx, .y = sy },
                s.style.thickness,
                s.style.color,
            );
        }

        prev_sx = sx;
        prev_sy = sy;
    }

    // Point markers
    if (s.style.point_radius > 0) {
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const px = self.getSeriesScreenX(s, j);
            const py = self.mapY(s.y_data[j]);
            rl.DrawCircleV(.{ .x = px, .y = py }, s.style.point_radius, s.style.color);
        }
    }
}

fn getSeriesScreenX(self: *const Plot, s: Series, idx: usize) f32 {
    if (s.x_data) |xd| {
        return self.mapX(xd[idx]);
    } else {
        return self.mapX(@floatFromInt(idx));
    }
}

fn fadeColor(c: rl.Color, alpha: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = alpha };
}

// ── Internal: legend ─────────────────────────────────────

fn drawLegend(self: *Plot) void {
    // Count labeled series
    var label_count: usize = 0;
    for (0..self.series_count) |i| {
        if (self.series[i].style.label != null) label_count += 1;
    }
    if (label_count == 0) return;

    const r = self.config.rect;
    const pad: f32 = 8;
    const line_h: f32 = 16;
    const swatch_w: f32 = 12;
    const box_h = @as(f32, @floatFromInt(label_count)) * line_h + pad * 2;

    // Measure max label width
    var max_w: c_int = 0;
    for (0..self.series_count) |i| {
        if (self.series[i].style.label) |lbl| {
            const w = rl.MeasureText(lbl, 12);
            if (w > max_w) max_w = w;
        }
    }
    const box_w = @as(f32, @floatFromInt(max_w)) + swatch_w + pad * 3;

    // Position
    var lx: f32 = undefined;
    var ly: f32 = undefined;
    switch (self.config.legend_pos) {
        .top_left => {
            lx = r.x + 8;
            ly = r.y + 8;
        },
        .top_right => {
            lx = r.x + r.width - box_w - 8;
            ly = r.y + 8;
        },
        .bottom_left => {
            lx = r.x + 8;
            ly = r.y + r.height - box_h - 8;
        },
        .bottom_right => {
            lx = r.x + r.width - box_w - 8;
            ly = r.y + r.height - box_h - 8;
        },
    }

    // Background
    rl.DrawRectangleRec(
        .{ .x = lx, .y = ly, .width = box_w, .height = box_h },
        .{ .r = 0, .g = 0, .b = 0, .a = 160 },
    );

    // Entries
    var row: f32 = 0;
    for (0..self.series_count) |i| {
        if (self.series[i].style.label) |lbl| {
            const ey = ly + pad + row * line_h;
            // Color swatch
            rl.DrawRectangleRec(
                .{ .x = lx + pad, .y = ey + 2, .width = swatch_w, .height = 10 },
                self.series[i].style.color,
            );
            // Label text
            rl.DrawText(
                lbl,
                @intFromFloat(lx + pad + swatch_w + pad),
                @intFromFloat(ey),
                12,
                rl.WHITE,
            );
            row += 1;
        }
    }
}

// ── Internal: cursor readout ─────────────────────────────

fn drawCursor(self: *Plot) void {
    const mx = @as(f32, @floatFromInt(rl.GetMouseX()));
    const my = @as(f32, @floatFromInt(rl.GetMouseY()));
    const r = self.config.rect;

    const in_rect = mx >= r.x and mx <= r.x + r.width and
        my >= r.y and my <= r.y + r.height;

    if (!in_rect) return;

    // Crosshair lines
    const cross_color = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 80 };
    rl.DrawLineV(.{ .x = mx, .y = r.y }, .{ .x = mx, .y = r.y + r.height }, cross_color);
    rl.DrawLineV(.{ .x = r.x, .y = my }, .{ .x = r.x + r.width, .y = my }, cross_color);

    // Convert to data coordinates
    const data_x = self.view_x[0] + (mx - r.x) / r.width * (self.view_x[1] - self.view_x[0]);
    const data_y = self.view_y[1] - (my - r.y) / r.height * (self.view_y[1] - self.view_y[0]);

    // Readout text
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "x:{d:.1} y:{d:.2}", .{ data_x, data_y }) catch return;

    // Draw readout near cursor, offset to avoid overlap
    const tx: c_int = @intFromFloat(mx + 10);
    const ty: c_int = @intFromFloat(my - 18);
    rl.DrawText(text.ptr, tx, ty, 12, rl.YELLOW);
}

// ── Internal: auto-scale ─────────────────────────────────

fn autoScale(self: *Plot) void {
    if (self.series_count == 0) return;

    const auto_x = self.config.x_range == null;
    const auto_y = self.config.y_range == null;
    if (!auto_x and !auto_y) return;

    var x_min: f32 = std.math.inf(f32);
    var x_max: f32 = -std.math.inf(f32);
    var y_min: f32 = std.math.inf(f32);
    var y_max: f32 = -std.math.inf(f32);

    for (0..self.series_count) |i| {
        const s = self.series[i];
        for (0..s.y_data.len) |j| {
            const y = s.y_data[j];
            if (y < y_min) y_min = y;
            if (y > y_max) y_max = y;

            if (s.x_data) |xd| {
                const x = xd[j];
                if (x < x_min) x_min = x;
                if (x > x_max) x_max = x;
            } else {
                const x: f32 = @floatFromInt(j);
                if (x < x_min) x_min = x;
                if (x > x_max) x_max = x;
            }
        }
    }

    // Add 5% padding
    if (auto_x and x_min < x_max) {
        const pad = (x_max - x_min) * 0.05;
        self.view_x = .{ x_min - pad, x_max + pad };
        self.orig_x = self.view_x;
    }

    if (auto_y and y_min < y_max) {
        const pad = (y_max - y_min) * 0.05;
        self.view_y = .{ y_min - pad, y_max + pad };
        self.orig_y = self.view_y;
    }
}
