import SwiftUI
import MetalKit
import AVFoundation
import CoreImage

public final class MetalVideoRenderer: NSObject, MTKViewDelegate {
    private let engine: ColorGradingEngine
    private let commandQueue: MTLCommandQueue?
    private let videoOutput: AVPlayerItemVideoOutput
    private var latestPixelBuffer: CVPixelBuffer?
    public let player: AVPlayer

    public var currentParameters = GradingParameters()
    public var sourceIsHDR: Bool = false

    public init(engine: ColorGradingEngine, player: AVPlayer) {
        self.engine = engine
        self.player = player
        self.commandQueue = engine.metalDevice.makeCommandQueue()

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        super.init()
    }

    public func attachOutput(to item: AVPlayerItem) {
        if !item.outputs.contains(videoOutput) {
            item.add(videoOutput)
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let currentDrawable = view.currentDrawable else {
            return
        }

        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        if itemTime.isValid && videoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
            if let freshBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                latestPixelBuffer = freshBuffer
            }
        }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }

        let baseImage: CIImage
        if let pixelBuffer = latestPixelBuffer {
            baseImage = CIImage(cvPixelBuffer: pixelBuffer)
        } else {
            baseImage = Self.generateReferenceTestBars(size: drawableSize)
        }

        let gradedImage = engine.processFrame(
            sourceImage: baseImage,
            params: currentParameters,
            sourceIsHDR: sourceIsHDR
        )

        let sourceExtent = gradedImage.extent
        let scaleX = drawableSize.width / max(sourceExtent.width, 1)
        let scaleY = drawableSize.height / max(sourceExtent.height, 1)
        let scale = min(scaleX, scaleY)

        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale
        let offsetX = (drawableSize.width - scaledWidth) * 0.5
        let offsetY = (drawableSize.height - scaledHeight) * 0.5

        let transformedImage = gradedImage
            .transformed(by: CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        let background = CIImage(color: CIColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: drawableSize))
        let finalComposite = transformedImage.composited(over: background)

        let destination = CIRenderDestination(
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
            pixelFormat: view.colorPixelFormat,
            commandBuffer: commandBuffer,
            mtlTextureProvider: {
                return currentDrawable.texture
            }
        )

        _ = try? engine.ciContext.startTask(toRender: finalComposite, to: destination)
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }

    /// Generates an offline SMPTE-inspired colorist skin/gradient reference frame when no video asset is loaded.
    private static func generateReferenceTestBars(size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: CGSize(width: max(size.width, 640), height: max(size.height, 360)))
        guard let gradient = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: rect.width, y: rect.height),
                "inputColor0": CIColor(red: 0.14, green: 0.18, blue: 0.25, alpha: 1.0),
                "inputColor1": CIColor(red: 0.85, green: 0.54, blue: 0.36, alpha: 1.0)
            ]
        )?.outputImage?.cropped(to: rect) else {
            return CIImage(color: .black).cropped(to: rect)
        }
        return gradient
    }
}

#if os(iOS)
public struct MetalVideoSurfaceRepresentable: UIViewRepresentable {
    public let renderer: MetalVideoRenderer
    public let engine: ColorGradingEngine
    public let parameters: GradingParameters
    public let sourceIsHDR: Bool

    public func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: engine.metalDevice)
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.clearColor = MTLClearColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1.0)
        mtkView.delegate = renderer
        return mtkView
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        renderer.currentParameters = parameters
        renderer.sourceIsHDR = sourceIsHDR
    }
}
#elseif os(macOS)
public struct MetalVideoSurfaceRepresentable: NSViewRepresentable {
    public let renderer: MetalVideoRenderer
    public let engine: ColorGradingEngine
    public let parameters: GradingParameters
    public let sourceIsHDR: Bool

    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: engine.metalDevice)
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.clearColor = MTLClearColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1.0)
        mtkView.delegate = renderer
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        renderer.currentParameters = parameters
        renderer.sourceIsHDR = sourceIsHDR
    }
}
#endif

public struct VideoPlayerView: View {
    @Bindable public var engine: ColorGradingEngine
    public let player: AVPlayer
    @State private var renderer: MetalVideoRenderer?
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var isSplitComparisonEnabled: Bool = false

    public init(engine: ColorGradingEngine, player: AVPlayer) {
        self.engine = engine
        self.player = player
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.035, green: 0.035, blue: 0.043)

                if let activeRenderer = renderer {
                    MetalVideoSurfaceRepresentable(
                        renderer: activeRenderer,
                        engine: engine,
                        parameters: engine.parameters,
                        sourceIsHDR: engine.sourceIsHDR
                    )
                    .scaleEffect(zoomScale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoomScale = min(max(lastZoomScale * value, 1.0), 4.0)
                            }
                            .onEnded { _ in
                                lastZoomScale = zoomScale
                            }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.18)
                            .onChanged { _ in
                                engine.parameters.isBypassed = true
                            }
                            .onEnded { _ in
                                engine.parameters.isBypassed = false
                            }
                    )
                }

                // Interactive Split-Screen Before/After Wipe Bar (@samdesain 1px Zinc Divider)
                if engine.parameters.splitComparisonNormalizedX < 0.999 {
                    let xPos = geo.size.width * CGFloat(engine.parameters.splitComparisonNormalizedX)
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 1.5, height: geo.size.height)
                            .position(x: xPos, y: geo.size.height * 0.5)

                        HStack(spacing: 4) {
                            Text("GRADED")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.75))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            Circle()
                                .fill(Color(red: 0.96, green: 0.62, blue: 0.04))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Image(systemName: "arrow.left.and.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.black)
                                )

                            Text("ORIGINAL")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.75))
                                .foregroundStyle(Color(white: 0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .position(x: xPos, y: geo.size.height * 0.5)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    let normalized = Float(drag.location.x / max(geo.size.width, 1))
                                    engine.parameters.splitComparisonNormalizedX = min(max(normalized, 0.05), 0.95)
                                }
                        )
                    }
                }

                // Top Technical Telemetry Strip (@samdesain 10% Fallback: Matte Zinc, 1px Border, 4px Radius)
                VStack {
                    HStack(spacing: 8) {
                        TelemetryBadge(label: engine.sourceIsHDR ? "HDR -> Rec.709 SDR" : "Rec.709 SDR", isAccent: engine.sourceIsHDR)
                        TelemetryBadge(label: "\(Int(engine.videoNaturalSize.width))x\(Int(engine.videoNaturalSize.height))", isAccent: false)
                        TelemetryBadge(label: String(format: "%.0f FPS", engine.nominalFrameRate), isAccent: false)
                        if engine.parameters.antiBandingDitherEnabled {
                            TelemetryBadge(label: "DITHER 0.5 LSB", isAccent: false)
                        }
                        Spacer()
                        if engine.parameters.isBypassed {
                            TelemetryBadge(label: "BYPASS (ORIGINAL)", isAccent: true)
                        }
                    }
                    .padding(10)
                    Spacer()
                }
            }
        }
        .onAppear {
            let newRenderer = MetalVideoRenderer(engine: engine, player: player)
            if let currentItem = player.currentItem {
                newRenderer.attachOutput(to: currentItem)
            }
            self.renderer = newRenderer
        }
        .onChange(of: engine.currentAsset) { _, newAsset in
            guard let asset = newAsset else { return }
            let item = AVPlayerItem(asset: asset)
            renderer?.attachOutput(to: item)
            player.replaceCurrentItem(with: item)
            player.play()
        }
    }
}

private struct TelemetryBadge: View {
    let label: String
    let isAccent: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(isAccent ? Color(red: 0.98, green: 0.75, blue: 0.14) : Color(white: 0.88))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.9))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isAccent ? Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.6) : Color(white: 0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

