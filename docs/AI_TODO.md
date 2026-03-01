# AI TODO

## FRS Decoder Improvements

### Squelch Hysteresis
The current squelch is a simple threshold comparison which can cause rapid open/close chatter on weak signals. Add hysteresis: open threshold slightly higher than close threshold, or add a hold timer that keeps squelch open for a minimum duration after it first opens.

### DCS (Digital Coded Squelch) Detection
FRS radios also support DCS codes (134.4 bps FSK bitstream using Golay(23,12) encoding). This would require:
- Low-pass filter to isolate sub-300 Hz DCS signal
- FSK demodulator at 134.4 bps
- Golay(23,12) decoder with error correction
- 83 standard code lookup table

### Multi-Channel FRS Scanner
Monitor multiple FRS channels simultaneously by running parallel channelizers on the wideband IQ capture. Would require FFT-based channelization or multiple NCO+FIR chains.

### CTCSS Threshold Tuning
The current CTCSS detection threshold (0.001 * avg_signal_power) may need adjustment based on real-world testing with actual FRS radios. Consider making it configurable or adaptive.

### Audio High-Pass Filter for CTCSS Removal
Add a high-pass filter (~300 Hz cutoff) after CTCSS detection to remove the subaudible tone from the speaker output. Currently the CTCSS tone is audible at low frequencies.
