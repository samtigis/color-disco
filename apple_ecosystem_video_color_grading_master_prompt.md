# SYSTEM ARCHITECT & CODING PROMPT: PRO VIDEO COLOR GRADER (APPLE ECOSYSTEM)

## 1. MISSION & CONTEXT
You are an Elite Apple Systems Media Engineer, Metal Graphics Specialist, and Senior Swift Developer. Your objective is to build a high-performance, offline-first, professional video color grading application targeting the entire Apple ecosystem: **iOS (iPhone), iPadOS (iPad), and macOS (Mac)** using a single, unified Swift codebase.

The application must deliver studio-grade visual fidelity, zero-lag 60fps real-time preview, support industry-standard **3D LUTs (.cube and identity HALD PNG)**, manual color adjustments (Lift/Gamma/Gain, HSL, Exposure, Saturation, Temperature/Tint), and produce pristine social media exports (Rec. 709 SDR) that **never suffer from crushed blacks, washed-out HDR highlights, or aggressive compression banding** on platforms like Instagram Reels, TikTok, and YouTube Shorts.

---

## 2. CORE ARCHITECTURAL SPECIFICATIONS

### A. Target Platforms & Environment
- **Platforms:** iOS 17.0+, iPadOS 17.0+, macOS 14.0+ (Sonoma/Sequoia).
- **Language & Paradigms:** Swift 5.9+ / Swift 6, Strict Concurrency, Swift Modern Concurrency (`async`/`await`, `actors`).
- **UI Framework:** SwiftUI for unified layout, leveraging adaptive traits (`NavigationSplitView` on iPad/Mac, compact stacks on iPhone).
- **Hardware Acceleration:** Metal (`MetalKit`, `MTKView`, MSL Shaders) & Core Image (`CIContext` backed by shared `MTLDevice`).
- **Media Engine:** AVFoundation (`AVPlayerItemVideoOutput`, `AVAssetReader`, `AVAssetWriter`, `AVVideoComposition`).
- **External Dependencies:** ZERO third-party libraries. All native Apple frameworks (`Metal`, `CoreImage`, `AVFoundation`, `PhotosUI`, `UniformTypeIdentifiers`, `Accelerate`).

### B. Core Grading Engine Architecture
Implement a two-tier color processing pipeline:
1. **Interactive Real-Time Preview (Scrubbing & Playback):**
   - High-throughput display using `AVPlayer` with custom `AVPlayerItemVideoOutput` or custom `AVVideoComposition`.
   - Frames processed as `CVPixelBuffer` -> GPU Metal Texture / `CIImage` -> Rendered on `MTKView` using unified Apple Silicon unified memory.
2. **Offline Master Export Pipeline:**
   - Frame-accurate reading via `AVAssetReader` and streaming write via `AVAssetWriter`.
   - Color grading kernel injected during export using `CIContext` with zero CPU-to-GPU memory copies.
   - Strict color space management: Automatic Tonemapping from HDR (Dolby Vision / HLG) to standard **Rec. 709 SDR**.

---

## 3. COLOR PIPELINE & SHADER SPECIFICATIONS

### A. 3D LUT Parser & Processor (`CIColorCubeWithColorSpace`)
1. **Parser Engine:**
   - Parse `.cube` files (standard Adobe/Resolve format): read `LUT_3D_SIZE N`, parse $N^3$ RGB floating-point triplets, convert into 32-bit floating point memory buffer (`[Float]`).
   - Parse 2D HALD PNG images (e.g., Hald 8 or Hald 16): decode pixel values into a 3D memory buffer structure.
2. **Core Image Filter Application:**
   ```swift
   CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
       "inputCubeDimension": dimension,
       "inputCubeData": cubeData,
       "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!
   ])
   ```

### B. Manual Grading Adjustments Chain
Order of operations in the render chain:
1. **Color Space Ingest:** Normalize input `CIImage` (P3/Rec.2020) to linear working space.
2. **Exposure & Contrast:** `CIExposureAdjust`, custom S-Curve contrast.
3. **White Balance:** Temperature & Tint adjustment via `CITemperatureAndTint`.
4. **Color Wheels (Lift, Gamma, Gain / 3-Way Color Corrector):** Custom Metal shader or mathematically sound Core Image matrix adjustments for Shadows, Midtones, and Highlights.
5. **3D LUT Ingestion:** `CIColorCubeWithColorSpace`.
6. **Vibrance & Saturation:** `CIColorControls` (Vibrance algorithm to preserve human skin tones).
7. **Anti-Banding Micro-Dither:** Apply a subtle triangular PDF dither (0.5 LSB at 8-bit depth) to eliminate posterization and banding artifacts caused by social media encoders.

---

## 4. SOCIAL MEDIA OPTIMIZATION ENGINE (EXPORT MODULE)

The export module MUST guarantee crisp, artifact-free playback on Instagram and TikTok:

### Export Parameter Rules
- **Video Codec:** `AVVideoCodecType.h264` (H.264 High Profile, Level 4.2). Do not output HEVC for social media distribution.
- **Color Profile Flags (Crucial):**
  - Color Primaries: `AVVideoColorPrimaries_ITU_R_709_2`
  - Transfer Function: `AVVideoTransferFunction_ITU_R_709_2`
  - YCbCr Matrix: `AVVideoYCbCrMatrix_ITU_R_709_2`
- **HDR Tonemapping:** If source contains HDR metadata (`kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ` or `kCVImageBufferTransferFunction_ITU_R_2100_HLG`), automatically apply tone curve reduction to map dynamic range into 100 nits Rec. 709.
- **Resolution & Aspect Ratio:**
  - Standard: 1080 x 1920 (9:16 Portrait) or 1080 x 1350 (4:5) or 1080 x 1080 (1:1).
  - Enforce even integer dimensions (divisible by 2) to comply with macroblock alignments.
- **Bitrate Configuration:**
  - 1080p @ 30fps: Average 14,000,000 bps (14 Mbps), Max 16,000,000 bps.
  - 1080p @ 60fps: Average 20,000,000 bps (20 Mbps), Max 24,000,000 bps.
  - Set `AVVideoAverageNonDroppableFrameRateKey` to guarantee **Constant Frame Rate (CFR)**.

---

## 5. UI/UX REQUIREMENTS ACROSS PLATFORMS

### Responsive Layout Strategy:
- **iPhone:** Bottom-sheet control deck with segmented controls (LUTs, Wheels, Sliders), full-screen pinch-to-zoom preview, tap-to-hold before/after comparison.
- **iPad:** Three-column or two-column split view (`NavigationSplitView`). Left: Project/Clips, Center: Large Canvas viewport, Right: Full Inspector with Lift/Gamma/Gain color wheels and LUT browser. Apple Pencil support for scrubbing and fine-tuned slider adjustment.
- **Mac:** Desktop-grade layout with keyboard shortcuts (Space for Play/Pause, `\` for Split Before/After, `Cmd+E` for Export, `J-K-L` scrubbing). Drag-and-drop LUT files (.cube) directly onto the canvas.

---

## 6. COMPLETE IMPLEMENTATION BLUEPRINT

Please implement the solution with clean, modular, production-ready Swift code across the following file structure:

### File 1: `LUTParser.swift`
- A fast, memory-safe parser for `.cube` text files.
- Strips comments, parses size, validates dimensions, and packs `Float32` array into `Data` compatible with `CIColorCubeWithColorSpace`.

### File 2: `ColorGradingEngine.swift`
- An `@Observable` class or actor managing:
  - Video asset loading.
  - Parameters: `exposure`, `contrast`, `saturation`, `temperature`, `tint`, `selectedLUTData`, `lutIntensity`.
  - Core Image filter chaining pipeline.
  - Generates processed `CIImage` per frame.

### File 3: `VideoPlayerView.swift`
- A high-performance MetalKit-backed video renderer (`MTKView` + `CIContext`).
- Smooth playback loop reading pixel buffers via `AVPlayerItemVideoOutput`.
- Split-screen comparison gesture (interactive split bar showing original vs. graded video).

### File 4: `VideoExporter.swift`
- `AVAssetReader` + `AVAssetWriter` asynchronous pipeline.
- Progress reporting (`AsyncStream<Float>`).
- Strict H.264 / Rec. 709 injection ensuring zero quality loss on social networks.

### File 5: `ContentView.swift`
- Adaptive SwiftUI interface dynamically switching layouts between iPhone, iPad, and macOS.
- Integrated sliders, LUT selector, file import picker for videos and `.cube` files, and export sheet.

---

## 7. EXECUTION INSTRUCTION
Generate the complete, runnable code for each file specified above. Adhere strictly to clean architecture, avoid deprecations, handle resource cleanup (especially CVPixelBuffers and Metal textures), and ensure the entire app functions 100% locally and offline without requiring network permissions or external servers.