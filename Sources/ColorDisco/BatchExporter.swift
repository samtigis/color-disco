import Foundation
import AVFoundation
import CoreImage
import CoreVideo

public struct BatchExportItem: Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let kind: MediaItemKind

    public init(id: UUID = UUID(), sourceURL: URL, kind: MediaItemKind) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = kind
    }
}

public struct BatchExportProgress: Sendable {
    public let completedItems: Int
    public let totalItems: Int
    public let currentItemFraction: Float
    public let overallFraction: Float
    public let currentFileName: String

    public init(
        completedItems: Int,
        totalItems: Int,
        currentItemFraction: Float,
        overallFraction: Float,
        currentFileName: String
    ) {
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.currentItemFraction = currentItemFraction
        self.overallFraction = overallFraction
        self.currentFileName = currentFileName
    }
}

public final class BatchExporter: Sendable {
    private let videoExporter = VideoExporter()

    public init() {}

    /// Exports a single graded photo (ProRAW/DNG, HEIC, JPEG, PNG) to maximum quality Rec.709/sRGB JPEG, 16-bit TIFF, or PNG.
    public func exportGradedPhoto(
        sourceImage: CIImage,
        outputURL: URL,
        engine: ColorGradingEngine,
        parameters: GradingParameters,
        format: PhotoExportFormat = .jpegRec709
    ) throws {
        var exportParams = parameters
        exportParams.splitComparisonNormalizedX = 1.0
        exportParams.isBypassed = false

        let graded = engine.processFrame(
            sourceImage: sourceImage,
            params: exportParams,
            sourceIsHDR: false,
            frameIndex: 0
        )

        let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB)!

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        switch format {
        case .jpegRec709:
            try engine.ciContext.writeJPEGRepresentation(
                of: graded,
                to: outputURL,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0]
            )
        case .tiff16Bit:
            try engine.ciContext.writeTIFFRepresentation(
                of: graded,
                to: outputURL,
                format: .RGBA16,
                colorSpace: colorSpace,
                options: [:]
            )
        case .pngLossless:
            try engine.ciContext.writePNGRepresentation(
                of: graded,
                to: outputURL,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [:]
            )
        }
    }

    /// Executes offline batch processing across multiple photos and videos with memory-safe autoreleasepool buffer reuse.
    public func exportBatch(
        items: [BatchExportItem],
        outputDirectory: URL,
        engine: ColorGradingEngine,
        parameters: GradingParameters,
        aspectPreset: SocialAspectRatioPreset,
        frameRatePreset: ExportFrameRatePreset,
        photoFormat: PhotoExportFormat = .jpegRec709
    ) -> AsyncThrowingStream<BatchExportProgress, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let total = max(items.count, 1)

                    for (index, item) in items.enumerated() {
                        if Task.isCancelled {
                            throw VideoExporterError.exportCancelled
                        }

                        let baseName = item.sourceURL.deletingPathExtension().lastPathComponent
                        switch item.kind {
                        case .photo:
                            let destURL = outputDirectory.appendingPathComponent("\(baseName)_Graded.\(photoFormat.fileExtension)")
                            try autoreleasepool {
                                guard let ciImg = CIImage(contentsOf: item.sourceURL, options: [.applyOrientationProperty: true]) else {
                                    throw VideoExporterError.exportFailed("Could not decode photo \(item.sourceURL.lastPathComponent)")
                                }
                                try self.exportGradedPhoto(
                                    sourceImage: ciImg,
                                    outputURL: destURL,
                                    engine: engine,
                                    parameters: parameters,
                                    format: photoFormat
                                )
                            }
                            let overall = Float(index + 1) / Float(total)
                            continuation.yield(BatchExportProgress(
                                completedItems: index + 1,
                                totalItems: total,
                                currentItemFraction: 1.0,
                                overallFraction: overall,
                                currentFileName: item.sourceURL.lastPathComponent
                            ))

                        case .video:
                            let destURL = outputDirectory.appendingPathComponent("\(baseName)_Rec709.mp4")
                            let asset = AVURLAsset(url: item.sourceURL)
                            let stream = self.videoExporter.exportSocialMaster(
                                asset: asset,
                                outputURL: destURL,
                                engine: engine,
                                parameters: parameters,
                                sourceIsHDR: parameters.basics.hdrToSdrTonemapEnabled,
                                aspectPreset: aspectPreset,
                                frameRatePreset: frameRatePreset
                            )

                            for try await clipProgress in stream {
                                let overall = (Float(index) + clipProgress) / Float(total)
                                continuation.yield(BatchExportProgress(
                                    completedItems: index,
                                    totalItems: total,
                                    currentItemFraction: clipProgress,
                                    overallFraction: overall,
                                    currentFileName: item.sourceURL.lastPathComponent
                                ))
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

