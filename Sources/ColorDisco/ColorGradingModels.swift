import Foundation
import CoreGraphics

public enum MediaItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case video = "Video (Log / HDR / SDR)"
    case photo = "Photo (ProRAW / DNG / HEIC / JPEG)"

    public var id: String { rawValue }
}

public enum PhotoExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpegRec709 = "JPEG (Rec.709 / sRGB Max Quality)"
    case tiff16Bit = "TIFF (16-Bit Uncompressed)"
    case pngLossless = "PNG (Lossless)"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .jpegRec709: return "jpg"
        case .tiff16Bit: return "tiff"
        case .pngLossless: return "png"
        }
    }
}

public struct BasicAdjustments: Codable, Equatable, Sendable {
    public var appleLogToRec709Enabled: Bool = false
    public var hdrToSdrTonemapEnabled: Bool = true
    public var exposure: Float = 0.0          // EV: -3.0 ... +3.0
    public var contrast: Float = 1.0          // 0.5 ... 1.5
    public var sCurveContrast: Float = 0.0    // 0.0 ... 1.0
    public var temperature: Float = 6500.0    // Kelvin: 3000 ... 10000
    public var tint: Float = 0.0              // Green/Magenta: -100 ... +100
    public var highlights: Float = 0.0        // -1.0 ... +1.0
    public var shadows: Float = 0.0           // -1.0 ... +1.0
    public var whites: Float = 0.0            // -1.0 ... +1.0
    public var blacks: Float = 0.0            // -1.0 ... +1.0
    public var vibrance: Float = 0.0          // -1.0 ... +1.0
    public var saturation: Float = 1.0        // 0.0 ... 2.0

    public init() {}
}

public enum CurveChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case masterLuma = "Master (Luma)"
    case red = "Red"
    case green = "Green"
    case blue = "Blue"

    public var id: String { rawValue }
}

public struct CurveControlPoint: Codable, Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = min(max(x, 0.0), 1.0)
        self.y = min(max(y, 0.0), 1.0)
    }
}

/// 5-point parametric spline control points for `CIToneCurve` per channel.
public struct CurvePoints: Codable, Equatable, Sendable {
    public var p0: CurveControlPoint = CurveControlPoint(x: 0.00, y: 0.00)
    public var p1: CurveControlPoint = CurveControlPoint(x: 0.25, y: 0.25)
    public var p2: CurveControlPoint = CurveControlPoint(x: 0.50, y: 0.50)
    public var p3: CurveControlPoint = CurveControlPoint(x: 0.75, y: 0.75)
    public var p4: CurveControlPoint = CurveControlPoint(x: 1.00, y: 1.00)

    public init() {}

    public var isIdentity: Bool {
        abs(p0.y - 0.00) < 0.001 &&
        abs(p1.y - 0.25) < 0.001 &&
        abs(p2.y - 0.50) < 0.001 &&
        abs(p3.y - 0.75) < 0.001 &&
        abs(p4.y - 1.00) < 0.001
    }
}

public struct ToneCurvesConfig: Codable, Equatable, Sendable {
    public var master: CurvePoints = CurvePoints()
    public var red: CurvePoints = CurvePoints()
    public var green: CurvePoints = CurvePoints()
    public var blue: CurvePoints = CurvePoints()

    public init() {}

    public var isIdentity: Bool {
        master.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    public subscript(channel: CurveChannel) -> CurvePoints {
        get {
            switch channel {
            case .masterLuma: return master
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            switch channel {
            case .masterLuma: master = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }
}

public enum HSLChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case cyan = "Cyan"
    case blue = "Blue"
    case purple = "Purple"
    case magenta = "Magenta"

    public var id: String { rawValue }

    /// Normalized center hue angle in [0.0, 1.0].
    public var centerHue: Float {
        switch self {
        case .red: return 0.000
        case .orange: return 0.075
        case .yellow: return 0.160
        case .green: return 0.333
        case .cyan: return 0.500
        case .blue: return 0.640
        case .purple: return 0.760
        case .magenta: return 0.880
        }
    }
}

public struct HSLSegment: Codable, Equatable, Sendable {
    public var hueShift: Float = 0.0        // -1.0 ... +1.0
    public var saturation: Float = 0.0      // -1.0 ... +1.0
    public var luminance: Float = 0.0       // -1.0 ... +1.0

    public init(hueShift: Float = 0.0, saturation: Float = 0.0, luminance: Float = 0.0) {
        self.hueShift = hueShift
        self.saturation = saturation
        self.luminance = luminance
    }

    public var isIdentity: Bool {
        abs(hueShift) < 0.001 && abs(saturation) < 0.001 && abs(luminance) < 0.001
    }
}

public struct ColorWheelVector: Codable, Equatable, Sendable {
    public var redOffset: Float = 0.0
    public var greenOffset: Float = 0.0
    public var blueOffset: Float = 0.0
    public var masterLuma: Float = 0.0

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

public struct ColorWheelOffsets: Codable, Equatable, Sendable {
    public var lift: ColorWheelVector = ColorWheelVector()
    public var gamma: ColorWheelVector = ColorWheelVector()
    public var gain: ColorWheelVector = ColorWheelVector()

    public init() {}

    public var isIdentity: Bool {
        lift.isIdentity && gamma.isIdentity && gain.isIdentity
    }
}

public struct FilmEmulationConfig: Codable, Equatable, Sendable {
    /// Halation warm red/amber edge bleed around specular highlights (0.0 ... 1.0).
    public var halationIntensity: Float = 0.0
    public var halationThreshold: Float = 0.72
    public var halationRadius: Float = 12.0

    /// Procedural per-frame organic film grain (0.0 ... 1.0).
    public var grainIntensity: Float = 0.0
    public var grainSize: Float = 1.25       // 0.5 ... 3.0
    public var grainRoughness: Float = 0.50  // 0.0 ... 1.0

    public init() {}

    public var hasHalation: Bool { halationIntensity > 0.001 }
    public var hasGrain: Bool { grainIntensity > 0.001 }
}

/// Complete, JSON-serializable grading recipe supporting Preset Management and Copy/Paste Grade across clips & photos.
public struct GradingParameters: Codable, Equatable, Sendable {
    public var presetName: String = "Untitled Grade"
    public var basics: BasicAdjustments = BasicAdjustments()
    public var curves: ToneCurvesConfig = ToneCurvesConfig()
    public var hslSegments: [HSLChannel: HSLSegment] = {
        var map: [HSLChannel: HSLSegment] = [:]
        for ch in HSLChannel.allCases {
            map[ch] = HSLSegment()
        }
        return map
    }()
    public var skinToneProtectionLock: Bool = true
    public var wheels: ColorWheelOffsets = ColorWheelOffsets()
    public var film: FilmEmulationConfig = FilmEmulationConfig()
    public var selectedLUT: ParsedLUT? = nil
    public var lutIntensity: Float = 1.0
    public var antiBandingDitherEnabled: Bool = true
    public var ditherStrengthLSB: Float = 0.5
    public var splitComparisonNormalizedX: Float = 1.0
    public var isBypassed: Bool = false

    public init() {}

    // Convenience flat accessors for existing bindings
    public var exposure: Float {
        get { basics.exposure }
        set { basics.exposure = newValue }
    }
    public var contrast: Float {
        get { basics.contrast }
        set { basics.contrast = newValue }
    }
    public var temperature: Float {
        get { basics.temperature }
        set { basics.temperature = newValue }
    }
    public var tint: Float {
        get { basics.tint }
        set { basics.tint = newValue }
    }
    public var saturation: Float {
        get { basics.saturation }
        set { basics.saturation = newValue }
    }
    public var vibrance: Float {
        get { basics.vibrance }
        set { basics.vibrance = newValue }
    }
    public var hdrToSdrTonemapEnabled: Bool {
        get { basics.hdrToSdrTonemapEnabled }
        set { basics.hdrToSdrTonemapEnabled = newValue }
    }
    public var lift: ColorWheelVector {
        get { wheels.lift }
        set { wheels.lift = newValue }
    }
    public var gamma: ColorWheelVector {
        get { wheels.gamma }
        set { wheels.gamma = newValue }
    }
    public var gain: ColorWheelVector {
        get { wheels.gain }
        set { wheels.gain = newValue }
    }

    public var hasActiveHSL: Bool {
        hslSegments.values.contains { !$0.isIdentity }
    }
}

