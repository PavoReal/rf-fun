const std = @import("std");
const hackrf = @import("rf_fun");
const FixedSizeRingBuffer = @import("ring_buffer.zig").FixedSizeRingBuffer;
const plot = @import("plot.zig");
const SimpleFFT = @import("simple_fft.zig").SimpleFFT;
const Waterfall = @import("waterfall.zig").Waterfall;
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

        self.rx_buffer = try FixedSizeRingBuffer([2]f32).init(alloc, util.mb(256));

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
    const sample_rate_labels: [:0]const u8 = "2 MHz\x004 MHz\x008 MHz\x0010 MHz\x0016 MHz\x0020 MHz";

    const fft_size_values = [_]u32{ 64, 128, 256, 512, 1024, 2048, 4096, 8192 };
    const fft_size_labels: [:0]const u8 = "64\x00128\x00256\x00512\x001024\x002048\x004096\x008192";

    var cf_slider: f32 = @as(f32, @floatFromInt(@as(u32, @intCast(default_cf)))) / util.mhz(1);
    var fs_index: i32 = 5;
    var fft_size_index: i32 = 7;

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

    const next_fft_update_delay = 100; // ms
    var next_fft_update_time = zsdl.getTicks() + next_fft_update_delay;

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
                const current_time = zsdl.getTicks();
                if (current_time >= next_fft_update_time) {
                    const fft_slice = fft_buf[0..fft.fft_size];

                    sdr.?.mutex.lock();
                    const copied = sdr.?.rx_buffer.copyNewest(fft_slice);
                    sdr.?.mutex.unlock();

                    if (copied == fft.fft_size) {
                        fft.calc(fft_slice);
                        waterfall.pushRow(fft.fft_mag);
                    }

                    next_fft_update_time = current_time + next_fft_update_delay;
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
                const viewport = zgui.getMainViewport();
                //const work_pos = viewport.getWorkPos();
                const work_size = viewport.getWorkSize();

                zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
                zgui.setNextWindowSize(.{ .h = work_size[1] * 0.25, .w = work_size[0] });

                if (zgui.begin("Config", .{
                    .flags = .{
                        .no_collapse = true,
                        .no_resize = true,
                        .no_move = true,
                        .no_title_bar = true
                    },
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
                                fft = try SimpleFFT.init(alloc, new_size, cf_slider * 1e6, @floatCast(fs_hz), .NONE);

                                fft_buf = try alloc.realloc(fft_buf, new_size);

                                // Recreate waterfall for new FFT size
                                waterfall.deinit(alloc);
                                waterfall = try Waterfall.init(alloc, new_size, 256);
                                destroyWaterfallTexture(gpu_device, &wf_gpu_texture, &wf_sampler, &wf_transfer_buf);
                                createWaterfallTexture(gpu_device, new_size, 256, &wf_gpu_texture, &wf_sampler, &wf_transfer_buf, &wf_tex_w, &wf_tex_h, &wf_binding);
                            }

                            // Waterfall dB range sliders
                            zgui.separatorText("Waterfall");
                            if (zgui.sliderFloat("dB Min", .{ .min = -160, .max = 0, .v = &waterfall.db_min })) {
                                waterfall.dirty = true;
                            }
                            if (zgui.sliderFloat("dB Max", .{ .min = -160, .max = 0, .v = &waterfall.db_max })) {
                                waterfall.dirty = true;
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

                zgui.setNextWindowPos(.{ .x = 0, .y = work_size[1] * 0.25 });
                zgui.setNextWindowSize(.{ .h = work_size[1] * 0.75, .w = work_size[0] });

                if (zgui.begin("Data", .{
                    .flags = .{
                        .no_move = true,
                        .no_resize = true,
                        .no_collapse = true,
                        .no_title_bar = true,
                    },
                })) {
                    const avail = zgui.getContentRegionAvail();
                    const line_h = avail[1] * 0.35;
                    const wf_h = avail[1] * 0.60;

                    // FFT line plot (top portion)
                    plot.render("FFT", "Freq (MHz)", "dB", fft.fft_freqs, fft.fft_mag, .{ -120.0, 0.0 }, refit_x, line_h);
                    refit_x = false;

                    // Waterfall image (bottom portion)
                    if (wf_binding.texture != null) {
                        const tex_ref = zgui.TextureRef{
                            .tex_data = null,
                            .tex_id = @enumFromInt(@intFromPtr(&wf_binding)),
                        };
                        zgui.image(tex_ref, .{ .w = avail[0], .h = wf_h });
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
