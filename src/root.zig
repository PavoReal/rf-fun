const std = @import("std");
const Io = std.Io;

const hrf = @cImport({
    @cInclude("hackrf.h");
});

const HackRF = struct {
    device: *hrf.hackrf_device,

    pub fn init() c_int {
        return hrf.hackrf_init();
    }
    
    pub fn deinit() c_int {
        return hrf.hackrf_exit();
    }

    pub fn hackrf_library_version() ?[*:0]const u8 {
        return hrf.hackrf_library_version();
    }

    pub fn hackrf_library_release() ?[*:0]const u8 {
        return hrf.hackrf_library_release();
    }

    pub fn hackrf_device_list() ?*hrf.hackrf_device_list_t {
        return hrf.hackrf_device_list();
    }

    pub fn hackrf_device_list_free(list: *hrf.hackrf_device_list_t) void {
        hrf.hackrf_device_list_free(list);
    }
};

test "hackrf library init" {
    const init_status = HackRF.init();
    std.testing.expect(init_status == hrf.HACKRF_SUCCESS);

    const exit_status = HackRF.deinit();
    std.testing.expect(exit_status == hrf.HACKRF_SUCCESS);
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
    const init_status = HackRF.init();
    std.testing.expect(init_status == hrf.HACKRF_SUCCESS);

    const device_list = HackRF.hackrf_device_list().?;
    defer HackRF.hackrf_device_list_free(device_list.native);

    std.debug.print("libhackrf device list contains {d} entries\n", .{device_list.devicecount});

    for (0..device_list.devicecount) |i| {
        std.debug.print("{d}: ", .{i});
    }

    const exit_status = HackRF.deinit();
    std.testing.expect(exit_status == hrf.HACKRF_SUCCESS);
}
