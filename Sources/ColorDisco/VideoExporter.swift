import Foundation
import AVFoundation
import CoreImage
import CoreVideo

public enum SocialAspectRatioPreset: String, CaseIterable, Identifiable, Sendable {
    case portrait9x16 = "9:16 Reels / TikTok (1080x1920)"
    case portrait4x5 = "4:5 Instagram Feed (1080x1350)"
    case square1x1 = "1:1 Square Post (1080x1080)"

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .portrait9x16: return "9:16 (1080x1920)"
        case .portrait4x5: return "4:5 (1080x1350)"
        case .square1x1: return "1:1 (1080x1080)"
        }
    }

    /// Enforces even integer macroblock dimensions (divisible by 2) for H.264 High Profile compatibility.
    public var targetDimensions: CGSize {
        switch self {
        case .portrait9x16:
            return CGSize(width: 1080, height: 1920)
        case .portrait4x5:
            return CGSize(width: 1080, height: 1350)
        case .square1x1:
            return CGSize(width: 1080, height: 1080)
        }
    }
}

public enum ExportFrameRatePreset: Int, CaseIterable, Identifiable, Sendable {
    case fps30 = 30
    case fps60 = 60

    public var id: Int { rawValue }

    public var averageBitrateBps: Int {
        switch self {
        case .fps30: return 14_000_000 // 14 Mbps average for 1080p @ 30fps
        case .fps60: return 20_000_000 // 20 Mbps average for 1080p @ 60fps
        }
    }

    public var maxBitrateBps: Int {
        switch self {
        case .fps30: return 16_000_000 // 16 Mbps peak ceiling
        case .fps60: return 24_000_000 // 24 Mbps peak ceiling
        }
    }
}

public enum VideoExporterError: LocalizedError, Sendable {
    case missingVideoTrack
    case readerInitializationFailed(String)
    case writerInitializationFailed(String)
    case pixelBufferPoolUnavailable
    case exportCancelled
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "Source asset does not contain a readable video track."
        case .readerInitializationFailed(let reason):
            return "AVAssetReader failed to initialize: \(reason)"
        case .writerInitializationFailed(let reason):
            return "AVAssetWriter failed to initialize: \(reason)"
        case .pixelBufferPoolUnavailable:
            return "Failed to allocate CVPixelBufferPool for hardware-accelerated export."
        case .exportCancelled:
            return "Video export was cancelled."
        case .exportFailed(let reason):
            return "Video export failed: \(reason)"
        }
    }
}

public final class VideoExporter: Sendable {
    public init() {}

    /// Streams offline frame-accurate graded frames using `AVAssetReader` + `AVAssetWriter`
    /// with strict H.264 High Profile Level 4.2, Rec. 709 color tags, and Constant Frame Rate (CFR).
    public func exportSocialMaster(
        asset: AVAsset,
        outputURL: URL,
        engine: ColorGradingEngine,
        parameters: GradingParameters,
        sourceIsHDR: Bool,
        aspectPreset: SocialAspectRatioPreset,
        frameRatePreset: ExportFrameRatePreset
    ) -> AsyncThrowingStream<Float, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        try FileManager.default.removeItem(at: outputURL)
                    }

                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    guard let videoTrack = videoTracks.first else {
                        throw VideoExporterError.missingVideoTrack
                    }

                    let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
                    let duration = try await asset.load(.duration)
                    let totalDurationSeconds = max(CMTimeGetSeconds(duration), 0.001)
                    let preferredTransform = try await videoTrack.load(.preferredTransform)

                    let reader = try AVAssetReader(asset: asset)

                    let readerVideoSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                        kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ]
                    let videoReaderOutput = AVAssetReaderTrackOutput(
                        track: videoTrack,
                        outputSettings: readerVideoSettings
                    )
                    videoReaderOutput.alwaysCopiesSampleData = false
                    guard reader.canAdd(videoReaderOutput) else {
                        throw VideoExporterError.readerInitializationFailed("Cannot attach video track output.")
                    }
                    reader.add(videoReaderOutput)

                    var audioReaderOutput: AVAssetReaderTrackOutput?
                    if let firstAudioTrack = audioTracks?.first {
                        let audioOut = AVAssetReaderTrackOutput(
                            track: firstAudioTrack,
                            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
                        )
                        audioOut.alwaysCopiesSampleData = false
                        if reader.canAdd(audioOut) {
                            reader.add(audioOut)
                            audioReaderOutput = audioOut
                        }
                    }

                    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

                    // Enforce macroblock-even dimensions
                    let rawSize = aspectPreset.targetDimensions
                    let evenWidth = Int(rawSize.width) & ~1
                    let evenHeight = Int(rawSize.height) & ~1

                    let compressionProperties: [String: Any] = [
                        AVVideoAverageBitRateKey: frameRatePreset.averageBitrateBps,
                        AVVideoDataRateLimitsKey: [
                            frameRatePreset.maxBitrateBps / 8,
                            1.0
                        ],
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264High42,
                        AVVideoExpectedSourceFrameRateKey: frameRatePreset.rawValue,
                        AVVideoAverageNonDroppableFrameRateKey: frameRatePreset.rawValue,
                        AVVideoMaxKeyFrameIntervalKey: frameRatePreset.rawValue * 2,
                        AVVideoAllowFrameReorderingKey: true
                    ]

                    // Explicit Rec. 709 SDR color tagging prevents Instagram/TikTok color shifts
                    let colorProperties: [String: Any] = [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                    ]

                    let videoWriterSettings: [String: Any] = [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: evenWidth,
                        AVVideoHeightKey: evenHeight,
                        AVVideoCompressionPropertiesKey: compressionProperties,
                        AVVideoColorPropertiesKey: colorProperties
                    ]

                    let videoWriterInput = AVAssetWriterInput(
                        mediaType: .video,
                        outputSettings: videoWriterSettings
                    )
                    videoWriterInput.expectsMediaDataInRealTime = false

                    let sourcePixelBufferAttributes: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                        kCVPixelBufferWidthKey as String: evenWidth,
                        kCVPixelBufferHeightKey as String: evenHeight,
                        kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ]

                    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                        assetWriterInput: videoWriterInput,
                        sourcePixelBufferAttributes: sourcePixelBufferAttributes
                    )

                    guard writer.canAdd(videoWriterInput) else {
                        throw VideoExporterError.writerInitializationFailed("Cannot add H.264 Rec.709 video writer input.")
                    }
                    writer.add(videoWriterInput)

                    var audioWriterInput: AVAssetWriterInput?
                    if audioReaderOutput != nil {
                        let aacSettings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVNumberOfChannelsKey: 2,
                            AVSampleRateKey: 48_000,
                            AVEncoderBitRateKey: 256_000
                        ]
                        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                        aInput.expectsMediaDataInRealTime = false
                        if writer.canAdd(aInput) {
                            writer.add(aInput)
                            audioWriterInput = aInput
                        }
                    }

                    guard reader.startReading() else {
                        throw VideoExporterError.readerInitializationFailed(reader.error?.localizedDescription ?? "Unknown reader error")
                    }
                    guard writer.startWriting() else {
                        throw VideoExporterError.writerInitializationFailed(writer.error?.localizedDescription ?? "Unknown writer error")
                    }

                    writer.startSession(atSourceTime: .zero)

                    var exportParams = parameters
                    exportParams.splitComparisonNormalizedX = 1.0
                    exportParams.isBypassed = false

                    let targetRect = CGRect(x: 0, y: 0, width: CGFloat(evenWidth), height: CGFloat(evenHeight))

                    while reader.status == .reading {
                        if Task.isCancelled {
                            reader.cancelReading()
                            writer.cancelWriting()
                            throw VideoExporterError.exportCancelled
                        }

                        if videoWriterInput.isReadyForMoreMediaData {
                            if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() {
                                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                                    guard let pool = adaptor.pixelBufferPool else {
                                        throw VideoExporterError.pixelBufferPoolUnavailable
                                    }
                                    var outputPixelBuffer: CVPixelBuffer?
                                    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputPixelBuffer)
                                    guard status == kCVReturnSuccess, let dstBuffer = outputPixelBuffer else {
                                        throw VideoExporterError.pixelBufferPoolUnavailable
                                    }

                                    var sourceCI = CIImage(cvPixelBuffer: imageBuffer)
                                        .transformed(by: preferredTransform)
                                    let srcExtent = sourceCI.extent
                                    sourceCI = sourceCI.transformed(
                                        by: CGAffineTransform(translationX: -srcExtent.minX, y: -srcExtent.minY)
                                    )

                                    // Aspect-fill crop into target social canvas
                                    let scale = max(
                                        targetRect.width / max(sourceCI.extent.width, 1),
                                        targetRect.height / max(sourceCI.extent.height, 1)
                                    )
                                    let scaledW = sourceCI.extent.width * scale
                                    let scaledH = sourceCI.extent.height * scale
                                    let dx = (targetRect.width - scaledW) * 0.5
                                    let dy = (targetRect.height - scaledH) * 0.5

                                    let fittedCI = sourceCI
                                        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                                        .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                                        .cropped(to: targetRect)

                                    let gradedCI = engine.processFrame(
                                        sourceImage: fittedCI,
                                        params: exportParams,
                                        sourceIsHDR: sourceIsHDR
                                    )

                                    engine.ciContext.render(
                                        gradedCI,
                                        to: dstBuffer,
                                        bounds: targetRect,
                                        colorSpace: engine.outputColorSpace
                                    )

                                    adaptor.append(dstBuffer, withPresentationTime: presentationTime)
                                }

                                let seconds = CMTimeGetSeconds(presentationTime)
                                let progress = Float(min(max(seconds / totalDurationSeconds, 0.0), 0.99))
                                continuation.yield(progress)
                            } else {
                                videoWriterInput.markAsFinished()
                                break
                            }
                        } else {
                            try await Task.sleep(nanoseconds: 2_000_000)
                        }
                    }

                    if let audioOut = audioReaderOutput, let audioIn = audioWriterInput {
                        while reader.status == .reading {
                            if audioIn.isReadyForMoreMediaData {
                                if let audioSample = audioOut.copyNextSampleBuffer() {
                                    audioIn.append(audioSample)
                                } else {
                                    audioIn.markAsFinished()
                                    break
                                }
                            } else {
                                try await Task.sleep(nanoseconds: 2_000_000)
                            }
                        }
                    }

                    await writer.finishWriting()
                    if writer.status == .failed {
                        throw VideoExporterError.exportFailed(writer.error?.localizedDescription ?? "Writer failed.")
                    }

                    continuation.yield(1.0)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

