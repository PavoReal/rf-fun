const std = @import("std");
const zgui = @import("zgui");
const bands = @import("bands.zig");

extern fn rfFunGetPlotLimits(x_min: *f64, x_max: *f64, y_min: *f64, y_max: *f64) void;
extern fn rfFunGetPlotPos(x: *f32, y: *f32) void;
extern fn rfFunGetPlotSize(w: *f32, h: *f32) void;

pub const PlotSeries = struct {
    label: [:0]const u8,
    x_data: []const f32,
    y_data: []const f32,
    color: ?[4]f32 = null,
    line_weight: f32 = -1.0,
};

pub const BandRenderEntry = struct {
    start_mhz: f32,
    end_mhz: f32,
    label: [:0]const u8,
    color: [4]f32,
};

pub const PlotLimits = struct { x_min: f64, x_max: f64 };

pub const RenderResult = struct {
    limits: PlotLimits,
    hovered: bool,
    plot_pos: [2]f32,
    plot_size: [2]f32,
};

pub fn render(
    title: [:0]const u8,
    x_label: [:0]const u8,
    y_label: [:0]const u8,
    series: []const PlotSeries,
    y_range: [2]f64,
    x_range: ?[2]f64,
    refit_x: bool,
    height: f32,
    overlay_text: ?[:0]const u8,
    band_entries: []const BandRenderEntry,
) RenderResult {
    var result = RenderResult{
        .limits = .{ .x_min = 0, .x_max = 0 },
        .hovered = false,
        .plot_pos = .{ 0, 0 },
        .plot_size = .{ 0, 0 },
    };

    if (zgui.plot.beginPlot(title, .{ .w = -1.0, .h = height, .flags = .{ .crosshairs = true } })) {
        zgui.plot.setupAxis(.x1, .{ .label = x_label });
        zgui.plot.setupAxis(.y1, .{
            .label = y_label,
            .flags = .{ .lock_min = true, .lock_max = true },
        });

        // Y-axis: always locked
        zgui.plot.setupAxisLimits(.y1, .{
            .min = y_range[0],
            .max = y_range[1],
            .cond = .always,
        });

        // X-axis: refit when requested, otherwise user can pan/zoom
        if (x_range) |xr| {
            zgui.plot.setupAxisLimits(.x1, .{
                .min = xr[0],
                .max = xr[1],
                .cond = if (refit_x) .always else .once,
            });
        }

        zgui.plot.setupLegend(.{ .north = true, .east = true }, .{});
        zgui.plot.setupFinish();

        // ── Band overlays (drawn first so they render behind the FFT trace) ──
        if (band_entries.len > 0) {
            // Get plot dimensions for pixel-width gating of labels
            var xmin_d: f64 = 0;
            var xmax_d: f64 = 0;
            var ymin_d: f64 = 0;
            var ymax_d: f64 = 0;
            rfFunGetPlotLimits(&xmin_d, &xmax_d, &ymin_d, &ymax_d);
            var plot_w: f32 = 0;
            var plot_h: f32 = 0;
            rfFunGetPlotSize(&plot_w, &plot_h);
            _ = plot_h;

            const x_span = xmax_d - xmin_d;

            for (band_entries, 0..) |entry, i| {
                // Shaded rectangle with hidden label (##) to suppress legend entry
                var id_buf: [32]u8 = undefined;
                const id_str = std.fmt.bufPrintZ(&id_buf, "##band_{d}", .{i}) catch "##band";

                const fill_color = [4]f32{ entry.color[0], entry.color[1], entry.color[2], 0.10 };
                zgui.plot.pushStyleColor4f(.{ .idx = .fill, .c = fill_color });

                const xv = [2]f32{ entry.start_mhz, entry.end_mhz };
                const yv = [2]f32{ @floatCast(y_range[1]), @floatCast(y_range[1]) };
                zgui.plot.plotShaded(id_str, f32, .{
                    .xv = &xv,
                    .yv = &yv,
                    .yref = y_range[0],
                });

                zgui.plot.popStyleColor(.{ .count = 1 });

                // Label: only show if the band is wide enough in pixels
                if (x_span > 0 and plot_w > 0) {
                    const band_width_mhz: f64 = @as(f64, entry.end_mhz) - @as(f64, entry.start_mhz);
                    const pixel_width = band_width_mhz / x_span * @as(f64, plot_w);
                    if (pixel_width > 30) {
                        const cx: f64 = (@as(f64, entry.start_mhz) + @as(f64, entry.end_mhz)) / 2.0;
                        const label_y: f64 = y_range[1] - (y_range[1] - y_range[0]) * 0.03;
                        zgui.plot.plotText(entry.label, .{
                            .x = cx,
                            .y = label_y,
                            .flags = .{},
                        });
                    }
                }
            }
        }

        // ── Series (FFT trace, peak hold, etc.) ──
        for (series) |s| {
            if (s.color) |col| {
                zgui.plot.pushStyleColor4f(.{ .idx = .line, .c = col });
            }
            if (s.line_weight >= 0) {
                zgui.plot.pushStyleVar1f(.{ .idx = .line_weight, .v = s.line_weight });
            }

            zgui.plot.plotLine(s.label, f32, .{
                .xv = s.x_data,
                .yv = s.y_data,
            });

            if (s.line_weight >= 0) {
                zgui.plot.popStyleVar(.{});
            }
            if (s.color != null) {
                zgui.plot.popStyleColor(.{});
            }
        }

        if (overlay_text) |txt| {
            // Place text at center of current plot
            var xmin: f64 = 0;
            var xmax: f64 = 0;
            var ymin: f64 = 0;
            var ymax: f64 = 0;
            rfFunGetPlotLimits(&xmin, &xmax, &ymin, &ymax);
            zgui.plot.plotText(txt, .{
                .x = (xmin + xmax) / 2.0,
                .y = (ymin + ymax) / 2.0,
            });
        }

        result.hovered = zgui.plot.isPlotHovered();

        // Read back plot limits before ending
        var xmin: f64 = 0;
        var xmax: f64 = 0;
        var ymin: f64 = 0;
        var ymax: f64 = 0;
        rfFunGetPlotLimits(&xmin, &xmax, &ymin, &ymax);
        result.limits = .{ .x_min = xmin, .x_max = xmax };

        // Read back plot pixel position and size for alignment
        rfFunGetPlotPos(&result.plot_pos[0], &result.plot_pos[1]);
        rfFunGetPlotSize(&result.plot_size[0], &result.plot_size[1]);

        zgui.plot.endPlot();
    }

    return result;
}
