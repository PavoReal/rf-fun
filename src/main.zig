const std = @import("std");
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

fn rxCallback(_: hackrf.Transfer, _: void) hackrf.StreamAction {
    return .stop;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

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

    try device.startRx(void, rxCallback, {});

    var stdin_buf: [4096]u8 = undefined;
    var stdin_rdr = std.Io.File.stdin().reader(io, &stdin_buf);

    const stdin = &stdin_rdr.interface;

    std.log.info("Press q to exit", .{});
    while (stdin.takeDelimiterExclusive('\n')) |line| {
        stdin.toss(1); // toss the delimiter

        if (std.mem.eql(u8, line, "q")) {
            return;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.StreamTooLong => return err,
        error.ReadFailed => return err,
    }

    std.log.debug("hackrf config done", .{});
}
