pub const DemodMethod = enum { discriminator, envelope };

pub const Stage1CutoffMode = enum { proportional, fixed, nfm_adaptive };

pub const DemodProfile = struct {
    name: [:0]const u8,
    short_name: [:0]const u8,
    intermediate_rate: f32,
    audio_rate: f32,
    stage2_decimation: usize,
    demod_method: DemodMethod,
    stage1_cutoff_mode: Stage1CutoffMode,
    stage1_cutoff_value: f32,
    max_deviation: f32,
    has_deemphasis: bool,
    default_tau: f32,
    has_agc: bool,
    has_pilot_notch: bool,
    pilot_notch_freq: f32,
    has_tone_detection: bool,
    uses_dc_block: bool,
};

pub const fm_profile = DemodProfile{
    .name = "FM Broadcast",
    .short_name = "FM",
    .intermediate_rate = 400_000.0,
    .audio_rate = 50_000.0,
    .stage2_decimation = 8,
    .demod_method = .discriminator,
    .stage1_cutoff_mode = .proportional,
    .stage1_cutoff_value = 0.45,
    .max_deviation = 75_000.0,
    .has_deemphasis = true,
    .default_tau = 75e-6,
    .has_agc = false,
    .has_pilot_notch = true,
    .pilot_notch_freq = 19000.0,
    .has_tone_detection = false,
    .uses_dc_block = false,
};

pub const am_profile = DemodProfile{
    .name = "AM Broadcast",
    .short_name = "AM",
    .intermediate_rate = 32_000.0,
    .audio_rate = 16_000.0,
    .stage2_decimation = 2,
    .demod_method = .envelope,
    .stage1_cutoff_mode = .fixed,
    .stage1_cutoff_value = 5000.0,
    .max_deviation = 1.0,
    .has_deemphasis = false,
    .default_tau = 0.0,
    .has_agc = true,
    .has_pilot_notch = false,
    .pilot_notch_freq = 0.0,
    .has_tone_detection = false,
    .uses_dc_block = true,
};

pub const nfm_profile = DemodProfile{
    .name = "Narrowband FM",
    .short_name = "NFM",
    .intermediate_rate = 50_000.0,
    .audio_rate = 25_000.0,
    .stage2_decimation = 2,
    .demod_method = .discriminator,
    .stage1_cutoff_mode = .nfm_adaptive,
    .stage1_cutoff_value = 0.0,
    .max_deviation = 5_000.0,
    .has_deemphasis = true,
    .default_tau = 75e-6,
    .has_agc = false,
    .has_pilot_notch = false,
    .pilot_notch_freq = 0.0,
    .has_tone_detection = true,
    .uses_dc_block = false,
};

pub const combo_labels: [:0]const u8 = "FM\x00AM\x00NFM\x00";
