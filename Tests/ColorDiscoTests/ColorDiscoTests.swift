import XCTest
import CoreImage
import CoreGraphics
@testable import ColorDisco

final class ColorDiscoTests: XCTestCase {

    func testCubeParserValidatesStandardCubeAndDomainScaling() throws {
        let cubeText = """
        # Studio Test Cube
        TITLE "Rec709 Test 2x2x2"
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """

        let parsed = try LUTParser.parseCubeString(cubeText)
        XCTAssertEqual(parsed.title, "Rec709 Test 2x2x2")
        XCTAssertEqual(parsed.dimension, 2)
        // 2^3 * 4 RGBA floats * 4 bytes per Float32 = 128 bytes
        XCTAssertEqual(parsed.cubeData.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
    }

    func testCubeParserSupports65CubedDimensionDeclaration() {
        let invalidHeaderOnly = """
        TITLE "Invalid Count"
        LUT_3D_SIZE 65
        0.0 0.0 0.0
        """
        XCTAssertThrowsError(try LUTParser.parseCubeString(invalidHeaderOnly)) { error in
            guard case LUTParserError.tripletCountMismatch(let expected, let actual) = error else {
                XCTFail("Expected tripletCountMismatch for 65^3, got \(error)")
                return
            }
            XCTAssertEqual(expected, 65 * 65 * 65)
            XCTAssertEqual(actual, 1)
        }
    }

    func testHaldPNGDecoderExtracts3DCubeBuffer() throws {
        // 8 x 8 square image = 64 pixels = 4^3 3D LUT cube
        let width = 8
        let height = 8
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else {
            XCTFail("Could not create test HALD CGImage")
            return
        }

        let parsed = try LUTParser.parseHaldCGImage(cgImage, title: "Identity Hald 4")
        XCTAssertEqual(parsed.dimension, 4)
        XCTAssertEqual(parsed.cubeData.count, 64 * 4 * MemoryLayout<Float>.size)
    }

    func testGradingParametersCodableRoundTripForCopyPasteGrade() throws {
        var params = GradingParameters()
        params.presetName = "Teal & Tungsten ProRAW"
        params.basics.appleLogToRec709Enabled = true
        params.basics.exposure = 0.65
        params.basics.highlights = -0.35
        params.basics.shadows = 0.25
        params.curves.master.p0 = CurveControlPoint(x: 0.0, y: 0.06)
        params.hslSegments[.orange] = HSLSegment(hueShift: 0.04, saturation: 0.12, luminance: 0.08)
        params.skinToneProtectionLock = true
        params.wheels.lift = ColorWheelVector(redOffset: -0.05, greenOffset: 0.0, blueOffset: 0.08, masterLuma: 0.02)
        params.film.halationIntensity = 0.42
        params.film.grainIntensity = 0.28

        let encoded = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(GradingParameters.self, from: encoded)
        XCTAssertEqual(decoded, params)
    }

    func testMacroblockEvenDimensionsOnSocialPresets() {
        for preset in SocialAspectRatioPreset.allCases {
            let size = preset.targetDimensions
            XCTAssertEqual(Int(size.width) % 2, 0, "Width for \(preset.rawValue) must be divisible by 2")
            XCTAssertEqual(Int(size.height) % 2, 0, "Height for \(preset.rawValue) must be divisible by 2")
        }
    }

    @MainActor
    func testEightStagePipelineAndScopesTelemetry() {
        let engine = ColorGradingEngine()
        engine.parameters.basics.appleLogToRec709Enabled = true
        engine.parameters.basics.exposure = 0.35
        engine.parameters.curves.master.p1 = CurveControlPoint(x: 0.25, y: 0.20)
        engine.parameters.hslSegments[.blue] = HSLSegment(hueShift: -0.08, saturation: 0.20, luminance: -0.10)
        engine.parameters.wheels.gain = ColorWheelVector(redOffset: 0.06, greenOffset: 0.02, blueOffset: -0.04, masterLuma: 0.0)
        engine.parameters.film.halationIntensity = 0.30
        engine.parameters.film.grainIntensity = 0.20

        let input = CIImage(color: CIColor(red: 0.52, green: 0.44, blue: 0.38, alpha: 1.0))
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))

        let output = engine.processFrame(
            sourceImage: input,
            params: engine.parameters,
            sourceIsHDR: true,
            frameIndex: 12
        )

        XCTAssertEqual(output.extent, input.extent)

        let scopes = engine.computeScopesSnapshot(from: output)
        XCTAssertEqual(scopes.waveformColumns.count, 64)
        XCTAssertEqual(scopes.redHistogram.count, 32)
        XCTAssertEqual(scopes.lumaHistogram.count, 32)
    }

    func testDiscoBrandAssetVariantsMapToAssetCatalogNames() {
        XCTAssertEqual(DiscoBrandVariant.iconOnly.rawValue, "DiscoIcon")
        XCTAssertEqual(DiscoBrandVariant.logoTextOnly.rawValue, "DiscoLogoText")
        XCTAssertEqual(DiscoBrandVariant.iconLogoText.rawValue, "DiscoIconLogoText")
        XCTAssertEqual(DiscoBrandVariant.iconOnly.accessibilityLabel, "Disco App Icon")
        XCTAssertEqual(DiscoBrandVariant.logoTextOnly.accessibilityLabel, "Disco Wordmark")
        XCTAssertEqual(DiscoBrandVariant.iconLogoText.accessibilityLabel, "Disco Studio Brand Lockup")
    }
}

