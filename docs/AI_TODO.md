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

## SSB Demodulation — Future Improvements

### DONE: Basic USB/LSB ✓
NCO frequency shifting (±1500 Hz) for sideband selection, real-part extraction, DC blocking, AGC. 16kHz intermediate rate, 8kHz audio output.

### SSB Filter Bandwidth Control
Add adjustable passband width (currently hardcoded 3kHz). Allow narrowing to 2.4kHz or widening to 3.5kHz via UI slider.

### SSB BFO Fine-Tune
Add a Beat Frequency Oscillator fine-tune offset (±500 Hz) for manual sideband centering. Useful for off-frequency SSB signals.

### AGC Mode Selection
Expose AGC attack/decay parameters via UI (fast/medium/slow presets). Current defaults (2ms attack, 300ms decay) work for voice but may not suit CW or data modes.

## I/Q File Playback — Future Improvements

### DONE: Basic WAV Playback ✓
WAV reader (8-bit/16-bit PCM), FileSource rate-paced thread, SDL file dialog integration, full DSP pipeline reuse.

### Raw I/Q File Support
Support headerless raw I/Q formats (.raw, .iq, .cf32, .cs8) with user-specified sample rate and format dialogs.

### Playback Controls
Add pause/resume, seek bar, playback speed adjustment (0.5x-2x), and position indicator in the UI.

### Recording Center Frequency Metadata
Store center frequency in WAV metadata or sidecar file so playback can restore the correct frequency display.
