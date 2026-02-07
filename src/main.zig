const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const fftw = @cImport({
    @cDefine("__float128", "double");
    @cInclude("fftw3.h");
});

const rl = @cImport({
    @cInclude("raylib.h");
});

fn ghz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e9);
}

fn mhz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e6);
}

fn khz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

fn kb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

fn mb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e6);
}

fn gb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e9);
}

const PlotSpace = struct {
    // Screen rect (pixels)
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,

    // Data ranges (what the axes represent)
    x_min: f32,
    x_max: f32,
    y_min: f32,
    y_max: f32,

    /// Map a data-space point to a screen-space Vector2.
    fn map(self: PlotSpace, data_x: f32, data_y: f32) rl.Vector2 {
        const sx = @as(f32, @floatFromInt(self.x)) +
            (data_x - self.x_min) / (self.x_max - self.x_min) * @as(f32, @floatFromInt(self.width));
        const sy = @as(f32, @floatFromInt(self.y + self.height)) -
            (data_y - self.y_min) / (self.y_max - self.y_min) * @as(f32, @floatFromInt(self.height));
        return .{ .x = sx, .y = sy };
    }

    /// Begin clipped drawing (call before drawing data).
    fn beginClip(self: PlotSpace) void {
        rl.BeginScissorMode(self.x, self.y, self.width, self.height);
    }

    /// End clipped drawing.
    fn endClip() void {
        rl.EndScissorMode();
    }

    /// Draw the plot background.
    fn drawBg(self: PlotSpace, color: rl.Color) void {
        rl.DrawRectangle(self.x, self.y, self.width, self.height, color);
    }
};

const CallbackState = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    should_stop: bool = true,
    bytes_transfered: u64 = 0,
    target_buffer: *FixedSizeRingBuffer(hackrf.IQSample),
};

fn rxCallback(trans: hackrf.Transfer, state: *CallbackState) hackrf.StreamAction {
    state.mutex.lock(state.io) catch {
        std.log.err("Failed to get rxCallback mutex lock", .{});
    };

    defer state.mutex.unlock(state.io);

    const valid_length = trans.validLength();
    state.bytes_transfered += valid_length;

    state.target_buffer.append(trans.iqSamples());

    if (state.should_stop) return .stop;
    return .@"continue";
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();

    const alloc = allocator.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_wtr = std.Io.File.stdout().writer(io, &stdout_buf);

    const stdout = &stdout_wtr.interface;

    // For dev cycle, clear stdout. Good with
    // zig build run --watch
    try stdout.writeAll("\x1B[2J\x1B[3J\x1B[H");
    try stdout.flush();

    std.log.debug("Starting FFT", .{});
    const N = 8;

    const in: *[N]fftw.fftw_complex = @ptrCast(@alignCast(fftw.fftw_malloc(@sizeOf(fftw.fftw_complex) * N)));
    defer fftw.fftw_free(in);

    const out: *[N]fftw.fftw_complex = @ptrCast(@alignCast(fftw.fftw_malloc(@sizeOf(fftw.fftw_complex) * N)));
    defer fftw.fftw_free(out);

    const plan = fftw.fftw_plan_dft_1d(N, in, out, fftw.FFTW_FORWARD, fftw.FFTW_ESTIMATE);
    defer fftw.fftw_destroy_plan(plan);

    // Set up a simple impulse: 1 + 0i at index 0, rest zeros
    for (0..N) |i| {
        in[i][0] = 0.0; // real
        in[i][1] = 0.0; // imag
    }
    in[0][0] = 1.0; // DC impulse

    fftw.fftw_execute(plan);

    // FFT of an impulse should be all 1s
    std.debug.print("FFT output:\n", .{});

    for (0..N) |i| {
        std.debug.print("  [{d}] {d:.4} + {d:.4}i\n", .{ i, out[i][0], out[i][1] });
    }
    std.log.debug("FFT Done", .{});

    try hackrf.init();
    defer hackrf.deinit() catch {};

    var list = try hackrf.DeviceList.get();
    defer list.deinit();

    if (list.count() == 0) {
        std.log.err("Failed to find hackrf device", .{});
        return;
    }

    const device = try hackrf.Device.open();
    defer device.close();

    var version_buf: [256]u8 = undefined;
    const version = try device.versionStringRead(&version_buf);

    std.log.debug("Found hackrf device running firmware {s}", .{version});

    device.stopTx() catch {};
    try device.setSampleRate(mhz(1));
    try device.setFreq(ghz(2.4));
    try device.setAmpEnable(true);

    std.log.debug("hackrf config done", .{});

    var rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, mb(256));
    defer rx_buffer.deinit(alloc);

    var rx_state = CallbackState{ .target_buffer = &rx_buffer, .should_stop = false, .mutex = std.Io.Mutex.init, .io = io };

    try device.startRx(*CallbackState, rxCallback, &rx_state);

    const screen_width = 800;
    const screen_height = 450;

    rl.InitWindow(screen_width, screen_height, "rf-fun");
    defer rl.CloseWindow();

    rl.SetTargetFPS(240);
    const start_time: f64 = rl.GetTime();

    const samples_to_show = screen_width;
    const samples: []hackrf.IQSample = try alloc.alloc(hackrf.IQSample, samples_to_show);
    defer alloc.free(samples);

    const points: []rl.Vector2 = try alloc.alloc(rl.Vector2, samples_to_show);
    defer alloc.free(points);

    const top_height = 40;
    const left_border = 10;

    const plot = PlotSpace{
        .x = left_border,
        .y = top_height,
        .width = screen_width - 20,
        .height = screen_height - 50,
        .x_min = 0,
        .x_max = @floatFromInt(samples_to_show),
        .y_min = -1,
        .y_max = 1,
    };

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.BLACK);
        plot.drawBg(rl.GRAY);

        try rx_state.mutex.lock(io);
        const rx_total_bytes = rx_state.bytes_transfered;

        const sample_slices = rx_state.target_buffer.newest(samples_to_show);

        if (sample_slices.first.len > 0) {
            std.mem.copyForwards(hackrf.IQSample, samples, sample_slices.first);
        }

        if (sample_slices.second.len > 0) {
            std.mem.copyForwards(hackrf.IQSample, samples[sample_slices.first.len..], sample_slices.second);
        }
        rx_state.mutex.unlock(io);

        for (samples, 0..) |s, i| {
            const f = s.toFloat();
            points[i] = plot.map(@floatFromInt(i), f[0]);
        }

        // Draw waveform clipped to plot area
        plot.beginClip();
        rl.DrawLineStrip(@ptrCast(points.ptr), @intCast(points.len), rl.GREEN);
        PlotSpace.endClip();

        var rx_stat_str_buf = std.mem.zeroes([128]u8);

        const current_time: f64 = rl.GetTime();
        const elapsed_time = current_time - start_time;

        _ = try std.fmt.bufPrint(&rx_stat_str_buf, "Received {d} MB @ {d:.2} MB/s", .{ rx_total_bytes / mb(1), (@as(f64, @floatFromInt(rx_total_bytes)) / elapsed_time) / mb(1) });

        rl.DrawText(&rx_stat_str_buf, 10, 10, 20, rl.MAROON);
        rl.DrawFPS(screen_width - 100, 10);
    }

    rx_state.should_stop = true;
}

test "fftw" {

}
