const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const plot = @import("plot.zig");
const SimpleFFT = @import("simple_fft.zig").SimpleFFT;
const WindowType = @import("simple_fft.zig").WindowType;
const Waterfall = @import("waterfall.zig").Waterfall;
const bands = @import("bands.zig");
const util = @import("util.zig");
const zsdl = @import("zsdl3");
const zgui = @import("zgui");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

fn sdrRxCallback(trans: hackrf.Transfer, state: *SDR) hackrf.StreamAction {
    state.mutex.lock();
    defer state.mutex.unlock();

    const valid_length = trans.validLength();
    state.rx_bytes_received += valid_length;

    const raw_samples = trans.iqSamples();

    for (raw_samples) |sample| {
        state.rx_buffer.appendOne(sample.toFloat());
    }

    if (!state.rx_running) return .stop;
    return .@"continue";
}

const SDR = struct {
    const Self = @This();

    device: hackrf.Device = undefined,
    connected: bool = false,
    version_str: [256]u8 = std.mem.zeroes([256]u8),

    fs: f64 = util.mhz(20),
    cf: u64 = util.ghz(0.9),

    mutex: std.Thread.Mutex = .{},

    rx_running: bool = false,
    rx_bytes_received: u64 = 0,

    rx_buffer: FixedSizeRingBuffer([2]f32) = undefined,

    pub fn init(alloc: std.mem.Allocator, cf: u64, fs: f64) !Self {
        var self = Self{};
        self.cf = cf;
        self.fs = fs;
        try hackrf.init();

        var list = try hackrf.DeviceList.get();
        defer list.deinit();

        if (list.count() == 0) return self;

        self.device = try hackrf.Device.open();
        _ = try self.device.versionStringRead(&self.version_str);

        self.device.stopTx() catch {};
        try self.device.setSampleRate(self.fs);
        try self.device.setFreq(self.cf);
        try self.device.setAmpEnable(true);

        self.rx_buffer = try FixedSizeRingBuffer([2]f32).init(alloc, util.mb(64));

        return self;
    }

    pub fn startRx(self: *Self) !void {
        self.rx_running = true;
        try self.device.startRx(*Self, sdrRxCallback, self);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) !void {
        self.rx_buffer.deinit(alloc);
        self.device.close();

        try hackrf.deinit();
    }
};

fn createWaterfallTexture(
    device: *c.SDL_GPUDevice,
    width: u32,
    height: u32,
    out_tex: *?*c.SDL_GPUTexture,
    out_sampler: *?*c.SDL_GPUSampler,
    out_transfer: *?*c.SDL_GPUTransferBuffer,
    out_w: *u32,
    out_h: *u32,
    out_binding: *c.SDL_GPUTextureSamplerBinding,
) void {
    const tex_info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };
    out_tex.* = c.SDL_CreateGPUTexture(device, &tex_info);

    const sampler_info = c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0,
        .max_anisotropy = 1,
        .compare_op = 0,
        .min_lod = 0,
        .max_lod = 0,
        .enable_anisotropy = false,
        .enable_compare = false,
        .padding1 = 0,
        .padding2 = 0,
        .props = 0,
    };
    out_sampler.* = c.SDL_CreateGPUSampler(device, &sampler_info);

    const transfer_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = width * height * 4,
        .props = 0,
    };
    out_transfer.* = c.SDL_CreateGPUTransferBuffer(device, &transfer_info);

    out_w.* = width;
    out_h.* = height;
    out_binding.texture = out_tex.*;
    out_binding.sampler = out_sampler.*;
}

fn destroyWaterfallTexture(
    device: *c.SDL_GPUDevice,
    tex: *?*c.SDL_GPUTexture,
    sampler: *?*c.SDL_GPUSampler,
    transfer: *?*c.SDL_GPUTransferBuffer,
) void {
    if (tex.*) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (sampler.*) |s| c.SDL_ReleaseGPUSampler(device, s);
    if (transfer.*) |tb| c.SDL_ReleaseGPUTransferBuffer(device, tb);
    tex.* = null;
    sampler.* = null;
    transfer.* = null;
}

fn uploadWaterfallTexture(
    device: *c.SDL_GPUDevice,
    waterfall: *Waterfall,
    tex: ?*c.SDL_GPUTexture,
    transfer_buf: ?*c.SDL_GPUTransferBuffer,
    tex_w: u32,
    tex_h: u32,
) void {
    const tb = transfer_buf orelse return;
    const texture = tex orelse return;

    const mapped: ?[*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(device, tb, false));
    if (mapped) |ptr| {
        const byte_count = tex_w * tex_h * 4;
        @memcpy(ptr[0..byte_count], waterfall.pixels[0..byte_count]);
        c.SDL_UnmapGPUTransferBuffer(device, tb);
    }

    const cmd_buf = c.SDL_AcquireGPUCommandBuffer(device) orelse return;
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse return;

    const src = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = tb,
        .offset = 0,
        .pixels_per_row = tex_w,
        .rows_per_layer = tex_h,
    };

    const dst = c.SDL_GPUTextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = tex_w,
        .h = tex_h,
        .d = 1,
    };

    c.SDL_UploadToGPUTexture(copy_pass, &src, &dst, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);

    const alloc = allocator.allocator();

    var sdr: ?SDR = null;

    //
    // SDL3 + GPU init
    //

    try zsdl.init(.{ .video = true, .events = true });
    defer zsdl.quit();

    const window = try zsdl.createWindow("rf-fun", 1920, 1080, .{ .resizable = true, .high_pixel_density = true });
    defer zsdl.destroyWindow(window);

    const gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_METALLIB | c.SDL_GPU_SHADERFORMAT_SPIRV, true, null) orelse {
        std.log.err("Failed to create GPU device", .{});
        return;
    };
    defer c.SDL_DestroyGPUDevice(gpu_device);

    if (!c.SDL_ClaimWindowForGPUDevice(gpu_device, @ptrCast(window))) {
        std.log.err("Failed to claim window for GPU device", .{});
        return;
    }

    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(gpu_device, @ptrCast(window));

    //
    // zgui + ImPlot init
    //

    zgui.init(alloc);
    defer zgui.deinit();

    zgui.plot.init();
    defer zgui.plot.deinit();

    zgui.getStyle().setColorsDark();

    zgui.backend.init(@ptrCast(window), .{
        .device = @ptrCast(gpu_device),
        .color_target_format = swapchain_format,
        .msaa_samples = @intCast(c.SDL_GPU_SAMPLECOUNT_1),
    });
    defer zgui.backend.deinit();

    //
    // FFT setup
    //

    const default_cf = util.ghz(2.4);
    const default_fs = util.mhz(20);

    const sample_rate_values = [_]f64{ util.mhz(2), util.mhz(4), util.mhz(8), util.mhz(10), util.mhz(16), util.mhz(20) };
    const sample_rate_labels: [:0]const u8 = "2 MHz\x004 MHz\x008 MHz\x0010 MHz\x0016 MHz\x0020 MHz\x00";

    const fft_size_values = [_]u32{ 64, 128, 256, 512, 1024, 2048, 4096, 8192 };
    const fft_size_labels: [:0]const u8 = "64\x00128\x00256\x00512\x001024\x002048\x004096\x008192\x00";

    var cf_slider: f32 = @as(f32, @floatFromInt(@as(u32, @intCast(default_cf)))) / util.mhz(1);
    var fs_index: i32 = 5;
    var fft_size_index: i32 = 6;

    const default_fft_size = fft_size_values[@intCast(fft_size_index)];

    var refit_x = true;

    var fft = try SimpleFFT.init(alloc, default_fft_size, default_cf, default_fs, .NONE);
    defer fft.deinit(alloc);

    var fft_buf: [][2]f32 = try alloc.alloc([2]f32, default_fft_size);
    defer alloc.free(fft_buf);

    // Waterfall state
    var waterfall = try Waterfall.init(alloc, default_fft_size, 256);
    defer waterfall.deinit(alloc);

    // SDL3 GPU texture state for waterfall
    var wf_gpu_texture: ?*c.SDL_GPUTexture = null;
    var wf_sampler: ?*c.SDL_GPUSampler = null;
    var wf_transfer_buf: ?*c.SDL_GPUTransferBuffer = null;
    var wf_tex_w: u32 = 0;
    var wf_tex_h: u32 = 0;
    var wf_binding: c.SDL_GPUTextureSamplerBinding = .{ .texture = null, .sampler = null };

    // Create initial waterfall texture
    createWaterfallTexture(gpu_device, default_fft_size, 256, &wf_gpu_texture, &wf_sampler, &wf_transfer_buf, &wf_tex_w, &wf_tex_h, &wf_binding);
    defer destroyWaterfallTexture(gpu_device, &wf_gpu_texture, &wf_sampler, &wf_transfer_buf);

    var fft_target_fps: i32 = 60;
    var fft_frame_interval_us: u64 = 1_000_000 / 60;
    var last_fft_time_us: u64 = zsdl.getTicks() * 1000;

    //
    // RF Gain state
    //
    var lna_gain: i32 = 0; // 0-40, 8dB steps
    var vga_gain: i32 = 0; // 0-62, 2dB steps
    var amp_enable: bool = true;

    //
    // CF follow / rate-limit state
    //
    var last_retune_time_ms: u64 = 0;

    //
    // Peak hold state
    //
    var peak_hold_enabled: bool = false;
    var peak_hold_data: []f32 = try alloc.alloc(f32, default_fft_size);
    defer alloc.free(peak_hold_data);
    @memset(peak_hold_data, -200.0);
    var peak_decay_rate: f32 = 1.6; // dB/s, 0 = classic hold (no decay)
    var last_peak_time_ms: u64 = 0;

    //
    // EMA state
    //
    var avg_count: i32 = 2; // 1 = no averaging
    var ema_data: []f32 = try alloc.alloc(f32, default_fft_size);
    defer alloc.free(ema_data);
    @memset(ema_data, -200.0);
    var ema_initialized: bool = false;

    //
    // Window function state
    //
    var window_index: i32 = 3; // BLACKMAN_HARRIS

    //
    // Band overlay state
    //
    var show_bands: bool = true;
    var band_categories_enabled = [_]bool{true} ** bands.category_count;

    //
    // Main loop
    //

    var running = true;
    while (running) {
        {
            //
            // Handle OS events
            //

            var event: zsdl.Event = undefined;
            while (zsdl.pollEvent(&event)) {
                _ = zgui.backend.processEvent(@ptrCast(&event));
                if (event.type == .quit) {
                    running = false;
                }
            }
        }

        {
            //
            // SDR Update
            //

            if (sdr != null) {
                // FFT update
                const current_time_us = zsdl.getTicks() * 1000;
                if (current_time_us - last_fft_time_us >= fft_frame_interval_us) {
                    last_fft_time_us = current_time_us;
                    const fft_slice = fft_buf[0..fft.fft_size];

                    sdr.?.mutex.lock();
                    const copied = sdr.?.rx_buffer.copyNewest(fft_slice);
                    sdr.?.mutex.unlock();

                    if (copied == fft.fft_size) {
                        fft.calc(fft_slice);

                        // EMA processing
                        const alpha: f32 = 1.0 / @as(f32, @floatFromInt(avg_count));
                        if (alpha < 1.0) {
                            if (!ema_initialized) {
                                @memcpy(ema_data[0..fft.fft_size], fft.fft_mag[0..fft.fft_size]);
                                ema_initialized = true;
                            } else {
                                for (0..fft.fft_size) |i| {
                                    ema_data[i] = alpha * fft.fft_mag[i] + (1.0 - alpha) * ema_data[i];
                                }
                            }
                        }

                        // Peak hold
                        if (peak_hold_enabled) {
                            const src = if (alpha < 1.0) ema_data[0..fft.fft_size] else fft.fft_mag[0..fft.fft_size];
                            // Time-based decay
                            const now_ms = zsdl.getTicks();
                            if (last_peak_time_ms > 0 and peak_decay_rate > 0) {
                                const dt: f32 = @floatFromInt(now_ms - last_peak_time_ms);
                                const decay = peak_decay_rate * dt / 1000.0;
                                for (0..fft.fft_size) |i| {
                                    peak_hold_data[i] -= decay;
                                }
                            }
                            last_peak_time_ms = now_ms;
                            for (0..fft.fft_size) |i| {
                                peak_hold_data[i] = @max(peak_hold_data[i], src[i]);
                            }
                        }

                        // Waterfall push
                        const wf_src = if (alpha < 1.0) ema_data[0..fft.fft_size] else fft.fft_mag[0..fft.fft_size];
                        waterfall.pushRow(wf_src);
                    }

                }

            }
        }

        {
            //
            // Waterfall view update
            //

            // Upload waterfall pixels to GPU if dirty
            if (waterfall.dirty and wf_transfer_buf != null) {
                waterfall.renderPixels();
                uploadWaterfallTexture(gpu_device, &waterfall, wf_gpu_texture, wf_transfer_buf, wf_tex_w, wf_tex_h);
            }
        }

        {
            //
            // Render
            //

            const cmd_buf = c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse continue;

            var swapchain_texture: ?*c.SDL_GPUTexture = null;
            var sw_w: u32 = 0;
            var sw_h: u32 = 0;

            if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buf, @ptrCast(window), &swapchain_texture, &sw_w, &sw_h)) {
                _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
                continue;
            }

            if (swapchain_texture == null) {
                _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
                continue;
            }

            var win_w: c_int = 0;
            var win_h: c_int = 0;
            zsdl.getWindowSize(window, &win_w, &win_h) catch {};
            const fb_scale: f32 = if (win_w > 0) @as(f32, @floatFromInt(sw_w)) / @as(f32, @floatFromInt(win_w)) else 1.0;

            zgui.backend.newFrame(sw_w, sw_h, fb_scale);

            {
                zgui.setNextWindowPos(.{ .x = 174, .y = 109, .cond = .first_use_ever });
                zgui.setNextWindowSize(.{ .w = 509, .h = 500, .cond = .first_use_ever });

                if (zgui.begin(zgui.formatZ("Config ({d:.0} fps)###Config", .{zgui.io.getFramerate()}), .{
                    .flags = .{},
                })) {
                    if (sdr != null) {
                        if (zgui.button("Disconnect", .{})) {
                            sdr.?.rx_running = false;
                            try sdr.?.deinit(alloc);
                            sdr = null;

                            @memset(fft.fft_mag, 0);
                            waterfall.clear();
                        } else {
                            zgui.text("hackrf firmware verison {s}", .{sdr.?.version_str});

                            if (zgui.sliderFloat("Center Freq (MHz)", .{ .min = 0, .max = 6000, .v = &cf_slider })) {
                                const cf_hz: u64 = @intFromFloat(cf_slider * 1e6);
                                try sdr.?.device.setFreq(cf_hz);
                                fft.updateFreqs(cf_slider * 1e6, @floatCast(sample_rate_values[@intCast(fs_index)]));
                                refit_x = true;
                                ema_initialized = false;
                            }

                            if (zgui.combo("Sample Rate", .{
                                .current_item = &fs_index,
                                .items_separated_by_zeros = sample_rate_labels,
                            })) {
                                const new_fs = sample_rate_values[@intCast(fs_index)];
                                try sdr.?.device.setSampleRate(new_fs);
                                fft.updateFreqs(cf_slider * 1e6, @floatCast(new_fs));
                                refit_x = true;
                            }

                            if (zgui.combo("FFT Size", .{
                                .current_item = &fft_size_index,
                                .items_separated_by_zeros = fft_size_labels,
                            })) {
                                const new_size = fft_size_values[@intCast(fft_size_index)];
                                const fs_hz: f64 = sample_rate_values[@intCast(fs_index)];
                                fft.deinit(alloc);
                                fft = try SimpleFFT.init(alloc, new_size, cf_slider * 1e6, @floatCast(fs_hz), @enumFromInt(window_index));

                                fft_buf = try alloc.realloc(fft_buf, new_size);

                                // Recreate waterfall for new FFT size
                                waterfall.deinit(alloc);
                                waterfall = try Waterfall.init(alloc, new_size, 256);
                                destroyWaterfallTexture(gpu_device, &wf_gpu_texture, &wf_sampler, &wf_transfer_buf);
                                createWaterfallTexture(gpu_device, new_size, 256, &wf_gpu_texture, &wf_sampler, &wf_transfer_buf, &wf_tex_w, &wf_tex_h, &wf_binding);

                                // Realloc peak hold and EMA buffers
                                peak_hold_data = try alloc.realloc(peak_hold_data, new_size);
                                @memset(peak_hold_data, -200.0);

                                ema_data = try alloc.realloc(ema_data, new_size);
                                @memset(ema_data, -200.0);
                                ema_initialized = false;
                            }

                            if (zgui.sliderInt("FFT Rate (fps)", .{ .min = 1, .max = 120, .v = &fft_target_fps })) {
                                fft_frame_interval_us = 1_000_000 / @as(u64, @intCast(@max(fft_target_fps, 1)));
                            }

                            // --- RF Gain ---
                            zgui.separatorText("RF Gain");

                            if (zgui.sliderInt("LNA (dB)", .{ .min = 0, .max = 40, .v = &lna_gain })) {
                                // Snap to 8dB steps
                                lna_gain = @divTrunc(lna_gain + 4, 8) * 8;
                                lna_gain = std.math.clamp(lna_gain, 0, 40);
                                sdr.?.device.setLnaGain(@intCast(lna_gain)) catch {};
                            }

                            if (zgui.sliderInt("VGA (dB)", .{ .min = 0, .max = 62, .v = &vga_gain })) {
                                // Snap to 2dB steps
                                vga_gain = @divTrunc(vga_gain + 1, 2) * 2;
                                vga_gain = std.math.clamp(vga_gain, 0, 62);
                                sdr.?.device.setVgaGain(@intCast(vga_gain)) catch {};
                            }

                            if (zgui.checkbox("RF Amp (+14 dB)", .{ .v = &amp_enable })) {
                                sdr.?.device.setAmpEnable(amp_enable) catch {};
                            }

                            // --- DSP ---
                            zgui.separatorText("DSP");

                            if (zgui.combo("Window", .{
                                .current_item = &window_index,
                                .items_separated_by_zeros = @import("simple_fft.zig").window_labels,
                            })) {
                                fft.setWindow(@enumFromInt(window_index));
                            }

                            if (zgui.sliderInt("Averages", .{ .min = 1, .max = 100, .v = &avg_count })) {
                                if (avg_count <= 1) {
                                    ema_initialized = false;
                                }
                            }

                            _ = zgui.checkbox("Peak Hold", .{ .v = &peak_hold_enabled });
                            zgui.sameLine(.{});
                            if (zgui.button("Reset Peak", .{})) {
                                @memset(peak_hold_data, -200.0);
                                last_peak_time_ms = 0;
                            }
                            _ = zgui.sliderFloat("Peak Decay (dB/s)", .{ .min = 0, .max = 100, .v = &peak_decay_rate });

                            // --- Waterfall ---
                            zgui.separatorText("Waterfall");
                            if (zgui.sliderFloat("dB Min", .{ .min = -160, .max = 0, .v = &waterfall.db_min })) {
                                waterfall.rebuildLut();
                                waterfall.dirty = true;
                            }
                            if (zgui.sliderFloat("dB Max", .{ .min = -160, .max = 0, .v = &waterfall.db_max })) {
                                waterfall.rebuildLut();
                                waterfall.dirty = true;
                            }

                            // --- Band Overlay ---
                            zgui.separatorText("Band Overlay");
                            _ = zgui.checkbox("Show Bands", .{ .v = &show_bands });

                            if (show_bands) {
                                const fields = @typeInfo(bands.BandCategory).@"enum".fields;
                                inline for (fields, 0..) |field, i| {
                                    const cat: bands.BandCategory = @enumFromInt(field.value);
                                    const col = bands.categoryColor(cat);
                                    zgui.pushStyleColor4f(.{ .idx = .text, .c = col });
                                    _ = zgui.checkbox(bands.categoryName(cat), .{ .v = &band_categories_enabled[i] });
                                    zgui.popStyleColor(.{ .count = 1 });

                                    // 2-column layout
                                    if (i % 2 == 0 and i + 1 < fields.len) {
                                        zgui.sameLine(.{});
                                        zgui.setCursorPosX(zgui.getCursorPosX() + 20);
                                    }
                                }
                            }
                        }
                    } else {
                        if (zgui.button("Connect", .{})) {
                            const cf_hz: u64 = @intFromFloat(cf_slider * 1e6);
                            const fs_hz: f64 = sample_rate_values[@intCast(fs_index)];
                            sdr = try SDR.init(alloc, cf_hz, fs_hz);
                            try sdr.?.startRx();
                            fft.updateFreqs(cf_slider * 1e6, @floatCast(fs_hz));
                        }
                    }
                }
                zgui.end();

                zgui.setNextWindowPos(.{ .x = 683, .y = 109, .cond = .first_use_ever });
                zgui.setNextWindowSize(.{ .w = 1149, .h = 810, .cond = .first_use_ever });

                if (zgui.begin("Data View", .{
                    .flags = .{},
                })) {
                    const avail = zgui.getContentRegionAvail();
                    const line_h = avail[1] * 0.35;
                    const wf_h = avail[1] * 0.60;

                    // Build series for plot
                    const alpha: f32 = 1.0 / @as(f32, @floatFromInt(avg_count));
                    const display_data = if (alpha < 1.0 and ema_initialized) ema_data[0..fft.fft_size] else fft.fft_mag[0..fft.fft_size];

                    var series_buf: [2]plot.PlotSeries = undefined;
                    var series_count: usize = 0;

                    series_buf[series_count] = .{
                        .label = "Magnitude",
                        .x_data = fft.fft_freqs[0..fft.fft_size],
                        .y_data = display_data,
                    };
                    series_count += 1;

                    if (peak_hold_enabled) {
                        series_buf[series_count] = .{
                            .label = "Peak Hold",
                            .x_data = fft.fft_freqs[0..fft.fft_size],
                            .y_data = peak_hold_data[0..fft.fft_size],
                            .color = .{ 1.0, 0.2, 0.2, 0.8 },
                            .line_weight = 1.0,
                        };
                        series_count += 1;
                    }

                    // Compute x_range from frequency array
                    const x_range: ?[2]f64 = if (fft.fft_freqs.len > 0) .{
                        @floatCast(fft.fft_freqs[0]),
                        @floatCast(fft.fft_freqs[fft.fft_size - 1]),
                    } else null;

                    const overlay: ?[:0]const u8 = null;

                    // Build band render entries (pre-filtered by enabled category and view range)
                    var band_buf: [bands.all_bands.len]plot.BandRenderEntry = undefined;
                    var band_count: usize = 0;
                    if (show_bands) {
                        // Use x_range for initial filter; once the user has panned
                        // the plot limits will diverge, but x_range is our best pre-render guess
                        const view_min: f32 = if (x_range) |xr| @floatCast(xr[0]) else 0;
                        const view_max: f32 = if (x_range) |xr| @floatCast(xr[1]) else 6000;
                        for (bands.all_bands) |band| {
                            if (!band_categories_enabled[@intFromEnum(band.category)]) continue;
                            if (band.end_mhz < view_min or band.start_mhz > view_max) continue;
                            band_buf[band_count] = .{
                                .start_mhz = band.start_mhz,
                                .end_mhz = band.end_mhz,
                                .label = band.label,
                                .color = bands.categoryColor(band.category),
                            };
                            band_count += 1;
                        }
                    }

                    // FFT line plot (top portion)
                    const plot_result = plot.render(
                        "FFT",
                        "Freq (MHz)",
                        "dB",
                        series_buf[0..series_count],
                        .{ -120.0, 0.0 },
                        x_range,
                        refit_x,
                        line_h,
                        overlay,
                        band_buf[0..band_count],
                    );
                    refit_x = false;

                    // CF follow: rate-limited retune on horizontal pan (max 10 Hz)
                    if (sdr != null and plot_result.hovered) {
                        const plot_center = (plot_result.limits.x_min + plot_result.limits.x_max) / 2.0;
                        const cf_mhz: f64 = @floatCast(cf_slider);
                        const diff = @abs(plot_center - cf_mhz);

                        if (diff > 0.1) {
                            const now = zsdl.getTicks();
                            if (now >= last_retune_time_ms + 100) {
                                last_retune_time_ms = now;
                                const new_cf_hz: u64 = @intFromFloat(@max(0.0, plot_center * 1e6));
                                if (new_cf_hz > 0) {
                                    sdr.?.device.setFreq(new_cf_hz) catch {};
                                    cf_slider = @floatCast(plot_center);
                                    fft.updateFreqs(@floatCast(plot_center * 1e6), @floatCast(sample_rate_values[@intCast(fs_index)]));
                                    ema_initialized = false;
                                    refit_x = true;
                                }
                            }
                        }
                    }

                    // Waterfall image (bottom portion), aligned to FFT plot data area
                    if (wf_binding.texture != null) {
                        const tex_ref = zgui.TextureRef{
                            .tex_data = null,
                            .tex_id = @enumFromInt(@intFromPtr(&wf_binding)),
                        };
                        const window_pos = zgui.getWindowPos();
                        const plot_left_local = plot_result.plot_pos[0] - window_pos[0];
                        const waterfall_width = plot_result.plot_size[0];
                        zgui.setCursorPosX(plot_left_local);
                        zgui.image(tex_ref, .{ .w = waterfall_width, .h = wf_h });
                    }
                }
                zgui.end();
            }

            zgui.backend.render();
            zgui.backend.prepareDrawData(@ptrCast(cmd_buf));

            const color_target = c.SDL_GPUColorTargetInfo{
                .texture = swapchain_texture,
                .mip_level = 0,
                .layer_or_depth_plane = 0,
                .clear_color = .{ .r = 0.12, .g = 0.12, .b = 0.12, .a = 1.0 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .resolve_texture = null,
                .resolve_mip_level = 0,
                .resolve_layer = 0,
                .cycle = false,
                .cycle_resolve_texture = false,
                .padding1 = 0,
                .padding2 = 0,
            };

            const render_pass = c.SDL_BeginGPURenderPass(cmd_buf, &color_target, 1, null);
            if (render_pass != null) {
                zgui.backend.renderDrawData(@ptrCast(cmd_buf), @ptrCast(render_pass.?), null);
                c.SDL_EndGPURenderPass(render_pass);
            }

            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
        }
    }

    if (sdr != null) {
        sdr.?.rx_running = false;
        try sdr.?.deinit(alloc);
    }
}
