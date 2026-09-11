import SwiftUI

/// "Overview": hero status + big switch, live throughput, session stats, routing & local proxy.
struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner
    @EnvironmentObject private var stats: SpeedSampler
    @EnvironmentObject private var proxy: SystemProxyManager

    private var coreMissing: Bool {
        runner.resolvedCorePath().map { !FileManager.default.isExecutableFile(atPath: $0) } ?? true
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if coreMissing { CoreSetupCard() }
                hero
                throughput
                statTiles
                // Same height side by side: each card fills the taller one's height.
                HStack(alignment: .top, spacing: 16) {
                    routingCard
                    proxyCard
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.tr("sidebar.overview"))
    }

    // MARK: hero

    private var heroProfile: ConnectionProfile? {
        runner.currentProfile ?? model.preferredProfileID.flatMap { store.profile($0) }
    }

    private var hero: some View {
        let connected = runner.state.isRunning
        return HStack(spacing: 20) {
            RocketBadge(connected: connected, size: 76)
            VStack(alignment: .leading, spacing: 6) {
                Text(runner.state.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(runner.state.failure != nil ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                if let p = heroProfile {
                    HStack(spacing: 8) {
                        ProtocolBadge(proto: p.proto)
                        Text(p.displayName).font(.title3.weight(.medium)).lineLimit(1)
                        if p.proto != .custom {
                            Text("\(p.address):\(String(p.port))").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    Text(L10n.tr("hero.noProfile")).foregroundStyle(.secondary)
                }
                Group {
                    if connected, let start = runner.startedAt {
                        Text(L10n.tr("hero.uptime")) + Text(" ") + Text(start, style: .timer)
                    } else if let failure = runner.state.failure {
                        Text(failure).foregroundStyle(.red)
                    } else if heroProfile != nil {
                        Text(L10n.tr("hero.ready"))
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                PowerButton(state: runner.state, size: 64) { Task { await model.toggleConnection() } }
                Text(connected ? L10n.tr("conn.disconnect") : L10n.tr("conn.connect"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if heroProfile == nil {
                Button(L10n.tr("import.title") + "…") { model.showImport() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: connected
                                     ? [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.05)]
                                     : [Color.primary.opacity(0.05), Color.primary.opacity(0.02)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        }
        .animation(.easeInOut(duration: 0.4), value: connected)
    }

    // MARK: throughput

    private var throughput: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    CardHeader(title: L10n.tr("speed.title"), symbol: "waveform.path.ecg")
                    Spacer()
                    if runner.state.isRunning && !stats.apiHealthy {
                        Label(L10n.tr("speed.apiUnavailable"), systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    SpeedReadout(symbol: "arrow.down", value: fmtSpeed(stats.currentDown), caption: L10n.tr("speed.down"), tint: .blue)
                    SpeedReadout(symbol: "arrow.up", value: fmtSpeed(stats.currentUp), caption: L10n.tr("speed.up"), tint: .orange)
                        .padding(.leading, 12)
                }
                if runner.state.isRunning && stats.history.count > 1 {
                    ThroughputChart(samples: stats.history)
                        .frame(height: 190)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text(L10n.tr("speed.noData")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 190)
                }
            }
        }
    }

    // MARK: tiles

    private var statTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
            tile(L10n.tr("speed.totalDown"), value: fmtBytes(stats.totalDown), symbol: "arrow.down.circle.fill", tint: .blue)
            tile(L10n.tr("speed.totalUp"), value: fmtBytes(stats.totalUp), symbol: "arrow.up.circle.fill", tint: .orange)
            latencyTile
            tile(L10n.tr("tile.direct"), value: fmtSpeed(stats.directDown + stats.directUp),
                 symbol: "arrow.right.circle.fill", tint: .teal)
        }
    }

    private func tile(_ title: String, value: String, symbol: String, tint: Color) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(height: 18)
                Text(value)
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }
        }
    }

    private var latencyTile: some View {
        let p = heroProfile
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L10n.tr("tile.latency"), systemImage: "bolt.horizontal.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                    Spacer()
                    if let p {
                        Button {
                            Task { await model.testLatency(ids: [p.id]) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isTesting(p.id))
                        .help(L10n.tr("conn.testLatency"))
                    }
                }
                .frame(height: 18)
                Group {
                    if let p, model.isTesting(p.id) {
                        ProgressView().controlSize(.small)
                    } else if let p, let value = store.latencies[p.id] {
                        Text(value.map { "\($0) ms" } ?? L10n.tr("conn.timeout"))
                            .foregroundStyle(value.map { LatencyPill.color(for: $0) } ?? .red)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
            }
        }
    }

    // MARK: routing & proxy

    private var routingCard: some View {
        Card(fillHeight: true) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: L10n.tr("sidebar.routing"), symbol: "arrow.triangle.branch")
                Picker(L10n.tr("panel.mode"), selection: Binding(
                    get: { model.currentMode },
                    set: { mode in Task { await model.selectMode(mode) } })) {
                    ForEach(RoutingMode.allCases, id: \.self) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    Text(L10n.tr("routing.activeScheme")).foregroundStyle(.secondary)
                    Text(store.currentRoutingScheme.localizedName).fontWeight(.medium)
                    Spacer()
                    Button(L10n.tr("routing.editRules")) { model.sidebarSelection = .routing }
                        .buttonStyle(.link)
                }
                .font(.callout)
                Spacer(minLength: 0)
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeExplanation: String {
        switch model.currentMode {
        case .rules: return L10n.tr("mode.rules.help")
        case .global: return L10n.tr("mode.global.help")
        case .direct: return L10n.tr("mode.direct.help")
        }
    }

    private var proxyCard: some View {
        let prefs = store.preferences
        let host = prefs.systemProxyHost
        return Card(fillHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: L10n.tr("dash.localProxy"), symbol: "network")
                Toggle(L10n.tr("tray.systemProxy"), isOn: Binding(
                    get: { model.systemProxyEnabled },
                    set: { on in Task { await model.setSystemProxy(on) } }))
                    .toggleStyle(.switch)
                    .disabled(proxy.isBusy)
                if prefs.useSocks { endpointRow("SOCKS5", "\(host):\(prefs.socksPort)") }
                if prefs.useHTTP { endpointRow("HTTP", "\(host):\(prefs.httpPort)") }
                Spacer(minLength: 0)
                Button {
                    copy(terminalCommand(prefs: prefs))
                    model.showBanner(L10n.tr("dash.copiedShell"), error: false)
                } label: {
                    Label(L10n.tr("dash.copyShell"), systemImage: "terminal")
                }
                .controlSize(.small)
            }
        }
    }

    private func endpointRow(_ kind: String, _ value: String) -> some View {
        HStack {
            Text(kind).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
            Spacer()
            Button { copy(value) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(L10n.tr("common.copy"))
        }
    }

    private func terminalCommand(prefs: Preferences) -> String {
        let host = prefs.systemProxyHost
        var parts: [String] = []
        if prefs.useHTTP {
            parts.append("https_proxy=http://\(host):\(prefs.httpPort)")
            parts.append("http_proxy=http://\(host):\(prefs.httpPort)")
        }
        if prefs.useSocks { parts.append("all_proxy=socks5://\(host):\(prefs.socksPort)") }
        return "export " + parts.joined(separator: " ")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Shown on the Overview when no v2ray / Xray binary can be found.
struct CoreSetupCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("setup.title")).font(.headline)
                    Text(L10n.tr("setup.body")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text("brew install xray")
                            .font(.callout.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install xray", forType: .string)
                            model.showBanner(L10n.tr("common.copied"), error: false)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                    }
                    HStack {
                        Button(L10n.tr("setup.choose")) { chooseCore() }
                            .buttonStyle(.borderedProminent)
                        Button(L10n.tr("setup.recheck")) { runner.refreshCoreInfo() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func chooseCore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = L10n.tr("pref.corePath")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.preferences.corePath = url.path
        store.savePrefs()
        runner.refreshCoreInfo()
    }
}
