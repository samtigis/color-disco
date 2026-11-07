import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

public enum InspectorDeckTab: String, CaseIterable, Identifiable {
    case luts = "LUTs"
    case wheels = "Wheels"
    case sliders = "Sliders"
    case export = "Export"

    public var id: String { rawValue }
}

public struct ContentView: View {
    @State private var engine = ColorGradingEngine()
    @State private var player = AVPlayer()
    @State private var selectedTab: InspectorDeckTab = .luts
    @State private var selectedLUTCategory: String = "All"
    @State private var lutSearchQuery: String = ""
    @State private var isPlaying: Bool = false

    @State private var isImportingVideo: Bool = false
    @State private var isImportingLUT: Bool = false
    @State private var isShowingExportSheet: Bool = false
    @State private var isDarkAppearance: Bool = true

    @State private var selectedAspectRatio: SocialAspectRatioPreset = .portrait9x16
    @State private var selectedFrameRate: ExportFrameRatePreset = .fps60
    @State private var isExporting: Bool = false
    @State private var exportProgress: Float = 0.0
    @State private var exportedFileURL: URL?
    @State private var activeErrorMessage: String?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private let exporter = VideoExporter()

    public init() {}

    public var body: some View {
        Group {
            #if os(macOS)
            macOSProWorkspace
            #else
            if horizontalSizeClass == .regular {
                iPadOSSplitWorkspace
            } else {
                iPhoneCompactWorkspace
            }
            #endif
        }
        .preferredColorScheme(isDarkAppearance ? .dark : .light)
        .fileImporter(
            isPresented: $isImportingVideo,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            handleVideoImport(result)
        }
        .fileImporter(
            isPresented: $isImportingLUT,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .png],
            allowsMultipleSelection: false
        ) { result in
            handleLUTImport(result)
        }
        .sheet(isPresented: $isShowingExportSheet) {
            exportMasterSheet
        }
        .alert(
            "Grading Operation Notice",
            isPresented: Binding(
                get: { activeErrorMessage != nil },
                set: { if !$0 { activeErrorMessage = nil } }
            )
        ) {
            Button("Dismiss", role: .cancel) {
                activeErrorMessage = nil
            }
        } message: {
            Text(activeErrorMessage ?? "An unexpected error occurred.")
        }
    }

    // MARK: - 1. iPhone Compact Layout (Bottom Deck + Full Viewport)

    private var iPhoneCompactWorkspace: some View {
        VStack(spacing: 0) {
            topNavigationBar
            ZStack {
                VideoPlayerView(engine: engine, player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                hudConfirmationBanner
            }
            transportToolbar
            VStack(spacing: 12) {
                Picker("Inspector Mode", selection: $selectedTab) {
                    ForEach(InspectorDeckTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ScrollView {
                    activeDeckContent
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .frame(height: 290)
            }
            .background(isDarkAppearance ? Color(red: 0.07, green: 0.07, blue: 0.085) : Color(white: 0.96))
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1),
                alignment: .top
            )
        }
    }

    // MARK: - 2. iPadOS Adaptive Three-Column Split View

    private var iPadOSSplitWorkspace: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                lutBrowserPanel
            }
            .navigationTitle("LUTs & Clips")
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    topNavigationBar
                    ZStack {
                        VideoPlayerView(engine: engine, player: player)
                        hudConfirmationBanner
                    }
                    transportToolbar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        threeWayWheelsPanel
                        Divider()
                        primarySlidersPanel
                        Divider()
                        inlineExportConfigurationPanel
                    }
                    .padding(16)
                }
                .frame(width: 340)
                .background(isDarkAppearance ? Color(red: 0.07, green: 0.07, blue: 0.085) : Color(white: 0.96))
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1),
                    alignment: .leading
                )
            }
        }
    }

    // MARK: - 3. macOS Desktop Pro Workspace (Keyboard Shortcuts + Drag & Drop)

    private var macOSProWorkspace: some View {
        NavigationSplitView {
            lutBrowserPanel
                .frame(minWidth: 250)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    topNavigationBar
                    ZStack {
                        VideoPlayerView(engine: engine, player: player)
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                handleDroppedFiles(providers: providers)
                            }
                        hudConfirmationBanner
                    }
                    transportToolbar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        threeWayWheelsPanel
                        Divider()
                        primarySlidersPanel
                        Divider()
                        inlineExportConfigurationPanel
                    }
                    .padding(18)
                }
                .frame(width: 360)
                .background(isDarkAppearance ? Color(red: 0.07, green: 0.07, blue: 0.085) : Color(white: 0.96))
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1),
                    alignment: .leading
                )
            }
        }
        .background(
            Group {
                // macOS NLE Keyboard Shortcuts: Space (Play/Pause), \ (Split Wipe), Cmd+E (Export), J/K/L (Scrub)
                Button("") { togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { toggleSplitWipe() }
                    .keyboardShortcut("\\", modifiers: [])
                Button("") { isShowingExportSheet = true }
                    .keyboardShortcut("e", modifiers: [.command])
                Button("") { scrubBy(seconds: -1.0) }
                    .keyboardShortcut("j", modifiers: [])
                Button("") { pausePlayback() }
                    .keyboardShortcut("k", modifiers: [])
                Button("") { scrubBy(seconds: 1.0) }
                    .keyboardShortcut("l", modifiers: [])
            }
            .opacity(0)
        )
    }

    // MARK: - Shared Navigation & Transport Bars (@samios 90% Primary)

    private var topNavigationBar: some View {
        HStack(spacing: 10) {
            Button {
                isImportingVideo = true
            } label: {
                Label("Open Clip", systemImage: "film")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)

            Button {
                isImportingLUT = true
            } label: {
                Label("Import .cube / HALD", systemImage: "cube")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)

            Spacer()

            Text("ColorDisco Studio")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Button {
                isDarkAppearance.toggle()
            } label: {
                Image(systemName: isDarkAppearance ? "moon.fill" : "sun.max.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Toggle Dark or Light Appearance")

            Button {
                engine.resetAllParameters()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)

            Button {
                isShowingExportSheet = true
            } label: {
                Label("Export Rec.709", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.96, green: 0.62, blue: 0.04))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var transportToolbar: some View {
        HStack(spacing: 14) {
            Button {
                scrubBy(seconds: -1.0)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .accessibilityLabel("Step Back 1 Second")

            Button {
                togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(isPlaying ? "Pause Video" : "Play Video")

            Button {
                scrubBy(seconds: 1.0)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .accessibilityLabel("Step Forward 1 Second")

            Divider()
                .frame(height: 18)

            Button {
                toggleSplitWipe()
            } label: {
                Label(
                    engine.parameters.splitComparisonNormalizedX < 0.999 ? "Split: On" : "Split Wipe",
                    systemImage: "rectangle.split.2x1"
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Button {
                engine.parameters.isBypassed.toggle()
            } label: {
                Label(
                    engine.parameters.isBypassed ? "Bypassed" : "Compare Original",
                    systemImage: "eye"
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Spacer()

            Text(engine.parameters.selectedLUT?.title ?? "Identity LUT")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var hudConfirmationBanner: some View {
        if let message = engine.statusBannerMessage {
            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.top, 46)
                Spacer()
            }
        }
    }

    // MARK: - Inspector Deck Views

    @ViewBuilder
    private var activeDeckContent: some View {
        switch selectedTab {
        case .luts:
            lutBrowserPanel
        case .wheels:
            threeWayWheelsPanel
        case .sliders:
            primarySlidersPanel
        case .export:
            inlineExportConfigurationPanel
        }
    }

    private var lutBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter 3D LUTs (.cube / HALD)", text: $lutSearchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["All", "Technical", "Film Print", "Imported"], id: \.self) { category in
                        Button {
                            selectedLUTCategory = category
                        } label: {
                            Text(category)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selectedLUTCategory == category
                                        ? Color(red: 0.96, green: 0.62, blue: 0.04)
                                        : Color.primary.opacity(0.08)
                                )
                                .foregroundStyle(selectedLUTCategory == category ? .black : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ParameterSliderRow(
                label: "LUT Intensity",
                value: $engine.parameters.lutIntensity,
                range: 0.0...1.0,
                unitFormat: "%.0f%%",
                displayMultiplier: 100.0
            )

            VStack(spacing: 6) {
                ForEach(filteredStudioPresets) { preset in
                    Button {
                        engine.selectStudioPreset(preset)
                    } label: {
                        HStack {
                            Image(systemName: engine.activePreset == preset ? "checkmark.circle.fill" : "cube.transparent")
                                .foregroundStyle(
                                    engine.activePreset == preset
                                        ? Color(red: 0.96, green: 0.62, blue: 0.04)
                                        : .secondary
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(preset.category) : 32x32x32 Float32 Cube")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.primary.opacity(engine.activePreset == preset ? 0.12 : 0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                ForEach(engine.customLUTs, id: \.title) { customLUT in
                    Button {
                        engine.parameters.selectedLUT = customLUT
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.gearshape")
                            Text(customLUT.title)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(customLUT.dimension)^3")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var filteredStudioPresets: [StudioLUTPreset] {
        StudioLUTPreset.allCases.filter { preset in
            let matchesCategory = selectedLUTCategory == "All" || preset.category == selectedLUTCategory
            let matchesQuery = lutSearchQuery.isEmpty || preset.rawValue.localizedCaseInsensitiveContains(lutSearchQuery)
            return matchesCategory && matchesQuery
        }
    }

    // MARK: - 3-Way Color Wheels (@samdesain 10% Fallback: Swiss Minimalist 1px Border)

    private var threeWayWheelsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("3-WAY COLOR WHEELS (LIFT / GAMMA / GAIN)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Zero Wheels") {
                    engine.parameters.lift = ColorWheelVector()
                    engine.parameters.gamma = ColorWheelVector()
                    engine.parameters.gain = ColorWheelVector()
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
            }

            HStack(spacing: 10) {
                ColorWheelControl(title: "LIFT (SHADOWS)", vector: $engine.parameters.lift)
                ColorWheelControl(title: "GAMMA (MIDS)", vector: $engine.parameters.gamma)
                ColorWheelControl(title: "GAIN (HIGHLIGHTS)", vector: $engine.parameters.gain)
            }
        }
    }

    private var primarySlidersPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PRIMARY COLOR & ANTI-BANDING CHAIN")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            ParameterSliderRow(
                label: "Exposure (EV)",
                value: $engine.parameters.exposure,
                range: -3.0...3.0,
                unitFormat: "%+.2f EV"
            )
            ParameterSliderRow(
                label: "S-Curve Contrast",
                value: $engine.parameters.contrast,
                range: 0.5...1.5,
                unitFormat: "%.2fx"
            )
            ParameterSliderRow(
                label: "Temperature",
                value: $engine.parameters.temperature,
                range: 3000.0...10000.0,
                unitFormat: "%.0fK"
            )
            ParameterSliderRow(
                label: "Tint (G/M)",
                value: $engine.parameters.tint,
                range: -100.0...100.0,
                unitFormat: "%+.0f"
            )
            ParameterSliderRow(
                label: "Skin Vibrance",
                value: $engine.parameters.vibrance,
                range: -1.0...1.0,
                unitFormat: "%+.2f"
            )
            ParameterSliderRow(
                label: "Saturation",
                value: $engine.parameters.saturation,
                range: 0.0...2.0,
                unitFormat: "%.2fx"
            )

            Toggle(isOn: $engine.parameters.hdrToSdrTonemapEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HDR PQ/HLG to Rec.709 Tonemap")
                        .font(.system(size: 13, weight: .medium))
                    Text("Maps Dolby Vision & HLG highlights into 100-nit SDR ceiling")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $engine.parameters.antiBandingDitherEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Triangular PDF Micro-Dither (0.5 LSB)")
                        .font(.system(size: 13, weight: .medium))
                    Text("Prevents 8-bit H.264 compression banding on Reels & TikTok")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inlineExportConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SOCIAL MEDIA MASTER EXPORT (REC. 709)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                ForEach(SocialAspectRatioPreset.allCases) { preset in
                    Text(preset.shortLabel).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            Picker("Constant Frame Rate (CFR)", selection: $selectedFrameRate) {
                Text("30 FPS (14 Mbps)").tag(ExportFrameRatePreset.fps30)
                Text("60 FPS (20 Mbps)").tag(ExportFrameRatePreset.fps60)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Text("Codec: H.264 High Profile Level 4.2 (.mp4)")
                Text("Color Tags: ITU-R BT.709-2 Primaries / Transfer / Matrix")
                Text("Target Bitrate: \(selectedFrameRate.averageBitrateBps / 1_000_000) Mbps Avg / \(selectedFrameRate.maxBitrateBps / 1_000_000) Mbps Max CFR")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                isShowingExportSheet = true
            } label: {
                HStack {
                    Image(systemName: "bolt.horizontal.circle.fill")
                    Text("Render Master Social Export")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.96, green: 0.62, blue: 0.04))
        }
    }

    private var exportMasterSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Master Social Export (Rec. 709 SDR)")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    isShowingExportSheet = false
                }
            }

            inlineExportConfigurationPanel

            if isExporting {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: exportProgress, total: 1.0)
                    Text(String(format: "Encoding H.264 Rec.709 CFR... %.0f%%", exportProgress * 100))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if let outURL = exportedFileURL {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Saved: \(outURL.lastPathComponent)")
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            HStack {
                Spacer()
                Button("Start Hardware Export") {
                    runOfflineExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || engine.currentAsset == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
    }

    // MARK: - Actions & Handlers

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func pausePlayback() {
        player.pause()
        isPlaying = false
    }

    private func scrubBy(seconds: Double) {
        let current = CMTimeGetSeconds(player.currentTime())
        let target = CMTime(seconds: max(0, current + seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func toggleSplitWipe() {
        if engine.parameters.splitComparisonNormalizedX < 0.999 {
            engine.parameters.splitComparisonNormalizedX = 1.0
        } else {
            engine.parameters.splitComparisonNormalizedX = 0.5
        }
    }

    private func handleVideoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            Task {
                do {
                    try await engine.loadVideoAsset(from: first)
                } catch {
                    activeErrorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            activeErrorMessage = error.localizedDescription
        }
    }

    private func handleLUTImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            do {
                try engine.importLUTFile(from: first)
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        case .failure(let error):
            activeErrorMessage = error.localizedDescription
        }
    }

    private func handleDroppedFiles(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                let ext = url.pathExtension.lowercased()
                if ext == "cube" || ext == "png" {
                    do {
                        try engine.importLUTFile(from: url)
                    } catch {
                        activeErrorMessage = error.localizedDescription
                    }
                } else {
                    try? await engine.loadVideoAsset(from: url)
                }
            }
        }
        return true
    }

    private func runOfflineExport() {
        guard let asset = engine.currentAsset else {
            activeErrorMessage = "Load a video clip before starting the hardware export pipeline."
            return
        }

        isExporting = true
        exportProgress = 0.0
        exportedFileURL = nil

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorDisco_Rec709_\(Int(Date().timeIntervalSince1970)).mp4")

        let stream = exporter.exportSocialMaster(
            asset: asset,
            outputURL: outputURL,
            engine: engine,
            parameters: engine.parameters,
            sourceIsHDR: engine.sourceIsHDR,
            aspectPreset: selectedAspectRatio,
            frameRatePreset: selectedFrameRate
        )

        Task {
            do {
                for try await progress in stream {
                    await MainActor.run {
                        self.exportProgress = progress
                    }
                }
                await MainActor.run {
                    self.isExporting = false
                    self.exportedFileURL = outputURL
                    self.engine.statusBannerMessage = "Export complete: Rec.709 H.264 Master"
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.activeErrorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Subcomponents (@samdesain 10% Fallback Modules)

private struct ParameterSliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let unitFormat: String
    var displayMultiplier: Float = 1.0

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(String(format: unitFormat, value * displayMultiplier))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .tint(Color(red: 0.96, green: 0.62, blue: 0.04))
        }
    }
}

private struct ColorWheelControl: View {
    let title: String
    @Binding var vector: ColorWheelVector

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let diameter = min(geo.size.width, geo.size.height)
                let radius = diameter * 0.5
                ZStack {
                    Circle()
                        .fill(Color(red: 0.09, green: 0.09, blue: 0.11))
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.22), lineWidth: 1)
                        )

                    Path { path in
                        path.move(to: CGPoint(x: radius, y: 4))
                        path.addLine(to: CGPoint(x: radius, y: diameter - 4))
                        path.move(to: CGPoint(x: 4, y: radius))
                        path.addLine(to: CGPoint(x: diameter - 4, y: radius))
                    }
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)

                    Circle()
                        .fill(Color(red: 0.96, green: 0.62, blue: 0.04))
                        .frame(width: 12, height: 12)
                        .position(
                            x: radius + CGFloat(vector.redOffset) * (radius - 10),
                            y: radius - CGFloat(vector.blueOffset) * (radius - 10)
                        )
                }
                .frame(width: diameter, height: diameter)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let dx = Float((drag.location.x - radius) / max(radius - 10, 1))
                            let dy = Float((radius - drag.location.y) / max(radius - 10, 1))
                            let clampedX = min(max(dx, -1.0), 1.0)
                            let clampedY = min(max(dy, -1.0), 1.0)
                            vector.redOffset = clampedX * 0.35
                            vector.blueOffset = clampedY * 0.35
                            vector.greenOffset = -(clampedX + clampedY) * 0.18
                        }
                )
            }
            .frame(height: 86)

            Slider(value: $vector.masterLuma, in: -0.25...0.25)
                .controlSize(.mini)

            Text(String(format: "Y:%+.2f R:%+.2f B:%+.2f", vector.masterLuma, vector.redOffset, vector.blueOffset))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

