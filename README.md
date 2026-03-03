# rf-fun

**Real-time SDR spectrum analysis and radio decoding for HackRF One, written in
Zig.**

![Zig 0.15.2](https://img.shields.io/badge/Zig-0.15.2-f7a41d?logo=zig&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<!-- Screenshots — replace these once you have actual captures -->
<!--
<p align="center">
  <img src="docs/screenshots/main-ui.png" alt="Main UI — spectrum plot, waterfall, and config panels" width="720" />
</p>
<p align="center">
  <img src="docs/screenshots/radio-decoder.png" alt="Radio decoder tuned to an FRS channel" width="720" />
</p>
-->

## Overview

rf-fun is a real-time spectrum analyzer and radio decoder built from scratch in
Zig. It reads raw I/Q samples from a HackRF One, processes them through a
custom DSP pipeline, and renders everything in an immediate-mode GUI powered by
zgui (Dear ImGui) and SDL3.

The project started as a learning exercise in RF signal processing and has
grown into a capable tool for exploring the radio spectrum, demodulating
FM/AM/NFM broadcasts, and monitoring FRS channels with CTCSS/DCS tone
detection.

## Features

### Spectrum Analyzer

- FFT sizes from 64 to 8192 bins
- 5 window functions: None, Hanning, Hamming, Blackman-Harris, Flat-Top
- DC spike filter (IIR high-pass on I/Q)
- Exponential moving average (EMA) smoothing with configurable depth
- Peak hold with adjustable decay rate
- Interactive zoom/pan on the frequency axis with click-to-retune

### Waterfall Display

- 256-row scrolling spectrogram
- GPU texture upload via SDL3 for efficient rendering
- Decode band overlay showing the active demodulation window

### Radio Demodulation

- **FM** (wideband, 400 kHz IF, 50 kHz audio)
- **AM** (32 kHz IF, 16 kHz audio)
- **NFM** (narrowband FM, 50 kHz IF, 25 kHz audio)
- De-emphasis filtering with per-mode time constants (75 us FM, 750 us NFM)
- CTCSS sub-audible tone detection (standard tone table)
- DCS digital coded squelch (Golay 23,12 decoder)
- Noise squelch with hysteresis and configurable threshold
- Tone squelch (CTCSS/DCS-gated audio)
- High-pass filter to remove CTCSS sub-tone from speaker output

### Channel Presets & Scanner

- 22 FRS Standard channels (462/467 MHz)
- 16 Retevis H777 presets with CTCSS/DCS codes
- One-click tune from channel table
- Multi-channel scanner with automatic squelch-based stop/hold

### HackRF Configuration

- Center frequency, sample rate, LNA/VGA/IF gains
- Antenna power, amplifier enable, baseband filter
- All settings adjustable at runtime while streaming
- Persistent configuration saved across sessions

### I/Q Recording

- WAV file export (8-bit or 16-bit PCM)
- Native OS file dialog for save location
- Records raw I/Q data from the ring buffer

### Performance Monitoring

- Real-time FPS counter
- RX buffer fill level and throughput
- Per-stage DSP pipeline latency (EMA-smoothed)
- Audio underrun tracking
- Separate stats for spectrum and radio pipelines

## Prerequisites

### All Platforms

- **[Zig 0.15.2](https://ziglang.org/download/)** (must be exactly 0.15.x)
- **HackRF One** with USB connection
- **FFTW3** library

### Windows

- FFTW DLLs are bundled in the repo (`lib/` directory) — no extra install
  needed
- **[Zadig](https://zadig.akeo.ie/)** to install the WinUSB driver for HackRF
  1. Plug in HackRF
  2. Run Zadig, select the HackRF device
  3. Install the **WinUSB** driver

### macOS

<!-- prettier-ignore -->
```sh
brew install fftw
```

### Linux

<!-- prettier-ignore -->
```sh
# Debian/Ubuntu
sudo apt install libfftw3-dev

# Fedora
sudo dnf install fftw-devel

# Arch
sudo pacman -S fftw
```

You may also need udev rules for HackRF — see the [HackRF
docs](https://hackrf.readthedocs.io/en/latest/installing_hackrf_software.html).

## Building and Running

<!-- prettier-ignore -->
```sh
git clone https://github.com/GarrisonPeacock/rf-fun.git
cd rf-fun
zig build run
```

All Zig dependencies (zgui, zsdl, SDL3, libhackrf, libusb) are fetched
automatically on the first build via `build.zig.zon`. The first build will take
a few minutes.

### Build Commands

<!-- prettier-ignore -->
| Command | Description |
|---------|-------------|
| `zig build run` | Build and launch the application |
| `zig build` | Build without running |
| `zig build -Doptimize=ReleaseFast` | Optimized release build |
| `zig build -Doptimize=Debug` | Debug build (default) |

### Troubleshooting

- **"No HackRF device detected"** — Check USB connection; on Windows, make sure
  Zadig installed the WinUSB driver
- **FFTW not found (Linux/macOS)** — Install `libfftw3-dev` or `fftw` via your
  package manager
- **Slow first build** — Expected; Zig compiles all C dependencies (SDL3,
  libusb, etc.) from source on the first run

## Usage

### Getting Started

1. Connect your HackRF One via USB
2. Run `zig build run`
3. The app auto-connects to the first HackRF it finds
4. If no device is detected, a popup offers to retry or exit

### UI Layout

The interface uses a dockable panel layout (drag panels to rearrange):

- **Left panel** — HackRF configuration, I/Q save controls, radio decoder
  settings
- **Center** — FFT spectrum plot (top) and waterfall spectrogram (bottom)
- **Right** — Stats overview dashboard

### Spectrum Analysis

- Use the FFT size dropdown to trade frequency resolution for update rate
- Select a window function to control spectral leakage
- Enable peak hold to track signal peaks over time
- Zoom/pan the frequency axis by scrolling and dragging on the plot
- The center frequency auto-retunes when you pan beyond the current capture
  window

### Radio Decoder

- Enable the radio decoder in the left panel
- Pick a modulation type (FM, AM, NFM)
- Drag the magenta frequency line on the FFT plot to tune, or select a preset
  channel
- CTCSS/DCS tones are detected automatically and displayed in the channel table
- Use the scanner to sweep through all preset channels, stopping on active
  transmissions

## Architecture

### Thread Model

rf-fun runs four threads:

<!-- prettier-ignore -->
| Thread | Role |
|--------|------|
| **Main** | GUI rendering, event handling, HackRF configuration |
| **RX** | HackRF USB callback — writes raw I/Q into a shared ring buffer |
| **Spectrum DSP** | Reads I/Q, applies DC filter, runs FFT, computes display data |
| **Radio DSP** | Reads I/Q, mixes/decimates, demodulates, detects tones, outputs audio |

### Data Flow

<!-- prettier-ignore -->
```
HackRF One
    |
    v
+---------------------+
|  RX Callback        |--->  FixedSizeRingBuffer (shared, mutex-protected)
+---------------------+             |
                           +---------+---------+
                           v                   v
                  +-----------------+  +------------------+
                  | Spectrum Worker |  |   Radio Worker   |
                  |  DC Filter      |  |  NCO Mix         |
                  |  FFT            |  |  Decimate (2x)   |
                  |  EMA Average    |  |  FM/AM Demod     |
                  |  Peak Hold      |  |  Decimate (2x)   |
                  +--------+--------+  |  De-emphasis     |
                           |           |  CTCSS/DCS       |
                           v           |  Squelch         |
                  +-----------------+  |  Audio Output    |
                  | DoubleBuffer    |  +--------+---------+
                  | (lock-free)     |           |
                  +--------+--------+           v
                           |           +------------------+
                           v           | SDL Audio Queue  |
                  +-----------------+  +------------------+
                  |  Main Thread    |
                  |  Plot+Waterfall |
                  +-----------------+
```

### DSP Framework

The DSP layer uses a comptime-composable processor convention:

- **Processor**: any type with `Input`/`Output` types, a `process(self, input,
  output) usize` method, and `reset(self)`
- **Chain(A, B)**: comptime-composes two processors where `A.Output == B.Input`
- **ProcessorWorker(P)**: adapts a Processor into a Worker with DoubleBuffer
  output
- **DspThread(Worker)**: generic thread runner that reads from a shared ring
  buffer
- **DoubleBuffer(T)**: lock-free double-buffered output for passing frames
  between threads

No dynamic allocations occur in the data path. All buffers are allocated at
init/compile time and freed at shutdown.

## Project Structure

<!-- prettier-ignore -->
```
rf-fun/
├── build.zig              # Build configuration (links all C deps from source)
├── build.zig.zon          # Package manifest and dependency URLs
├── CLAUDE.md              # AI assistant instructions
├── code_rules.md          # Coding philosophy (Casey Muratori)
├── LICENSE                # MIT license
├── TODO.md                # Human task tracking
│
├── docs/
│   ├── AI_TODO.md         # AI-maintained improvement backlog
│   ├── AI_LESSONS.md      # Lessons learned log
│   └── screenshots/       # UI screenshots (placeholder)
│
├── lib/                   # Bundled FFTW DLLs (Windows)
│
└── src/
    ├── main.zig           # Entry point — HackRF init, render loop, UI layout
    ├── root.zig           # HackRF Zig bindings (libhackrf + libusb)
    ├── ring_buffer.zig    # Generic fixed-size ring buffer
    ├── plot.zig           # Reusable plot API (grid, axes, zoom/pan, cursors)
    ├── waterfall.zig      # Waterfall spectrogram renderer
    ├── simple_fft.zig     # FFT wrapper with windowing
    ├── signal_stats.zig   # Peak detection and signal statistics
    ├── spectrum_analyzer.zig  # Spectrum DSP worker + UI facade
    ├── radio_decoder.zig  # Radio DSP worker, presets, scanner, UI
    ├── scanner.zig        # Multi-channel scanner state machine
    ├── hackrf_config.zig  # HackRF settings panel + persistence
    ├── save_manager.zig   # I/Q WAV recording with file dialog
    ├── wav_writer.zig     # WAV file format writer
    ├── stats_window.zig   # Performance stats dashboard
    ├── fm_decoder.zig     # Legacy FM decoder (superseded by radio_decoder)
    ├── util.zig           # Small utility functions
    ├── dsp.zig            # Barrel file for DSP modules
    └── dsp/
        ├── dsp_thread.zig      # DspThread + ProcessorWorker
        ├── double_buffer.zig   # Lock-free double buffer
        ├── dc_filter.zig       # IIR DC removal filter
        ├── chain.zig           # Comptime processor composition
        ├── decimating_fir.zig  # FIR low-pass + decimation
        ├── nco.zig             # Numerically controlled oscillator (SIMD atan2)
        ├── deemphasis.zig      # FM de-emphasis IIR filter
        ├── biquad.zig          # Generic biquad IIR filter
        ├── ctcss_detector.zig  # CTCSS sub-audible tone detector
        ├── dcs_detector.zig    # DCS digital coded squelch decoder
        ├── golay.zig           # Golay(23,12) error-correcting codec
        ├── noise_squelch.zig   # Noise-based squelch with hysteresis
        ├── tone_squelch.zig    # CTCSS/DCS-gated squelch
        └── pipeline_stats.zig  # Per-stage latency tracking
```

## Dependencies

<!-- prettier-ignore -->
| Dependency | Version | Role |
|------------|---------|------|
| [zgui](https://github.com/zig-gamedev/zgui) | 0.6.0-dev | Dear ImGui + ImPlot bindings for Zig |
| [zsdl / SDL3](https://github.com/zig-gamedev/zsdl) | 0.4.0 / 3.4.0 | Window, GPU, audio, input |
| [libhackrf](https://github.com/greatscottgadgets/hackrf) | 2026.01.2 | HackRF One USB interface |
| [libusb](https://github.com/libusb/libusb) | 1.0.27 | Cross-platform USB access |
| [FFTW3](https://www.fftw.org/) | 3.x | Fast Fourier Transform (system library) |

All Zig dependencies are fetched automatically via `zig build --fetch`. FFTW
must be installed separately on macOS and Linux (bundled on Windows).

## Roadmap

Planned improvements (see [TODO.md](TODO.md) and
[docs/AI_TODO.md](docs/AI_TODO.md)):

- Time domain view for raw I/Q waveforms
- DCS detection improvements and error correction tuning
- Multi-channel FRS scanner with FFT-based channelization
- Adaptive CTCSS detection thresholds
- Audio high-pass filter for CTCSS tone removal from speaker output
- Squelch hysteresis and hold timer refinements
- Full node-based dataflow system for custom DSP graphs

## Contributing

Contributions are welcome! If you're interested in SDR, DSP, or Zig, feel free
to open an issue or submit a pull request. This is a learning project, so
questions and discussions are encouraged.

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgments

- [Great Scott Gadgets](https://greatscottgadgets.com/) for the HackRF One
  hardware and firmware
- [FFTW](https://www.fftw.org/) for the fastest Fourier transforms in the West
- [zig-gamedev](https://github.com/zig-gamedev) for zgui and zsdl bindings
- [SDL](https://www.libsdl.org/) for cross-platform windowing, GPU, and audio
