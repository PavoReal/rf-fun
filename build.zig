const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const resolved_target = target.result;
    const os_tag = resolved_target.os.tag;
    const is_darwin = (os_tag == .macos) or (os_tag == .ios) or (os_tag == .tvos) or (os_tag == .watchos);
    const is_posix = is_darwin or (os_tag == .linux) or (os_tag == .openbsd);

    //
    // Build libusb from source
    //
    const libusb_dep = b.dependency("libusb", .{});

    const libusb_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Compiler flags for libusb
    const libusb_cflags: []const []const u8 = &.{
        "-DDEFAULT_VISIBILITY=",
        "-DPRINTF_FORMAT(a,b)=",
        "-DENABLE_LOGGING=1",
    };

    // Common libusb source files
    libusb_mod.addCSourceFiles(.{
        .root = libusb_dep.path(""),
        .files = &.{
            "libusb/core.c",
            "libusb/descriptor.c",
            "libusb/hotplug.c",
            "libusb/io.c",
            "libusb/strerror.c",
            "libusb/sync.c",
        },
        .flags = libusb_cflags,
    });

    // POSIX platform sources
    if (is_posix) {
        libusb_mod.addCSourceFiles(.{
            .root = libusb_dep.path(""),
            .files = &.{
                "libusb/os/events_posix.c",
                "libusb/os/threads_posix.c",
            },
            .flags = libusb_cflags,
        });
    }

    // Platform-specific sources
    if (os_tag == .windows) {
        libusb_mod.addCSourceFiles(.{
            .root = libusb_dep.path(""),
            .files = &.{
                "libusb/os/events_windows.c",
                "libusb/os/threads_windows.c",
                "libusb/os/windows_common.c",
                "libusb/os/windows_usbdk.c",
                "libusb/os/windows_winusb.c",
            },
            .flags = libusb_cflags,
        });
    } else if (os_tag == .linux) {
        libusb_mod.addCSourceFiles(.{
            .root = libusb_dep.path(""),
            .files = &.{
                "libusb/os/linux_usbfs.c",
                "libusb/os/linux_netlink.c",
            },
            .flags = libusb_cflags,
        });
    } else if (is_darwin) {
        libusb_mod.addCSourceFiles(.{
            .root = libusb_dep.path(""),
            .files = &.{
                "libusb/os/darwin_usb.c",
            },
            .flags = libusb_cflags,
        });
        libusb_mod.linkFramework("IOKit", .{});
        libusb_mod.linkFramework("Security", .{});
    } else if (os_tag == .netbsd) {
        libusb_mod.addCSourceFiles(.{
            .root = libusb_dep.path(""),
            .files = &.{"libusb/os/netbsd_usb.c"},
            .flags = libusb_cflags,
        });
    } else if (os_tag == .openbsd) {
        libusb_mod.addCSourceFiles(.{
            .root = libusb_dep.path(""),
            .files = &.{"libusb/os/openbsd_usb.c"},
            .flags = libusb_cflags,
        });
    } else if (os_tag == .haiku) {
        libusb_mod.addCSourceFiles(.{
            .root = libusb_dep.path(""),
            .files = &.{
                "libusb/os/haiku_pollfs.cpp",
                "libusb/os/haiku_usb_backend.cpp",
                "libusb/os/haiku_usb_raw.cpp",
            },
            .flags = libusb_cflags,
        });
    }

    libusb_mod.addIncludePath(libusb_dep.path("libusb"));

    // Generate config.h (simple defines only - function-like macros are in cflags)
    const config_h = b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        .HAVE_CLOCK_GETTIME = if (os_tag != .windows) @as(i64, 1) else null,
        .HAVE_STRUCT_TIMESPEC = 1,
        .HAVE_SYS_TIME_H = if (os_tag != .windows) @as(i64, 1) else null,
        .PLATFORM_POSIX = if (is_posix) @as(i64, 1) else null,
        .PLATFORM_WINDOWS = if (os_tag == .windows) @as(i64, 1) else null,
    });
    libusb_mod.addConfigHeader(config_h);

    const libusb = b.addLibrary(.{
        .name = "usb-1.0",
        .linkage = .static,
        .root_module = libusb_mod,
    });

    //
    // hackrf one dep
    //
    const hackrf_dep = b.dependency("libhackrf", .{
        .target = target,
        .optimize = optimize,
    });

    const libhackrf_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    libhackrf_mod.addCSourceFiles(.{
        .root = hackrf_dep.path("host/libhackrf/src"),
        .files = &.{"hackrf.c"},
        .flags = &.{
            "-DLIBRARY_VERSION=\"2026.01.2\"",
            "-DLIBRARY_RELEASE=\"release\"",
        },
    });

    libhackrf_mod.addIncludePath(hackrf_dep.path("host/libhackrf/src"));
    libhackrf_mod.addIncludePath(libusb_dep.path("libusb"));

    // Link our built libusb
    libhackrf_mod.linkLibrary(libusb);

    const libhackrf = b.addLibrary(.{
        .name = "hackrf",
        .linkage = .static,
        .root_module = libhackrf_mod,
    });

    //
    // root module
    //

    const mod = b.addModule("rf_fun", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.linkLibrary(libhackrf);
    mod.addIncludePath(hackrf_dep.path("host/libhackrf/src"));

    //
    // main exe
    //

    const exe = b.addExecutable(.{
        .name = "rf_fun",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rf_fun", .module = mod },
            },
        }),
    });

    exe.root_module.linkLibrary(libhackrf);
    exe.root_module.addIncludePath(hackrf_dep.path("host/libhackrf/src"));

    b.installArtifact(exe);

    //
    // run
    //

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    //
    // Tests
    //

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
