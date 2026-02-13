/// Frequency band allocations for the US (California focus).
/// Used to overlay labeled band regions on the FFT spectrum plot.

pub const BandCategory = enum(u8) {
    ham,
    aviation,
    marine,
    public_safety,
    frs_gmrs_murs,
    broadcast,
    ism,
    cellular,
    gps,
    weather,
    satellite,
    wifi_bt,
    misc,
    cb,
    railroad,
};

pub const category_count = @typeInfo(BandCategory).@"enum".fields.len;

pub const Band = struct {
    start_mhz: f32,
    end_mhz: f32,
    label: [:0]const u8,
    category: BandCategory,
};

pub fn categoryName(cat: BandCategory) [:0]const u8 {
    return switch (cat) {
        .ham => "Ham Radio",
        .aviation => "Aviation",
        .marine => "Marine",
        .public_safety => "Public Safety",
        .frs_gmrs_murs => "FRS/GMRS/MURS",
        .broadcast => "Broadcast",
        .ism => "ISM",
        .cellular => "Cellular",
        .gps => "GPS",
        .weather => "Weather",
        .satellite => "Satellite",
        .wifi_bt => "WiFi/BT",
        .misc => "Misc",
        .cb => "CB Radio",
        .railroad => "Railroad",
    };
}

/// Returns RGBA color (full alpha). Caller adjusts alpha for fill vs label.
pub fn categoryColor(cat: BandCategory) [4]f32 {
    return switch (cat) {
        .ham => .{ 1.0, 0.9, 0.0, 1.0 },
        .aviation => .{ 0.0, 0.8, 1.0, 1.0 },
        .marine => .{ 0.0, 0.4, 1.0, 1.0 },
        .public_safety => .{ 1.0, 0.2, 0.2, 1.0 },
        .frs_gmrs_murs => .{ 1.0, 0.6, 0.0, 1.0 },
        .broadcast => .{ 0.2, 0.8, 0.2, 1.0 },
        .ism => .{ 0.8, 0.2, 0.8, 1.0 },
        .cellular => .{ 1.0, 0.4, 0.6, 1.0 },
        .gps => .{ 1.0, 0.84, 0.0, 1.0 },
        .weather => .{ 0.0, 0.7, 0.5, 1.0 },
        .satellite => .{ 0.6, 0.3, 1.0, 1.0 },
        .wifi_bt => .{ 0.4, 1.0, 0.4, 1.0 },
        .misc => .{ 0.6, 0.6, 0.6, 1.0 },
        .cb => .{ 0.7, 0.5, 0.2, 1.0 },
        .railroad => .{ 0.8, 0.4, 0.0, 1.0 },
    };
}

pub const all_bands: []const Band = &.{
    // ── Ham Radio ──
    .{ .start_mhz = 1.8, .end_mhz = 2.0, .label = "160m", .category = .ham },
    .{ .start_mhz = 3.5, .end_mhz = 4.0, .label = "80m", .category = .ham },
    .{ .start_mhz = 7.0, .end_mhz = 7.3, .label = "40m", .category = .ham },
    .{ .start_mhz = 10.1, .end_mhz = 10.15, .label = "30m", .category = .ham },
    .{ .start_mhz = 14.0, .end_mhz = 14.35, .label = "20m", .category = .ham },
    .{ .start_mhz = 18.068, .end_mhz = 18.168, .label = "17m", .category = .ham },
    .{ .start_mhz = 21.0, .end_mhz = 21.45, .label = "15m", .category = .ham },
    .{ .start_mhz = 24.89, .end_mhz = 24.99, .label = "12m", .category = .ham },
    .{ .start_mhz = 28.0, .end_mhz = 29.7, .label = "10m", .category = .ham },
    .{ .start_mhz = 50.0, .end_mhz = 54.0, .label = "6m", .category = .ham },
    .{ .start_mhz = 144.0, .end_mhz = 148.0, .label = "2m", .category = .ham },
    .{ .start_mhz = 222.0, .end_mhz = 225.0, .label = "1.25m", .category = .ham },
    .{ .start_mhz = 420.0, .end_mhz = 450.0, .label = "70cm", .category = .ham },
    .{ .start_mhz = 902.0, .end_mhz = 928.0, .label = "33cm", .category = .ham },
    .{ .start_mhz = 1240.0, .end_mhz = 1300.0, .label = "23cm", .category = .ham },
    .{ .start_mhz = 2300.0, .end_mhz = 2450.0, .label = "13cm", .category = .ham },
    .{ .start_mhz = 3300.0, .end_mhz = 3450.0, .label = "9cm", .category = .ham },
    .{ .start_mhz = 5650.0, .end_mhz = 5925.0, .label = "5cm", .category = .ham },

    // ── Aviation ──
    .{ .start_mhz = 108.0, .end_mhz = 117.95, .label = "VOR/ILS", .category = .aviation },
    .{ .start_mhz = 118.0, .end_mhz = 137.0, .label = "Air Band", .category = .aviation },
    .{ .start_mhz = 225.0, .end_mhz = 400.0, .label = "Mil Air", .category = .aviation },
    .{ .start_mhz = 960.0, .end_mhz = 1215.0, .label = "DME/TACAN", .category = .aviation },
    .{ .start_mhz = 1089.5, .end_mhz = 1090.5, .label = "ADS-B", .category = .aviation },

    // ── Marine ──
    .{ .start_mhz = 156.0, .end_mhz = 162.025, .label = "Marine VHF", .category = .marine },

    // ── Public Safety ──
    .{ .start_mhz = 138.0, .end_mhz = 174.0, .label = "PS VHF", .category = .public_safety },
    .{ .start_mhz = 450.0, .end_mhz = 470.0, .label = "PS UHF", .category = .public_safety },
    .{ .start_mhz = 758.0, .end_mhz = 805.0, .label = "700 PS", .category = .public_safety },
    .{ .start_mhz = 806.0, .end_mhz = 869.0, .label = "800 PS", .category = .public_safety },

    // ── FRS/GMRS/MURS ──
    .{ .start_mhz = 151.82, .end_mhz = 154.6, .label = "MURS", .category = .frs_gmrs_murs },
    .{ .start_mhz = 462.5, .end_mhz = 467.75, .label = "FRS/GMRS", .category = .frs_gmrs_murs },

    // ── Broadcast ──
    .{ .start_mhz = 0.535, .end_mhz = 1.705, .label = "AM Radio", .category = .broadcast },
    .{ .start_mhz = 54.0, .end_mhz = 88.0, .label = "TV VHF-Lo", .category = .broadcast },
    .{ .start_mhz = 88.0, .end_mhz = 108.0, .label = "FM Radio", .category = .broadcast },
    .{ .start_mhz = 174.0, .end_mhz = 216.0, .label = "TV VHF-Hi", .category = .broadcast },
    .{ .start_mhz = 470.0, .end_mhz = 608.0, .label = "TV UHF", .category = .broadcast },

    // ── ISM ──
    .{ .start_mhz = 902.0, .end_mhz = 928.0, .label = "915 ISM", .category = .ism },
    .{ .start_mhz = 2400.0, .end_mhz = 2483.5, .label = "2.4G ISM", .category = .ism },
    .{ .start_mhz = 5725.0, .end_mhz = 5850.0, .label = "5.8G ISM", .category = .ism },

    // ── Cellular (US LTE) ──
    .{ .start_mhz = 617.0, .end_mhz = 698.0, .label = "LTE 600", .category = .cellular },
    .{ .start_mhz = 698.0, .end_mhz = 756.0, .label = "LTE 700", .category = .cellular },
    .{ .start_mhz = 824.0, .end_mhz = 894.0, .label = "LTE 850", .category = .cellular },
    .{ .start_mhz = 1710.0, .end_mhz = 1755.0, .label = "AWS UL", .category = .cellular },
    .{ .start_mhz = 1850.0, .end_mhz = 1990.0, .label = "PCS", .category = .cellular },
    .{ .start_mhz = 2110.0, .end_mhz = 2200.0, .label = "AWS DL", .category = .cellular },

    // ── GPS ──
    .{ .start_mhz = 1166.0, .end_mhz = 1186.0, .label = "GPS L5", .category = .gps },
    .{ .start_mhz = 1217.0, .end_mhz = 1237.0, .label = "GPS L2", .category = .gps },
    .{ .start_mhz = 1565.0, .end_mhz = 1585.0, .label = "GPS L1", .category = .gps },

    // ── Weather ──
    .{ .start_mhz = 162.4, .end_mhz = 162.55, .label = "NOAA WX", .category = .weather },

    // ── Satellite ──
    .{ .start_mhz = 137.0, .end_mhz = 138.0, .label = "WX Sat", .category = .satellite },
    .{ .start_mhz = 1616.0, .end_mhz = 1626.5, .label = "Iridium", .category = .satellite },
    .{ .start_mhz = 1694.0, .end_mhz = 1710.0, .label = "GOES/HRPT", .category = .satellite },

    // ── WiFi / Bluetooth ──
    .{ .start_mhz = 2400.0, .end_mhz = 2483.5, .label = "WiFi 2.4G", .category = .wifi_bt },
    .{ .start_mhz = 5150.0, .end_mhz = 5850.0, .label = "WiFi 5G", .category = .wifi_bt },

    // ── Misc ──
    .{ .start_mhz = 314.5, .end_mhz = 315.5, .label = "TPMS", .category = .misc },
    .{ .start_mhz = 433.42, .end_mhz = 434.42, .label = "433 Remotes", .category = .misc },

    // ── CB Radio ──
    .{ .start_mhz = 26.965, .end_mhz = 27.405, .label = "CB", .category = .cb },

    // ── Railroad ──
    .{ .start_mhz = 160.215, .end_mhz = 161.565, .label = "Railroad", .category = .railroad },
};
