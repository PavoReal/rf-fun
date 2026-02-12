pub fn ghz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e9);
}

pub fn mhz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e6);
}

pub fn khz(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

pub fn kb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e3);
}

pub fn mb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e6);
}

pub fn gb(val: comptime_float) comptime_int {
    return @intFromFloat(val * 1e9);
}
