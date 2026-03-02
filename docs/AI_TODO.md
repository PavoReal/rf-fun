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

### Multi-Channel Parallel Monitoring
Monitor multiple FRS channels simultaneously by running parallel channelizers on the wideband IQ capture. Would require FFT-based channelization or multiple NCO+FIR chains.

### DCS Detector Tuning
The DCS detector uses integrate-and-dump with early-late gate clock recovery. Real-world testing may reveal the need for:
- Adjustable confidence threshold (currently 3 consecutive matches)
- Better clock recovery loop bandwidth
- Signal strength thresholding to avoid false decodes on noise

### CTCSS Threshold Tuning
The CTCSS detection threshold (0.001 * avg_signal_power) may need adjustment based on real-world testing. Consider making it configurable or adaptive.

### Scan Activity Export
Allow exporting the activity log to a file for later analysis.
