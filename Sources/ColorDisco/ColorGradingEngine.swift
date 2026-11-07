import Foundation
import Observation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import AVFoundation

public struct ColorWheelVector: Sendable, Equatable {
    /// Chromatic offset on the color wheel in normalized range [-1.0, 1.0].
    public var redOffset: Float
    public var greenOffset: Float
    public var blueOffset: Float
    /// Master luminance offset for the tonal zone in range [-0.5, 0.5].
    public var masterLuma: Float

    public init(
        redOffset: Float = 0.0,
        greenOffset: Float = 0.0,
        blueOffset: Float = 0.0,
        masterLuma: Float = 0.0
    ) {
        self.redOffset = redOffset
        self.greenOffset = greenOffset
        self.blueOffset = blueOffset
        self.masterLuma = masterLuma
    }

    public var isIdentity: Bool {
        abs(redOffset) < 0.0001 &&
        abs(greenOffset) < 0.0001 &&
        abs(blueOffset) < 0.0001 &&
        abs(masterLuma) < 0.0001
    }
}

public struct GradingParameters: Sendable, Equatable {
    public var exposure: Float = 0.0              // EV: -3.0 ... +3.0
    public var contrast: Float = 1.0              // Multiplier: 0.5 ... 1.5
    public var temperature: Float = 6500.0        // Kelvin: 3000 ... 10000
    public var tint: Float = 0.0                  // Green/Magenta: -100 ... +100
    public var saturation: Float = 1.0            // Multiplier: 0.0 ... 2.0
    public var vibrance: Float = 0.0              // Skin-safe boost: -1.0 ... +1.0
    public var lift: ColorWheelVector = ColorWheelVector()
    public var gamma: ColorWheelVector = ColorWheelVector()
    public var gain: ColorWheelVector = ColorWheelVector()
    public var selectedLUT: ParsedLUT? = nil
    public var lutIntensity: Float = 1.0          // 0.0 ... 1.0
    public var hdrToSdrTonemapEnabled: Bool = true
    public var antiBandingDitherEnabled: Bool = true
    public var ditherStrengthLSB: Float = 0.5     // 0.5 LSB at 8-bit depth
    public var splitComparisonNormalizedX: Float = 1.0 // 1.0 = full graded, 0.5 = 50/50 split
    public var isBypassed: Bool = false

    public init() {}
}

@Observable
@MainActor
public final class ColorGradingEngine {
    public var parameters = GradingParameters()
    public var currentAsset: AVAsset?
    public var currentVideoURL: URL?
    public var sourceIsHDR: Bool = false
    public var videoNaturalSize: CGSize = CGSize(width: 1080, height: 1920)
    public var nominalFrameRate: Float = 60.0
    public var activePreset: StudioLUTPreset = .rec709Natural
    public var customLUTs: [ParsedLUT] = []
    public var statusBannerMessage: String?

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
        statusBannerMessage = "Loaded LUT: \(parsed.title) (\(parsed.dimension)x\(parsed.dimension)x\(parsed.dimension))"
    }

    public func resetAllParameters() {
        let currentLUT = parameters.selectedLUT
        parameters = GradingParameters()
        parameters.selectedLUT = currentLUT
        statusBannerMessage = "Parameters reset to reference neutral"
    }

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

        self.currentVideoURL = url
        self.currentAsset = asset
        self.videoNaturalSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        self.nominalFrameRate = fps > 0 ? fps : 30.0
        self.sourceIsHDR = detectedHDR
    }

    /// Thread-safe, zero-copy CoreImage grading chain invoked from real-time display link or background export queue.
    public nonisolated func processFrame(
        sourceImage: CIImage,
        params: GradingParameters,
        sourceIsHDR: Bool
    ) -> CIImage {
        if params.isBypassed {
            return sourceImage
        }

        let extent = sourceImage.extent
        var working = sourceImage

        // Stage 1: Color Space Ingest & HDR (PQ/HLG) to Rec.709 100-nit SDR Tonemapping
        if sourceIsHDR && params.hdrToSdrTonemapEnabled {
            working = Self.applyHDRToSDRTonemap(to: working)
        }

        // Stage 2: Exposure & S-Curve Contrast
        if abs(params.exposure) > 0.001 {
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = working
            exposureFilter.ev = params.exposure
            if let out = exposureFilter.outputImage {
                working = out
            }
        }

        if abs(params.contrast - 1.0) > 0.001 {
            working = Self.applySCurveContrast(to: working, contrast: params.contrast)
        }

        // Stage 3: White Balance (Temperature & Tint)
        if abs(params.temperature - 6500.0) > 1.0 || abs(params.tint) > 0.5 {
            let tempFilter = CIFilter.temperatureAndTint()
            tempFilter.inputImage = working
            tempFilter.neutral = CIVector(x: CGFloat(params.temperature), y: CGFloat(params.tint))
            tempFilter.targetNeutral = CIVector(x: 6500, y: 0)
            if let out = tempFilter.outputImage {
                working = out
            }
        }

        // Stage 4: 3-Way Color Wheels (Lift / Gamma / Gain)
        if !params.lift.isIdentity || !params.gamma.isIdentity || !params.gain.isIdentity {
            working = Self.applyThreeWayWheels(
                to: working,
                lift: params.lift,
                gamma: params.gamma,
                gain: params.gain
            )
        }

        // Stage 5: 3D LUT Application (CIColorCubeWithColorSpace) + Intensity Blend
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

        // Stage 6: Skin-Safe Vibrance & Saturation
        if abs(params.vibrance) > 0.001 {
            let vibranceFilter = CIFilter.vibrance()
            vibranceFilter.inputImage = working
            vibranceFilter.amount = params.vibrance
            if let out = vibranceFilter.outputImage {
                working = out
            }
        }

        if abs(params.saturation - 1.0) > 0.001 {
            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = working
            colorControls.saturation = params.saturation
            colorControls.brightness = 0.0
            colorControls.contrast = 1.0
            if let out = colorControls.outputImage {
                working = out
            }
        }

        // Stage 7: Anti-Banding Triangular PDF Micro-Dither (0.5 LSB at 8-bit depth)
        if params.antiBandingDitherEnabled && params.ditherStrengthLSB > 0.01 {
            working = Self.applyTriangularPDFMicroDither(
                to: working,
                extent: extent,
                lsbAmplitude: params.ditherStrengthLSB
            )
        }

        // Interactive Split-Screen Before/After Wipe
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

    // MARK: - Mathematical Color Operators

    private nonisolated static func applyHDRToSDRTonemap(to image: CIImage) -> CIImage {
        // Compress PQ/HLG highlight roll-off above 0.75 into Rec.709 100-nit ceiling using Reinhard-style knee.
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

    private nonisolated static func applyThreeWayWheels(
        to image: CIImage,
        lift: ColorWheelVector,
        gamma: ColorWheelVector,
        gain: ColorWheelVector
    ) -> CIImage {
        // Lift shifts shadow floor (bias), Gain scales highlight ceiling (slope), Gamma adjusts midtone power.
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
        // 0.5 LSB at 8-bit (1 / 255 = 0.0039215) prevents 8-bit H.264 quantization banding in sky/wall gradients.
        let amplitude = CGFloat((lsbAmplitude / 255.0) * 0.85)
        let randomGen = CIFilter.randomGenerator()
        guard let noiseA = randomGen.outputImage?.cropped(to: extent),
              let noiseB = randomGen.outputImage?
                .transformed(by: CGAffineTransform(translationX: 37.0, y: 73.0))
                .cropped(to: extent) else {
            return image
        }

        // Sum of two uniform random variables minus 1 yields a zero-mean Triangular PDF distribution.
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

