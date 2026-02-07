const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;

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
    try device.setSampleRate(mhz(10));
    try device.setFreq(ghz(0.9));
    try device.setAmpEnable(true);

    std.log.debug("hackrf config done", .{});

    var rx_buffer = try FixedSizeRingBuffer(hackrf.IQSample).init(alloc, mb(256));
    var rx_state = CallbackState{ .target_buffer = &rx_buffer, .should_stop = false, .mutex = std.Io.Mutex.init, .io = io };

    try device.startRx(*CallbackState, rxCallback, &rx_state);

    const screen_width = 800;
    const screen_height = 450;

    rl.InitWindow(screen_width, screen_height, "raylib [zig] - hello world");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.RAYWHITE);

        // Draw some rectangles
        rl.DrawRectangle(100, 80, 200, 120, rl.LIGHTGRAY);
        rl.DrawRectangle(150, 100, 200, 120, rl.BLUE);
        rl.DrawRectangleLines(400, 80, 180, 140, rl.DARKGREEN);
        rl.DrawRectangle(500, 200, 100, 80, rl.RED);
        rl.DrawRectangle(50, 300, 300, 60, rl.ORANGE);

        // Draw some text
        rl.DrawText("Hello, Raylib + Zig!", 220, 20, 30, rl.DARKGRAY);
        rl.DrawText("This is a rectangle party.", 260, 360, 20, rl.MAROON);

        rl.DrawFPS(10, 10);
    }

    rx_state.should_stop = true;
}
