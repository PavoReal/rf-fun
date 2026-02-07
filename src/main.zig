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

fn kb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

fn mb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

fn gb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

const CallbackState = struct {
    should_stop: bool = true,
    bytes_transfered: u64 = 0,
    stdout_wtr: *std.Io.Writer
};

fn rxCallback(trans: hackrf.Transfer, state: *CallbackState) hackrf.StreamAction {
    const valid_length = trans.validLength();
    state.bytes_transfered += valid_length;

    std.log.debug("(rxCallback) received {d} KB", .{valid_length / 1000});

    if (state.should_stop) return .stop;
    return .@"continue";
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin_rdr = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_wtr = std.Io.File.stdout().writer(io, &stdout_buf);

    const stdin = &stdin_rdr.interface;
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

    // Config hackrf
    device.stopTx() catch {};
    try device.setSampleRate(mhz(10));
    try device.setFreq(ghz(0.9));
    try device.setAmpEnable(true);
    
    std.log.debug("hackrf config done", .{});

    var rx_state = CallbackState{.stdout_wtr = stdout, .should_stop = false};

    try device.startRx(*CallbackState, rxCallback, &rx_state);


    std.log.info("Press q<Enter> to exit", .{});
    while (stdin.takeDelimiterExclusive('\n')) |line| {
        stdin.toss(1); // toss the delimiter

        if (std.mem.eql(u8, line, "q")) {
            break;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.StreamTooLong => return err,
        error.ReadFailed => return err,
    }

    rx_state.should_stop = true;
}

