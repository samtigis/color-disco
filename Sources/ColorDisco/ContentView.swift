import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

public enum InspectorDeckTab: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case curves = "Curves"
    case hsl = "HSL"
    case wheels = "Wheels"
    case film = "Film"
    case luts = "LUTs"

    public var id: String { rawValue }
}

public struct ContentView: View {
    @State private var engine = ColorGradingEngine()
    @State private var player = AVPlayer()
    @State private var selectedTab: InspectorDeckTab = .basics
    @State private var selectedCurveChannel: CurveChannel = .masterLuma
    @State private var selectedHSLChannel: HSLChannel = .orange
    @State private var selectedLUTCategory: String = "All"
    @State private var lutSearchQuery: String = ""
    @State private var isPlaying: Bool = false
    @State private var isShowingScopesOverlay: Bool = true

    @State private var isImportingVideo: Bool = false
    @State private var isImportingPhoto: Bool = false
    @State private var isImportingLUT: Bool = false
    @State private var isImportingBatch: Bool = false
    @State private var isShowingExportSheet: Bool = false
    @State private var isDarkAppearance: Bool = true

    @State private var selectedAspectRatio: SocialAspectRatioPreset = .portrait9x16
    @State private var selectedFrameRate: ExportFrameRatePreset = .fps60
    @State private var selectedPhotoFormat: PhotoExportFormat = .jpegRec709
    @State private var batchQueue: [BatchExportItem] = []
    @State private var isExporting: Bool = false
    @State private var exportProgress: Float = 0.0
    @State private var exportStatusText: String = ""
    @State private var exportedFileURL: URL?
    @State private var activeErrorMessage: String?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private let videoExporter = VideoExporter()
    private let batchExporter = BatchExporter()

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
            isPresented: $isImportingPhoto,
            allowedContentTypes: [.image, .rawImage, .heic, .jpeg, .png, .tiff],
            allowsMultipleSelection: false
        ) { result in
            handlePhotoImport(result)
        }
        .fileImporter(
            isPresented: $isImportingLUT,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .png],
            allowsMultipleSelection: false
        ) { result in
            handleLUTImport(result)
        }
        .fileImporter(
            isPresented: $isImportingBatch,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .image, .rawImage, .heic, .jpeg, .png],
            allowsMultipleSelection: true
        ) { result in
            handleBatchQueueImport(result)
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

    // MARK: - 1. iPhone Compact Layout (Top Metal Canvas + Overlay Scopes + Bottom Thumb Deck)

    private var iPhoneCompactWorkspace: some View {
        VStack(spacing: 0) {
            topNavigationBar
            ZStack(alignment: .bottomTrailing) {
                VideoPlayerView(engine: engine, player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                hudConfirmationBanner

                if isShowingScopesOverlay {
                    ScopesView(telemetry: engine.scopeTelemetry)
                        .frame(width: 240)
                        .padding(10)
                }
            }
            transportToolbar
            VStack(spacing: 10) {
                Picker("Inspector Mode", selection: $selectedTab) {
                    ForEach(InspectorDeckTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 10)

                ScrollView {
                    activeDeckContent
                        .padding(.horizontal, 14)
                        .padding(.bottom, 16)
                }
                .frame(height: 310)
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

    // MARK: - 2. iPadOS Adaptive Multi-Column Split View

    private var iPadOSSplitWorkspace: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScopesView(telemetry: engine.scopeTelemetry)
                    lutBrowserPanel
                    gradeClipboardAndPresetsPanel
                }
                .padding(12)
            }
            .navigationTitle("Scopes & LUTs")
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

                VStack(spacing: 0) {
                    Picker("Inspector", selection: $selectedTab) {
                        ForEach(InspectorDeckTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(12)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            activeDeckContent
                            Divider()
                            inlineExportConfigurationPanel
                        }
                        .padding(16)
                    }
                }
                .frame(width: 370)
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

    // MARK: - 3. macOS Desktop Studio Workspace (Drag-and-Drop + Keyboard Shortcuts)

    private var macOSProWorkspace: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScopesView(telemetry: engine.scopeTelemetry)
                    lutBrowserPanel
                    gradeClipboardAndPresetsPanel
                }
                .padding(12)
            }
            .frame(minWidth: 280)
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

                VStack(spacing: 0) {
                    Picker("Deck", selection: $selectedTab) {
                        ForEach(InspectorDeckTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(12)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            activeDeckContent
                            Divider()
                            inlineExportConfigurationPanel
                        }
                        .padding(18)
                    }
                }
                .frame(width: 390)
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
                Button("") { togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { toggleSplitWipe() }
                    .keyboardShortcut("\\", modifiers: [])
                Button("") { isShowingExportSheet = true }
                    .keyboardShortcut("e", modifiers: [.command])
                Button("") { engine.copyGradeToClipboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("") { engine.pasteGradeFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
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

    // MARK: - Top Navigation & Bottom Transport Bars (@samios 90% Primary)

    private var topNavigationBar: some View {
        HStack(spacing: 8) {
            Button {
                isImportingVideo = true
            } label: {
                Label("Video", systemImage: "film")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Button {
                isImportingPhoto = true
            } label: {
                Label("Photo / ProRAW", systemImage: "camera.aperture")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Button {
                isImportingLUT = true
            } label: {
                Label(".cube / HALD", systemImage: "cube")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Spacer()

            Text("Pro Grade Studio")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Button {
                engine.copyGradeToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .help("Copy Grade Recipe")

            Button {
                engine.pasteGradeFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .help("Paste Grade Recipe")

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
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Reset All Parameters")

            Button {
                isShowingExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.96, green: 0.62, blue: 0.04))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var transportToolbar: some View {
        HStack(spacing: 12) {
            if engine.activeMediaKind == .video {
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
                        .frame(width: 26, height: 26)
                }
                .accessibilityLabel(isPlaying ? "Pause Video" : "Play Video")

                Button {
                    scrubBy(seconds: 1.0)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .accessibilityLabel("Step Forward 1 Second")

                Divider()
                    .frame(height: 16)
            }

            Button {
                toggleSplitWipe()
            } label: {
                Label(
                    engine.parameters.splitComparisonNormalizedX < 0.999 ? "A/B Split: On" : "A/B Split",
                    systemImage: "rectangle.split.2x1"
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Button {
                engine.parameters.isBypassed.toggle()
            } label: {
                Label(
                    engine.parameters.isBypassed ? "Bypassed" : "Hold Original",
                    systemImage: "eye"
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Button {
                isShowingScopesOverlay.toggle()
            } label: {
                Label("Scopes", systemImage: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Spacer()

            Text(engine.parameters.selectedLUT?.title ?? "Identity LUT")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
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

    // MARK: - Inspector Deck Switcher

    @ViewBuilder
    private var activeDeckContent: some View {
        switch selectedTab {
        case .basics:
            primarySlidersPanel
        case .curves:
            parametricToneCurvesPanel
        case .hsl:
            eightChannelHSLPanel
        case .wheels:
            threeWayWheelsPanel
        case .film:
            filmEmulationPanel
        case .luts:
            VStack(alignment: .leading, spacing: 16) {
                lutBrowserPanel
                Divider()
                gradeClipboardAndPresetsPanel
            }
        }
    }

    // MARK: - Tab 1: Basics (Apple Log, HDR Tonemap, Exposure, WB, Highlights/Shadows/Whites/Blacks)

    private var primarySlidersPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INPUT NORMALIZATION & PRIMARY GRADE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Toggle(isOn: $engine.parameters.basics.appleLogToRec709Enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Log to Rec.709 Transform")
                        .font(.system(size: 13, weight: .medium))
                    Text("One-click iPhone 15/16 Pro Log normalization")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $engine.parameters.basics.hdrToSdrTonemapEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HDR10 / Dolby Vision to Rec.709 Tonemap")
                        .font(.system(size: 13, weight: .medium))
                    Text("Compresses PQ/HLG highlights into 100-nit SDR ceiling")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            ParameterSliderRow(label: "Exposure (EV)", value: $engine.parameters.basics.exposure, range: -3.0...3.0, unitFormat: "%+.2f EV")
            ParameterSliderRow(label: "Contrast", value: $engine.parameters.basics.contrast, range: 0.5...1.5, unitFormat: "%.2fx")
            ParameterSliderRow(label: "S-Curve Contrast", value: $engine.parameters.basics.sCurveContrast, range: 0.0...1.0, unitFormat: "%.0f%%", displayMultiplier: 100)
            ParameterSliderRow(label: "Temperature (K)", value: $engine.parameters.basics.temperature, range: 3000.0...10000.0, unitFormat: "%.0fK")
            ParameterSliderRow(label: "Tint (G/M)", value: $engine.parameters.basics.tint, range: -100.0...100.0, unitFormat: "%+.0f")
            ParameterSliderRow(label: "Highlights", value: $engine.parameters.basics.highlights, range: -1.0...1.0, unitFormat: "%+.2f")
            ParameterSliderRow(label: "Shadows", value: $engine.parameters.basics.shadows, range: -1.0...1.0, unitFormat: "%+.2f")
            ParameterSliderRow(label: "Whites", value: $engine.parameters.basics.whites, range: -1.0...1.0, unitFormat: "%+.2f")
            ParameterSliderRow(label: "Blacks", value: $engine.parameters.basics.blacks, range: -1.0...1.0, unitFormat: "%+.2f")
            ParameterSliderRow(label: "Skin Vibrance", value: $engine.parameters.basics.vibrance, range: -1.0...1.0, unitFormat: "%+.2f")
            ParameterSliderRow(label: "Saturation", value: $engine.parameters.basics.saturation, range: 0.0...2.0, unitFormat: "%.2fx")
        }
    }

    // MARK: - Tab 2: 4-Channel RGB & Luma Parametric Bezier Tone Curves

    private var parametricToneCurvesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("4-CHANNEL PARAMETRIC TONE CURVES")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Curve") {
                    engine.parameters.curves[selectedCurveChannel] = CurvePoints()
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
            }

            Picker("Channel", selection: $selectedCurveChannel) {
                ForEach(CurveChannel.allCases) { ch in
                    Text(ch.rawValue).tag(ch)
                }
            }
            .pickerStyle(.segmented)

            ToneCurveInteractiveView(
                points: Binding(
                    get: { engine.parameters.curves[selectedCurveChannel] },
                    set: { engine.parameters.curves[selectedCurveChannel] = $0 }
                ),
                channel: selectedCurveChannel
            )
            .frame(height: 180)

            HStack(spacing: 8) {
                Button("Matte / Faded Blacks") {
                    var pts = engine.parameters.curves[selectedCurveChannel]
                    pts.p0 = CurveControlPoint(x: 0.00, y: 0.08)
                    pts.p1 = CurveControlPoint(x: 0.25, y: 0.27)
                    engine.parameters.curves[selectedCurveChannel] = pts
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))

                Button("Film S-Curve") {
                    var pts = engine.parameters.curves[selectedCurveChannel]
                    pts.p0 = CurveControlPoint(x: 0.00, y: 0.00)
                    pts.p1 = CurveControlPoint(x: 0.25, y: 0.19)
                    pts.p2 = CurveControlPoint(x: 0.50, y: 0.50)
                    pts.p3 = CurveControlPoint(x: 0.75, y: 0.81)
                    pts.p4 = CurveControlPoint(x: 1.00, y: 1.00)
                    engine.parameters.curves[selectedCurveChannel] = pts
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
            }
        }
    }

    // MARK: - Tab 3: Secondary 8-Channel HSL Warper + Skin Tone Protection Lock

    private var eightChannelHSLPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("8-CHANNEL HSL WARPER")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Zero HSL") {
                    for ch in HSLChannel.allCases {
                        engine.parameters.hslSegments[ch] = HSLSegment()
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
            }

            Toggle(isOn: $engine.parameters.skinToneProtectionLock) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skin Tone Protection Lock")
                        .font(.system(size: 13, weight: .medium))
                    Text("Protects Orange/Red human skin locus during intense Teal & Orange shifts")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(HSLChannel.allCases) { ch in
                        Button {
                            selectedHSLChannel = ch
                        } label: {
                            Text(ch.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selectedHSLChannel == ch
                                        ? Color(red: 0.96, green: 0.62, blue: 0.04)
                                        : Color.primary.opacity(0.08)
                                )
                                .foregroundStyle(selectedHSLChannel == ch ? .black : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            let segmentBinding = Binding<HSLSegment>(
                get: { engine.parameters.hslSegments[selectedHSLChannel] ?? HSLSegment() },
                set: { engine.parameters.hslSegments[selectedHSLChannel] = $0 }
            )

            ParameterSliderRow(
                label: "\(selectedHSLChannel.rawValue) Hue Shift",
                value: segmentBinding.hueShift,
                range: -1.0...1.0,
                unitFormat: "%+.2f"
            )
            ParameterSliderRow(
                label: "\(selectedHSLChannel.rawValue) Saturation",
                value: segmentBinding.saturation,
                range: -1.0...1.0,
                unitFormat: "%+.2f"
            )
            ParameterSliderRow(
                label: "\(selectedHSLChannel.rawValue) Luminance",
                value: segmentBinding.luminance,
                range: -1.0...1.0,
                unitFormat: "%+.2f"
            )
        }
    }

    // MARK: - Tab 4: 3-Way Color Wheels (Lift / Gamma / Gain)

    private var threeWayWheelsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("3-WAY COLOR WHEELS (LIFT / GAMMA / GAIN)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Zero Wheels") {
                    engine.parameters.wheels = ColorWheelOffsets()
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
            }

            HStack(spacing: 10) {
                ColorWheelControl(title: "LIFT (SHADOWS)", vector: $engine.parameters.wheels.lift)
                ColorWheelControl(title: "GAMMA (MIDS)", vector: $engine.parameters.wheels.gamma)
                ColorWheelControl(title: "GAIN (HIGHLIGHTS)", vector: $engine.parameters.wheels.gain)
            }
        }
    }

    // MARK: - Tab 5: Film Emulation Engine (Halation, Procedural Grain, Anti-Banding Dither)

    private var filmEmulationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FILM EMULATION ENGINE (HALATION & ORGANIC GRAIN)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            ParameterSliderRow(
                label: "Halation Intensity",
                value: $engine.parameters.film.halationIntensity,
                range: 0.0...1.0,
                unitFormat: "%.0f%%",
                displayMultiplier: 100
            )
            ParameterSliderRow(
                label: "Halation Edge Threshold",
                value: $engine.parameters.film.halationThreshold,
                range: 0.40...0.95,
                unitFormat: "%.2f IRE"
            )
            ParameterSliderRow(
                label: "Halation Scatter Radius",
                value: $engine.parameters.film.halationRadius,
                range: 4.0...28.0,
                unitFormat: "%.1f px"
            )

            Divider()

            ParameterSliderRow(
                label: "Dynamic Film Grain Amount",
                value: $engine.parameters.film.grainIntensity,
                range: 0.0...1.0,
                unitFormat: "%.0f%%",
                displayMultiplier: 100
            )
            ParameterSliderRow(
                label: "Film Grain Size (16mm / 35mm)",
                value: $engine.parameters.film.grainSize,
                range: 0.5...3.0,
                unitFormat: "%.2fx"
            )
            ParameterSliderRow(
                label: "Emulsion Roughness",
                value: $engine.parameters.film.grainRoughness,
                range: 0.0...1.0,
                unitFormat: "%.0f%%",
                displayMultiplier: 100
            )

            Divider()

            Toggle(isOn: $engine.parameters.antiBandingDitherEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anti-Banding Triangular Micro-Dither (0.5 LSB)")
                        .font(.system(size: 13, weight: .medium))
                    Text("Prevents 8-bit quantization banding on flat skies when compressed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Tab 6: 3D LUT Browser + Copy/Paste Grade & JSON Presets

    private var lutBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter 3D LUTs (.cube 17^3-65^3 / HALD)", text: $lutSearchQuery)
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
                label: "3D LUT Opacity / Intensity",
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

    private var gradeClipboardAndPresetsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GRADE MANAGEMENT & CLIPBOARD")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    engine.copyGradeToClipboard()
                } label: {
                    Label("Copy Grade", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    engine.pasteGradeFromClipboard()
                } label: {
                    Label("Paste Grade", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(engine.copiedGradeClipboard == nil)
            }

            Button {
                engine.saveCurrentPreset(named: "Recipe \(engine.savedPresets.count + 1)")
            } label: {
                Label("Save Current Recipe to Local Presets", systemImage: "bookmark.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if !engine.savedPresets.isEmpty {
                ForEach(Array(engine.savedPresets.enumerated()), id: \.offset) { _, saved in
                    Button {
                        engine.parameters = saved
                        engine.statusBannerMessage = "Loaded Preset: \(saved.presetName)"
                    } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                            Text(saved.presetName)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("Apply")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.05))
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

    // MARK: - Social Media & Batch Export Configuration

    private var inlineExportConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SOCIAL MEDIA & BATCH EXPORT (REC. 709)")
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

            Picker("Still Photo Format", selection: $selectedPhotoFormat) {
                ForEach(PhotoExportFormat.allCases) { fmt in
                    Text(fmt.rawValue).tag(fmt)
                }
            }

            HStack(spacing: 8) {
                Button {
                    isImportingBatch = true
                } label: {
                    Label("Add Batch Clips/Photos (\(batchQueue.count))", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                isShowingExportSheet = true
            } label: {
                HStack {
                    Image(systemName: "bolt.horizontal.circle.fill")
                    Text("Open Export & Batch Queue")
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
                Text("Master Social & Batch Exporter (Rec. 709 SDR)")
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
                    Text(exportStatusText.isEmpty ? String(format: "Encoding Rec.709... %.0f%%", exportProgress * 100) : exportStatusText)
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
                if !batchQueue.isEmpty {
                    Button("Run Batch Export (\(batchQueue.count) Items)") {
                        runBatchOfflineExport()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExporting)
                }
                Spacer()
                Button("Export Current Media") {
                    runSingleOfflineExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || (engine.currentAsset == nil && engine.currentPhotoImage == nil))
            }
        }
        .padding(24)
        .frame(minWidth: 420)
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

    private func handlePhotoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            do {
                try engine.loadPhotoAsset(from: first)
            } catch {
                activeErrorMessage = error.localizedDescription
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

    private func handleBatchQueueImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let photoExts: Set<String> = ["dng", "raw", "heic", "jpg", "jpeg", "png", "tiff"]
            for url in urls {
                let kind: MediaItemKind = photoExts.contains(url.pathExtension.lowercased()) ? .photo : .video
                batchQueue.append(BatchExportItem(sourceURL: url, kind: kind))
            }
            engine.statusBannerMessage = "Queued \(urls.count) items for Batch Export"
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
                    try? engine.importLUTFile(from: url)
                } else if ["dng", "raw", "heic", "jpg", "jpeg", "tiff"].contains(ext) {
                    try? engine.loadPhotoAsset(from: url)
                } else {
                    try? await engine.loadVideoAsset(from: url)
                }
            }
        }
        return true
    }

    private func runSingleOfflineExport() {
        isExporting = true
        exportProgress = 0.0
        exportStatusText = ""
        exportedFileURL = nil

        if engine.activeMediaKind == .photo, let photoCI = engine.currentPhotoImage {
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ColorDisco_Photo_\(Int(Date().timeIntervalSince1970)).\(selectedPhotoFormat.fileExtension)")
            Task {
                do {
                    try batchExporter.exportGradedPhoto(
                        sourceImage: photoCI,
                        outputURL: outURL,
                        engine: engine,
                        parameters: engine.parameters,
                        format: selectedPhotoFormat
                    )
                    await MainActor.run {
                        self.exportProgress = 1.0
                        self.isExporting = false
                        self.exportedFileURL = outURL
                        self.engine.statusBannerMessage = "Exported Photo (\(selectedPhotoFormat.fileExtension.uppercased()))"
                    }
                } catch {
                    await MainActor.run {
                        self.isExporting = false
                        self.activeErrorMessage = error.localizedDescription
                    }
                }
            }
            return
        }

        guard let asset = engine.currentAsset else {
            isExporting = false
            activeErrorMessage = "Load a video clip or ProRAW/photo before starting export."
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorDisco_Rec709_\(Int(Date().timeIntervalSince1970)).mp4")

        let stream = videoExporter.exportSocialMaster(
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

    private func runBatchOfflineExport() {
        guard !batchQueue.isEmpty else { return }
        isExporting = true
        exportProgress = 0.0
        let outDir = FileManager.default.temporaryDirectory

        let stream = batchExporter.exportBatch(
            items: batchQueue,
            outputDirectory: outDir,
            engine: engine,
            parameters: engine.parameters,
            aspectPreset: selectedAspectRatio,
            frameRatePreset: selectedFrameRate,
            photoFormat: selectedPhotoFormat
        )

        Task {
            do {
                for try await batchStatus in stream {
                    await MainActor.run {
                        self.exportProgress = batchStatus.overallFraction
                        self.exportStatusText = "Batch (\(batchStatus.completedItems)/\(batchStatus.totalItems)): \(batchStatus.currentFileName)"
                    }
                }
                await MainActor.run {
                    self.isExporting = false
                    self.exportedFileURL = outDir
                    self.engine.statusBannerMessage = "Completed Batch Export (\(batchQueue.count) items)"
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

// MARK: - Subcomponents (@samdesain 10% Fallback Modules: Curves, Wheels, Sliders)

private struct ToneCurveInteractiveView: View {
    @Binding var points: CurvePoints
    let channel: CurveChannel

    private var strokeColor: Color {
        switch channel {
        case .masterLuma: return .white
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.065))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.20), lineWidth: 1)
                    )

                // Quarter grid lines + diagonal reference
                Path { path in
                    for f in [0.25, 0.50, 0.75] {
                        path.move(to: CGPoint(x: w * f, y: 0))
                        path.addLine(to: CGPoint(x: w * f, y: h))
                        path.move(to: CGPoint(x: 0, y: h * f))
                        path.addLine(to: CGPoint(x: w, y: h * f))
                    }
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w, y: 0))
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 1)

                // Spline Path
                Path { path in
                    let pts = [points.p0, points.p1, points.p2, points.p3, points.p4]
                    for (idx, pt) in pts.enumerated() {
                        let cgPt = CGPoint(x: CGFloat(pt.x) * w, y: (1.0 - CGFloat(pt.y)) * h)
                        if idx == 0 {
                            path.move(to: cgPt)
                        } else {
                            path.addLine(to: cgPt)
                        }
                    }
                }
                .stroke(strokeColor, lineWidth: 2)

                // 5 Interactive Control Handles
                curveHandle(point: $points.p0, width: w, height: h)
                curveHandle(point: $points.p1, width: w, height: h)
                curveHandle(point: $points.p2, width: w, height: h)
                curveHandle(point: $points.p3, width: w, height: h)
                curveHandle(point: $points.p4, width: w, height: h)
            }
        }
    }

    private func curveHandle(point: Binding<CurveControlPoint>, width: CGFloat, height: CGFloat) -> some View {
        Circle()
            .fill(Color(red: 0.96, green: 0.62, blue: 0.04))
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
            .position(
                x: CGFloat(point.wrappedValue.x) * width,
                y: (1.0 - CGFloat(point.wrappedValue.y)) * height
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newY = Float(1.0 - min(max(drag.location.y / height, 0.0), 1.0))
                        point.wrappedValue.y = newY
                    }
            )
    }
}

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
