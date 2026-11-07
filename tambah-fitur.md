# SYSTEM ARCHITECT & CODING PROMPT: PRO GRADE STUDIO (APPLE ECOSYSTEM)
## Dual Video & Photo Native Color Suite (iOS, iPadOS, macOS)

---

## 1. MISSION & CONTEXT

You are an Elite Apple Systems Graphics & Media Architect, Metal Shading Specialist, and Senior Swift Developer. Your objective is to build a studio-grade, 100% offline-first, professional video and photo color grading application for **iOS (iPhone), iPadOS (iPad), and macOS (Mac)** using a single, unified Swift codebase.

The application must function as a mini DaVinci Resolve / Lightroom hybrid, supporting **both high-resolution video (including Apple Log, 4K60, HDR/HLG) and still photography (ProRAW, DNG, HEIC, JPEG)**. It must provide real-time 60fps GPU preview, advanced colorist scopes, secondary selective HSL correction, RGB curves, film emulation, and pristine social-ready export with zero server dependencies or account requirements.

---

## 2. TECHNICAL FOUNDATION & DEPENDENCIES

* **Platforms:** iOS 17.0+, iPadOS 17.0+, macOS 14.0+ (Sonoma/Sequoia).
* **Language & Paradigms:** Swift 5.9+ / Swift 6, Strict Concurrency, Swift Modern Concurrency (`async`/`await`, `actors`, `@Observable`).
* **UI Framework:** SwiftUI with multiplatform ergonomics (`NavigationSplitView` for Mac/iPad, ergonomic bottom deck for iPhone).
* **Graphics & Processing Core:**
  * **Metal & MetalKit:** Custom MSL fragment kernels for HSL, Halation, Film Grain, and Waveform rendering.
  * **Core Image:** High-level accelerated pipeline, `CIContext` bound to a shared low-power `MTLDevice`.
  * **Accelerate / vImage & Metal Performance Shaders (MPS):** For zero-overhead histogram extraction and waveform data generation.
* **Media Frameworks:** AVFoundation (`AVPlayerItemVideoOutput`, `AVAssetReader`, `AVAssetWriter`), PhotosUI, UniformTypeIdentifiers.
* **External Dependencies:** **ZERO third-party libraries.** Pure native Apple frameworks.

---

## 3. FULL FEATURE SET SPECIFICATION

### A. Dual Media Handling (Video & Photo)
* **Video Ingestion:** Decodes via `AVPlayerItemVideoOutput` (for scrubbing/playback) and `AVAssetReader` (for final export).
* **Photo Ingestion:** Instant decoding of ProRAW/DNG (via `CIFilter(name: "CIRAWFilter")`), HEIC, PNG, and JPEG into full-precision float `CIImage`.
* **Universal Grading Pipeline:** The exact same adjustment parameters apply identically to both photos and video frames.

### B. Color Correction Pipeline (Order of Operations)
1. **Input Normalization & Apple Log Transform:**
   * One-click LUT/Matrix transform for **Apple Log (iPhone 15 Pro / 16 Pro)** to Rec.709.
   * Auto-tonemapping for HDR10 / Dolby Vision sources into Rec.709 SDR standard.
2. **Primary Grading:**
   * Exposure, Contrast, S-Curve Contrast.
   * White Balance (Kelvin Temperature and Green/Magenta Tint).
   * Highlights, Shadows, Whites, Blacks.
3. **RGB & Luma Tone Curves:**
   * 4-Channel Parametric Bezier Curves: Master (Luma), Red, Green, and Blue.
   * Interactive control points for creating matte/faded blacks, S-curves, and color cross-processing.
4. **Secondary Color Correction (8-Channel HSL Warper):**
   * Targeted controls for Red, Orange, Yellow, Green, Cyan, Blue, Purple, and Magenta.
   * Per-channel Hue Shift, Saturation, and Luminance adjustment.
   * **Skin Tone Protection Lock:** Protects Orange/Red hues while pushing intense secondary palettes (e.g., Teal & Orange look).
5. **3D LUT Ingestion:**
   * Fast `.cube` text parser (supporting $17^3$ to $65^3$ cubes) and HALD-PNG loader.
   * `CIColorCubeWithColorSpace` application with dynamic **LUT Opacity/Intensity** blending ($0.0 - 1.0$).
6. **Three-Way Color Wheels (Lift, Gamma, Gain):**
   * Chromaticity offset targeting Shadows (Lift), Midtones (Gamma), and Highlights (Gain).
7. **Film Emulation Engine:**
   * **Halation:** Warm/reddish bleeding around high-contrast edges and specular highlights.
   * **Dynamic Film Grain:** Procedural per-frame organic noise generator (Metal shader, not a looping video overlay) with adjustable grain size and roughness.
8. **Anti-Banding Micro-Dither Guard:**
   * Subtle 0.5 LSB triangular dither to prevent 8-bit quantization banding on flat skies/shadows when compressed by social media.

### C. Real-Time Colorist Scopes (GPU-Accelerated)
* **RGB & Luma Waveform:** Visualizes luminance distribution ($0 - 100$ IRE) from left to right across the image.
* **Vectorscope:** Polar plot displaying color saturation and hue angle, including the dedicated Skin Tone reference line.
* **Histogram:** Real-time channel separation (R, G, B, Luma).

### D. Workflow & Productivity Tools
* **Interactive A/B Comparison:**
  * Hold-to-preview original media (bypass toggle).
  * Draggable vertical split-screen wipe (graded vs. original) during real-time playback.
* **Grade Management:**
  * Save custom presets locally (JSON serializable recipes).
  * **Copy Grade / Paste Grade:** Instant grading transfer between different photos and video clips.
* **Batch Processing (Offline):**
  * Select multiple photos or videos and execute background rendering with memory-safe buffer reuse.

---

## 4. SOCIAL MEDIA ENCODING SPECIFICATIONS (ANTI-COMPRESSION ENGINE)

To prevent social networks (Instagram, TikTok, YouTube Shorts) from ruining export quality:

* **Video Codec:** `AVVideoCodecType.h264` (H.264 High Profile, Level 4.2). Avoid raw HEVC export for social ingest.
* **Color Primaries & Transfer Matrix:**
  * Tag explicitly: `AVVideoColorPrimaries_ITU_R_709_2`
  * Tag explicitly: `AVVideoTransferFunction_ITU_R_709_2`
  * Tag explicitly: `AVVideoYCbCrMatrix_ITU_R_709_2`
* **Bitrate Profile:**
  * 1080p @ 30fps: Average VBR **14 Mbps** (Peak 16 Mbps).
  * 1080p @ 60fps: Average VBR **20 Mbps** (Peak 24 Mbps).
  * Constant Frame Rate (CFR) strictly enforced to avoid audio desync and platform frame drops.
* **Photo Export:** Maximum quality sRGB / Rec.709 JPEG with embedded color profile and optional uncompressed TIFF/PNG.

---

## 5. UI/UX ADAPTIVE ARCHITECTURE

* **iPhone:**
  * Top: 16:9 / 9:16 Metal canvas with swipeable A/B split view and toggleable overlay scopes.
  * Bottom: Thumb-friendly segmented control bar (Basics, Curves, HSL, Wheels, Film, LUTs) with precision haptic wheel sliders.
* **iPad:**
  * Multi-column split view with Apple Pencil scrub capability, floating Scopes window, and dual before/after viewer.
* **macOS:**
  * Dedicated Studio workspace: Drag-and-drop `.cube` files directly onto clips, J-K-L playback scrubbing, Spacebar play/pause, `\` split preview toggle, and full multi-monitor support.

---

## 6. COMPLETE CODE IMPLEMENTATION BLUEPRINT

Implement the complete solution across the following modular Swift files:

### File 1: `ColorGradingModels.swift`
* Data structures for all parameters: `BasicAdjustments`, `HSLSegment` (8 channels), `CurvePoints` (Bezier splines), `ColorWheelOffsets`, and `FilmEmulationConfig`.
* `Codable` grade preset representation for saving, loading, and clipboard copying.

### File 2: `LUTParser.swift`
* Memory-efficient `.cube` text file parser supporting arbitrary sizes ($N \times N \times N$).
* Converts text triplets to packed float 32-bit `Data` ready for `CIColorCubeWithColorSpace`.

### File 3: `Shaders.metal`
* **MSL Kernel 1:** 8-Channel HSL manipulation with smooth Gaussian hue transitions and skin tone isolation mask.
* **MSL Kernel 2:** Procedural organic film grain (simplex/golden ratio noise based on time/frame index) and edge-detection halation.
* **MSL Kernel 3:** Anti-banding dithering.
* **MSL Kernel 4:** Waveform & vectorscope render compute pass.

### File 4: `ColorGradingEngine.swift`
* Central `@Observable` rendering coordinator.
* Takes a source `CIImage` and applies the complete deterministic node graph:
  * Log/HDR conversion $\to$ Basics $\to$ Curves $\to$ HSL $\to$ 3D LUT $\to$ Wheels $\to$ Film Effects $\to$ Dither.
* Produces output `CIImage` for both preview viewport and final export.

### File 5: `VideoPlayerView.swift`
* Custom `MTKView` subclass / SwiftUI wrapper.
* Connects to `AVPlayerItemVideoOutput` for 60fps continuous render loop.
* Implements touch/drag split-screen wipe with interactive dividing line.

### File 6: `ScopesView.swift`
* Compact, performant SwiftUI/Metal view displaying real-time Waveform, Vectorscope, and RGB Parade without blocking the main render thread.

### File 7: `BatchExporter.swift`
* Handles offline batch rendering for both photos (`CIContext.writeJPEGRepresentation`) and videos (`AVAssetReader` + `AVAssetWriter`).
* Injects social-proof H.264 profiles and Rec.709 color tags.
* Provides `AsyncStream<Float>` progress telemetry.

### File 8: `ContentView.swift`
* Master multiplatform UI dynamically adapting between iPhone compact layout, iPad split view, and macOS desktop dashboard.

---

## 7. EXECUTION INSTRUCTIONS

Generate the full production-ready Swift and Metal implementations for each file specified above. Ensure zero memory leaks (proper autorelease pools for `CVPixelBuffer` handles), high cache utilization, strict 60fps responsiveness on Apple Silicon, and complete offline capability.