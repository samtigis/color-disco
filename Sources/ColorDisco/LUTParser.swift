import Foundation
import CoreGraphics
import CoreImage
import ImageIO

public enum LUTParserError: LocalizedError, Sendable {
    case fileNotFound
    case unreadableTextEncoding
    case missingLUTDimension
    case invalidDimension(Int)
    case malformedColorTriplet(lineNumber: Int, rawLine: String)
    case tripletCountMismatch(expected: Int, actual: Int)
    case invalidHaldImageDimensions(width: Int, height: Int)
    case bitmapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "LUT file could not be found on disk."
        case .unreadableTextEncoding:
            return "LUT file is not valid UTF-8 or ASCII text."
        case .missingLUTDimension:
            return "Missing LUT_3D_SIZE declaration in .cube file."
        case .invalidDimension(let dim):
            return "LUT dimension \(dim) is outside the supported CoreImage range (2 to 64)."
        case .malformedColorTriplet(let line, let raw):
            return "Invalid RGB floating-point triplet at line \(line): '\(raw)'."
        case .tripletCountMismatch(let expected, let actual):
            return "Expected \(expected) RGB triplets (\(Int(cbrt(Double(expected))))^3), but parsed \(actual)."
        case .invalidHaldImageDimensions(let w, let h):
            return "HALD PNG must be a square image with root-cubic dimension (got \(w)x\(h))."
        case .bitmapCreationFailed:
            return "Failed to allocate RGBA8 bitmap buffer for HALD PNG extraction."
        }
    }
}

public struct ParsedLUT: Sendable, Equatable {
    public let title: String
    public let dimension: Int
    public let cubeData: Data
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>

    public init(
        title: String,
        dimension: Int,
        cubeData: Data,
        domainMin: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        domainMax: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    ) {
        self.title = title
        self.dimension = dimension
        self.cubeData = cubeData
        self.domainMin = domainMin
        self.domainMax = domainMax
    }
}

public enum LUTParser {

    /// Parses an Adobe/Resolve `.cube` 3D LUT file into `CIColorCubeWithColorSpace` RGBA Float32 `Data`.
    public static func parseCubeFile(at url: URL) throws -> ParsedLUT {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LUTParserError.fileNotFound
        }

        let rawData = try Data(contentsOf: url)
        guard let content = String(data: rawData, encoding: .utf8) ?? String(data: rawData, encoding: .ascii) else {
            throw LUTParserError.unreadableTextEncoding
        }

        return try parseCubeString(content, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    public static func parseCubeString(_ content: String, fallbackTitle: String = "Custom 3D LUT") throws -> ParsedLUT {
        var title = fallbackTitle
        var dimension: Int?
        var domainMin = SIMD3<Float>(0.0, 0.0, 0.0)
        var domainMax = SIMD3<Float>(1.0, 1.0, 1.0)

        var rgbaBuffer: [Float] = []
        var parsedTriplets = 0
        var lineNumber = 0

        content.enumerateLines { rawLine, _ in
            lineNumber += 1
        }

        let lines = content.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineIdx = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let commentStripped: String
            if let hashIndex = trimmed.firstIndex(of: "#") {
                commentStripped = String(trimmed[..<hashIndex]).trimmingCharacters(in: .whitespaces)
            } else {
                commentStripped = trimmed
            }

            if commentStripped.isEmpty { continue }

            let upper = commentStripped.uppercased()

            if upper.hasPrefix("TITLE") {
                if let firstQuote = commentStripped.firstIndex(of: "\""),
                   let lastQuote = commentStripped.lastIndex(of: "\""),
                   firstQuote < lastQuote {
                    let start = commentStripped.index(after: firstQuote)
                    title = String(commentStripped[start..<lastQuote])
                } else {
                    let parts = commentStripped.split(separator: " ", maxSplits: 1)
                    if parts.count == 2 {
                        title = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
                continue
            }

            if upper.hasPrefix("LUT_3D_SIZE") {
                let parts = commentStripped.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 2, let size = Int(parts[1]) else {
                    throw LUTParserError.missingLUTDimension
                }
                guard (2...64).contains(size) else {
                    throw LUTParserError.invalidDimension(size)
                }
                dimension = size
                rgbaBuffer.reserveCapacity(size * size * size * 4)
                continue
            }

            if upper.hasPrefix("DOMAIN_MIN") {
                let parts = commentStripped.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 4,
                   let r = Float(parts[1]),
                   let g = Float(parts[2]),
                   let b = Float(parts[3]) {
                    domainMin = SIMD3<Float>(r, g, b)
                }
                continue
            }

            if upper.hasPrefix("DOMAIN_MAX") {
                let parts = commentStripped.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 4,
                   let r = Float(parts[1]),
                   let g = Float(parts[2]),
                   let b = Float(parts[3]) {
                    domainMax = SIMD3<Float>(r, g, b)
                }
                continue
            }

            if upper.hasPrefix("LUT_1D_SIZE") || upper.hasPrefix("LUT_3D_INPUT_RANGE") {
                continue
            }

            let tokens = commentStripped.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count >= 3,
                  let rRaw = Float(tokens[0]),
                  let gRaw = Float(tokens[1]),
                  let bRaw = Float(tokens[2]) else {
                throw LUTParserError.malformedColorTriplet(lineNumber: lineIdx, rawLine: rawLine)
            }

            let span = domainMax - domainMin
            let rNorm = span.x > 0 ? (rRaw - domainMin.x) / span.x : rRaw
            let gNorm = span.y > 0 ? (gRaw - domainMin.y) / span.y : gRaw
            let bNorm = span.z > 0 ? (bRaw - domainMin.z) / span.z : bRaw

            // CoreImage CIColorCube expects premultiplied RGBA Float32 values clamped to [0, 1].
            rgbaBuffer.append(min(max(rNorm, 0.0), 1.0))
            rgbaBuffer.append(min(max(gNorm, 0.0), 1.0))
            rgbaBuffer.append(min(max(bNorm, 0.0), 1.0))
            rgbaBuffer.append(1.0)
            parsedTriplets += 1
        }

        guard let resolvedDimension = dimension else {
            throw LUTParserError.missingLUTDimension
        }

        let expectedTriplets = resolvedDimension * resolvedDimension * resolvedDimension
        guard parsedTriplets == expectedTriplets else {
            throw LUTParserError.tripletCountMismatch(expected: expectedTriplets, actual: parsedTriplets)
        }

        let cubeData = rgbaBuffer.withUnsafeBufferPointer { bufferPointer in
            Data(buffer: bufferPointer)
        }

        return ParsedLUT(
            title: title,
            dimension: resolvedDimension,
            cubeData: cubeData,
            domainMin: domainMin,
            domainMax: domainMax
        )
    }

    /// Decodes a 2D HALD PNG (e.g., Hald 8 = 512x512 -> 64^3 cube, or Hald 4 = 64x64 -> 16^3 cube)
    /// into a 3D LUT buffer compatible with `CIColorCubeWithColorSpace`.
    public static func parseHaldPNG(at url: URL) throws -> ParsedLUT {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LUTParserError.fileNotFound
        }

        return try parseHaldCGImage(cgImage, title: url.deletingPathExtension().lastPathComponent)
    }

    public static func parseHaldCGImage(_ cgImage: CGImage, title: String = "HALD 3D LUT") throws -> ParsedLUT {
        let width = cgImage.width
        let height = cgImage.height
        guard width == height else {
            throw LUTParserError.invalidHaldImageDimensions(width: width, height: height)
        }

        let totalPixels = width * height
        let cubeDimensionDouble = round(cbrt(Double(totalPixels)))
        let cubeDimension = Int(cubeDimensionDouble)

        guard cubeDimension * cubeDimension * cubeDimension == totalPixels,
              (2...64).contains(cubeDimension) else {
            throw LUTParserError.invalidHaldImageDimensions(width: width, height: height)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rawPixels = [UInt8](repeating: 0, count: totalPixels * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &rawPixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            throw LUTParserError.bitmapCreationFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rgbaFloat = [Float](repeating: 1.0, count: totalPixels * 4)
        let scale: Float = 1.0 / 255.0

        for i in 0..<totalPixels {
            let byteOffset = i * 4
            let floatOffset = i * 4
            rgbaFloat[floatOffset + 0] = Float(rawPixels[byteOffset + 0]) * scale
            rgbaFloat[floatOffset + 1] = Float(rawPixels[byteOffset + 1]) * scale
            rgbaFloat[floatOffset + 2] = Float(rawPixels[byteOffset + 2]) * scale
            rgbaFloat[floatOffset + 3] = 1.0
        }

        let cubeData = rgbaFloat.withUnsafeBufferPointer { Data(buffer: $0) }
        return ParsedLUT(title: title, dimension: cubeDimension, cubeData: cubeData)
    }

    /// Generates built-in studio reference 3D LUTs procedurally so the app works immediately offline.
    public static func generateBuiltInLUT(preset: StudioLUTPreset, dimension: Int = 32) -> ParsedLUT {
        let count = dimension * dimension * dimension
        var buffer = [Float](repeating: 1.0, count: count * 4)
        let denom = Float(dimension - 1)
        var offset = 0

        for bIdx in 0..<dimension {
            let b = Float(bIdx) / denom
            for gIdx in 0..<dimension {
                let g = Float(gIdx) / denom
                for rIdx in 0..<dimension {
                    let r = Float(rIdx) / denom
                    let transformed = preset.transform(r: r, g: g, b: b)
                    buffer[offset + 0] = min(max(transformed.x, 0.0), 1.0)
                    buffer[offset + 1] = min(max(transformed.y, 0.0), 1.0)
                    buffer[offset + 2] = min(max(transformed.z, 0.0), 1.0)
                    buffer[offset + 3] = 1.0
                    offset += 4
                }
            }
        }

        let data = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
        return ParsedLUT(title: preset.rawValue, dimension: dimension, cubeData: data)
    }
}

public enum StudioLUTPreset: String, CaseIterable, Identifiable, Sendable {
    case rec709Natural = "Rec.709 Natural Neutral"
    case kodak2383Print = "Kodak 2383 Film Print"
    case cineTealTungsten = "Cine Tungsten & Amber"
    case bleachBypass = "Silver Bleach Retention"
    case logToRec709 = "Apple Log to Rec.709 SDR"

    public var id: String { rawValue }

    public var category: String {
        switch self {
        case .rec709Natural, .logToRec709: return "Technical"
        case .kodak2383Print, .cineTealTungsten, .bleachBypass: return "Film Print"
        }
    }

    func transform(r: Float, g: Float, b: Float) -> SIMD3<Float> {
        switch self {
        case .rec709Natural:
            return SIMD3<Float>(r, g, b)
        case .kodak2383Print:
            let sCurve: (Float) -> Float = { x in
                let clamped = min(max(x, 0), 1)
                return clamped * clamped * (3.0 - 2.0 * clamped)
            }
            let rOut = sCurve(r) * 1.02
            let gOut = sCurve(g) * 0.99
            let bOut = sCurve(b) * 0.94 + (1.0 - sCurve(b)) * 0.03
            return SIMD3<Float>(rOut, gOut, bOut)
        case .cineTealTungsten:
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let shadowWeight = max(0.0, 1.0 - luma * 1.6)
            let highWeight = max(0.0, (luma - 0.35) * 1.4)
            let rOut = r - shadowWeight * 0.04 + highWeight * 0.05
            let gOut = g + shadowWeight * 0.015 + highWeight * 0.01
            let bOut = b + shadowWeight * 0.05 - highWeight * 0.04
            return SIMD3<Float>(rOut, gOut, bOut)
        case .bleachBypass:
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let contrastLuma = min(max((luma - 0.5) * 1.28 + 0.5, 0.0), 1.0)
            let mixR = r * 0.55 + contrastLuma * 0.45
            let mixG = g * 0.55 + contrastLuma * 0.45
            let mixB = b * 0.55 + contrastLuma * 0.45
            return SIMD3<Float>(mixR, mixG, mixB)
        case .logToRec709:
            let expand: (Float) -> Float = { v in
                let x = min(max(v, 0.0), 1.0)
                return pow(x, 0.85) * (x * (2.5 - 1.5 * x))
            }
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let satBoost: Float = 1.18
            let er = expand(luma + (r - luma) * satBoost)
            let eg = expand(luma + (g - luma) * satBoost)
            let eb = expand(luma + (b - luma) * satBoost)
            return SIMD3<Float>(er, eg, eb)
        }
    }
}

