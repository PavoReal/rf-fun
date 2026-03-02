# AI TODO

## FRS Decoder — Future Improvements

### DONE: DCS Detection ✓
Implemented Golay(23,12) codec, DCS detector (LPF + integrate-and-dump + clock recovery + Golay decode), 104 standard codes, normal+inverted polarity.

### DONE: CTCSS Hysteresis ✓
Expanded to 50 tones, added confirmed_tone_index with consecutive-block hysteresis.

### DONE: Tone Squelch ✓
Secondary audio gate with modes: carrier_only, ctcss_any/match, dcs_any/match, tone_any.

### DONE: Scanner ✓
Channel cycling state machine with dwell/hold timers, activity log, per-channel timestamps.

### DONE: Multi-Channel Parallel Monitoring ✓
ChannelManager runs multiple DecoderWorker instances from a single thread, reads IQ once, fans out to all channels, mixes resampled audio to one SDL output. Mixing-console-style UI with per-channel volume/mute/solo and signal meters. Up to 32 channels supported.

### Multi-Channel Improvements
- Profile CPU with 16+ channels active, consider multi-threading if needed
- Per-channel squelch threshold editing in the UI
- Add/remove individual channels dynamically (currently preset-based)
- Mixed modulation types per preset (FM + AM + NFM in one preset table)

### DCS Detector Tuning
The DCS detector uses integrate-and-dump with early-late gate clock recovery. Real-world testing may reveal the need for:
- Adjustable confidence threshold (currently 3 consecutive matches)
- Better clock recovery loop bandwidth
- Signal strength thresholding to avoid false decodes on noise

### CTCSS Threshold Tuning
The CTCSS detection threshold (0.001 * avg_signal_power) may need adjustment based on real-world testing. Consider making it configurable or adaptive.

### Scan Activity Export
Allow exporting the activity log to a file for later analysis.
