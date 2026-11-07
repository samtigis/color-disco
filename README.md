# ColorDisco Studio

High-performance, offline-first professional video color grading application for **iOS (iPhone)**, **iPadOS (iPad)**, and **macOS (Mac)** built with Swift, SwiftUI, Metal (`MTKView` + MSL stitchable shaders), Core Image (`CIContext`), and AVFoundation (`AVAssetReader` / `AVAssetWriter`).

## Architecture & Features

- **Unified Apple Ecosystem Codebase**: Targets iOS 17+, iPadOS 17+, and macOS 14+ (Sonoma/Sequoia) with zero third-party dependencies.
- **3D LUT Engine (`LUTParser.swift`)**:
  - Parses standard Adobe/Resolve `.cube` 3D LUT files (`LUT_3D_SIZE N`, `DOMAIN_MIN`, `DOMAIN_MAX`, $N^3$ RGB float triplets).
  - Decodes 2D HALD PNG identity/graded images into `CIColorCubeWithColorSpace` RGBA Float32 buffers.
  - Includes procedural studio presets (`Rec.709 Natural Neutral`, `Kodak 2383 Film Print`, `Cine Tungsten & Amber`, `Silver Bleach Retention`, `Apple Log to Rec.709 SDR`).
- **7-Stage Color Pipeline (`ColorGradingEngine.swift` & `ColorGradingShaders.metal`)**:
  1. Linear working space ingest & automatic HDR (PQ SMPTE ST 2084 / HLG BT.2100) to Rec. 709 100-nit SDR tonemapping.
  2. Exposure (`CIExposureAdjust`) & S-Curve Contrast (`CIToneCurve`).
  3. White Balance Temperature & Tint (`CITemperatureAndTint`).
  4. 3-Way Color Corrector (Lift / Gamma / Gain) for Shadows, Midtones, and Highlights.
  5. 3D LUT application (`CIColorCubeWithColorSpace`) with continuous intensity blending.
  6. Skin-safe Vibrance (`CIVibrance`) & Saturation (`CIColorControls`).
  7. Zero-mean Triangular PDF Micro-Dither (`0.5 LSB` at 8-bit depth) to eliminate sky/gradient banding on social media encoders.
- **Real-Time 60fps Metal Preview (`VideoPlayerView.swift`)**:
  - `MTKView` + `AVPlayerItemVideoOutput` zero-copy rendering with interactive **Split-Screen Before/After Wipe** and **Tap-and-Hold Bypass**.
- **Social Media Master Exporter (`VideoExporter.swift`)**:
  - Offline frame-accurate `AVAssetReader` + `AVAssetWriter` pipeline with `AsyncThrowingStream<Float>` progress.
  - H.264 High Profile Level 4.2, explicit `ITU_R_709_2` Color Primaries / Transfer / Matrix tags, macroblock-even dimensions (`1080x1920`, `1080x1350`, `1080x1080`), and Constant Frame Rate (CFR `14 Mbps` @ 30fps, `20 Mbps` @ 60fps).
- **UI/UX System (`@samios` & `antislop`)**:
  - 90% iOS 26 Kit components + 10% `@samdesain` Utilitarian Swiss Minimalist fallback (`DESIGN.md`).
  - Interactive browser prototype in `prototype/index.html` with iPhone, iPad, and Mac workspace modes.

## Repository Structure

```text
├── DESIGN.md
├── Package.swift
├── apple_ecosystem_video_color_grading_master_prompt.md
├── prototype/
│   ├── index.html
│   └── sample_kodak_2383.cube
└── Sources/
    └── ColorDisco/
        ├── ColorDiscoApp.swift
        ├── ColorGradingEngine.swift
        ├── ColorGradingShaders.metal
        ├── ContentView.swift
        ├── LUTParser.swift
        ├── VideoExporter.swift
        └── VideoPlayerView.swift
```
