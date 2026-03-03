pub const Mode = enum(u4) {
    am,
    fm,
    nfm,
    usb,
    lsb,
    cw,
    digital,
    various,
    none,

    pub fn label(self: Mode) [:0]const u8 {
        return switch (self) {
            .am => "AM",
            .fm => "FM",
            .nfm => "NFM",
            .usb => "USB",
            .lsb => "LSB",
            .cw => "CW",
            .digital => "DIG",
            .various => "VAR",
            .none => "",
        };
    }

    pub fn color(self: Mode) [4]f32 {
        return switch (self) {
            .am => .{ 1.0, 0.84, 0.0, 1.0 },
            .fm => .{ 0.0, 1.0, 1.0, 1.0 },
            .nfm => .{ 0.0, 0.9, 0.4, 1.0 },
            .usb => .{ 1.0, 0.6, 0.2, 1.0 },
            .lsb => .{ 1.0, 0.4, 0.1, 1.0 },
            .cw => .{ 1.0, 0.4, 0.7, 1.0 },
            .digital => .{ 0.7, 0.4, 1.0, 1.0 },
            .various => .{ 0.7, 0.7, 0.7, 1.0 },
            .none => .{ 0.5, 0.5, 0.5, 1.0 },
        };
    }
};

pub const FreqEntry = struct {
    freq_start_mhz: f64,
    freq_end_mhz: f64,
    mode: Mode,
    name: [:0]const u8,
    description: [:0]const u8,
};

pub const SubCategory = struct {
    name: [:0]const u8,
    entries: []const FreqEntry,
};

pub const Category = struct {
    name: [:0]const u8,
    subcategories: []const SubCategory,
};

fn e(start: f64, end: f64, mode: Mode, name: [:0]const u8, desc: [:0]const u8) FreqEntry {
    return .{ .freq_start_mhz = start, .freq_end_mhz = end, .mode = mode, .name = name, .description = desc };
}

fn s(start: f64, mode: Mode, name: [:0]const u8, desc: [:0]const u8) FreqEntry {
    return .{ .freq_start_mhz = start, .freq_end_mhz = start, .mode = mode, .name = name, .description = desc };
}

// ── Amateur Radio ──

const ham_160m = [_]FreqEntry{
    e(1.800, 2.000, .various, "160m Band", "Top Band, night propagation"),
    e(1.800, 1.810, .cw, "160m CW DX Window", "CW DX calling"),
    s(1.838, .digital, "160m FT8", "FT8 digital mode"),
    s(1.840, .digital, "160m FT4", "FT4 digital mode"),
    e(1.843, 2.000, .usb, "160m SSB", "Phone segment"),
    s(1.900, .usb, "160m SSB Calling", "General phone calling"),
};

const ham_80m = [_]FreqEntry{
    e(3.500, 4.000, .various, "80m Band", "Night band, regional"),
    e(3.500, 3.600, .cw, "80m CW", "CW sub-band"),
    s(3.573, .digital, "80m FT8", "FT8 digital mode"),
    s(3.575, .digital, "80m FT4", "FT4 digital mode"),
    s(3.580, .digital, "80m PSK31", "PSK31 calling"),
    e(3.600, 4.000, .usb, "80m SSB", "Phone segment"),
    s(3.818, .usb, "80m Maritme Mobile", "Maritime mobile net"),
    s(3.860, .usb, "80m SSTV", "Slow-scan TV"),
    s(3.885, .am, "80m AM Window", "AM activity"),
    s(3.916, .usb, "80m Intercon Net", "West Coast net"),
};

const ham_60m = [_]FreqEntry{
    s(5.3305, .usb, "60m Ch 1", "USB only, 100W ERP"),
    s(5.3465, .usb, "60m Ch 2", "USB only, 100W ERP"),
    s(5.3570, .usb, "60m Ch 3", "Primary calling channel"),
    s(5.3715, .usb, "60m Ch 4", "USB only, 100W ERP"),
    s(5.4035, .usb, "60m Ch 5", "USB only, 100W ERP"),
};

const ham_40m = [_]FreqEntry{
    e(7.000, 7.300, .various, "40m Band", "Day/night workhorse band"),
    e(7.000, 7.125, .cw, "40m CW", "CW sub-band"),
    s(7.030, .cw, "40m QRP CW", "QRP calling freq"),
    s(7.074, .digital, "40m FT8", "FT8 digital mode"),
    s(7.047, .digital, "40m FT4", "FT4 digital mode"),
    s(7.070, .digital, "40m PSK31", "PSK31 calling"),
    e(7.125, 7.300, .usb, "40m SSB", "Phone segment"),
    s(7.185, .usb, "40m SSTV", "Slow-scan TV"),
    s(7.200, .usb, "40m SSB Lower", "Ragchew area"),
    s(7.290, .am, "40m AM", "AM activity"),
    s(7.295, .usb, "40m Traffic Net", "NTS traffic"),
};

const ham_30m = [_]FreqEntry{
    e(10.100, 10.150, .various, "30m Band", "CW/Digital only, 200W"),
    s(10.106, .cw, "30m QRP CW", "QRP calling freq"),
    s(10.116, .digital, "30m WSPR", "WSPR beacon"),
    s(10.136, .digital, "30m FT8", "FT8 digital mode"),
    s(10.140, .digital, "30m FT4", "FT4 digital mode"),
};

const ham_20m = [_]FreqEntry{
    e(14.000, 14.350, .various, "20m Band", "Primary DX band"),
    e(14.000, 14.150, .cw, "20m CW", "CW sub-band"),
    s(14.060, .cw, "20m QRP CW", "QRP calling freq"),
    s(14.070, .digital, "20m PSK31", "PSK31 calling"),
    s(14.074, .digital, "20m FT8", "FT8 digital mode"),
    s(14.080, .digital, "20m FT4", "FT4 digital mode"),
    s(14.100, .cw, "20m NCDXF Beacon", "IBP beacon network"),
    e(14.150, 14.350, .usb, "20m SSB", "Phone segment"),
    s(14.230, .usb, "20m SSTV", "Slow-scan TV"),
    s(14.236, .usb, "20m Digital Voice", "FreeDV"),
    s(14.286, .usb, "20m AM Window", "AM/SSB activity"),
    s(14.300, .usb, "20m Emergency", "Intercon/Emergency net"),
};

const ham_17m = [_]FreqEntry{
    e(18.068, 18.168, .various, "17m Band", "WARC band, no contests"),
    e(18.068, 18.110, .cw, "17m CW", "CW sub-band"),
    s(18.100, .digital, "17m FT8", "FT8 digital mode"),
    s(18.104, .digital, "17m FT4", "FT4 digital mode"),
    e(18.110, 18.168, .usb, "17m SSB", "Phone segment"),
    s(18.150, .usb, "17m SSB DX", "DX calling area"),
};

const ham_15m = [_]FreqEntry{
    e(21.000, 21.450, .various, "15m Band", "Daytime DX band"),
    e(21.000, 21.200, .cw, "15m CW", "CW sub-band"),
    s(21.060, .cw, "15m QRP CW", "QRP calling freq"),
    s(21.074, .digital, "15m FT8", "FT8 digital mode"),
    s(21.140, .digital, "15m FT4", "FT4 digital mode"),
    e(21.200, 21.450, .usb, "15m SSB", "Phone segment"),
    s(21.340, .usb, "15m SSTV", "Slow-scan TV"),
};

const ham_12m = [_]FreqEntry{
    e(24.890, 24.990, .various, "12m Band", "WARC band, no contests"),
    e(24.890, 24.930, .cw, "12m CW", "CW sub-band"),
    s(24.915, .digital, "12m FT8", "FT8 digital mode"),
    e(24.930, 24.990, .usb, "12m SSB", "Phone segment"),
};

const ham_10m = [_]FreqEntry{
    e(28.000, 29.700, .various, "10m Band", "Sporadic-E, F2 skip"),
    e(28.000, 28.300, .cw, "10m CW", "CW sub-band"),
    s(28.060, .cw, "10m QRP CW", "QRP calling freq"),
    s(28.074, .digital, "10m FT8", "FT8 digital mode"),
    s(28.180, .digital, "10m FT4", "FT4 digital mode"),
    s(28.200, .cw, "10m NCDXF Beacon", "IBP beacon network"),
    e(28.300, 29.300, .usb, "10m SSB", "Phone segment"),
    s(28.400, .usb, "10m SSB Calling", "SSB calling freq"),
    s(28.680, .am, "10m AM", "AM activity"),
    e(29.000, 29.200, .digital, "10m Digital", "Packet/digital"),
    e(29.300, 29.510, .various, "10m Satellite", "Satellite sub-band"),
    s(29.520, .nfm, "10m Repeater In", "Repeater input"),
    s(29.600, .nfm, "10m FM Calling", "FM simplex calling"),
    s(29.620, .nfm, "10m Repeater Out", "Repeater output"),
    e(29.620, 29.680, .nfm, "10m FM Repeaters", "FM repeater outputs"),
};

const ham_6m = [_]FreqEntry{
    e(50.000, 54.000, .various, "6m Band", "Magic Band, sporadic-E"),
    s(50.060, .cw, "6m CW Beacon", "Beacon sub-band"),
    s(50.090, .cw, "6m CW Calling", "CW calling freq"),
    s(50.110, .usb, "6m DX Calling", "SSB DX calling"),
    s(50.125, .usb, "6m SSB Calling", "SSB calling freq"),
    s(50.260, .digital, "6m SSTV", "Slow-scan TV"),
    s(50.313, .digital, "6m FT8", "FT8 digital mode"),
    s(50.318, .digital, "6m FT4", "FT4 digital mode"),
    e(50.600, 50.980, .digital, "6m Digital", "Digital sub-band"),
    e(51.000, 51.100, .nfm, "6m Pacific DX", "FM DX window"),
    s(51.500, .nfm, "6m Simplex 1", "FM simplex"),
    s(52.020, .nfm, "6m Repeater In", "Repeater inputs"),
    s(52.525, .nfm, "6m FM Calling", "National FM calling"),
    s(53.020, .nfm, "6m Repeater Out", "Repeater outputs"),
};

const ham_2m = [_]FreqEntry{
    e(144.000, 148.000, .various, "2m Band", "Primary VHF band"),
    s(144.050, .cw, "2m CW Calling", "CW calling freq"),
    s(144.174, .digital, "2m FT8", "FT8 digital mode"),
    s(144.200, .usb, "2m SSB Calling", "SSB calling freq"),
    s(144.390, .digital, "2m APRS", "APRS packet 1200 baud"),
    e(144.300, 144.500, .usb, "2m SSB/CW", "Weak signal"),
    e(145.200, 145.500, .nfm, "2m Repeater Out", "Repeater outputs"),
    e(145.800, 146.000, .various, "2m Satellite", "Satellite sub-band"),
    s(146.520, .nfm, "2m FM Calling", "National simplex calling"),
    s(146.550, .nfm, "2m Simplex", "Simplex channel"),
    s(146.580, .nfm, "2m Simplex", "Simplex channel"),
    e(146.610, 147.390, .nfm, "2m Repeaters", "Repeater pairs"),
    e(147.420, 147.570, .nfm, "2m Simplex", "Simplex channels"),
};

const ham_125m = [_]FreqEntry{
    e(222.000, 225.000, .various, "1.25m Band", "222 MHz band"),
    s(222.100, .cw, "1.25m CW/SSB", "Weak signal calling"),
    s(223.500, .nfm, "1.25m FM Calling", "FM simplex calling"),
    e(223.850, 224.980, .nfm, "1.25m Repeaters", "Repeater outputs"),
};

const ham_70cm = [_]FreqEntry{
    e(420.000, 450.000, .various, "70cm Band", "Primary UHF band"),
    s(432.100, .cw, "70cm CW/SSB", "Weak signal calling"),
    s(432.174, .digital, "70cm FT8", "FT8 digital mode"),
    e(433.000, 435.000, .various, "70cm Aux Links", "Auxiliary/repeater links"),
    e(435.000, 438.000, .various, "70cm Satellite", "Satellite sub-band"),
    s(446.000, .nfm, "70cm FM Calling", "National simplex calling"),
    s(446.500, .nfm, "70cm Simplex", "Simplex channel"),
    e(442.000, 445.000, .nfm, "70cm Repeater Out", "Repeater outputs"),
    e(447.000, 450.000, .nfm, "70cm Repeater In", "Repeater inputs"),
    e(440.000, 444.975, .digital, "70cm D-STAR", "D-STAR/DMR repeaters"),
    s(441.000, .nfm, "70cm ATV Input", "Fast-scan ATV"),
};

const ham_33cm = [_]FreqEntry{
    e(902.000, 928.000, .various, "33cm Band", "Shared with ISM"),
    s(902.100, .cw, "33cm CW/SSB", "Weak signal"),
    s(906.500, .nfm, "33cm FM Calling", "FM simplex calling"),
    e(927.000, 928.000, .nfm, "33cm Repeaters", "FM repeaters"),
};

const ham_23cm = [_]FreqEntry{
    e(1240.000, 1300.000, .various, "23cm Band", "Microwave entry band"),
    s(1294.500, .nfm, "23cm FM Calling", "FM simplex calling"),
    e(1290.000, 1294.000, .nfm, "23cm Repeaters", "FM repeaters"),
    e(1260.000, 1270.000, .various, "23cm Satellite", "Satellite sub-band"),
    e(1240.000, 1246.000, .various, "23cm ATV", "Fast-scan ATV"),
};

const amateur_subs = [_]SubCategory{
    .{ .name = "160m", .entries = &ham_160m },
    .{ .name = "80m", .entries = &ham_80m },
    .{ .name = "60m", .entries = &ham_60m },
    .{ .name = "40m", .entries = &ham_40m },
    .{ .name = "30m", .entries = &ham_30m },
    .{ .name = "20m", .entries = &ham_20m },
    .{ .name = "17m", .entries = &ham_17m },
    .{ .name = "15m", .entries = &ham_15m },
    .{ .name = "12m", .entries = &ham_12m },
    .{ .name = "10m", .entries = &ham_10m },
    .{ .name = "6m", .entries = &ham_6m },
    .{ .name = "2m", .entries = &ham_2m },
    .{ .name = "1.25m", .entries = &ham_125m },
    .{ .name = "70cm", .entries = &ham_70cm },
    .{ .name = "33cm", .entries = &ham_33cm },
    .{ .name = "23cm", .entries = &ham_23cm },
};

// ── Aviation ──

const aviation_vhf = [_]FreqEntry{
    e(118.000, 136.975, .am, "VHF Airband", "Civil aviation voice"),
    s(121.500, .am, "Guard / Emergency", "International distress"),
    s(121.600, .am, "Civil ELT", "Emergency locator transmitter"),
    s(121.700, .am, "FAA Flight Service", "Ground-based advisory"),
    s(121.900, .am, "Ground Control", "Typical ground frequency"),
    s(122.000, .am, "EFAS / Flight Watch", "En-route flight advisory"),
    s(122.200, .am, "FSS", "Flight service station"),
    s(122.750, .am, "Air-Air", "Air-to-air advisory"),
    s(122.800, .am, "UNICOM", "Uncontrolled field advisory"),
    s(122.900, .am, "Multicom", "Multi-use advisory"),
    s(122.950, .am, "UNICOM", "Controlled airports"),
    s(123.025, .am, "Heli Air-Air", "Helicopter common"),
    s(123.100, .am, "SAR", "Search and rescue"),
    s(123.450, .am, "Air-Air", "Airline unofficial common"),
    s(124.600, .am, "SoCal Approach", "Southern California TRACON"),
    s(125.800, .am, "NorCal Approach", "Northern California TRACON"),
    s(126.200, .am, "Oakland Center", "Oakland ARTCC"),
    s(127.950, .am, "LAX Tower", "Los Angeles Intl tower"),
    s(128.400, .am, "SFO ATIS", "San Francisco ATIS"),
    s(132.650, .am, "LAX ATIS", "Los Angeles ATIS"),
    s(135.950, .am, "Oakland Clearance", "Clearance delivery"),
};

const aviation_mil = [_]FreqEntry{
    e(225.000, 400.000, .am, "Military UHF Air", "Military aviation band"),
    s(243.000, .am, "UHF Guard", "Military distress"),
    s(255.400, .am, "Red Arrows", "USAF Thunderbirds/Demo"),
    s(282.800, .am, "Blue Angels", "USN demo team"),
    s(311.000, .am, "Air Refueling", "USAF tanker operations"),
    s(319.400, .am, "Edwards Tower", "Edwards AFB tower"),
    s(340.200, .am, "Pt Mugu Tower", "NAS Pt Mugu tower"),
    s(372.200, .am, "Mil Common", "Common military tactical"),
};

const aviation_nav = [_]FreqEntry{
    e(108.000, 117.950, .none, "VOR/ILS Band", "VHF omnidirectional range"),
    e(108.100, 111.950, .none, "ILS Localizer", "ILS localizer frequencies"),
    s(109.900, .none, "LAX ILS 25L", "LAX runway 25L localizer"),
    s(110.750, .none, "SFO ILS 28R", "SFO runway 28R localizer"),
    e(329.150, 335.000, .none, "ILS Glideslope", "ILS glideslope band"),
    e(0.190, 0.535, .am, "NDB", "Non-directional beacons"),
};

const aviation_acars = [_]FreqEntry{
    s(129.125, .am, "ACARS Primary", "Aircraft comm addressing"),
    s(130.025, .am, "ACARS Secondary", "Additional ACARS"),
    s(130.450, .am, "ACARS", "ACARS frequency"),
    s(131.125, .am, "ACARS", "ACARS frequency"),
    s(131.550, .am, "ACARS Primary USA", "Primary US ACARS"),
    s(136.900, .am, "ACARS VDL", "VHF data link"),
};

const aviation_adsb = [_]FreqEntry{
    s(1090.000, .digital, "ADS-B 1090ES", "Mode S extended squitter"),
    s(978.000, .digital, "ADS-B UAT", "Universal access transceiver"),
};

const aviation_subs = [_]SubCategory{
    .{ .name = "VHF Airband", .entries = &aviation_vhf },
    .{ .name = "Military UHF", .entries = &aviation_mil },
    .{ .name = "Nav Aids", .entries = &aviation_nav },
    .{ .name = "ACARS", .entries = &aviation_acars },
    .{ .name = "ADS-B", .entries = &aviation_adsb },
};

// ── Marine ──

const marine_vhf = [_]FreqEntry{
    s(156.800, .nfm, "Ch 16 Distress", "International distress/calling"),
    s(156.450, .nfm, "Ch 9 Calling", "Boater calling channel"),
    s(156.650, .nfm, "Ch 13 Bridge", "Intership navigation safety"),
    s(156.300, .nfm, "Ch 6 Intership", "Intership safety"),
    s(156.050, .nfm, "Ch 1 Pilot", "Pilot operations"),
    s(156.250, .nfm, "Ch 5 Port Ops", "Port operations"),
    s(156.500, .nfm, "Ch 10 Commercial", "Commercial working"),
    s(156.550, .nfm, "Ch 11 VTS", "Vessel traffic service"),
    s(156.600, .nfm, "Ch 12 VTS", "Vessel traffic service"),
    s(156.700, .nfm, "Ch 14 VTS", "Vessel traffic service"),
    s(157.000, .nfm, "Ch 20 Port Ops", "Port operations"),
    s(157.100, .nfm, "Ch 22A USCG", "Coast Guard liaison"),
    s(156.375, .nfm, "Ch 67 Bridge", "Bridge-to-bridge"),
    s(156.475, .nfm, "Ch 69 Recreational", "Recreational working"),
    s(156.575, .nfm, "Ch 71 Recreational", "Recreational working"),
    s(156.625, .nfm, "Ch 72 Non-Commercial", "Non-commercial working"),
    s(156.875, .nfm, "Ch 17 SAR", "State/local SAR"),
    s(161.975, .digital, "AIS 1", "Automatic identification"),
    s(162.025, .digital, "AIS 2", "Automatic identification"),
};

const marine_hf = [_]FreqEntry{
    s(2.182, .usb, "HF Distress", "International HF distress"),
    s(2.670, .usb, "USCG HF", "Coast Guard calling"),
    s(4.125, .usb, "HF Distress Alt", "HF distress/calling"),
    s(4.134, .digital, "HF DSC", "Digital selective calling"),
    s(6.215, .usb, "HF Ship-Shore", "Ship to shore calling"),
    s(8.291, .usb, "HF Ship-Shore", "Ship to shore calling"),
    s(12.290, .usb, "HF Ship-Shore", "Ship to shore calling"),
};

const marine_subs = [_]SubCategory{
    .{ .name = "VHF Channels", .entries = &marine_vhf },
    .{ .name = "HF Marine", .entries = &marine_hf },
};

// ── Public Safety ──

const ps_vhf = [_]FreqEntry{
    s(155.7525, .nfm, "VCALL10", "VHF calling interop"),
    s(151.1375, .nfm, "VTAC11", "VHF tactical interop"),
    s(154.4525, .nfm, "VTAC12", "VHF tactical interop"),
    s(158.7375, .nfm, "VTAC13", "VHF tactical interop"),
    s(159.4725, .nfm, "VTAC14", "VHF tactical interop"),
    s(155.4750, .nfm, "VLAW31", "VHF law enforcement"),
    s(155.7075, .nfm, "VLAW32", "VHF law enforcement"),
    s(154.2800, .nfm, "VFIRE21", "VHF fire tactical"),
    s(154.2950, .nfm, "VFIRE22", "VHF fire tactical"),
    s(155.3400, .nfm, "VMED28", "VHF EMS"),
    s(155.2200, .nfm, "VMED29", "VHF EMS"),
    s(155.1000, .nfm, "SAR", "Search and rescue"),
};

const ps_uhf = [_]FreqEntry{
    s(453.2125, .nfm, "UCALL40", "UHF calling interop"),
    s(453.4625, .nfm, "UTAC41", "UHF tactical interop"),
    s(453.7125, .nfm, "UTAC42", "UHF tactical interop"),
    s(453.8625, .nfm, "UTAC43", "UHF tactical interop"),
    s(454.0000, .nfm, "UTAC44", "UHF tactical interop"),
};

const ps_700 = [_]FreqEntry{
    e(764.000, 776.000, .digital, "700 MHz PS", "Public safety narrowband"),
    e(794.000, 806.000, .digital, "700 MHz PS", "Public safety narrowband"),
    s(769.244, .digital, "7CALL50", "700 MHz calling interop"),
    s(769.494, .digital, "7TAC51", "700 MHz tactical"),
    s(769.744, .digital, "7TAC52", "700 MHz tactical"),
    s(769.994, .digital, "7TAC53", "700 MHz tactical"),
    s(770.244, .digital, "7TAC54", "700 MHz tactical"),
    s(770.994, .digital, "7LAW61", "700 MHz law enforcement"),
    s(771.244, .digital, "7FIRE63", "700 MHz fire"),
    s(771.744, .digital, "7MED65", "700 MHz EMS"),
};

const ps_800 = [_]FreqEntry{
    e(806.000, 824.000, .digital, "800 MHz PS", "Trunked/conventional"),
    e(851.000, 869.000, .digital, "800 MHz PS", "Trunked/conventional"),
    s(851.0125, .digital, "8CALL90", "800 MHz calling interop"),
    s(851.5125, .digital, "8TAC91", "800 MHz tactical"),
    s(852.0125, .digital, "8TAC92", "800 MHz tactical"),
    s(852.5125, .digital, "8TAC93", "800 MHz tactical"),
    s(853.0125, .digital, "8TAC94", "800 MHz tactical"),
    s(866.0125, .digital, "8CALL100", "800 MHz calling"),
};

const ps_fed = [_]FreqEntry{
    s(162.6375, .nfm, "BLM Common", "Bureau of Land Management"),
    s(164.1125, .nfm, "USFS Common", "US Forest Service"),
    s(165.1625, .nfm, "NPS Common", "National Park Service"),
    s(166.4625, .nfm, "USFS Tactical", "Forest Service tactical"),
    s(168.3500, .nfm, "DOI Emergency", "Dept of Interior emergency"),
    s(170.0000, .nfm, "FBI Common", "Federal law enforcement"),
    s(170.9250, .nfm, "DHS Common", "Homeland Security"),
    s(173.7875, .nfm, "DEA Common", "Drug Enforcement Admin"),
    s(165.2375, .nfm, "CBP Common", "Customs & Border Protection"),
    s(163.1000, .nfm, "Secret Service", "USSS common"),
    s(164.8875, .nfm, "ATF Common", "Bureau of Alcohol/Firearms"),
};

const ps_subs = [_]SubCategory{
    .{ .name = "VHF Interop", .entries = &ps_vhf },
    .{ .name = "UHF Interop", .entries = &ps_uhf },
    .{ .name = "700 MHz", .entries = &ps_700 },
    .{ .name = "800 MHz", .entries = &ps_800 },
    .{ .name = "Federal", .entries = &ps_fed },
};

// ── Weather ──

const weather_noaa = [_]FreqEntry{
    s(162.400, .nfm, "WX1 (NWR)", "NOAA Weather Radio"),
    s(162.425, .nfm, "WX2 (NWR)", "NOAA Weather Radio"),
    s(162.450, .nfm, "WX3 (NWR)", "NOAA Weather Radio"),
    s(162.475, .nfm, "WX4 (NWR)", "NOAA Weather Radio"),
    s(162.500, .nfm, "WX5 (NWR)", "NOAA Weather Radio"),
    s(162.525, .nfm, "WX6 (NWR)", "NOAA Weather Radio"),
    s(162.550, .nfm, "WX7 (NWR)", "NOAA Weather Radio"),
};

const weather_sat = [_]FreqEntry{
    s(137.100, .nfm, "NOAA 19 APT", "APT weather imagery"),
    s(137.620, .nfm, "NOAA 15 APT", "APT weather imagery"),
    s(137.912, .nfm, "NOAA 18 APT", "APT weather imagery"),
    s(1694.100, .digital, "GOES LRIT", "GOES LRIT downlink"),
    s(1681.000, .digital, "GOES HRIT", "GOES HRIT downlink"),
    s(137.025, .digital, "Meteor M2 LRPT", "Russian weather sat"),
};

const weather_sonde = [_]FreqEntry{
    e(400.000, 406.000, .digital, "Radiosondes", "Weather balloon telemetry"),
    s(400.500, .digital, "Radiosonde Common", "Typical sonde frequency"),
    s(401.500, .digital, "Radiosonde Common", "Typical sonde frequency"),
    s(403.000, .digital, "Radiosonde Common", "Typical sonde frequency"),
    s(1680.000, .digital, "Radiosonde 1680", "L-band sonde telemetry"),
};

const weather_subs = [_]SubCategory{
    .{ .name = "NOAA Weather Radio", .entries = &weather_noaa },
    .{ .name = "Weather Satellites", .entries = &weather_sat },
    .{ .name = "Radiosondes", .entries = &weather_sonde },
};

// ── Broadcast ──

const broadcast_am = [_]FreqEntry{
    e(0.530, 1.700, .am, "AM Broadcast Band", "Medium wave broadcast"),
    s(0.640, .am, "KFI Los Angeles", "50kW clear channel"),
    s(0.680, .am, "KNBR San Francisco", "50kW sports radio"),
    s(0.740, .am, "KCBS San Francisco", "50kW news radio"),
    s(0.790, .am, "KABC Los Angeles", "50kW talk radio"),
    s(0.810, .am, "KGO San Francisco", "50kW news/talk"),
    s(0.980, .am, "KFWB Los Angeles", "News radio"),
    s(1.020, .am, "KDKA Pittsburgh", "50kW clear channel"),
    s(1.070, .am, "KNX Los Angeles", "50kW news radio"),
    s(1.160, .am, "KSL Salt Lake", "50kW clear channel"),
    s(1.500, .am, "KSTP Minneapolis", "50kW clear channel"),
    s(1.520, .am, "KFBK Sacramento", "50kW regional"),
};

const broadcast_fm = [_]FreqEntry{
    e(88.100, 107.900, .fm, "FM Broadcast Band", "VHF broadcast"),
    e(88.100, 91.900, .fm, "NCE Band", "Non-commercial educational"),
    e(92.100, 107.900, .fm, "Commercial FM", "Commercial broadcast"),
    s(89.300, .fm, "KPCC Pasadena", "NPR affiliate"),
    s(88.500, .fm, "KQED San Francisco", "NPR affiliate"),
    s(89.900, .fm, "KCRW Santa Monica", "Public radio"),
    s(93.100, .fm, "KFBK Sacramento", "FM translator"),
    s(94.700, .fm, "KSSJ Sacramento", "Spanish radio"),
    s(97.100, .fm, "KAMP Los Angeles", "Contemporary"),
    s(102.700, .fm, "KIIS Los Angeles", "Top 40"),
};

const broadcast_tv_vhf = [_]FreqEntry{
    e(54.000, 60.000, .various, "TV Ch 2", "VHF-Lo Channel 2"),
    e(60.000, 66.000, .various, "TV Ch 3", "VHF-Lo Channel 3"),
    e(66.000, 72.000, .various, "TV Ch 4", "VHF-Lo Channel 4"),
    e(76.000, 82.000, .various, "TV Ch 5", "VHF-Lo Channel 5"),
    e(82.000, 88.000, .various, "TV Ch 6", "VHF-Lo Channel 6"),
    e(174.000, 180.000, .various, "TV Ch 7", "VHF-Hi Channel 7"),
    e(180.000, 186.000, .various, "TV Ch 8", "VHF-Hi Channel 8"),
    e(186.000, 192.000, .various, "TV Ch 9", "VHF-Hi Channel 9"),
    e(192.000, 198.000, .various, "TV Ch 10", "VHF-Hi Channel 10"),
    e(198.000, 204.000, .various, "TV Ch 11", "VHF-Hi Channel 11"),
    e(204.000, 210.000, .various, "TV Ch 12", "VHF-Hi Channel 12"),
    e(210.000, 216.000, .various, "TV Ch 13", "VHF-Hi Channel 13"),
};

const broadcast_tv_uhf = [_]FreqEntry{
    e(470.000, 476.000, .various, "TV Ch 14", "UHF Channel 14"),
    e(476.000, 482.000, .various, "TV Ch 15", "UHF Channel 15"),
    e(482.000, 488.000, .various, "TV Ch 16", "UHF Channel 16"),
    e(488.000, 494.000, .various, "TV Ch 17", "UHF Channel 17"),
    e(494.000, 500.000, .various, "TV Ch 18", "UHF Channel 18"),
    e(500.000, 506.000, .various, "TV Ch 19", "UHF Channel 19"),
    e(506.000, 512.000, .various, "TV Ch 20", "UHF Channel 20"),
    e(512.000, 518.000, .various, "TV Ch 21", "UHF Channel 21"),
    e(518.000, 524.000, .various, "TV Ch 22", "UHF Channel 22"),
    e(524.000, 530.000, .various, "TV Ch 23", "UHF Channel 23"),
    e(530.000, 536.000, .various, "TV Ch 24", "UHF Channel 24"),
    e(536.000, 542.000, .various, "TV Ch 25", "UHF Channel 25"),
    e(542.000, 548.000, .various, "TV Ch 26", "UHF Channel 26"),
    e(548.000, 554.000, .various, "TV Ch 27", "UHF Channel 27"),
    e(554.000, 560.000, .various, "TV Ch 28", "UHF Channel 28"),
    e(560.000, 566.000, .various, "TV Ch 29", "UHF Channel 29"),
    e(566.000, 572.000, .various, "TV Ch 30", "UHF Channel 30"),
    e(572.000, 578.000, .various, "TV Ch 31", "UHF Channel 31"),
    e(578.000, 584.000, .various, "TV Ch 32", "UHF Channel 32"),
    e(584.000, 590.000, .various, "TV Ch 33", "UHF Channel 33"),
    e(590.000, 596.000, .various, "TV Ch 34", "UHF Channel 34"),
    e(596.000, 602.000, .various, "TV Ch 35", "UHF Channel 35"),
    e(602.000, 608.000, .various, "TV Ch 36", "UHF Channel 36"),
};

const broadcast_subs = [_]SubCategory{
    .{ .name = "AM Broadcast", .entries = &broadcast_am },
    .{ .name = "FM Broadcast", .entries = &broadcast_fm },
    .{ .name = "TV VHF", .entries = &broadcast_tv_vhf },
    .{ .name = "TV UHF", .entries = &broadcast_tv_uhf },
};

// ── Time Signals ──

const time_wwv = [_]FreqEntry{
    s(2.500, .am, "WWV 2.5 MHz", "NIST time signal, Ft Collins CO"),
    s(5.000, .am, "WWV 5 MHz", "NIST time signal, Ft Collins CO"),
    s(10.000, .am, "WWV 10 MHz", "NIST time signal, Ft Collins CO"),
    s(15.000, .am, "WWV 15 MHz", "NIST time signal, Ft Collins CO"),
    s(20.000, .am, "WWV 20 MHz", "NIST time signal, Ft Collins CO"),
    s(25.000, .am, "WWV 25 MHz", "NIST time signal, Ft Collins CO"),
    s(2.500, .am, "WWVH 2.5 MHz", "NIST time signal, Kauai HI"),
    s(5.000, .am, "WWVH 5 MHz", "NIST time signal, Kauai HI"),
    s(10.000, .am, "WWVH 10 MHz", "NIST time signal, Kauai HI"),
    s(15.000, .am, "WWVH 15 MHz", "NIST time signal, Kauai HI"),
};

const time_chu = [_]FreqEntry{
    s(3.330, .am, "CHU 3.33 MHz", "NRC time signal, Ottawa"),
    s(7.850, .am, "CHU 7.85 MHz", "NRC time signal, Ottawa"),
    s(14.670, .am, "CHU 14.67 MHz", "NRC time signal, Ottawa"),
};

const time_subs = [_]SubCategory{
    .{ .name = "WWV/WWVH", .entries = &time_wwv },
    .{ .name = "CHU", .entries = &time_chu },
};

// ── Military/Utility ──

const mil_hfgcs = [_]FreqEntry{
    s(4.724, .usb, "HFGCS", "HF Global Comm System"),
    s(6.739, .usb, "HFGCS", "HF Global Comm System"),
    s(8.992, .usb, "HFGCS", "HF Global Comm System"),
    s(11.175, .usb, "HFGCS Primary", "EAM broadcast, Skyking"),
    s(13.200, .usb, "HFGCS", "HF Global Comm System"),
    s(15.016, .usb, "HFGCS", "HF Global Comm System"),
};

const mil_ale = [_]FreqEntry{
    s(3.596, .digital, "ALE 80m", "Automatic link establishment"),
    s(5.357, .digital, "ALE 60m", "Automatic link establishment"),
    s(7.102, .digital, "ALE 40m", "Automatic link establishment"),
    s(10.145, .digital, "ALE 30m", "Automatic link establishment"),
    s(14.346, .digital, "ALE 20m", "Automatic link establishment"),
    s(18.106, .digital, "ALE 17m", "Automatic link establishment"),
    s(5.211, .digital, "SHARES ALE", "Fed emergency HF network"),
    s(10.493, .digital, "SHARES ALE", "Fed emergency HF network"),
};

const mil_mars = [_]FreqEntry{
    s(4.025, .usb, "MARS HF", "Military Auxiliary Radio"),
    s(6.893, .usb, "MARS HF", "Military Auxiliary Radio"),
    s(13.927, .usb, "MARS HF Primary", "Primary MARS traffic"),
    s(14.441, .usb, "MARS HF", "Military Auxiliary Radio"),
    s(148.375, .nfm, "MARS VHF", "VHF MARS operations"),
};

const mil_subs = [_]SubCategory{
    .{ .name = "HFGCS", .entries = &mil_hfgcs },
    .{ .name = "ALE", .entries = &mil_ale },
    .{ .name = "MARS", .entries = &mil_mars },
};

// ── ISM Bands ──

const ism_900 = [_]FreqEntry{
    e(902.000, 928.000, .various, "900 MHz ISM", "Industrial/scientific/medical"),
    s(906.000, .digital, "LoRa 915", "LoRa/LoRaWAN devices"),
    s(915.000, .digital, "ISM Center", "Smart meters, IoT"),
    s(920.000, .digital, "Z-Wave", "Home automation"),
};

const ism_2400 = [_]FreqEntry{
    e(2400.000, 2483.500, .various, "2.4 GHz ISM", "WiFi, Bluetooth, microwave"),
    s(2412.000, .digital, "WiFi Ch 1", "802.11 b/g/n channel 1"),
    s(2437.000, .digital, "WiFi Ch 6", "802.11 b/g/n channel 6"),
    s(2462.000, .digital, "WiFi Ch 11", "802.11 b/g/n channel 11"),
    s(2402.000, .digital, "Bluetooth Start", "BLE advertising ch 37"),
    s(2426.000, .digital, "Bluetooth Mid", "BLE advertising ch 38"),
    s(2480.000, .digital, "Bluetooth End", "BLE advertising ch 39"),
};

const ism_5800 = [_]FreqEntry{
    e(5725.000, 5875.000, .various, "5.8 GHz ISM", "WiFi 5GHz, radar"),
    s(5745.000, .digital, "WiFi Ch 149", "802.11a/n/ac channel 149"),
    s(5785.000, .digital, "WiFi Ch 157", "802.11a/n/ac channel 157"),
    s(5805.000, .digital, "WiFi Ch 161", "802.11a/n/ac channel 161"),
};

const ism_subs = [_]SubCategory{
    .{ .name = "900 MHz", .entries = &ism_900 },
    .{ .name = "2.4 GHz", .entries = &ism_2400 },
    .{ .name = "5.8 GHz", .entries = &ism_5800 },
};

// ── Cellular ──

const cell_lte = [_]FreqEntry{
    e(1930.000, 1990.000, .digital, "LTE Band 2 DL", "PCS 1900 downlink"),
    e(1850.000, 1910.000, .digital, "LTE Band 2 UL", "PCS 1900 uplink"),
    e(2110.000, 2155.000, .digital, "LTE Band 4 DL", "AWS-1 downlink"),
    e(1710.000, 1755.000, .digital, "LTE Band 4 UL", "AWS-1 uplink"),
    e(869.000, 894.000, .digital, "LTE Band 5 DL", "Cellular 850 downlink"),
    e(824.000, 849.000, .digital, "LTE Band 5 UL", "Cellular 850 uplink"),
    e(729.000, 746.000, .digital, "LTE Band 12 DL", "Lower 700 downlink"),
    e(699.000, 716.000, .digital, "LTE Band 12 UL", "Lower 700 uplink"),
    e(746.000, 756.000, .digital, "LTE Band 13 DL", "Upper 700 C downlink"),
    e(777.000, 787.000, .digital, "LTE Band 13 UL", "Upper 700 C uplink"),
    e(758.000, 768.000, .digital, "LTE Band 14 DL", "FirstNet downlink"),
    e(788.000, 798.000, .digital, "LTE Band 14 UL", "FirstNet uplink"),
    e(734.000, 746.000, .digital, "LTE Band 17 DL", "Lower 700 B/C downlink"),
    e(704.000, 716.000, .digital, "LTE Band 17 UL", "Lower 700 B/C uplink"),
    e(1930.000, 1995.000, .digital, "LTE Band 25 DL", "Extended PCS downlink"),
    e(859.000, 894.000, .digital, "LTE Band 26 DL", "Extended CLR downlink"),
    e(617.000, 652.000, .digital, "LTE Band 71 DL", "600 MHz downlink"),
    e(663.000, 698.000, .digital, "LTE Band 71 UL", "600 MHz uplink"),
};

const cell_5g = [_]FreqEntry{
    e(2496.000, 2690.000, .digital, "5G n41", "CBRS/mid-band 2.5 GHz"),
    e(617.000, 652.000, .digital, "5G n71 DL", "600 MHz downlink"),
    e(663.000, 698.000, .digital, "5G n71 UL", "600 MHz uplink"),
    e(3300.000, 4200.000, .digital, "5G n77", "C-band mid-band"),
    e(3300.000, 3800.000, .digital, "5G n78", "C-band sub-range"),
};

const cell_subs = [_]SubCategory{
    .{ .name = "LTE Bands", .entries = &cell_lte },
    .{ .name = "5G NR", .entries = &cell_5g },
};

// ── Satellites ──

const sat_gps = [_]FreqEntry{
    s(1575.420, .digital, "GPS L1 C/A", "Coarse acquisition signal"),
    s(1227.600, .digital, "GPS L2", "Military/civilian signal"),
    s(1176.450, .digital, "GPS L5", "Safety-of-life signal"),
    s(1602.000, .digital, "GLONASS L1", "Russian navigation"),
    s(1246.000, .digital, "GLONASS L2", "Russian navigation"),
    s(1575.420, .digital, "Galileo E1", "European navigation"),
    s(1176.450, .digital, "Galileo E5a", "European navigation"),
    s(1561.098, .digital, "BeiDou B1", "Chinese navigation"),
};

const sat_goes = [_]FreqEntry{
    s(1694.100, .digital, "GOES LRIT", "Low-rate info transmission"),
    s(1681.000, .digital, "GOES HRIT", "High-rate info transmission"),
    s(1691.000, .digital, "GOES DCS", "Data collection system"),
    s(468.825, .digital, "GOES DCP", "Data collection platform"),
};

const sat_iridium = [_]FreqEntry{
    e(1616.000, 1626.500, .digital, "Iridium", "Iridium constellation"),
    s(1616.000, .digital, "Iridium Ring Alert", "Paging channel"),
    s(1621.350, .digital, "Iridium Messaging", "Short burst data"),
    s(1626.000, .digital, "Iridium Duplex", "Full duplex voice/data"),
};

const sat_inmarsat = [_]FreqEntry{
    e(1525.000, 1559.000, .digital, "Inmarsat L-band DL", "Downlink band"),
    e(1626.500, 1660.500, .digital, "Inmarsat L-band UL", "Uplink band"),
    s(1541.450, .digital, "Inmarsat-C EGC", "Enhanced group call"),
    s(1545.000, .digital, "Inmarsat Aero", "Aeronautical comm"),
};

const sat_orbcomm = [_]FreqEntry{
    e(137.000, 138.000, .digital, "Orbcomm DL", "VHF downlink"),
    e(148.000, 150.050, .digital, "Orbcomm UL", "VHF uplink"),
    s(137.250, .digital, "Orbcomm Common", "Typical downlink freq"),
    s(137.560, .digital, "Orbcomm Common", "Typical downlink freq"),
    s(137.710, .digital, "Orbcomm Common", "Typical downlink freq"),
};

const sat_amateur = [_]FreqEntry{
    s(145.800, .nfm, "ISS Voice DL", "International Space Station"),
    s(145.825, .digital, "ISS APRS DL", "ISS digipeater/packet"),
    s(437.550, .nfm, "ISS UHF DL", "ISS UHF crossband"),
    s(145.900, .nfm, "SO-50 DL", "Saudi-OSCAR 50 FM sat"),
    s(436.795, .nfm, "AO-91 DL", "Fox-1B FM satellite"),
    s(435.340, .digital, "AO-92 DL", "Fox-1D L/V mode"),
    e(435.000, 438.000, .various, "70cm Sat Band", "Amateur satellite sub-band"),
    e(145.800, 146.000, .various, "2m Sat Band", "Amateur satellite sub-band"),
};

const sat_subs = [_]SubCategory{
    .{ .name = "GPS/GNSS", .entries = &sat_gps },
    .{ .name = "GOES", .entries = &sat_goes },
    .{ .name = "Iridium", .entries = &sat_iridium },
    .{ .name = "Inmarsat", .entries = &sat_inmarsat },
    .{ .name = "Orbcomm", .entries = &sat_orbcomm },
    .{ .name = "Amateur Sats", .entries = &sat_amateur },
};

// ── Personal Radio ──

const pr_frs = [_]FreqEntry{
    s(462.5625, .nfm, "FRS/GMRS Ch 1", "Shared simplex, 2W FRS"),
    s(462.5875, .nfm, "FRS/GMRS Ch 2", "Shared simplex, 2W FRS"),
    s(462.6125, .nfm, "FRS/GMRS Ch 3", "Shared simplex, 2W FRS"),
    s(462.6375, .nfm, "FRS/GMRS Ch 4", "Shared simplex, 2W FRS"),
    s(462.6625, .nfm, "FRS/GMRS Ch 5", "Shared simplex, 2W FRS"),
    s(462.6875, .nfm, "FRS/GMRS Ch 6", "Shared simplex, 2W FRS"),
    s(462.7125, .nfm, "FRS/GMRS Ch 7", "Shared simplex, 2W FRS"),
    s(467.5625, .nfm, "FRS Ch 8", "FRS only, 0.5W"),
    s(467.5875, .nfm, "FRS Ch 9", "FRS only, 0.5W"),
    s(467.6125, .nfm, "FRS Ch 10", "FRS only, 0.5W"),
    s(467.6375, .nfm, "FRS Ch 11", "FRS only, 0.5W"),
    s(467.6625, .nfm, "FRS Ch 12", "FRS only, 0.5W"),
    s(467.6875, .nfm, "FRS Ch 13", "FRS only, 0.5W"),
    s(467.7125, .nfm, "FRS Ch 14", "FRS only, 0.5W"),
    s(462.5500, .nfm, "GMRS Ch 15", "GMRS repeater/simplex 50W"),
    s(462.5750, .nfm, "GMRS Ch 16", "GMRS repeater/simplex 50W"),
    s(462.6000, .nfm, "GMRS Ch 17", "GMRS repeater/simplex 50W"),
    s(462.6250, .nfm, "GMRS Ch 18", "GMRS repeater/simplex 50W"),
    s(462.6500, .nfm, "GMRS Ch 19", "GMRS repeater/simplex 50W"),
    s(462.6750, .nfm, "GMRS Ch 20", "GMRS calling channel"),
    s(462.7000, .nfm, "GMRS Ch 21", "GMRS repeater/simplex 50W"),
    s(462.7250, .nfm, "GMRS Ch 22", "GMRS repeater/simplex 50W"),
};

const pr_murs = [_]FreqEntry{
    s(151.820, .nfm, "MURS Ch 1", "Multi-Use Radio, 2W, 11.25kHz"),
    s(151.880, .nfm, "MURS Ch 2", "Multi-Use Radio, 2W, 11.25kHz"),
    s(151.940, .nfm, "MURS Ch 3", "Multi-Use Radio, 2W, 11.25kHz"),
    s(154.570, .nfm, "MURS Ch 4", "Multi-Use Radio, 2W, 20kHz"),
    s(154.600, .nfm, "MURS Ch 5", "Multi-Use Radio, 2W, 20kHz"),
};

const pr_cb = [_]FreqEntry{
    s(26.965, .am, "CB Ch 1", "Citizens Band"),
    s(26.975, .am, "CB Ch 2", "Citizens Band"),
    s(26.985, .am, "CB Ch 3", "Citizens Band"),
    s(27.005, .am, "CB Ch 4", "Citizens Band"),
    s(27.015, .am, "CB Ch 5", "Citizens Band"),
    s(27.025, .am, "CB Ch 6", "SSB calling"),
    s(27.035, .am, "CB Ch 7", "Citizens Band"),
    s(27.055, .am, "CB Ch 8", "Citizens Band"),
    s(27.065, .am, "CB Ch 9", "Emergency/REACT"),
    s(27.075, .am, "CB Ch 10", "Citizens Band"),
    s(27.085, .am, "CB Ch 11", "Citizens Band"),
    s(27.105, .am, "CB Ch 12", "Citizens Band"),
    s(27.115, .am, "CB Ch 13", "Citizens Band"),
    s(27.125, .am, "CB Ch 14", "Walkie-talkie common"),
    s(27.135, .am, "CB Ch 15", "Citizens Band"),
    s(27.155, .am, "CB Ch 16", "Citizens Band"),
    s(27.165, .am, "CB Ch 17", "Citizens Band"),
    s(27.175, .am, "CB Ch 18", "Citizens Band"),
    s(27.185, .am, "CB Ch 19", "Truckers/highway"),
    s(27.205, .am, "CB Ch 20", "Citizens Band"),
    s(27.215, .am, "CB Ch 21", "Citizens Band"),
    s(27.225, .am, "CB Ch 22", "Citizens Band"),
    s(27.255, .am, "CB Ch 23", "Citizens Band"),
    s(27.235, .am, "CB Ch 24", "Citizens Band"),
    s(27.245, .am, "CB Ch 25", "Citizens Band"),
    s(27.265, .am, "CB Ch 26", "Citizens Band"),
    s(27.275, .am, "CB Ch 27", "Citizens Band"),
    s(27.285, .am, "CB Ch 28", "Citizens Band"),
    s(27.295, .am, "CB Ch 29", "Citizens Band"),
    s(27.305, .am, "CB Ch 30", "Citizens Band"),
    s(27.315, .am, "CB Ch 31", "Citizens Band"),
    s(27.325, .am, "CB Ch 32", "Citizens Band"),
    s(27.335, .am, "CB Ch 33", "Citizens Band"),
    s(27.345, .am, "CB Ch 34", "Citizens Band"),
    s(27.355, .am, "CB Ch 35", "Citizens Band"),
    s(27.365, .am, "CB Ch 36", "SSB lower sideband"),
    s(27.375, .am, "CB Ch 37", "Citizens Band"),
    s(27.385, .am, "CB Ch 38", "SSB common/LSB"),
    s(27.395, .am, "CB Ch 39", "Citizens Band"),
    s(27.405, .am, "CB Ch 40", "Citizens Band"),
};

const pr_subs = [_]SubCategory{
    .{ .name = "FRS/GMRS", .entries = &pr_frs },
    .{ .name = "MURS", .entries = &pr_murs },
    .{ .name = "CB", .entries = &pr_cb },
};

// ── Paging ──

const paging_entries = [_]FreqEntry{
    s(152.480, .digital, "Paging VHF", "FLEX/POCSAG paging"),
    s(157.740, .digital, "Paging VHF", "FLEX/POCSAG paging"),
    s(158.700, .digital, "Paging VHF", "FLEX/POCSAG paging"),
    s(462.750, .digital, "Paging UHF", "FLEX/POCSAG paging"),
    s(929.013, .digital, "Paging 929", "FLEX paging"),
    s(929.613, .digital, "Paging 929", "FLEX paging"),
    s(929.950, .digital, "Paging 929", "FLEX paging"),
    s(931.063, .digital, "Paging 931", "FLEX paging"),
    s(931.663, .digital, "Paging 931", "FLEX paging"),
    s(931.938, .digital, "Paging 931", "FLEX paging"),
    e(929.000, 932.000, .digital, "Paging Band", "929-932 MHz paging band"),
};

const paging_subs = [_]SubCategory{
    .{ .name = "FLEX/POCSAG", .entries = &paging_entries },
};

// ── Railroad ──

const railroad_entries = [_]FreqEntry{
    s(160.215, .nfm, "AAR Ch 1 Road", "End-of-train device"),
    s(160.245, .nfm, "AAR Ch 2 Road", "Railroad road channel"),
    s(160.290, .nfm, "AAR Ch 3 Road", "Railroad road channel"),
    s(160.320, .nfm, "AAR Ch 4 Road", "Railroad road channel"),
    s(160.365, .nfm, "AAR Ch 5 Yard", "Railroad yard channel"),
    s(160.410, .nfm, "AAR Ch 6 Yard", "Railroad yard channel"),
    s(160.440, .nfm, "AAR Ch 7 Yard", "Railroad yard channel"),
    s(160.470, .nfm, "AAR Ch 8 Yard", "Railroad yard channel"),
    s(160.500, .nfm, "AAR Ch 9 Yard", "Railroad yard channel"),
    s(160.530, .nfm, "AAR Ch 10 Yard", "Railroad yard channel"),
    s(160.560, .nfm, "AAR Ch 11 Yard", "Railroad yard channel"),
    s(160.590, .nfm, "AAR Ch 12 Yard", "Railroad yard channel"),
    s(160.800, .nfm, "AAR Ch 19 Road", "Common road channel"),
    s(160.980, .nfm, "AAR Ch 25 Road", "Common road channel"),
    s(161.100, .nfm, "AAR Ch 29 Road", "Common road channel"),
    s(161.160, .nfm, "AAR Ch 31 Road", "Common road channel"),
    s(161.220, .nfm, "AAR Ch 33 Police", "Railroad police"),
    s(161.370, .nfm, "AAR Ch 38 Road", "Common road channel"),
    s(161.520, .nfm, "AAR Ch 43 Road", "Common road channel"),
    s(161.550, .nfm, "AAR Ch 44 MoW", "Maintenance of way"),
    s(161.565, .nfm, "AAR Ch 97 EOT", "End-of-train telemetry"),
};

const railroad_subs = [_]SubCategory{
    .{ .name = "AAR Channels", .entries = &railroad_entries },
};

// ── Shortwave ──

const sw_entries = [_]FreqEntry{
    e(2.300, 2.495, .am, "120m Band", "Tropical broadcast band"),
    e(3.200, 3.400, .am, "90m Band", "Tropical broadcast band"),
    e(3.900, 4.000, .am, "75m Band", "Tropical broadcast band"),
    e(4.750, 5.060, .am, "60m Band", "Tropical broadcast band"),
    e(5.900, 6.200, .am, "49m Band", "International broadcast"),
    e(7.200, 7.450, .am, "41m Band", "International broadcast"),
    e(9.400, 9.900, .am, "31m Band", "International broadcast"),
    e(11.600, 12.100, .am, "25m Band", "International broadcast"),
    e(13.570, 13.870, .am, "22m Band", "International broadcast"),
    e(15.100, 15.800, .am, "19m Band", "International broadcast"),
    e(17.480, 17.900, .am, "16m Band", "International broadcast"),
    e(18.900, 19.020, .am, "15m Band", "International broadcast"),
    e(21.450, 21.850, .am, "13m Band", "International broadcast"),
    e(25.670, 26.100, .am, "11m Band", "International broadcast"),
};

const sw_subs = [_]SubCategory{
    .{ .name = "Broadcast Bands", .entries = &sw_entries },
};

// ── Digital Modes ──

const digital_p25 = [_]FreqEntry{
    e(764.000, 776.000, .digital, "P25 700 MHz", "Phase I/II trunked"),
    e(851.000, 869.000, .digital, "P25 800 MHz", "Phase I/II trunked"),
    s(866.000, .digital, "P25 Common", "Common trunked control"),
    e(406.000, 420.000, .digital, "P25 UHF Federal", "Federal P25 systems"),
    e(150.000, 174.000, .digital, "P25 VHF", "State/local P25 systems"),
};

const digital_dmr = [_]FreqEntry{
    s(441.000, .digital, "DMR UHF", "Common DMR repeater"),
    s(442.950, .digital, "DMR UHF", "Common DMR repeater"),
    s(443.400, .digital, "DMR UHF", "Common DMR repeater"),
    s(445.100, .digital, "DMR UHF", "Common DMR repeater"),
    s(146.820, .digital, "DMR VHF", "VHF DMR repeater"),
};

const digital_dstar = [_]FreqEntry{
    s(145.670, .digital, "D-STAR VHF", "VHF DV calling"),
    s(146.460, .digital, "D-STAR VHF", "VHF DV simplex"),
    s(441.200, .digital, "D-STAR UHF", "UHF DV calling"),
    s(442.300, .digital, "D-STAR UHF", "UHF DV repeater"),
    s(1272.400, .digital, "D-STAR 23cm", "23cm DV repeater"),
};

const digital_aprs = [_]FreqEntry{
    s(144.390, .digital, "APRS North America", "1200 baud APRS"),
    s(144.800, .digital, "APRS Europe", "1200 baud APRS"),
    s(145.175, .digital, "APRS Australia", "1200 baud APRS"),
    s(144.660, .digital, "APRS Japan", "1200 baud APRS"),
};

const digital_subs = [_]SubCategory{
    .{ .name = "P25", .entries = &digital_p25 },
    .{ .name = "DMR", .entries = &digital_dmr },
    .{ .name = "D-STAR", .entries = &digital_dstar },
    .{ .name = "APRS", .entries = &digital_aprs },
};

// ── Unlicensed ──

const unlic_part15 = [_]FreqEntry{
    e(26.957, 27.283, .various, "Part 15 CB", "Low-power 27 MHz"),
    e(49.820, 49.900, .various, "Part 15 49 MHz", "Baby monitors, cordless phones"),
    e(72.000, 76.000, .various, "Part 15 72 MHz", "RC models, garage openers"),
    s(315.000, .various, "Part 15 315 MHz", "Keyless entry, remotes"),
    s(390.000, .various, "Part 15 390 MHz", "Keyless entry, remotes"),
    s(433.920, .various, "Part 15 434 MHz", "ISM/Part 15 devices"),
    e(902.000, 928.000, .various, "Part 15 900 MHz", "Cordless phones, IoT"),
    e(2400.000, 2483.500, .various, "Part 15 2.4 GHz", "WiFi, Bluetooth, ZigBee"),
    e(5725.000, 5875.000, .various, "Part 15 5.8 GHz", "WiFi, cordless phones"),
};

const unlic_wireless_mic = [_]FreqEntry{
    e(470.000, 698.000, .nfm, "Wireless Mics UHF", "Licensed wireless mics"),
    e(902.000, 928.000, .nfm, "Wireless Mics 900", "Part 74 wireless mics"),
    e(174.000, 216.000, .nfm, "Wireless Mics VHF", "Part 74 VHF wireless mics"),
    s(169.445, .nfm, "Wireless Mic Ch", "Common wireless mic freq"),
    s(170.245, .nfm, "Wireless Mic Ch", "Common wireless mic freq"),
    s(171.045, .nfm, "Wireless Mic Ch", "Common wireless mic freq"),
};

const unlic_subs = [_]SubCategory{
    .{ .name = "Part 15", .entries = &unlic_part15 },
    .{ .name = "Wireless Mics", .entries = &unlic_wireless_mic },
};

// ── California ──

const ca_calfire = [_]FreqEntry{
    s(151.145, .nfm, "CAL FIRE Cmd 1", "Command channel"),
    s(151.190, .nfm, "CAL FIRE Cmd 2", "Command channel"),
    s(151.250, .nfm, "CAL FIRE Cmd 3", "Command channel"),
    s(151.280, .nfm, "CAL FIRE Cmd 4", "Command channel"),
    s(151.310, .nfm, "CAL FIRE Cmd 5", "Command channel"),
    s(151.355, .nfm, "CAL FIRE Cmd 6", "Command channel"),
    s(151.385, .nfm, "CAL FIRE Cmd 7", "Command channel"),
    s(154.280, .nfm, "CAL FIRE Tac 1", "Tactical fireground"),
    s(154.295, .nfm, "CAL FIRE Tac 2", "Tactical fireground"),
    s(154.310, .nfm, "CAL FIRE Tac 3", "Tactical fireground"),
    s(159.300, .nfm, "CAL FIRE Air-Gnd", "Air-to-ground"),
    s(166.675, .nfm, "CAL FIRE Tac 12", "Interagency tactical"),
    s(168.050, .nfm, "CAL FIRE Tac 14", "Interagency tactical"),
    s(169.125, .nfm, "CAL FIRE Admin", "Administrative"),
    s(170.000, .nfm, "CAL FIRE State", "State fire coordination"),
};

const ca_chp = [_]FreqEntry{
    s(42.320, .nfm, "CHP Channel 1", "Primary dispatch"),
    s(42.340, .nfm, "CHP Channel 2", "Secondary dispatch"),
    s(42.360, .nfm, "CHP Channel 3", "Tactical"),
    s(42.380, .nfm, "CHP Channel 4", "Car-to-car"),
    s(42.440, .nfm, "CHP Channel 5", "Statewide interop"),
    s(154.905, .nfm, "CHP VHF", "VHF dispatch"),
    s(154.920, .nfm, "CHP VHF", "VHF dispatch"),
    s(155.475, .nfm, "CHP VHF", "CHP operations"),
    s(460.025, .nfm, "CHP UHF", "UHF operations"),
    s(460.075, .nfm, "CHP UHF", "UHF operations"),
    s(460.125, .nfm, "CHP UHF", "UHF operations"),
    s(460.175, .nfm, "CHP UHF", "UHF operations"),
    s(460.225, .nfm, "CHP UHF", "UHF operations"),
    s(460.275, .nfm, "CHP UHF", "UHF operations"),
    s(460.325, .nfm, "CHP UHF", "UHF operations"),
    s(460.375, .nfm, "CHP UHF", "UHF operations"),
    s(460.425, .nfm, "CHP UHF", "UHF operations"),
    s(460.475, .nfm, "CHP UHF", "UHF operations"),
};

const ca_emergency = [_]FreqEntry{
    s(155.475, .nfm, "CA CLEMARS", "Law enforcement mutual aid"),
    s(154.920, .nfm, "CA CLERS", "Law enforcement radio"),
    s(155.745, .nfm, "CA CALCORD", "CA coordination channel"),
    s(156.075, .nfm, "CA SAR 1", "Search and rescue"),
    s(453.975, .nfm, "CA OES UHF", "Office of Emergency Svcs"),
    s(460.025, .nfm, "CA OES UHF", "Office of Emergency Svcs"),
    s(465.025, .nfm, "CA OES UHF", "Office of Emergency Svcs"),
    s(453.100, .nfm, "CA DOT", "Dept of Transportation"),
    s(156.150, .nfm, "CA EDACS", "Emergency dispatch"),
    s(460.525, .nfm, "CA Corrections", "CDC operations"),
    s(155.505, .nfm, "CA State Parks", "State parks operations"),
    s(151.415, .nfm, "CA Forestry", "Forestry operations"),
};

const ca_subs = [_]SubCategory{
    .{ .name = "CAL FIRE", .entries = &ca_calfire },
    .{ .name = "CHP", .entries = &ca_chp },
    .{ .name = "Emergency Services", .entries = &ca_emergency },
};

// ── Database ──

const amateur_radio = Category{ .name = "Amateur Radio", .subcategories = &amateur_subs };
const aviation = Category{ .name = "Aviation", .subcategories = &aviation_subs };
const marine = Category{ .name = "Marine", .subcategories = &marine_subs };
const public_safety = Category{ .name = "Public Safety", .subcategories = &ps_subs };
const weather = Category{ .name = "Weather", .subcategories = &weather_subs };
const broadcast = Category{ .name = "Broadcast", .subcategories = &broadcast_subs };
const time_signals = Category{ .name = "Time Signals", .subcategories = &time_subs };
const military = Category{ .name = "Military/Utility", .subcategories = &mil_subs };
const ism = Category{ .name = "ISM Bands", .subcategories = &ism_subs };
const cellular = Category{ .name = "Cellular", .subcategories = &cell_subs };
const satellites = Category{ .name = "Satellites", .subcategories = &sat_subs };
const personal_radio = Category{ .name = "Personal Radio", .subcategories = &pr_subs };
const paging = Category{ .name = "Paging", .subcategories = &paging_subs };
const railroad = Category{ .name = "Railroad", .subcategories = &railroad_subs };
const shortwave = Category{ .name = "Shortwave", .subcategories = &sw_subs };
const digital_modes = Category{ .name = "Digital Modes", .subcategories = &digital_subs };
const unlicensed = Category{ .name = "Unlicensed", .subcategories = &unlic_subs };
const california = Category{ .name = "California", .subcategories = &ca_subs };

pub const database = [_]Category{
    amateur_radio, aviation,   marine,     public_safety,
    weather,       broadcast,  time_signals, military,
    ism,           cellular,   satellites, personal_radio,
    paging,        railroad,   shortwave,  digital_modes,
    unlicensed,    california,
};

pub const FlatEntry = struct {
    cat_idx: u16,
    sub_idx: u16,
    entry_idx: u16,
    entry: *const FreqEntry,
};

const flat_count = blk: {
    var n: usize = 0;
    for (database) |cat| {
        for (cat.subcategories) |sub| {
            n += sub.entries.len;
        }
    }
    break :blk n;
};

pub const flat_entries: [flat_count]FlatEntry = blk: {
    var arr: [flat_count]FlatEntry = undefined;
    var idx: usize = 0;
    for (database, 0..) |cat, ci| {
        for (cat.subcategories, 0..) |sub, si| {
            for (sub.entries, 0..) |*entry, ei| {
                arr[idx] = .{
                    .cat_idx = @intCast(ci),
                    .sub_idx = @intCast(si),
                    .entry_idx = @intCast(ei),
                    .entry = entry,
                };
                idx += 1;
            }
        }
    }
    break :blk arr;
};
