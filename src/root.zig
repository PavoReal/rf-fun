const std = @import("std");
const Io = std.Io;

const hrf = @cImport({
    @cInclude("hackrf.h");
});

const HackRF = struct {
    device: *hrf.hackrf_device,

    pub fn init() !void {
        if (hrf.hackrf_init() != hrf.HACKRF_SUCCESS) {
            return error.HackRFInitFailed;
        }
    }

    pub fn open() !HackRF {
        var device: ?*hrf.hackrf_device = null;

        if (hrf.hackrf_open(&device) != hrf.HACKRF_SUCCESS) {
            return error.HackRFOpenFailed;
        }

        std.debug.assert(device != null);

        return .{ .device = device.? };
    }

    pub fn hackrf_library_version() ?[*:0]const u8 {
        return hrf.hackrf_library_version();
    }

    pub fn hackrf_library_release() ?[*:0]const u8 {
        return hrf.hackrf_library_release();
    }

    pub fn hackrf_device_list() ?*hrf.hackrf_device_list {
        return hrf.hackrf_device_list();
    }

    pub fn deinit() void {
        _ = hrf.hackrf_exit();
    }
};

test "hackrf library init" {
    try HackRF.init();
    HackRF.deinit();
}

test "hackrf version" {
    const version = HackRF.hackrf_library_version().?;
    std.debug.print("libhackrf version: {s}\n", .{@as([*:0]const u8, version)});
}

test "hackrf release" {
    const version = HackRF.hackrf_library_release().?;
    std.debug.print("libhackrf release: {s}\n", .{@as([*:0]const u8, version)});
}

test "hackrf device list" {
    try HackRF.init();

    const device_list = HackRF.hackrf_device_list();

    HackRF.deinit();
}
