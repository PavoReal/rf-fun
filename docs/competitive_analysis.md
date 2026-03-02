# Competitive Analysis: rf-fun vs. GNU Radio, SDR++, SigDigger

*Date: 2026-03-02*

## Executive Summary

rf-fun is an early-stage, Zig-based SDR spectrum analyzer and radio decoder targeting the HackRF One. This analysis compares it against three established competitors across architecture, features, performance, complexity, scale, extensibility, and strategic positioning.

| Dimension | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| **Language** | Zig | C++ / Python | C++ | C / C++ |
| **Stage** | Early (learning/exploration) | Mature (20+ years) | Mature (~5 years) | Growing (~5 years) |
| **Lines of Code** | ~10,000 | ~1,000,000+ | ~50,000-80,000 est. | ~40,000+ est. |
| **GitHub Stars** | N/A (private) | ~5,500 | ~5,700 | ~1,500 |
| **License** | Private | GPL-3.0 | GPL-3.0 | GPL-3.0 |
| **Primary Use Case** | HackRF spectrum analysis + radio decoding | General-purpose SDR framework | Lightweight SDR receiver | Blind signal analysis |

---

## 1. Fundamental Architecture

### rf-fun

**Design Philosophy:** Comptime-composable, zero-allocation DSP pipeline in Zig.

**Thread Model (4 threads):**
```
HackRF One --> RX Callback --> FixedSizeRingBuffer (mutex-protected)
                                     |
                    +----------------+----------------+
                    |                                 |
           Spectrum Worker                     Radio Worker
     (DC Filter -> FFT -> EMA ->       (NCO Mix -> Decimate ->
      Peak Hold)                        Demod -> Squelch -> Audio)
           |                                      |
     DoubleBuffer (lock-free)              SDL Audio Queue
           |                                      |
       Main Thread (GUI)                    Speaker Output
```

**Core Abstraction:** The `Processor` pattern -- any struct with `Input`/`Output` types and `process()`/`reset()` methods. `Chain(A, B)` composes processors at compile time with type-checked compatibility. No vtables, no dynamic dispatch, no allocations in the hot path.

**Strengths:**
- Deterministic latency: all DSP buffers pre-allocated
- Lock-free output via `DoubleBuffer` with atomic indices
- Compile-time type safety eliminates entire categories of runtime errors
- SIMD vectorization (8-wide `@Vector`) in NCO and FIR filters
- Zero framework overhead -- no signal processing framework between you and the hardware

**Weaknesses:**
- Fixed 4-thread model (not dynamically scalable)
- Single hardware target (HackRF only)
- No hardware abstraction layer (no SoapySDR equivalent)
- Processor composition is linear chains only (no branching graphs)

### GNU Radio

**Design Philosophy:** General-purpose signal processing framework using dataflow graphs ("flowgraphs").

**Thread Model:** Each block runs in its own thread (or shares threads via thread groups). The scheduler manages data flow between blocks through circular buffers. GNU Radio 4.0 (in development) redesigns this with a compile-time graph model.

**Core Abstraction:** The `gr::block` -- a processing unit with typed input/output ports. Blocks connect into a `gr::top_block` flowgraph. The scheduler manages buffer allocation, threading, and flow control automatically.

```
Source Block --> [Buffer] --> Processing Block --> [Buffer] --> Sink Block
                                  |
                            (each block = 1 thread)
                            (buffers = circular, page-aligned)
```

**Strengths:**
- Arbitrary graph topologies (fan-out, fan-in, feedback loops)
- Massive block library (1000+ blocks)
- Python bindings for rapid prototyping; C++ for performance
- GNU Radio Companion: visual flowgraph editor
- Industry standard with 20+ years of battle testing

**Weaknesses:**
- Per-block threading creates overhead for simple pipelines (context switches, cache misses)
- Buffer management overhead between every block
- Python GIL limits multi-core Python processing
- Large framework footprint (~1M+ LoC, heavy dependency chain)
- GNU Radio 4.0 rewrite has been in progress for years (API instability risk)

### SDR++

**Design Philosophy:** Lightweight, bloat-free SDR receiver with modular architecture.

**Thread Model:** Separates GUI rendering (GLFW/OpenGL main loop) from DSP pipeline (separate threads). The signal path flows linearly:

```
Source Module -> IQ Frontend (FFT) -> VFO Manager -> Decoder -> Sink
```

**Core Abstraction:** Dynamically-loaded module system with four categories (source, sink, decoder, utility). Modules are shared libraries (.so/.dll) loaded at runtime.

**Strengths:**
- Multi-VFO: simultaneous independent demodulators within captured bandwidth
- 15+ hardware sources via native drivers + SoapySDR fallback
- SIMD via libvolk; FFTW3 for FFT
- Proven cross-platform (Win/Linux/macOS/Android)
- Lightest CPU footprint among major SDR GUIs

**Weaknesses:**
- Linear signal path only (no arbitrary graph topologies)
- Single-maintainer bottleneck; restrictive contribution policies led to community forks
- No transmit capability
- Module API poorly documented in mainline
- OpenGL rendering has non-trivial idle CPU cost

### SigDigger

**Design Philosophy:** Blind signal analysis -- extracting information from unknown signals.

**Thread Model:** Suscan distributes DSP across multiple cores via worker threads, optimized for real-time analysis tasks rather than general flowgraph execution.

**Core Abstraction:** Three-layer stack: sigutils (DSP primitives) -> suscan (real-time analysis engine) -> SigDigger (Qt GUI). Channel "inspectors" are configurable demodulator instances opened on any detected signal.

**Strengths:**
- Custom DSP stack (no GNU Radio dependency), ~20% less CPU than GQRX
- Inspector pattern enables dynamic channel analysis
- Digital demodulation (FSK, PSK, ASK) with constellation view
- Analog video demodulation (PAL, NTSC)
- TLE-based Doppler correction for satellite tracking
- Plugin system (v0.3.0+)

**Weaknesses:**
- Single developer (bus factor = 1)
- API not yet stable
- Windows support described as "a mess" by the developer
- Smaller community than alternatives
- Not optimized for casual "tune and listen" usage

### Architecture Verdict

| Aspect | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| Graph Topology | Linear chain | Arbitrary DAG | Linear | Linear + inspectors |
| Dispatch | Static (comptime) | Dynamic (vtable) | Dynamic (modules) | Dynamic (C callbacks) |
| Alloc in Hot Path | None | Per-buffer | Minimal | Minimal |
| Thread Scaling | Fixed 4 | Per-block (auto) | Fixed pipeline | Per-core workers |
| Type Safety | Compile-time | Runtime | Runtime | Runtime |
| Framework Overhead | Zero | Significant | Low | Low |

**rf-fun's architectural advantage** is zero-overhead composition and compile-time safety. Its disadvantage is flexibility -- it can't express the graph topologies that GNU Radio handles trivially.

---

## 2. Feature Comparison

### Signal Processing

| Feature | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| FFT Spectrum | 64-8192 bins | Arbitrary | Configurable | Up to 64K bins |
| Window Functions | 5 (Hanning, Hamming, Blackman-Harris, Flat-Top, None) | 10+ | Multiple | Multiple |
| Waterfall | 256 rows, GPU texture | Via QT GUI | OpenGL, full-width | OpenGL texture |
| DC Spike Filter | IIR high-pass | Multiple options | Yes | Yes |
| EMA Smoothing | Configurable depth | Via blocks | Yes | Yes |
| Peak Hold | Adjustable decay | Via blocks | Yes | N/A |
| Zoom/Pan | Interactive | Via GUI | Yes | Full-waterfall zoom |
| Click-to-Tune | Yes | No (graph-based) | Yes | Yes |

### Demodulation

| Mode | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| AM | Yes (32 kHz IF) | Yes | Yes | Yes |
| FM Wideband | Yes (400 kHz IF) | Yes | Yes (WFM) | Yes |
| FM Narrow | Yes (50 kHz IF) | Yes | Yes (NFM) | Yes |
| SSB (LSB/USB) | No | Yes | Yes | Yes |
| CW | No | Yes | Yes | No |
| DSB | No | Yes | Yes | No |
| FSK/PSK/ASK | No | Yes | No | Yes (inspectors) |
| Digital Modes (FT8, etc.) | No | Via OOT modules | No (Brown fork only) | No |
| Analog Video | No | Yes | No | Yes (PAL/NTSC) |
| De-emphasis | Yes (FM) | Yes | Yes | Yes |

### Signaling & Squelch

| Feature | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| Noise Squelch | Yes (hysteresis) | Yes | Yes | Basic |
| CTCSS Detection | 50 tones, Goertzel | Via blocks | No | No |
| DCS Detection | 104 codes, Golay(23,12) | Via blocks | No | No |
| Tone Squelch | CTCSS/DCS-gated | Configurable | No | No |
| Scanner | Multi-channel, dwell/hold | Via flowgraph | Basic (enhanced in CE) | No |
| Channel Presets | FRS, Retevis H777 | User-defined | Frequency manager | Auto-detect |

**rf-fun's unique strength** is its CTCSS/DCS detection and tone squelch system. This is a feature area where rf-fun surpasses SDR++ and SigDigger, which have no built-in sub-audible tone detection. GNU Radio can do this via blocks, but requires manual flowgraph assembly.

### Recording & I/O

| Feature | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| I/Q Recording | WAV (8/16-bit PCM) | Multiple formats | Yes (baseband) | Yes |
| Audio Recording | No (via SDL queue) | Yes | Yes (WAV) | Yes |
| File Playback | No | Yes | Yes | Yes (with seeking) |
| Network Streaming | No | Yes (ZMQ, etc.) | Yes (TCP/UDP) | Yes (remote analyzer) |
| Remote SDR | No | Yes | Yes (SDR++ Server) | Yes (Suscan remote) |

### Hardware Support

| Hardware | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| HackRF | Native (libhackrf) | Via gr-osmosdr/SoapySDR | Native | Via SoapySDR |
| RTL-SDR | No | Yes | Native | Via SoapySDR |
| USRP | No | Yes (UHD, first-class) | Native | Via SoapySDR |
| Airspy | No | Yes | Native | Via SoapySDR |
| BladeRF | No | Yes | Native | Via SoapySDR |
| LimeSDR | No | Yes | Native | Via SoapySDR |
| SDRPlay | No | Yes | Native | Via SoapySDR |
| PlutoSDR | No | Yes | Native | Via SoapySDR |
| SoapySDR (generic) | No | Yes | Yes (fallback) | Yes (primary) |
| Transmit | No | Yes | No | No |
| Hardware Count | 1 | 20+ | 15+ | 10+ (via SoapySDR) |

### Feature Verdict

rf-fun has a focused, deep feature set in its niche (HackRF spectrum analysis + FRS/GMRS radio monitoring with CTCSS/DCS). It cannot compete on breadth with any of the three competitors. However, its CTCSS/DCS detection pipeline with Golay error correction is more sophisticated than what SDR++ or SigDigger offer out of the box.

---

## 3. Performance

### Theoretical Analysis

| Factor | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| Language Overhead | Minimal (Zig = C-level) | C++ (some abstraction cost) | C++ | C (DSP) / C++ (GUI) |
| SIMD | Manual 8-wide @Vector | Via VOLK library | Via VOLK library | Custom in sigutils |
| FFT | FFTW3 (system lib) | FFTW3 | FFTW3 | Custom (sigutils) |
| Alloc in DSP Path | Zero | Per-buffer (managed) | Minimal | Minimal |
| Inter-block Overhead | None (comptime chain) | Significant (scheduler) | Low (linear path) | Low (worker threads) |
| GPU Rendering | SDL3 GPU (texture upload) | Qt OpenGL | GLFW/OpenGL | Qt/OpenGL |
| Lock Contention | Minimal (atomics) | Buffer management | Module boundaries | Worker synchronization |

### Published/Estimated Benchmarks

**SigDigger** (Intel i5-6200U, 2C/4T):
- Spectrum only (16K FFT, 60fps): 108 Msps
- FM demod (333 kHz BW): 17 Msps
- Analog TV demod: 5.6 Msps

**SDR++:**
- Raspberry Pi 4 with RTL-SDR: ~50% CPU (usable)
- Apple M1: ~14% reported CPU
- Generally lowest CPU footprint among major SDR GUIs

**GNU Radio:**
- Throughput scales with graph complexity
- Simple FM receiver: handles 20+ Msps on modern hardware
- Complex graphs: CPU-bound at lower rates due to scheduler overhead
- VOLK-accelerated blocks approach theoretical hardware limits

**rf-fun:**
- No published benchmarks yet
- Theoretical advantage: zero-copy comptime chains should outperform equivalent GNU Radio flowgraphs
- HackRF maxes at 20 Msps, well within Zig's processing capability
- SIMD NCO + DecimatingFIR should be competitive with VOLK equivalents

### Performance Verdict

rf-fun's architecture is designed for minimal overhead and should perform well for its use case (single HackRF at up to 20 Msps). However, it lacks benchmarks to prove this. The comptime chain pattern eliminates overhead that GNU Radio incurs by design, but GNU Radio has had decades of optimization. SDR++ and SigDigger are the most relevant performance comparisons -- both handle similar workloads with proven efficiency.

**Recommendation:** Establish benchmarks (Msps throughput, CPU%, latency) to quantify rf-fun's actual performance advantage.

---

## 4. Complexity & Developer Experience

### Build System

| Aspect | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| Build System | Zig Build | CMake | CMake | CMake |
| Dependency Resolution | `build.zig.zon` (auto-fetch) | Manual / distro packages | vcpkg (Win) / manual | Manual (4 repos) |
| Toolchain Required | `zig` binary only | CMake + C++ compiler + Python + SWIG + ... | CMake + C++ compiler + many libs | CMake + C compiler + Qt5/6 |
| From-Source Build | `zig build run` | Complex (30+ dependencies) | "Not straightforward" | Build 4 separate repos in order |
| Cross-Compile | Built-in (Zig cross-compile) | Difficult | Possible but complex | Difficult |

**rf-fun has a massive developer experience advantage.** `zig build run` with automatic dependency fetching vs. the dependency hell of C/C++ CMake projects. Cross-compilation is trivial in Zig and painful in all three competitors.

### Learning Curve

| Audience | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| End User | Install + run | Install + learn GRC or Python | Install + run | Install + learn concepts |
| Plugin Developer | N/A (no plugin system) | Learn block API + Python/C++ | Learn module API (poorly documented) | Learn inspector API (young) |
| Core Contributor | Know Zig + DSP | Know C++/Python + DSP + complex build system | Know C++ + ImGui + DSP | Know C + Qt + DSP |
| Codebase Navigation | ~10K LoC, well-structured | ~1M LoC, massive | ~50-80K LoC, modular | ~40K+ LoC, layered |

### Code Quality Indicators

| Metric | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| Memory Safety | Zig (compile-time checks, no UB) | C++ (manual, UB possible) | C++ (manual, UB possible) | C (manual, UB possible) |
| Error Handling | Zig error unions (exhaustive) | C++ exceptions + error codes | C++ (mixed) | C error codes |
| Type Safety | Comptime-verified chains | Runtime port types | Runtime module types | Runtime C types |
| Test Coverage | Unit tests present | Extensive test suite | Limited | Moderate |

---

## 5. Scale & Ecosystem

### Community & Support

| Metric | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| Age | Months | 20+ years | ~5 years | ~5 years |
| Contributors | 1 (+ AI) | 300+ | 1 primary + community | 1 primary + few |
| GitHub Stars | Private | ~5,500 | ~5,700 | ~1,500 |
| Ecosystem Size | Self-contained | 100+ OOT modules | ~10 third-party modules | ~5 plugins |
| Documentation | Minimal | Extensive (wiki, tutorials, books) | User guide PDF, CE dev docs | User manual, FOSDEM talks |
| Academic Use | None | Standard in university curricula | Minimal | Minimal |
| Industry Use | None | Defense, telecom, research labs | Hobbyist | Research / reverse engineering |
| Support Channels | None | Mailing list, IRC, Discourse | GitHub issues | GitHub issues |

### Maturity Assessment

```
                    Maturity Spectrum
    Experimental ----+--------+--------+--------+---- Production
                     |        |        |        |
                  rf-fun   SigDigger  SDR++   GNU Radio
                  (early)  (growing)  (stable) (mature)
```

---

## 6. Strategic Positioning

### Where Each Tool Fits

| Tool | Sweet Spot | Worst At |
|---|---|---|
| **GNU Radio** | Complex multi-stage DSP research, protocol development, education | Quick "tune and listen", mobile/embedded |
| **SDR++** | Lightweight spectrum browsing across many devices | Signal analysis, digital modes, transmit |
| **SigDigger** | Reverse engineering unknown signals, digital analysis | Casual listening, multi-platform deployment |
| **rf-fun** | HackRF-focused radio monitoring with tone squelch | Multi-device support, general-purpose DSP |

### rf-fun's Competitive Position

**Current Niche:** HackRF One spectrum analyzer + FRS/GMRS radio monitor with CTCSS/DCS detection.

**Unique Differentiators (things no competitor does as well):**
1. **Zig language** -- Only SDR tool in Zig. Compile-time safety, zero-cost abstractions, trivial cross-compilation, single-binary distribution
2. **Comptime DSP composition** -- Type-checked processor chains with zero runtime overhead. Novel approach not seen in any competitor
3. **CTCSS/DCS pipeline** -- Goertzel-based CTCSS + Golay(23,12) DCS decoding with hysteresis. More sophisticated than SDR++ or SigDigger offer natively
4. **Build simplicity** -- `zig build run` vs. dependency hell. Massive advantage for contributors
5. **Zero-allocation hot path** -- Deterministic latency by design, not by careful coding

**Gaps That Matter (things competitors all have):**
1. **Multi-hardware support** -- All competitors support 10+ devices; rf-fun supports 1
2. **SSB/CW demodulation** -- Table stakes for amateur radio use
3. **File playback** -- All competitors can replay I/Q recordings
4. **Multi-VFO** -- SDR++ and CubicSDR handle multiple simultaneous demodulators
5. **Network/remote operation** -- All competitors support remote SDR access
6. **Plugin/extension system** -- SDR++, SigDigger, and GNU Radio all support extensibility

---

## 7. Roadmap Comparison

### GNU Radio
- **GNU Radio 4.0** (in development): Complete rewrite with compile-time graph construction, better performance, modern C++20. Aims to address the scheduler overhead problem that rf-fun's architecture already solves.
- Risk: GR 4.0 has been in progress for years; the transition will fragment the ecosystem.

### SDR++
- No formal roadmap. Rolling nightly releases.
- Innovation happening primarily in community forks (SDR++CE, Brown fork).
- Mainline appears to be in maintenance mode.

### SigDigger
- Active roadmap: API stabilization, improved plugin system, squelch-controlled recording, better Windows support.
- Most actively evolving of the three competitors.

### rf-fun (from TODO.md and AI_TODO.md)
- Multi-channel parallel monitoring
- DCS/CTCSS threshold tuning
- Scan activity export
- Time-domain view
- Node-based dataflow graph (long-term)

---

## 8. Strategic Recommendations

### 1. Don't Try to Be GNU Radio

GNU Radio's value is its massive block library and 20-year ecosystem. rf-fun will never replicate that, and shouldn't try. GNU Radio 4.0's move toward compile-time graph construction validates rf-fun's architectural direction, but GNU Radio has the community and library depth to sustain its position.

### 2. Don't Try to Be SDR++

SDR++'s value is broad hardware support and lightweight "tune and listen" experience across every platform. Competing on device count is a losing strategy -- each hardware driver is weeks of work with diminishing returns.

### 3. Consider the SigDigger Path

SigDigger proves that a single developer with a custom DSP stack can build a differentiated, respected tool. BatchDrake succeeded by focusing on a specific use case (blind signal analysis) that the general-purpose tools serve poorly. rf-fun should similarly deepen its niche rather than broaden.

### 4. Double Down on What's Unique

**Zig's advantages are real and underexploited:**
- **Cross-compilation** -- Build for Linux ARM (Raspberry Pi) from any host with zero additional toolchain setup. No competitor can do this cleanly
- **Comptime DSP** -- The Processor/Chain pattern is a genuinely novel contribution to the SDR space. GNU Radio 4.0 is moving in this direction with C++20, but Zig's comptime is more expressive
- **Single binary distribution** -- No dependency hell, no shared library conflicts
- **Memory safety without runtime cost** -- Unlike Rust, Zig doesn't impose a borrow checker; unlike C++, it prevents undefined behavior at compile time

**CTCSS/DCS is a real differentiator:**
- SDR++ has no tone detection
- SigDigger has no tone detection
- GNU Radio requires manual flowgraph assembly
- rf-fun does it out of the box with Golay error correction

### 5. Suggested Priority Additions

In order of competitive impact:

1. **I/Q file playback** -- Every competitor has this. Essential for development, testing, and sharing interesting captures. Low effort, high value
2. **SSB demodulation** -- Table stakes for amateur radio users. AM/FM/SSB covers 90% of use cases
3. **SoapySDR integration** -- One integration unlocks RTL-SDR, Airspy, BladeRF, and many others. Transforms rf-fun from "HackRF tool" to "SDR tool"
4. **Performance benchmarks** -- Quantify the advantage. If rf-fun's comptime chains really are faster, prove it
5. **P25/DMR trunking awareness** -- Natural extension of the FRS/GMRS scanner + CTCSS/DCS work. Would be a genuine differentiator that no lightweight GUI SDR tool handles well

### 6. What NOT to Prioritize

- **Plugin system** -- Too early. Stabilize the core first. SDR++'s module system took years to mature and is still poorly documented
- **Arbitrary graph topologies** -- This is GNU Radio's territory. Linear chains serve 95% of receiver use cases
- **Android/mobile** -- Cross-platform complexity for minimal audience. Only SDR++ attempts this and it's buggy
- **Network streaming** -- Nice to have but not differentiating

---

## 9. SWOT Summary

### Strengths
- Zero-overhead comptime DSP composition (architecturally novel)
- CTCSS/DCS with Golay error correction (unique in the GUI SDR space)
- Zig build system (trivial builds, cross-compilation)
- Memory safety without runtime cost
- Clean, well-instrumented codebase (~10K LoC)
- Per-stage latency monitoring built in

### Weaknesses
- Single hardware target (HackRF only)
- No SSB/CW demodulation
- No file playback
- No remote/network operation
- No extension system
- No published benchmarks
- Single developer

### Opportunities
- Zig ecosystem is growing -- early SDR tool in Zig could attract contributors
- GNU Radio 4.0 transition will cause ecosystem fragmentation
- SDR++ mainline appears to be in maintenance mode; community frustrated
- FRS/GMRS/P25 monitoring niche is underserved by existing tools
- Cross-compilation to ARM (Raspberry Pi) with zero effort is genuinely unique
- Compile-time DSP composition is a novel concept worth publishing/presenting

### Threats
- GNU Radio 4.0 adopts similar compile-time graph techniques with massive ecosystem behind it
- SDR++ Community Edition addresses many of SDR++'s weaknesses
- SigDigger's inspector pattern could evolve to cover rf-fun's niche
- Zig language stability risk (0.15.x, pre-1.0)
- HackRF-only support limits addressable audience

---

## 10. Quantitative Summary

| Metric | rf-fun | GNU Radio | SDR++ | SigDigger |
|---|---|---|---|---|
| **Lines of Code** | ~10K | ~1M+ | ~50-80K | ~40K+ |
| **Source Files** | 33 | 3000+ | 200+ | 150+ |
| **Demod Modes** | 3 (AM/FM/NFM) | 20+ | 8 | 6+ inspectors |
| **Hardware Devices** | 1 | 20+ | 15+ | 10+ |
| **DSP Blocks/Processors** | ~12 | 1000+ | ~30 modules | ~20+ |
| **Window Functions** | 5 | 10+ | Multiple | Multiple |
| **Max FFT Size** | 8192 | Arbitrary | Configurable | 65536 |
| **Contributors** | 1 | 300+ | ~20 | ~5 |
| **Age (years)** | <1 | 20+ | ~5 | ~5 |
| **Build Command** | `zig build run` | Complex multi-step | Complex multi-step | 4-repo sequential |
| **Cross-Compile** | Built-in | Manual/difficult | Manual/difficult | Manual/difficult |
| **CTCSS Detection** | 50 tones (Goertzel) | Via blocks | No | No |
| **DCS Detection** | 104 codes (Golay) | Via blocks | No | No |
| **Tone Squelch** | Yes (4 modes) | Configurable | No | No |
| **Channel Scanner** | Yes (multi-channel) | Via flowgraph | Basic | No |
