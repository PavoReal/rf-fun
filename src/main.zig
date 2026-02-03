const std = @import("std");
const sdl = @cImport({
    @cInclude("SDL3/SDL.h");
});
const hackrf = @import("rf_fun");

fn ghz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e9);
}

fn mhz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e6);
}

fn khz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        std.debug.panic("SDL_Init failed: {s}\n", .{sdl.SDL_GetError()});
    }
    defer sdl.SDL_Quit();

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

    // Config hackrf
    device.stopTx() catch {};
    try device.setSampleRate(mhz(10));
    try device.setFreq(ghz(0.9));
    try device.setAmpEnable(true);

    std.log.debug("hackrf config done", .{});
}
