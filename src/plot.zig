const zgui = @import("zgui");

pub fn render(
    title: [:0]const u8,
    x_label: [:0]const u8,
    y_label: [:0]const u8,
    x_data: []const f32,
    y_data: []const f32,
    y_range: ?[2]f64,
    refit_x: bool,
) void {
    if (zgui.plot.beginPlot(title, .{ .w = -1.0, .h = -1.0, .flags = .{ .crosshairs = true } })) {
        defer zgui.plot.endPlot();

        zgui.plot.setupAxis(.x1, .{ .label = x_label });
        zgui.plot.setupAxis(.y1, .{ .label = y_label });

        if (x_data.len > 0) {
            zgui.plot.setupAxisLimits(.x1, .{
                .min = @floatCast(x_data[0]),
                .max = @floatCast(x_data[x_data.len - 1]),
                .cond = if (refit_x) .always else .once,
            });
        }

        if (y_range) |yr| {
            zgui.plot.setupAxisLimits(.y1, .{ .min = yr[0], .max = yr[1], .cond = .once });
        }

        zgui.plot.setupLegend(.{ .north = true, .east = true }, .{});
        zgui.plot.setupFinish();

        zgui.plot.plotLine("Magnitude", f32, .{
            .xv = x_data,
            .yv = y_data,
        });
    }
}
