const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const Plot = @import("plot.zig");
const rl = Plot.rl;

const SimpleFFT = @import("simple_fft.zig").SimpleFFT;
const util = @import("util.zig");

const RXCallbackState = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    should_stop: bool = true,
    bytes_transfered: u64 = 0,
    target_buffer: *FixedSizeRingBuffer(hackrf.IQSample),
};

fn rxCallback(trans: hackrf.Transfer, state: *RXCallbackState) hackrf.StreamAction {
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

    //var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    //defer allocator.deinit();

    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);

    const alloc = allocator.allocator();

    //
    // Setup hackrf one
    //

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

    const fs = util.mhz(10);
    const center_freq = util.ghz(0.9);

    device.stopTx() catch {};
    try device.setSampleRate(fs);
    try device.setFreq(center_freq);
    try device.setAmpEnable(true);

    std.log.debug("hackrf config done", .{});

    var rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, util.mb(256));
    defer rx_buffer.deinit(alloc);

    var rx_state = RXCallbackState{ .target_buffer = &rx_buffer, .should_stop = false, .mutex = std.Io.Mutex.init, .io = io };

    try device.startRx(*RXCallbackState, rxCallback, &rx_state);
    const start_time: f64 = rl.GetTime();
    _ = start_time;

    const screen_width = 800;
    const screen_height = 700;

    rl.InitWindow(screen_width, screen_height, "rf-fun");
    defer rl.CloseWindow();

    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);
    rl.SetTargetFPS(60);

    var fft = try SimpleFFT.init(alloc, 512, center_freq, fs);
    defer fft.deinit(alloc);

    var fft_plot = Plot.init(.{
        .title = "1024 point FFT",
        .x_label = "Freq (MHz)",
        .y_label = "dB",
        .rect = .{ .x = 10, .y = 40, .width = @as(f32, screen_width - 20), .height = 512 },
        .y_range = .{ -120.0, 0.0 },
    });

    var next_fft_update_time = rl.GetTime() + 0.5;

    while (!rl.WindowShouldClose()) {
        const w: f32 = @floatFromInt(rl.GetScreenWidth());
        const h: f32 = @floatFromInt(rl.GetScreenHeight());

        const current_time = rl.GetTime();

        if (current_time >= next_fft_update_time) {
            try rx_state.mutex.lock(rx_state.io);
            defer rx_state.mutex.unlock(rx_state.io);

            std.log.debug("fft update", .{});

            next_fft_update_time = current_time + 0.5;
        }

        fft_plot.setRect(.{ .x = 10, .y = 40, .width = w - 20, .height = h - 150 });
        fft_plot.update();
        fft_plot.clear();
        fft_plot.plotXY(fft.fft_freqs, fft.fft_mag, .{ .color = rl.SKYBLUE, .label = "Magnitude" });

        // Draw
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(.{ .r = 30, .g = 30, .b = 30, .a = 255 });
        fft_plot.render();

        rl.DrawFPS(rl.GetScreenWidth() - 100, 10);
    }

    rx_state.should_stop = true;
}
