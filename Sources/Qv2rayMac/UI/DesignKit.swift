import SwiftUI
import Charts

// MARK: - Rocket artwork (same geometry as the menu bar and app icons)

/// One part of the rocket, fitted into the view's frame (room reserved for the flame).
struct RocketPartShape: Shape {
    var part: RocketGeometry.Part

    func path(in rect: CGRect) -> Path {
        Path(RocketGeometry.path(part, in: rect, flipped: true, includeFlame: true))
    }
}

/// Round badge with the rocket: idle it's an outline at rest; connected it turns solid,
/// drifts along its flight line and fires a flickering exhaust.
struct RocketBadge: View {
    var connected: Bool
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(connected
                      ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                                     startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(Color.primary.opacity(0.08)))
            if connected {
                rocket
                    .phaseAnimator([false, true]) { content, up in
                        let d = size * (up ? 0.03 : -0.03)
                        content.offset(x: d, y: -d)
                    } animation: { _ in .easeInOut(duration: 1.1) }
            } else {
                rocket
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.4), value: connected)
    }

    private var rocket: some View {
        let glyph = size * 0.68
        let line = StrokeStyle(lineWidth: max(1.1, glyph / 16), lineCap: .round, lineJoin: .round)
        return ZStack {
            if connected {
                RocketPartShape(part: .flame)
                    .fill(LinearGradient(colors: [.yellow, .orange, .red.opacity(0.05)],
                                         startPoint: UnitPoint(x: 0.45, y: 0.55), endPoint: .bottomLeading))
                    .phaseAnimator([0.6, 1.0]) { content, k in content.opacity(k) } animation: { _ in .easeInOut(duration: 0.15) }
                RocketPartShape(part: .fins).fill(Color.white.opacity(0.72))
                RocketPartShape(part: .nozzle).fill(Color.white.opacity(0.55))
                RocketPartShape(part: .body).fill(Color.white)
                RocketPartShape(part: .window).fill(Color.accentColor)
            } else {
                RocketPartShape(part: .fins).stroke(Color.primary, style: line)
                RocketPartShape(part: .nozzle).stroke(Color.primary, style: line)
                RocketPartShape(part: .body).stroke(Color.primary, style: line)
                RocketPartShape(part: .window).stroke(Color.primary, lineWidth: line.lineWidth * 0.9)
            }
        }
        .frame(width: glyph, height: glyph)
    }
}

// MARK: - Status

extension CoreState {
    var tint: Color {
        switch self {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var title: String {
        switch self {
        case .running: return L10n.tr("status.connected")
        case .starting: return L10n.tr("status.connecting")
        case .failed: return L10n.tr("status.failed")
        case .stopped: return L10n.tr("status.idle")
        }
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color == .secondary ? .clear : color.opacity(0.6), radius: size / 2)
    }
}

/// Large round connect / disconnect control (Control Center style).
struct PowerButton: View {
    var state: CoreState
    var size: CGFloat = 44
    var action: () -> Void

    private var isOn: Bool { state.isRunning }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.1)))
                if state.isStarting {
                    ProgressView().controlSize(size > 50 ? .regular : .small)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .symbolEffect(.bounce, value: isOn)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: isOn ? Color.accentColor.opacity(0.45) : .clear, radius: size / 5, y: 2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isOn ? L10n.tr("conn.disconnect") : L10n.tr("conn.connect"))
        .animation(.easeInOut(duration: 0.25), value: isOn)
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    enum Style { case window, panel }
    var style: Style = .window
    var padding: CGFloat = 16
    /// Stretch to the offered height (equal-height cards side by side).
    var fillHeight = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: style == .panel ? 12 : 14, style: .continuous)
                switch style {
                case .window:
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
                        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
                case .panel:
                    shape.fill(Color.primary.opacity(0.055))
                }
            }
    }
}

struct CardHeader: View {
    var title: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(title).font(.headline)
        }
    }
}

// MARK: - Pills & badges

struct LatencyPill: View {
    var ms: Int??
    var testing = false

    var body: some View {
        Group {
            if testing {
                ProgressView().controlSize(.mini).frame(width: 44)
            } else if let value = ms {
                if let v = value {
                    pill("\(v) ms", color: Self.color(for: v))
                } else {
                    pill(L10n.tr("conn.timeout"), color: .red)
                }
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary).frame(minWidth: 44)
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    static func color(for ms: Int) -> Color {
        ms < 200 ? .green : (ms < 600 ? .orange : .red)
    }
}

struct ProtocolBadge: View {
    var proto: ProfileProto

    var body: some View {
        Text(proto.displayName.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.14)))
            .fixedSize()
    }

    private var tint: Color {
        switch proto {
        case .vmess: return .purple
        case .vless: return .blue
        case .shadowsocks: return .teal
        case .trojan: return .pink
        case .custom: return .gray
        }
    }
}

// MARK: - Throughput chart

struct ThroughputChart: View {
    var samples: [SpeedSampler.Sample]
    var compact = false

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let series: String
    }

    private var points: [Point] {
        let down = L10n.tr("speed.down"), up = L10n.tr("speed.up")
        return samples.flatMap {
            [Point(id: "d\($0.id)", date: $0.date, value: $0.down, series: down),
             Point(id: "u\($0.id)", date: $0.date, value: $0.up, series: up)]
        }
    }

    var body: some View {
        let maxV = max(samples.map { max($0.up, $0.down) }.max() ?? 0, 64 * 1024)
        Chart(points) { p in
            AreaMark(x: .value("t", p.date), y: .value("v", p.value), stacking: .unstacked)
                .foregroundStyle(by: .value("s", p.series))
                .interpolationMethod(.catmullRom)
                .opacity(compact ? 0.35 : 0.22)
            LineMark(x: .value("t", p.date), y: .value("v", p.value))
                .foregroundStyle(by: .value("s", p.series))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2))
        }
        .chartForegroundStyleScale([L10n.tr("speed.down"): Color.blue, L10n.tr("speed.up"): Color.orange])
        .chartYScale(domain: 0...(maxV * 1.15))
        .chartXAxis(.hidden)
        .chartYAxis {
            if compact {
                AxisMarks { _ in }
            } else {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(fmtSpeed(v)).font(.caption2) }
                    }
                }
            }
        }
        .chartLegend(compact ? .hidden : .visible)
        .chartLegend(position: .top, alignment: .trailing)
        .animation(.linear(duration: 0.35), value: samples.last?.id)
    }
}

/// Big "value + caption" number used in stat tiles and the traffic readouts.
struct SpeedReadout: View {
    var symbol: String
    var value: String
    var caption: String
    var tint: Color
    var large = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(large ? .title3.weight(.semibold) : .caption.weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(large ? .title2.monospacedDigit().weight(.semibold) : .callout.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Banner

struct BannerView: View {
    var banner: AppModel.Banner
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)
                .font(.title3)
            Text(banner.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Inline "changes need a reconnect" strip used by Settings, Routing and the editor.
struct ReconnectBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.needsReconnect {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor)
                Text(L10n.tr("reconnect.needed")).font(.callout)
                Spacer()
                Button(L10n.tr("conn.reconnect")) { Task { await model.reconnect() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity)
        }
    }
}

// MARK: - Formatting helpers

extension ConnectionProfile {
    /// "VLESS · ws · tls" style subtitle.
    var subtitle: String {
        proto == .custom ? L10n.tr("conn.customConfig") : "\(proto.displayName) · \(stream.summary)"
    }
}

func fmtDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}
