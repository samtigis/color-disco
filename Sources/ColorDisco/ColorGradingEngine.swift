import Foundation
import Observation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import AVFoundation
import Accelerate

public struct ScopeTelemetrySnapshot: Sendable, Equatable {
    /// 64 columns of [minIRE, avgIRE, maxIRE] in [0, 1] for Luma/RGB Waveform.
    public var waveformColumns: [SIMD3<Float>]
    /// 64 sampled (Cb, Cr) chromaticity coordinates in [-0.5, 0.5] for the Polar Vectorscope.
    public var vectorscopePoints: [SIMD2<Float>]
    /// 32-bin normalized histograms for Red, Green, Blue, and Luma in [0, 1].
    public var redHistogram: [Float]
    public var greenHistogram: [Float]
    public var blueHistogram: [Float]
    public var lumaHistogram: [Float]

    public init(
        waveformColumns: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0.15, 0.48, 0.82), count: 64),
        vectorscopePoints: [SIMD2<Float>] = [],
        redHistogram: [Float] = Array(repeating: 0.25, count: 32),
        greenHistogram: [Float] = Array(repeating: 0.25, count: 32),
        blueHistogram: [Float] = Array(repeating: 0.25, count: 32),
        lumaHistogram: [Float] = Array(repeating: 0.25, count: 32)
    ) {
        self.waveformColumns = waveformColumns
        self.vectorscopePoints = vectorscopePoints
        self.redHistogram = redHistogram
        self.greenHistogram = greenHistogram
        self.blueHistogram = blueHistogram
        self.lumaHistogram = lumaHistogram
    }
}

@Observable
@MainActor
public final class ColorGradingEngine {
    public var parameters = GradingParameters()
    public var activeMediaKind: MediaItemKind = .video

    // Video State
    public var currentAsset: AVAsset?
    public var currentVideoURL: URL?
    public var sourceIsHDR: Bool = false
    public var videoNaturalSize: CGSize = CGSize(width: 1080, height: 1920)
    public var nominalFrameRate: Float = 60.0

    // Still Photography State (ProRAW / DNG / HEIC / JPEG / PNG)
    public var currentPhotoImage: CIImage?
    public var currentPhotoURL: URL?
    public var isProRAWPhoto: Bool = false

    // LUTs, Presets & Clipboard State
    public var activePreset: StudioLUTPreset = .rec709Natural
    public var customLUTs: [ParsedLUT] = []
    public var savedPresets: [GradingParameters] = []
    public var copiedGradeClipboard: GradingParameters?
    public var statusBannerMessage: String?

    // Real-time GPU/Accelerate Scopes Telemetry
    public var scopeTelemetry = ScopeTelemetrySnapshot()

    public nonisolated let metalDevice: MTLDevice
    public nonisolated let ciContext: CIContext
    public nonisolated let workingColorSpace: CGColorSpace
    public nonisolated let outputColorSpace: CGColorSpace

    public init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal hardware acceleration is required for ColorDisco.")
        }
        self.metalDevice = device

        let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rec709 = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        self.workingColorSpace = linearSRGB
        self.outputColorSpace = rec709

        self.ciContext = CIContext(
            mtlDevice: device,
            options: [
                .workingColorSpace: linearSRGB,
                .outputColorSpace: rec709,
                .WorkingFormat: CIFormat.RGBAh,
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ]
        )

        let defaultLUT = LUTParser.generateBuiltInLUT(preset: .rec709Natural)
        self.parameters.selectedLUT = defaultLUT
    }

    // MARK: - LUT & Grade Management (Copy / Paste / Save JSON Presets)

    public func selectStudioPreset(_ preset: StudioLUTPreset) {
        activePreset = preset
        parameters.selectedLUT = LUTParser.generateBuiltInLUT(preset: preset)
        statusBannerMessage = "Applied \(preset.rawValue)"
    }

    public func importLUTFile(from url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let parsed: ParsedLUT
        if ext == "cube" {
            parsed = try LUTParser.parseCubeFile(at: url)
        } else if ext == "png" {
            parsed = try LUTParser.parseHaldPNG(at: url)
        } else {
            throw LUTParserError.unreadableTextEncoding
        }
        customLUTs.append(parsed)
        parameters.selectedLUT = parsed
        statusBannerMessage = "Loaded LUT: \(parsed.title) (\(parsed.dimension)^3)"
    }

    public func copyGradeToClipboard() {
        copiedGradeClipboard = parameters
        statusBannerMessage = "Copied Grade Recipe to Clipboard"
    }

    public func pasteGradeFromClipboard() {
        guard let copied = copiedGradeClipboard else {
            statusBannerMessage = "Clipboard is empty"
            return
        }
        let splitX = parameters.splitComparisonNormalizedX
        parameters = copied
        parameters.splitComparisonNormalizedX = splitX
        statusBannerMessage = "Pasted Grade Recipe"
    }

    public func saveCurrentPreset(named name: String) {
        var copy = parameters
        copy.presetName = name.isEmpty ? "Studio Grade \(savedPresets.count + 1)" : name
        savedPresets.append(copy)
        statusBannerMessage = "Saved Preset: \(copy.presetName)"
    }

    public func exportGradeRecipeJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(parameters)
    }

    public func importGradeRecipeJSON(_ data: Data) throws {
        let decoded = try JSONDecoder().decode(GradingParameters.self, from: data)
        parameters = decoded
        statusBannerMessage = "Imported Recipe: \(decoded.presetName)"
    }

    public func resetAllParameters() {
        let currentLUT = parameters.selectedLUT
        parameters = GradingParameters()
        parameters.selectedLUT = currentLUT
        statusBannerMessage = "Parameters reset to reference neutral"
    }

    // MARK: - Dual Media Ingest (Video & Still Photo ProRAW / DNG / HEIC / JPEG)

    public func loadVideoAsset(from url: URL) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { return }

        let size = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedSize = size.applying(transform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)

        var detectedHDR = false
        for desc in formatDescriptions {
            if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
               let transferFunc = extensions[kCVImageBufferTransferFunctionKey as String] as? String {
                if transferFunc == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) ||
                   transferFunc == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                    detectedHDR = true
                }
            }
        }

        self.activeMediaKind = .video
        self.currentVideoURL = url
        self.currentAsset = asset
        self.videoNaturalSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        self.nominalFrameRate = fps > 0 ? fps : 30.0
        self.sourceIsHDR = detectedHDR
        self.statusBannerMessage = "Loaded Video (\(Int(videoNaturalSize.width))x\(Int(videoNaturalSize.height)))"
    }

    /// Decodes Apple ProRAW / DNG (via `CIRAWFilter`), HEIC, PNG, or JPEG into full-precision float `CIImage`.
    public func loadPhotoAsset(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let ext = url.pathExtension.lowercased()
        let rawExtensions: Set<String> = ["dng", "raw", "cr2", "cr3", "nef", "arw"]

        if rawExtensions.contains(ext),
           let rawFilter = CIRAWFilter(imageURL: url) {
            rawFilter.isDraftModeEnabled = false
            rawFilter.localToneMapAmount = 0.0 // Preserve full linear latitude for manual grading
            if let rawOutput = rawFilter.outputImage {
                self.currentPhotoImage = rawOutput
                self.currentPhotoURL = url
                self.isProRAWPhoto = true
                self.activeMediaKind = .photo
                self.videoNaturalSize = rawOutput.extent.size
                self.statusBannerMessage = "Loaded ProRAW/DNG (\(Int(rawOutput.extent.width))x\(Int(rawOutput.extent.height)))"
                return
            }
        }

        guard let ciImg = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw LUTParserError.fileNotFound
        }

        self.currentPhotoImage = ciImg
        self.currentPhotoURL = url
        self.isProRAWPhoto = false
        self.activeMediaKind = .photo
        self.videoNaturalSize = ciImg.extent.size
        self.statusBannerMessage = "Loaded Photo (\(Int(ciImg.extent.width))x\(Int(ciImg.extent.height)))"
    }

    // MARK: - Complete 8-Stage Deterministic Color Pipeline (Video & Photo)

    public nonisolated func processFrame(
        sourceImage: CIImage,
        params: GradingParameters,
        sourceIsHDR: Bool,
        frameIndex: Int = 0
    ) -> CIImage {
        if params.isBypassed {
            return sourceImage
        }

        let extent = sourceImage.extent
        var working = sourceImage

        // Stage 1: Input Normalization (Apple Log to Rec.709 & HDR10/Dolby Vision to Rec.709 SDR)
        if params.basics.appleLogToRec709Enabled {
            working = Self.applyAppleLogToRec709(to: working)
        }
        if sourceIsHDR && params.basics.hdrToSdrTonemapEnabled {
            working = Self.applyHDRToSDRTonemap(to: working)
        }

        // Stage 2: Primary Grading (Exposure, Contrast, S-Curve, WB Temp/Tint, Highlights/Shadows/Whites/Blacks)
        if abs(params.basics.exposure) > 0.001 {
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = working
            exposureFilter.ev = params.basics.exposure
            if let out = exposureFilter.outputImage {
                working = out
            }
        }

        if abs(params.basics.contrast - 1.0) > 0.001 || params.basics.sCurveContrast > 0.001 {
            let combinedContrast = params.basics.contrast + params.basics.sCurveContrast * 0.35
            working = Self.applySCurveContrast(to: working, contrast: combinedContrast)
        }

        if abs(params.basics.temperature - 6500.0) > 1.0 || abs(params.basics.tint) > 0.5 {
            let tempFilter = CIFilter.temperatureAndTint()
            tempFilter.inputImage = working
            tempFilter.neutral = CIVector(x: CGFloat(params.basics.temperature), y: CGFloat(params.basics.tint))
            tempFilter.targetNeutral = CIVector(x: 6500, y: 0)
            if let out = tempFilter.outputImage {
                working = out
            }
        }

        if abs(params.basics.highlights) > 0.001 || abs(params.basics.shadows) > 0.001 {
            let hsFilter = CIFilter.highlightShadowAdjust()
            hsFilter.inputImage = working
            hsFilter.highlightAmount = 1.0 - params.basics.highlights * 0.5
            hsFilter.shadowAmount = params.basics.shadows * 0.75
            if let out = hsFilter.outputImage {
                working = out
            }
        }

        if abs(params.basics.whites) > 0.001 || abs(params.basics.blacks) > 0.001 {
            working = Self.applyWhitesAndBlacks(
                to: working,
                whites: params.basics.whites,
                blacks: params.basics.blacks
            )
        }

        // Stage 3: 4-Channel Parametric Tone Curves (Master Luma, Red, Green, Blue)
        if !params.curves.isIdentity {
            working = Self.applyFourChannelToneCurves(to: working, curves: params.curves)
        }

        // Stage 4: Secondary 8-Channel HSL Warper + Skin Tone Protection Lock
        if params.hasActiveHSL {
            working = Self.applyEightChannelHSL(
                to: working,
                segments: params.hslSegments,
                protectSkin: params.skinToneProtectionLock,
                colorSpace: outputColorSpace
            )
        }

        // Stage 5: 3D LUT Ingestion (CIColorCubeWithColorSpace) + Dynamic Opacity Blending
        if let lut = params.selectedLUT, params.lutIntensity > 0.001 {
            if let cubeFilter = CIFilter(
                name: "CIColorCubeWithColorSpace",
                parameters: [
                    "inputImage": working,
                    "inputCubeDimension": lut.dimension,
                    "inputCubeData": lut.cubeData,
                    "inputColorSpace": outputColorSpace
                ]
            ), let lutOutput = cubeFilter.outputImage {
                if params.lutIntensity >= 0.999 {
                    working = lutOutput
                } else {
                    working = Self.blendImages(
                        original: working,
                        graded: lutOutput,
                        intensity: params.lutIntensity
                    )
                }
            }
        }

        // Stage 6: Three-Way Color Wheels (Lift, Gamma, Gain) + Vibrance & Saturation
        if !params.wheels.isIdentity {
            working = Self.applyThreeWayWheels(
                to: working,
                lift: params.wheels.lift,
                gamma: params.wheels.gamma,
                gain: params.wheels.gain
            )
        }

        if abs(params.basics.vibrance) > 0.001 {
            let vibranceFilter = CIFilter.vibrance()
            vibranceFilter.inputImage = working
            vibranceFilter.amount = params.basics.vibrance
            if let out = vibranceFilter.outputImage {
                working = out
            }
        }

        if abs(params.basics.saturation - 1.0) > 0.001 {
            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = working
            colorControls.saturation = params.basics.saturation
            colorControls.brightness = 0.0
            colorControls.contrast = 1.0
            if let out = colorControls.outputImage {
                working = out
            }
        }

        // Stage 7: Film Emulation Engine (Halation & Dynamic Procedural Film Grain)
        if params.film.hasHalation {
            working = Self.applyFilmHalation(
                to: working,
                extent: extent,
                intensity: params.film.halationIntensity,
                threshold: params.film.halationThreshold,
                radius: params.film.halationRadius
            )
        }

        if params.film.hasGrain {
            working = Self.applyProceduralFilmGrain(
                to: working,
                extent: extent,
                intensity: params.film.grainIntensity,
                size: params.film.grainSize,
                roughness: params.film.grainRoughness,
                frameSeed: Float(frameIndex)
            )
        }

        // Stage 8: Anti-Banding Micro-Dither Guard (0.5 LSB Triangular PDF)
        if params.antiBandingDitherEnabled && params.ditherStrengthLSB > 0.01 {
            working = Self.applyTriangularPDFMicroDither(
                to: working,
                extent: extent,
                lsbAmplitude: params.ditherStrengthLSB
            )
        }

        // Interactive Vertical A/B Split-Screen Wipe
        let splitX = min(max(params.splitComparisonNormalizedX, 0.0), 1.0)
        if splitX < 0.999 {
            let splitPosition = extent.minX + extent.width * CGFloat(splitX)
            let leftCropRect = CGRect(
                x: extent.minX,
                y: extent.minY,
                width: max(0, splitPosition - extent.minX),
                height: extent.height
            )
            let croppedGraded = working.cropped(to: leftCropRect)
            working = croppedGraded.composited(over: sourceImage)
        }

        return working.cropped(to: extent)
    }

    // MARK: - Real-Time Waveform, Vectorscope & Histogram Extraction (Accelerate / vImage)

    public nonisolated func computeScopesSnapshot(from image: CIImage) -> ScopeTelemetrySnapshot {
        let sampleWidth = 64
        let sampleHeight = 36
        let extent = image.extent
        guard extent.width > 0 && extent.height > 0 else {
            return ScopeTelemetrySnapshot()
        }

        let scaleX = CGFloat(sampleWidth) / extent.width
        let scaleY = CGFloat(sampleHeight) / extent.height
        let thumb = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var rgbaBytes = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        ciContext.render(
            thumb,
            toBitmap: &rgbaBytes,
            rowBytes: sampleWidth * 4,
            bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight),
            format: .RGBA8,
            colorSpace: outputColorSpace
        )

        var waveformCols = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: sampleWidth)
        var vectorPoints: [SIMD2<Float>] = []
        vectorPoints.reserveCapacity(64)

        var rBins = [Float](repeating: 0, count: 32)
        var gBins = [Float](repeating: 0, count: 32)
        var bBins = [Float](repeating: 0, count: 32)
        var yBins = [Float](repeating: 0, count: 32)

        let inv255: Float = 1.0 / 255.0

        for x in 0..<sampleWidth {
            var minL: Float = 1.0
            var maxL: Float = 0.0
            var sumL: Float = 0.0

            for y in 0..<sampleHeight {
                let idx = (y * sampleWidth + x) * 4
                let r = Float(rgbaBytes[idx + 0]) * inv255
                let g = Float(rgbaBytes[idx + 1]) * inv255
                let b = Float(rgbaBytes[idx + 2]) * inv255
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                minL = min(minL, luma)
                maxL = max(maxL, luma)
                sumL += luma

                let rIdx = min(Int(r * 31.0), 31)
                let gIdx = min(Int(g * 31.0), 31)
                let bIdx = min(Int(b * 31.0), 31)
                let yIdx = min(Int(luma * 31.0), 31)
                rBins[rIdx] += 1
                gBins[gIdx] += 1
                bBins[bIdx] += 1
                yBins[yIdx] += 1

                if (x % 4 == 0) && (y % 4 == 0) && vectorPoints.count < 64 {
                    let cb = -0.1146 * r - 0.3854 * g + 0.5000 * b
                    let cr =  0.5000 * r - 0.4542 * g - 0.0458 * b
                    vectorPoints.append(SIMD2<Float>(cb, cr))
                }
            }

            waveformCols[x] = SIMD3<Float>(minL, sumL / Float(sampleHeight), maxL)
        }

        let normHist: ([Float]) -> [Float] = { bins in
            let peak = max(bins.max() ?? 1.0, 1.0)
            return bins.map { $0 / peak }
        }

        return ScopeTelemetrySnapshot(
            waveformColumns: waveformCols,
            vectorscopePoints: vectorPoints,
            redHistogram: normHist(rBins),
            greenHistogram: normHist(gBins),
            blueHistogram: normHist(bBins),
            lumaHistogram: normHist(yBins)
        )
    }

    // MARK: - Internal Pipeline Operators

    private nonisolated static func applyAppleLogToRec709(to image: CIImage) -> CIImage {
        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = image
        toneCurve.point0 = CGPoint(x: 0.00, y: 0.00)
        toneCurve.point1 = CGPoint(x: 0.22, y: 0.14)
        toneCurve.point2 = CGPoint(x: 0.48, y: 0.50)
        toneCurve.point3 = CGPoint(x: 0.74, y: 0.84)
        toneCurve.point4 = CGPoint(x: 1.00, y: 0.99)
        let curved = toneCurve.outputImage ?? image

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = curved
        colorControls.saturation = 1.22
        colorControls.contrast = 1.06
        return colorControls.outputImage ?? curved
    }

    private nonisolated static func applyHDRToSDRTonemap(to image: CIImage) -> CIImage {
        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = image
        toneCurve.point0 = CGPoint(x: 0.00, y: 0.00)
        toneCurve.point1 = CGPoint(x: 0.25, y: 0.24)
        toneCurve.point2 = CGPoint(x: 0.50, y: 0.50)
        toneCurve.point3 = CGPoint(x: 0.75, y: 0.73)
        toneCurve.point4 = CGPoint(x: 1.00, y: 0.96)
        return toneCurve.outputImage ?? image
    }

    private nonisolated static func applySCurveContrast(to image: CIImage, contrast: Float) -> CIImage {
        let delta = CGFloat((contrast - 1.0) * 0.14)
        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = image
        toneCurve.point0 = CGPoint(x: 0.00, y: 0.00)
        toneCurve.point1 = CGPoint(x: 0.25, y: min(max(0.25 - delta, 0.02), 0.48))
        toneCurve.point2 = CGPoint(x: 0.50, y: 0.50)
        toneCurve.point3 = CGPoint(x: 0.75, y: min(max(0.75 + delta, 0.52), 0.98))
        toneCurve.point4 = CGPoint(x: 1.00, y: 1.00)
        return toneCurve.outputImage ?? image
    }

    private nonisolated static func applyWhitesAndBlacks(
        to image: CIImage,
        whites: Float,
        blacks: Float
    ) -> CIImage {
        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = image
        toneCurve.point0 = CGPoint(x: 0.00, y: min(max(CGFloat(blacks * 0.15), 0.0), 0.22))
        toneCurve.point1 = CGPoint(x: 0.25, y: min(max(0.25 + CGFloat(blacks * 0.08), 0.05), 0.45))
        toneCurve.point2 = CGPoint(x: 0.50, y: 0.50)
        toneCurve.point3 = CGPoint(x: 0.75, y: min(max(0.75 + CGFloat(whites * 0.08), 0.55), 0.95))
        toneCurve.point4 = CGPoint(x: 1.00, y: min(max(1.00 + CGFloat(whites * 0.15), 0.78), 1.00))
        return toneCurve.outputImage ?? image
    }

    private nonisolated static func applyFourChannelToneCurves(
        to image: CIImage,
        curves: ToneCurvesConfig
    ) -> CIImage {
        var current = image

        if !curves.master.isIdentity {
            let masterFilter = CIFilter.toneCurve()
            masterFilter.inputImage = current
            masterFilter.point0 = CGPoint(x: CGFloat(curves.master.p0.x), y: CGFloat(curves.master.p0.y))
            masterFilter.point1 = CGPoint(x: CGFloat(curves.master.p1.x), y: CGFloat(curves.master.p1.y))
            masterFilter.point2 = CGPoint(x: CGFloat(curves.master.p2.x), y: CGFloat(curves.master.p2.y))
            masterFilter.point3 = CGPoint(x: CGFloat(curves.master.p3.x), y: CGFloat(curves.master.p3.y))
            masterFilter.point4 = CGPoint(x: CGFloat(curves.master.p4.x), y: CGFloat(curves.master.p4.y))
            current = masterFilter.outputImage ?? current
        }

        // Per-channel R, G, B midpoint/endpoint offsets via polynomial curve
        if !curves.red.isIdentity || !curves.green.isIdentity || !curves.blue.isIdentity {
            let rMidDelta = CGFloat(curves.red.p2.y - 0.5) * 1.4
            let gMidDelta = CGFloat(curves.green.p2.y - 0.5) * 1.4
            let bMidDelta = CGFloat(curves.blue.p2.y - 0.5) * 1.4

            let rLift = CGFloat(curves.red.p0.y)
            let gLift = CGFloat(curves.green.p0.y)
            let bLift = CGFloat(curves.blue.p0.y)

            let rGain = CGFloat(curves.red.p4.y)
            let gGain = CGFloat(curves.green.p4.y)
            let bGain = CGFloat(curves.blue.p4.y)

            if let poly = CIFilter(
                name: "CIColorPolynomial",
                parameters: [
                    "inputImage": current,
                    "inputRedCoefficients": CIVector(x: rLift, y: rGain - rLift + rMidDelta, z: -rMidDelta, w: 0),
                    "inputGreenCoefficients": CIVector(x: gLift, y: gGain - gLift + gMidDelta, z: -gMidDelta, w: 0),
                    "inputBlueCoefficients": CIVector(x: bLift, y: bGain - bLift + bMidDelta, z: -bMidDelta, w: 0)
                ]
            ), let out = poly.outputImage {
                current = out
            }
        }

        return current
    }

    private nonisolated static func applyEightChannelHSL(
        to image: CIImage,
        segments: [HSLChannel: HSLSegment],
        protectSkin: Bool,
        colorSpace: CGColorSpace
    ) -> CIImage {
        let dim = 16
        let total = dim * dim * dim
        var cube = [Float](repeating: 1.0, count: total * 4)
        let denom = Float(dim - 1)
        var offset = 0

        for bIdx in 0..<dim {
            let b = Float(bIdx) / denom
            for gIdx in 0..<dim {
                let g = Float(gIdx) / denom
                for rIdx in 0..<dim {
                    let r = Float(rIdx) / denom
                    let (h, s, l) = rgbToHSL(r: r, g: g, b: b)

                    var dHue: Float = 0.0
                    var dSat: Float = 0.0
                    var dLum: Float = 0.0

                    for channel in HSLChannel.allCases {
                        guard let seg = segments[channel], !seg.isIdentity else { continue }
                        var dist = abs(h - channel.centerHue)
                        dist = min(dist, 1.0 - dist)
                        let weight = exp(-(dist * dist) / (2.0 * 0.055 * 0.055)) * min(max(s * 2.0, 0.0), 1.0)
                        dHue += seg.hueShift * 0.14 * weight
                        dSat += seg.saturation * weight
                        dLum += seg.luminance * 0.25 * weight
                    }

                    if protectSkin {
                        var skinDist = abs(h - 0.078)
                        skinDist = min(skinDist, 1.0 - skinDist)
                        let skinMask = exp(-(skinDist * skinDist) / (2.0 * 0.042 * 0.042))
                        let attenuation = 1.0 - skinMask * 0.78
                        dHue *= attenuation
                        dSat *= attenuation
                    }

                    var newH = (h + dHue).truncatingRemainder(dividingBy: 1.0)
                    if newH < 0 { newH += 1.0 }
                    let newS = min(max(s * (1.0 + dSat), 0.0), 1.0)
                    let newL = min(max(l + dLum, 0.0), 1.0)

                    let (ro, go, bo) = hslToRGB(h: newH, s: newS, l: newL)
                    cube[offset + 0] = ro
                    cube[offset + 1] = go
                    cube[offset + 2] = bo
                    cube[offset + 3] = 1.0
                    offset += 4
                }
            }
        }

        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let filter = CIFilter(
            name: "CIColorCubeWithColorSpace",
            parameters: [
                "inputImage": image,
                "inputCubeDimension": dim,
                "inputCubeData": data,
                "inputColorSpace": colorSpace
            ]
        ), let out = filter.outputImage else {
            return image
        }
        return out
    }

    private nonisolated static func rgbToHSL(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let l = (maxC + minC) * 0.5
        let d = maxC - minC
        if d < 1e-5 { return (0.0, 0.0, l) }
        let s = (l > 0.5) ? (d / max(2.0 - maxC - minC, 1e-5)) : (d / max(maxC + minC, 1e-5))
        var h: Float = 0.0
        if maxC == r {
            h = (g - b) / d + (g < b ? 6.0 : 0.0)
        } else if maxC == g {
            h = (b - r) / d + 2.0
        } else {
            h = (r - g) / d + 4.0
        }
        return (h / 6.0, s, l)
    }

    private nonisolated static func hslToRGB(h: Float, s: Float, l: Float) -> (Float, Float, Float) {
        if s < 1e-5 { return (l, l, l) }
        let q = (l < 0.5) ? (l * (1.0 + s)) : (l + s - l * s)
        let p = 2.0 * l - q
        func hue2rgb(_ p: Float, _ q: Float, _ tIn: Float) -> Float {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
            return p
        }
        return (
            min(max(hue2rgb(p, q, h + 1.0 / 3.0), 0.0), 1.0),
            min(max(hue2rgb(p, q, h), 0.0), 1.0),
            min(max(hue2rgb(p, q, h - 1.0 / 3.0), 0.0), 1.0)
        )
    }

    private nonisolated static func applyThreeWayWheels(
        to image: CIImage,
        lift: ColorWheelVector,
        gamma: ColorWheelVector,
        gain: ColorWheelVector
    ) -> CIImage {
        var current = image

        let rSlope = CGFloat(max(0.1, 1.0 + gain.redOffset + gain.masterLuma - lift.redOffset * 0.5))
        let gSlope = CGFloat(max(0.1, 1.0 + gain.greenOffset + gain.masterLuma - lift.greenOffset * 0.5))
        let bSlope = CGFloat(max(0.1, 1.0 + gain.blueOffset + gain.masterLuma - lift.blueOffset * 0.5))

        let rBias = CGFloat((lift.redOffset + lift.masterLuma) * 0.18)
        let gBias = CGFloat((lift.greenOffset + lift.masterLuma) * 0.18)
        let bBias = CGFloat((lift.blueOffset + lift.masterLuma) * 0.18)

        let matrixFilter = CIFilter.colorMatrix()
        matrixFilter.inputImage = current
        matrixFilter.rVector = CIVector(x: rSlope, y: 0, z: 0, w: 0)
        matrixFilter.gVector = CIVector(x: 0, y: gSlope, z: 0, w: 0)
        matrixFilter.bVector = CIVector(x: 0, y: 0, z: bSlope, w: 0)
        matrixFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrixFilter.biasVector = CIVector(x: rBias, y: gBias, z: bBias, w: 0)
        if let out = matrixFilter.outputImage {
            current = out
        }

        if !gamma.isIdentity {
            let gammaR = CGFloat(max(0.25, 1.0 - (gamma.redOffset + gamma.masterLuma) * 0.65))
            let gammaG = CGFloat(max(0.25, 1.0 - (gamma.greenOffset + gamma.masterLuma) * 0.65))
            let gammaB = CGFloat(max(0.25, 1.0 - (gamma.blueOffset + gamma.masterLuma) * 0.65))

            if let polyFilter = CIFilter(
                name: "CIColorPolynomial",
                parameters: [
                    "inputImage": current,
                    "inputRedCoefficients": CIVector(x: 0, y: 1.0 / gammaR, z: 1.0 - (1.0 / gammaR), w: 0),
                    "inputGreenCoefficients": CIVector(x: 0, y: 1.0 / gammaG, z: 1.0 - (1.0 / gammaG), w: 0),
                    "inputBlueCoefficients": CIVector(x: 0, y: 1.0 / gammaB, z: 1.0 - (1.0 / gammaB), w: 0)
                ]
            ), let out = polyFilter.outputImage {
                current = out
            }
        }

        return current
    }

    private nonisolated static func applyFilmHalation(
        to image: CIImage,
        extent: CGRect,
        intensity: Float,
        threshold: Float,
        radius: Float
    ) -> CIImage {
        // Isolate bright specular highlights, tint warm red-orange, Gaussian blur, and screen-add
        let clampMatrix = CIFilter.colorMatrix()
        clampMatrix.inputImage = image
        let scale = CGFloat(max(0.0, intensity * 0.55))
        let bias = CGFloat(-threshold * intensity * 0.40)
        clampMatrix.rVector = CIVector(x: scale * 1.15, y: 0, z: 0, w: 0)
        clampMatrix.gVector = CIVector(x: 0, y: scale * 0.32, z: 0, w: 0)
        clampMatrix.bVector = CIVector(x: 0, y: 0, z: scale * 0.06, w: 0)
        clampMatrix.biasVector = CIVector(x: bias, y: bias * 0.3, z: 0, w: 0)

        guard let warmHighlights = clampMatrix.outputImage?.clampedToExtent() else {
            return image
        }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = warmHighlights
        blur.radius = radius
        guard let blurredHalo = blur.outputImage?.cropped(to: extent) else {
            return image
        }

        let add = CIFilter.additionCompositing()
        add.inputImage = blurredHalo
        add.backgroundImage = image
        return add.outputImage?.cropped(to: extent) ?? image
    }

    private nonisolated static func applyProceduralFilmGrain(
        to image: CIImage,
        extent: CGRect,
        intensity: Float,
        size: Float,
        roughness: Float,
        frameSeed: Float
    ) -> CIImage {
        let randomGen = CIFilter.randomGenerator()
        let seedShiftX = CGFloat((frameSeed * 37.0).truncatingRemainder(dividingBy: 512.0))
        let seedShiftY = CGFloat((frameSeed * 73.0).truncatingRemainder(dividingBy: 512.0))
        let grainScale = CGFloat(max(0.5, size))

        guard let rawNoise = randomGen.outputImage?
            .transformed(by: CGAffineTransform(translationX: seedShiftX, y: seedShiftY))
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .cropped(to: extent) else {
            return image
        }

        let amp = CGFloat(intensity * (0.06 + roughness * 0.06))
        let monoMatrix = CIFilter.colorMatrix()
        monoMatrix.inputImage = rawNoise
        monoMatrix.rVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        monoMatrix.gVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        monoMatrix.bVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        monoMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        monoMatrix.biasVector = CIVector(x: -amp * 0.5, y: -amp * 0.5, z: -amp * 0.5, w: 0)

        guard let filmNoise = monoMatrix.outputImage?.cropped(to: extent) else {
            return image
        }

        let add = CIFilter.additionCompositing()
        add.inputImage = filmNoise
        add.backgroundImage = image
        return add.outputImage?.cropped(to: extent) ?? image
    }

    private nonisolated static func blendImages(
        original: CIImage,
        graded: CIImage,
        intensity: Float
    ) -> CIImage {
        let alpha = CGFloat(min(max(intensity, 0.0), 1.0))
        let alphaMatrix = CIFilter.colorMatrix()
        alphaMatrix.inputImage = graded
        alphaMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
        guard let weightedGraded = alphaMatrix.outputImage else { return graded }
        return weightedGraded.composited(over: original)
    }

    private nonisolated static func applyTriangularPDFMicroDither(
        to image: CIImage,
        extent: CGRect,
        lsbAmplitude: Float
    ) -> CIImage {
        let amplitude = CGFloat((lsbAmplitude / 255.0) * 0.85)
        let randomGen = CIFilter.randomGenerator()
        guard let noiseA = randomGen.outputImage?.cropped(to: extent),
              let noiseB = randomGen.outputImage?
                .transformed(by: CGAffineTransform(translationX: 37.0, y: 73.0))
                .cropped(to: extent) else {
            return image
        }

        let addFilter = CIFilter.additionCompositing()
        addFilter.inputImage = noiseA
        addFilter.backgroundImage = noiseB
        guard let combinedNoise = addFilter.outputImage else { return image }

        let scaleMatrix = CIFilter.colorMatrix()
        scaleMatrix.inputImage = combinedNoise
        scaleMatrix.rVector = CIVector(x: amplitude, y: 0, z: 0, w: 0)
        scaleMatrix.gVector = CIVector(x: 0, y: amplitude, z: 0, w: 0)
        scaleMatrix.bVector = CIVector(x: 0, y: 0, z: amplitude, w: 0)
        scaleMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        scaleMatrix.biasVector = CIVector(x: -amplitude, y: -amplitude, z: -amplitude, w: 0)

        guard let triangularNoise = scaleMatrix.outputImage?.cropped(to: extent) else {
            return image
        }

        let composite = CIFilter.additionCompositing()
        composite.inputImage = triangularNoise
        composite.backgroundImage = image
        return composite.outputImage?.cropped(to: extent) ?? image
    }
}
