import SwiftUI

public enum ScopeDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case waveform = "Waveform (IRE)"
    case vectorscope = "Vectorscope"
    case histogram = "RGB Parade / Hist"

    public var id: String { rawValue }
}

/// Real-time Colorist Scopes View (@samdesain 10% Fallback: Matte Zinc, 1px Border, Tabular Readout).
public struct ScopesView: View {
    public let telemetry: ScopeTelemetrySnapshot
    @State private var selectedMode: ScopeDisplayMode = .waveform

    public init(telemetry: ScopeTelemetrySnapshot) {
        self.telemetry = telemetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REAL-TIME SCOPES")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Scope Mode", selection: $selectedMode) {
                    ForEach(ScopeDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.065))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    )

                switch selectedMode {
                case .waveform:
                    waveformCanvas
                case .vectorscope:
                    vectorscopeCanvas
                case .histogram:
                    histogramCanvas
                }
            }
            .frame(height: 120)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var waveformCanvas: some View {
        Canvas { context, size in
            // Draw 0, 25, 50, 75, 100 IRE reference graticules
            for ire in [0.0, 0.25, 0.50, 0.75, 1.0] {
                let y = size.height * (1.0 - ire)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(Color.white.opacity(0.12)), lineWidth: 0.75)
            }

            let cols = telemetry.waveformColumns
            guard !cols.isEmpty else { return }
            let stepX = size.width / CGFloat(cols.count)

            for (idx, col) in cols.enumerated() {
                let x = CGFloat(idx) * stepX + stepX * 0.5
                let yMin = size.height * CGFloat(1.0 - min(max(col.x, 0), 1))
                let yAvg = size.height * CGFloat(1.0 - min(max(col.y, 0), 1))
                let yMax = size.height * CGFloat(1.0 - min(max(col.z, 0), 1))

                var bar = Path()
                bar.move(to: CGPoint(x: x, y: yMax))
                bar.addLine(to: CGPoint(x: x, y: yMin))
                context.stroke(bar, with: .color(Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.55)), lineWidth: max(1.5, stepX * 0.65))

                let dotRect = CGRect(x: x - 1.2, y: yAvg - 1.2, width: 2.4, height: 2.4)
                context.fill(Path(ellipseIn: dotRect), with: .color(.white))
            }
        }
        .padding(8)
    }

    private var vectorscopeCanvas: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let radius = min(size.width, size.height) * 0.44

            // Outer & 50% saturation rings
            let outerRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let innerRect = CGRect(x: center.x - radius * 0.5, y: center.y - radius * 0.5, width: radius, height: radius)
            context.stroke(Path(ellipseIn: outerRect), with: .color(Color.white.opacity(0.22)), lineWidth: 1)
            context.stroke(Path(ellipseIn: innerRect), with: .color(Color.white.opacity(0.12)), lineWidth: 1)

            // Crosshair
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - radius, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - radius))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            context.stroke(cross, with: .color(Color.white.opacity(0.14)), lineWidth: 0.75)

            // Dedicated Skin Tone Reference I-Line (~123 deg in Cb/Cr space)
            let skinAngle: CGFloat = -2.14
            var skinLine = Path()
            skinLine.move(to: center)
            skinLine.addLine(to: CGPoint(
                x: center.x + cos(skinAngle) * radius,
                y: center.y + sin(skinAngle) * radius
            ))
            context.stroke(skinLine, with: .color(Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.85)), lineWidth: 1.5)

            for pt in telemetry.vectorscopePoints {
                let px = center.x + CGFloat(pt.x) * radius * 1.9
                let py = center.y - CGFloat(pt.y) * radius * 1.9
                let dot = CGRect(x: px - 1.5, y: py - 1.5, width: 3.0, height: 3.0)
                context.fill(Path(ellipseIn: dot), with: .color(Color.green.opacity(0.80)))
            }
        }
        .padding(6)
    }

    private var histogramCanvas: some View {
        Canvas { context, size in
            drawHistogramCurve(context: context, size: size, bins: telemetry.redHistogram, color: .red.opacity(0.75))
            drawHistogramCurve(context: context, size: size, bins: telemetry.greenHistogram, color: .green.opacity(0.75))
            drawHistogramCurve(context: context, size: size, bins: telemetry.blueHistogram, color: .blue.opacity(0.75))
            drawHistogramCurve(context: context, size: size, bins: telemetry.lumaHistogram, color: .white.opacity(0.90))
        }
        .padding(8)
    }

    private func drawHistogramCurve(context: GraphicsContext, size: CGSize, bins: [Float], color: Color) {
        guard bins.count > 1 else { return }
        var path = Path()
        let stepX = size.width / CGFloat(bins.count - 1)
        for (i, v) in bins.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height * (1.0 - CGFloat(min(max(v, 0), 1)))
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}
