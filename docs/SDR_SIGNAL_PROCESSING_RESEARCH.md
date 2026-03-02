# SDR Signal Processing Research

Research into standard practices across GNU Radio, SDR++, SDR# (SDRSharp), CubicSDR,
csdr, gqrx, and liquid-dsp. Compiled March 2026.

---

## 1. FM Demodulation

### Discriminator Algorithm

All major SDR applications use the **polar discriminator** (also called quadrature
demodulator). The formula is:

```
y[n] = arg(x[n] * conj(x[n-1]))
```

This computes the phase difference between consecutive complex samples. The `arg()`
function extracts the angle of the resulting complex product. This is mathematically
equivalent to computing instantaneous frequency.

| Application | Algorithm | Notes |
|-------------|-----------|-------|
| GNU Radio | `quadrature_demod_cf` | `arg(x[n] * conj(x[n-1])) * gain` |
| SDR++ | `dsp::demod::Quadrature` | `(phase - prev_phase) * (1/deviation)`, normalized to [-pi, pi] |
| CubicSDR | liquid-dsp `freqdem` | `arg(conj(r[k-1]) * r[k]) / (2*pi*kf)` |
| csdr | `fmdemod_quadri_cf` | Quadrature discriminator (vectorized). Also has `fmdemod_atan_cf` variant |
| gqrx | GNU Radio `gr_quadrature_demod` | Same as GNU Radio |

Nobody uses PLL-based FM demod for the primary audio path. SDR++ has a `WBFM_Receive_PLL`
variant in GNU Radio but the standard path uses polar discriminator.

### Deviation Normalization (WFM vs NFM)

The discriminator gain controls deviation normalization. The formula across all
implementations:

```
gain = sample_rate / (2 * pi * max_deviation)
```

This normalizes output to [-1.0, +1.0] range.

| Mode | Max Deviation | Gain Formula |
|------|--------------|--------------|
| WFM (broadcast) | 75 kHz | `fs / (2*pi*75000)` |
| NFM (voice) | 5 kHz | `fs / (2*pi*5000)` |

SDR++ uses `deviation = bandwidth / 2.0` for its FM demod, then passes `1/deviation`
(in radians) as the scaling factor.

CubicSDR/liquid-dsp uses `kf = 0.5` as the modulation factor for both FM and NBFM,
which represents normalized deviation relative to sample rate.

### Intermediate Sample Rates

Typical sample rate chains:

**WFM (Broadcast FM):**
```
Hardware: 2.4 Msps
  -> Decimation by 10 -> 240 ksps (channel filter)
  -> FM demod at 240 ksps
  -> Decimation by 5 -> 48 ksps (audio output)
```

| Application | WFM IF Rate | WFM AF Rate |
|-------------|-------------|-------------|
| SDR++ | 250,000 Hz | 250,000 Hz (resampled to 48k at audio sink) |
| GNU Radio | User-set (typical 240k-480k) | 48,000 Hz |
| CubicSDR | 200,000 Hz | Resampled via msresamp |
| csdr | 240,000 Hz (after decimate) | 48,000 Hz |

**NFM (Narrowband FM):**

| Application | NFM IF Rate | NFM AF Rate |
|-------------|-------------|-------------|
| SDR++ | 50,000 Hz | 50,000 Hz (resampled to 48k at sink) |
| GNU Radio | User-set (typical 48k-96k) | 16,000-48,000 Hz |
| CubicSDR | 12,500 Hz | Resampled to audio rate |

### Decimation Approach

| Application | Method | Details |
|-------------|--------|---------|
| GNU Radio | FIR decimation + Polyphase filterbank | `optfir.low_pass` with 0.1 dB ripple, 60 dB stopband. Polyphase channelizer preferred over frequency-xlating FIR for multi-channel |
| SDR++ | Polyphase FIR resampler | Uses VOLK for dot product. Polyphase bank built from interpolation factor decomposition |
| CubicSDR | liquid-dsp PFB channelizer | Polyphase filterbank channelizer for initial channelization |
| csdr | FIR decimation | `fir_decimate_cc` with Hamming window, transition BW typically 0.05 (5% of Nyquist) |

No major SDR uses CIC filters in software. CIC is primarily used in FPGA/hardware
decimation stages.

---

## 2. De-emphasis

### Time Constants

| Region | Time Constant | Corner Frequency |
|--------|--------------|-----------------|
| North America | 75 us | 2,122 Hz |
| Europe/Australia | 50 us | 3,183 Hz |
| Japan (sometimes) | 50 us | 3,183 Hz |

SDR++ additionally supports a **22 us** option (sometimes used for satellite/aviation).

### Filter Implementation

All implementations use a **single-pole IIR filter** designed via the bilinear transform.

**GNU Radio implementation (canonical reference):**

```
Analog prototype: H(s) = w_ca / (s + w_ca)
where w_ca = 2*fs*tan((1/tau) / (2*fs))   # prewarped frequency

Bilinear transform yields:
  k = -w_ca / (2*fs)
  p1 = (1+k) / (1-k)
  b0 = -k / (1-k)

  b = [b0, b0]       # numerator (b0 + b0*z^-1)
  a = [1.0, -p1]     # denominator (1 - p1*z^-1)
```

This is a first-order IIR: `H(z) = b0*(1 + z^-1) / (1 - p1*z^-1)`

**CubicSDR FM stereo implementation:**
Uses a second-order IIR filter for de-emphasis with configurable time constants
(50 us or 75 us), selectable by the user.

### De-emphasis for NFM

This is inconsistent across applications:

| Application | NFM De-emphasis | Default |
|-------------|----------------|---------|
| SDR++ | Optional (user toggle) | OFF |
| GNU Radio NBFM | Applied by default | 75 us |
| CubicSDR | Available in modem settings | Varies |
| csdr | Separate `deemphasis_nfm_ff` | FIR filter, 400-4000 Hz passband with -20dB/decade rolloff |

The rationale: narrowband two-way radio uses 6 dB/octave pre-emphasis (originally
because early transmitters were PM, not FM, and PM naturally has 6 dB/octave). There
is no industry standard for NFM de-emphasis time constants like there is for broadcast
FM.

---

## 3. Squelch

### Common Approaches

**1. Power Squelch (most common in SDR):**

Measures signal power, compares to threshold. Used by:
- GNU Radio `pwr_squelch_cc`: squared magnitude through single-pole IIR (alpha=0.0001)
- SDR++: magnitude average over buffer, converted to dB via `10*log10(sum)`, compared
  to threshold (range: -100 to 0 dB)
- CubicSDR: dynamic floor/ceiling tracking with exponential smoothing

**2. Noise Squelch (FM-specific):**

Monitors high-frequency audio content above voice band. When an FM signal is present,
HF noise drops dramatically. When no signal, HF noise is strong.
- More reliable than power squelch for FM
- Bandwidth-independent

**3. Spectral Variance (WebSDR approach):**

Computes relative variance of FFT bins: `variance / mean^2`. Pure noise has relative
variance ~1. Signal presence increases it. Scaled by `sqrt(bandwidth)` for
bandwidth-independent thresholds.
- Opening threshold: 18 (false opens every ~3 hours)
- Confirmation threshold: 5 (requires 3 consecutive hits, false rate: 0.0001%)
- Tested ~10 times/second

**4. Dual-band comparison (DB1NV approach):**

Compares power in 200-600 Hz band vs 1000-1500 Hz band. Human speech has much more
power in the lower range; noise is equal in both.

**5. Predictive remainder (WebSDR newer approach):**

Compares predictable vs unpredictable audio components. Voice (especially vowels) is
highly predictable; noise is not.

### Noise Floor Tracking (Auto-Squelch)

| Application | Method |
|-------------|--------|
| RTLSDR-Airband | Continuously estimates noise floor per channel, opens when signal exceeds noise by ~10 dB |
| liquid-dsp AGC | Tracks noise floor with 4 dB headroom. If signal drops 4 dB below threshold, threshold decremented |
| CubicSDR | Dynamic floor/ceiling with exponential smoothing: `level += (current - level) * 0.05 * sampleTime * 30.0` |

### Attack/Release

| Application | Attack/Release | Notes |
|-------------|---------------|-------|
| GNU Radio `pwr_squelch` | Configurable in samples, sinusoidal ramp | Ramp=0 for instant switching |
| SDR++ | Instantaneous per-buffer | No smoothing, no hysteresis (marked with TODO for rewrite) |
| CubicSDR | Exponential smoothing | `0.05 * sampleTime * 30.0` coefficient |

### Hysteresis

Most SDR software implementations are surprisingly basic:
- SDR++: No hysteresis at all (single threshold, instant switching)
- GNU Radio: Single threshold with optional sinusoidal ramp but no separate
  open/close thresholds
- CubicSDR: Dynamic floor/ceiling provides implicit hysteresis through smoothing

---

## 4. AM Demodulation

### Envelope Detection vs Coherent

All major SDR applications use **envelope detection** (magnitude extraction) as the
primary AM demodulation method:

```
audio[n] = |x[n]| = sqrt(I^2 + Q^2)
```

| Application | Method | Details |
|-------------|--------|---------|
| SDR++ | VOLK `volk_32fc_magnitude_32f` | Vectorized magnitude extraction |
| CubicSDR | `sqrt(I*I + Q*Q)` | Manual computation per sample |
| GNU Radio | `complex_to_mag` block | Standard magnitude |

Coherent/synchronous detection is available in some applications (GNU Radio has it as
an option, SDR# has it) but envelope detection is the default because:
- Simpler (no carrier recovery needed)
- Works for all AM signals regardless of carrier presence
- Good enough for most applications

### AGC Implementation

**SDR++ AM AGC (two modes):**
- CARRIER mode: AGC before magnitude detection (normalizes RF envelope)
- AUDIO mode: AGC after envelope detection (normalizes audio levels)
- Parameters: initial gain=1.0, attack=50.0/sampleRate, decay=5.0/sampleRate,
  reference=10MHz, threshold=10.0 dB

**GNU Radio AGC2 (canonical reference):**
```
output = input * gain
error = |output| - reference
if |error| > gain:
    gain -= error * attack_rate    # fast attack (default 0.1)
else:
    gain -= error * decay_rate     # slow decay (default 0.01)

if gain < 0: gain = 10e-5         # prevent negative gain
if max_gain > 0 and gain > max_gain: gain = max_gain
```

**GNU Radio AGC3:**
Same as AGC2 but with initial linear calculation for fast acquisition, then switches
to IIR tracking.

**liquid-dsp AGC:**
- Open-loop gain control (not feedback)
- Energy estimated via L2 norm over internal buffer of M=16 samples
- First-order IIR smoothing: `g[k] = alpha*g_ideal[k] + (1-alpha)*g[k-1]`
- alpha = sqrt(bandwidth_parameter)
- Gain limits: 10^-6 to 10^6 (default)
- 6-state squelch FSM: enabled, rising edge, signal high, falling edge, signal low, timeout

**CubicSDR AM AGC:**
Simple three-stage smoothing:
- Track peak level (aOutputCeil)
- Primary moving average: coefficient 0.025
- Secondary smoothed average: coefficient 0.025
- Gain = 0.5 / smoothed_average

### DC Removal

| Application | Method | Details |
|-------------|--------|---------|
| SDR++ | DC blocking filter | Configurable cutoff rate |
| CubicSDR | FIR DC blocker | `firfilt_rrrf_create_dc_blocker(25, 30.0f)` - 25 sample window, 30 dB reduction |
| GNU Radio | DC blocker block | Standard IIR high-pass |
| csdr | `dcblock_ff` / `fastdcblock_ff` | Two variants, fast version optimized |

---

## 5. Audio Resampling

### Typical Rates

| Stage | Typical Rate | Purpose |
|-------|-------------|---------|
| Hardware input | 2.4-10 Msps | Raw IQ from SDR |
| Channel (IF) rate | 240-250 kHz (WFM), 12.5-50 kHz (NFM), 15 kHz (AM) | After channel filter/decimation |
| Audio output | 48,000 Hz | Standard audio rate |

### Resampling Method

| Application | Method | Details |
|-------------|--------|---------|
| SDR++ | Polyphase FIR resampler | Integer interpolation/decimation with VOLK dot products. 1M sample stream buffers |
| CubicSDR | liquid-dsp `msresamp_rrrf` | Multi-stage arbitrary rate resampler, 60 dB stopband attenuation |
| GNU Radio | Polyphase filterbank or rational resampler | PFB preferred; FIR taps decomposed into N phases |
| csdr | `fractional_decimator_ff` | Fractional decimation for arbitrary ratios |
| gqrx | Polyphase filterbank resampler | PFB with configurable taps |

### Filter Quality

- CubicSDR: 60 dB stopband attenuation for audio resampler
- GNU Radio optfir: 0.1 dB passband ripple, 60 dB stopband attenuation (Parks-McClellan)
- csdr FIR decimation: Hamming window, transition BW = 5-10% of bandwidth
- SDR++ audio filter: Hamming window FIR, cutoff = audio_rate/2 - transition_width

---

## 6. Volume/Gain Control

### Gain Staging (typical chain)

```
[Hardware RF Gain]
  -> [IF AGC / Digital Gain]
    -> [Channel Filter]
      -> [Demodulator (includes deviation normalization)]
        -> [Audio AGC (optional)]
          -> [De-emphasis]
            -> [Audio Filter]
              -> [Volume Control]
                -> [Audio Output]
```

### AGC Placement

| Application | AGC Location | Notes |
|-------------|-------------|-------|
| SDR++ AM | Before or after envelope detection (user choice) | CARRIER mode = pre-detection, AUDIO mode = post-detection |
| GNU Radio | Typically post-detection | AGC2/AGC3 blocks placed after demod |
| CubicSDR | Post-demodulation, pre-resampling | Simple peak-tracking with MA smoothing |
| SDR# | IF AGC and Audio AGC separately configurable | Hang, Threshold, Decay, Slope parameters |

### Typical Gain Values

- GNU Radio WBFM: volume gain = 20.0 (applied as multiplier after demod)
- SDR++ AM: AGC attack=50.0/fs, decay=5.0/fs (fast attack, slow release)
- GNU Radio AGC2: attack=0.1, decay=0.01, reference=1.0
- CubicSDR: MA coefficient 0.025, target level 0.5

---

## 7. General Architecture

### Threading Model

| Application | Model | Details |
|-------------|-------|---------|
| SDR++ | Producer-consumer with double-buffered streams | Each DSP block has input/output streams. Double-buffered (write to one, read from other). Mutex+condvar for swap/ready signaling. Stream buffer = 1,000,000 samples |
| GNU Radio | Scheduler-driven dataflow | Thread pool, scheduler manages buffer flow between blocks. Circular buffers between blocks |
| CubicSDR | Dedicated threads per stage | DemodulatorThread, AudioThread, etc. Each with own processing loop |
| gqrx | GNU Radio scheduler | Inherits GNU Radio threading model |

### Buffer Sizes

| Application | Buffer Size | Notes |
|-------------|-------------|-------|
| SDR++ | STREAM_BUFFER_SIZE = 1,000,000 samples | Per-stream double buffer |
| GNU Radio | Configurable, typically 4096-32768 | Per-block output buffer |
| CubicSDR | Variable per stage | FM stereo uses 4096-sample reshaper for RDS |

### Typical Filter Orders

| Filter | Type | Order/Taps | Application |
|--------|------|-----------|-------------|
| Channel filter (WFM) | FIR low-pass | 50-200 taps | Depends on transition BW and decimation |
| Channel filter (NFM) | FIR low-pass | 20-80 taps | Narrower, fewer taps needed |
| Audio low-pass (NBFM) | FIR Hamming | ~50 taps | Cutoff 2.7 kHz, transition 500 Hz |
| Audio low-pass (WFM) | FIR Hamming | ~30 taps | Cutoff ~14 kHz, transition ~1.5 kHz |
| De-emphasis | IIR single-pole | 2 taps (1st order) | b=[b0,b0], a=[1,-p1] |
| Pilot bandpass (stereo) | IIR Chebyshev-II | Order 5 | 18.75-19.25 kHz passband, 3 kHz transition |
| DC blocker | FIR or IIR | 25 samples (FIR) or 1st order IIR | CubicSDR: 30 dB DC reduction |
| SDR++ FM IF NR | FIR | 9-32 bins | NOAA:9, Voice:15, Narrowband:31, Broadcast:32 |
| SDR++ Noise blanker | Rate-based | rate=500/24000, threshold=10 dB | Level range: 1-10 dB |

---

## 8. SDR# (SDRSharp) Signal Chain

SDR# is closed-source C#, but the signal chain is documented as:

```
Source -> DDC -> Main Filter -> [Plugin Filter] -> Detector -> AGC -> DC Removal (IIR HPF) -> Audio BPF -> Soundcard
```

AGC parameters exposed: Hang, Threshold, Decay, Slope.

Two DNR (Digital Noise Reduction) options:
- IF DNR: applied at IF stage
- Audio DNR: applied at audio output stage
- IF DNR generally works better

---

## Sources

- GNU Radio Quadrature Demod: https://wiki.gnuradio.org/index.php/Quadrature_Demod
- GNU Radio FM Demod: https://wiki.gnuradio.org/index.php/FM_Demod
- GNU Radio WBFM Receive: https://wiki.gnuradio.org/index.php/WBFM_Receive
- GNU Radio NBFM Receive: https://wiki.gnuradio.org/index.php/NBFM_Receive
- GNU Radio FM Deemphasis: https://wiki.gnuradio.org/index.php/FM_Deemphasis
- GNU Radio Power Squelch: https://wiki.gnuradio.org/index.php/Power_Squelch
- GNU Radio Simple Squelch: https://wiki.gnuradio.org/index.php/Simple_Squelch
- GNU Radio AGC2: https://wiki.gnuradio.org/index.php/AGC2
- GNU Radio source (fm_demod.py): https://github.com/gnuradio/gnuradio/blob/master/gr-analog/python/analog/fm_demod.py
- GNU Radio source (nbfm_rx.py): https://github.com/gnuradio/gnuradio/blob/master/gr-analog/python/analog/nbfm_rx.py
- GNU Radio source (fm_emph.py): https://github.com/gnuradio/gnuradio/blob/master/gr-analog/python/analog/fm_emph.py
- GNU Radio source (agc2.h): https://github.com/gnuradio/gnuradio/blob/master/gr-analog/include/gnuradio/analog/agc2.h
- SDR++ GitHub: https://github.com/AlexandreRouma/SDRPlusPlus
- SDR++ demod source: core/src/dsp/demod/{fm.h, quadrature.h, broadcast_fm.h, am.h}
- SDR++ stream architecture: core/src/dsp/stream.h
- SDR++ squelch: core/src/dsp/noise_reduction/squelch.h
- SDR++ radio module: decoder_modules/radio/src/radio_module.h
- SDR++ NFM demod: decoder_modules/radio/src/demodulators/nfm.h
- SDR++ WFM demod: decoder_modules/radio/src/demodulators/wfm.h
- SDR++ AM demod: decoder_modules/radio/src/demodulators/am.h
- CubicSDR GitHub: https://github.com/cjcliffe/CubicSDR
- CubicSDR ModemFM: src/modules/modem/analog/ModemFM.cpp
- CubicSDR ModemAM: src/modules/modem/analog/ModemAM.cpp
- CubicSDR ModemNBFM: src/modules/modem/analog/ModemNBFM.cpp
- CubicSDR ModemFMStereo: src/modules/modem/analog/ModemFMStereo.cpp
- CubicSDR ModemAnalog: src/modules/modem/analog/ModemAnalog.cpp
- liquid-dsp AGC: https://www.liquidsdr.org/doc/agc/
- liquid-dsp freqdem: https://www.liquidsdr.org/doc/freqmodem/
- csdr: https://github.com/ha7ilm/csdr
- gqrx: https://github.com/gqrx-sdr/gqrx
- gqrx FM demod header: src/dsp/rx_demod_fm.h
- WebSDR squelch algorithms: https://pa3fwm.nl/technotes/tn16e.html
- WebSDR squelch FFT approach: https://pa3fwm.nl/technotes/tn16f.html
