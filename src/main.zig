const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const fftw = @cImport({
    @cDefine("__float128", "double");
    @cInclude("fftw3.h");
});

const Plot = @import("plot.zig");
const rl = Plot.rl;

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
    try device.setFreq(ghz(0.9));
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

    rl.SetTargetFPS(60);
    const start_time: f64 = rl.GetTime();

    const samples_to_show = screen_width;
    const samples: []hackrf.IQSample = try alloc.alloc(hackrf.IQSample, samples_to_show);
    defer alloc.free(samples);

    // Separate float buffers for I and Q channels
    const i_samples: []f32 = try alloc.alloc(f32, samples_to_show);
    defer alloc.free(i_samples);
    const q_samples: []f32 = try alloc.alloc(f32, samples_to_show);
    defer alloc.free(q_samples);

    var time_plot = Plot.init(.{
        .title = "IQ Time Domain",
        .x_label = "Sample",
        .y_label = "Amp",
        .rect = .{ .x = 10, .y = 50, .width = @as(f32, screen_width - 20), .height = @as(f32, screen_height - 80) },
        .y_range = .{ -1.0, 1.0 },
    });

    while (!rl.WindowShouldClose()) {
        // Update (zoom/pan/cursor input)
        time_plot.update();

        // Copy sample data from ring buffer
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

        // Convert IQ samples to float arrays
        for (samples, 0..) |s, i| {
            const f = s.toFloat();
            i_samples[i] = f[0];
            q_samples[i] = f[1];
        }

        // Set data each frame
        time_plot.clear();
        time_plot.plotY(i_samples, .{ .color = rl.GREEN, .label = "I" });
        time_plot.plotY(q_samples, .{ .color = rl.RED, .label = "Q" });

        // Draw
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(.{ .r = 30, .g = 30, .b = 30, .a = 255 });
        time_plot.render();

        var rx_stat_str_buf = std.mem.zeroes([128]u8);

        const current_time: f64 = rl.GetTime();
        const elapsed_time = current_time - start_time;

        _ = try std.fmt.bufPrint(&rx_stat_str_buf, "Received {d} MB @ {d:.2} MB/s", .{ rx_total_bytes / mb(1), (@as(f64, @floatFromInt(rx_total_bytes)) / elapsed_time) / mb(1) });

        rl.DrawText(&rx_stat_str_buf, 10, 10, 20, rl.MAROON);
        //rl.DrawFPS(screen_width - 100, 10);
    }

    rx_state.should_stop = true;
}

test "fftw" {

}
