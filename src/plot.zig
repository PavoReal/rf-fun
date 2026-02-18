const zgui = @import("zgui");

extern fn rfFunGetPlotLimits(x_min: *f64, x_max: *f64, y_min: *f64, y_max: *f64) void;
extern fn rfFunGetPlotPos(x: *f32, y: *f32) void;
extern fn rfFunGetPlotSize(w: *f32, h: *f32) void;
extern fn rfFunDragLineX(id: c_int, value: *f64, r: f32, g: f32, b: f32, a: f32, thickness: f32) bool;
extern fn rfFunPlotBandX(x_min: f64, x_max: f64, r: f32, g: f32, b: f32, a: f32) void;

pub fn dragLineX(id: i32, value: *f64, color: [4]f32, thickness: f32) bool {
    return rfFunDragLineX(id, value, color[0], color[1], color[2], color[3], thickness);
}

pub fn plotBandX(x_min: f64, x_max: f64, color: [4]f32) void {
    rfFunPlotBandX(x_min, x_max, color[0], color[1], color[2], color[3]);
}

pub const PlotSeries = struct {
    label: [:0]const u8,
    x_data: []const f32,
    y_data: []const f32,
    color: ?[4]f32 = null,
    line_weight: f32 = -1.0,
};

pub const PlotMarker = struct {
    x_data: []const f32,
    y_data: []const f32,
    label: [:0]const u8 = "Peaks",
    color: [4]f32 = .{ 1.0, 1.0, 0.0, 1.0 },
    size: f32 = 6.0,
};

pub const PlotLimits = struct { x_min: f64, x_max: f64 };

pub const DragLine = struct {
    value: *f64,
    color: [4]f32 = .{ 0.0, 1.0, 0.5, 0.9 },
    thickness: f32 = 2.0,
};

pub const BandX = struct {
    center: f64,
    half_width: f64,
    color: [4]f32 = .{ 0.0, 1.0, 0.5, 0.15 },
};

pub const RenderResult = struct {
    limits: PlotLimits,
    hovered: bool,
    plot_pos: [2]f32,
    plot_size: [2]f32,
    drag_line_moved: bool = false,
};

pub fn render(
    title: [:0]const u8,
    x_label: [:0]const u8,
    y_label: [:0]const u8,
    series: []const PlotSeries,
    markers: []const PlotMarker,
    y_range: [2]f64,
    x_range: ?[2]f64,
    refit_x: bool,
    height: f32,
    overlay_text: ?[:0]const u8,
    drag_line: ?DragLine,
    band: ?BandX,
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

        for (markers) |m| {
            zgui.plot.pushStyleColor4f(.{ .idx = .line, .c = m.color });
            zgui.plot.pushStyleVar1i(.{ .idx = .marker, .v = @intFromEnum(zgui.plot.Marker.circle) });
            zgui.plot.pushStyleVar1f(.{ .idx = .marker_size, .v = m.size });
            zgui.plot.plotScatter(m.label, f32, .{ .xv = m.x_data, .yv = m.y_data });
            zgui.plot.popStyleVar(.{ .count = 2 });
            zgui.plot.popStyleColor(.{});

            for (m.x_data, m.y_data, 0..) |x, y, i| {
                const txt = zgui.formatZ("{d}", .{i + 1});
                zgui.plot.plotText(txt, .{ .x = @floatCast(x), .y = @floatCast(y), .pix_offset = .{ 8, -8 } });
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

        if (band) |b| {
            plotBandX(b.center - b.half_width, b.center + b.half_width, b.color);
        }

        if (drag_line) |dl| {
            if (dragLineX(0, dl.value, dl.color, dl.thickness)) {
                result.drag_line_moved = true;
            }
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
