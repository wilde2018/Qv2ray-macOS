import SwiftUI

/// "Overview": hero status + big switch, live throughput, session stats, routing & local proxy.
struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner
    @EnvironmentObject private var stats: SpeedSampler
    @EnvironmentObject private var proxy: SystemProxyManager
    @EnvironmentObject private var tun: TunManager
    @State private var copiedItem: String?

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
            if !store.data.profiles.isEmpty {
                NodeSwitch(currentID: heroProfile?.id, connected: connected)
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
        var endpoints: [(id: String, symbol: String, title: String, value: String)] = []
        if prefs.useSocks { endpoints.append(("socks", "arrow.left.arrow.right", "SOCKS5", "\(host):\(prefs.socksPort)")) }
        if prefs.useHTTP { endpoints.append(("http", "globe", "HTTP", "\(host):\(prefs.httpPort)")) }

        return Card(fillHeight: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardHeader(title: L10n.tr("dash.localProxy"), symbol: "network")
                    Spacer()
                    if !endpoints.isEmpty {
                        copyButton("shell", terminalCommand(prefs: prefs), symbol: "terminal",
                                   help: L10n.tr("dash.copyShell"))
                    }
                }

                ProxyGroup {
                    ProxyRow(symbol: "desktopcomputer", title: L10n.tr("tray.systemProxy"),
                             active: model.systemProxyEnabled) {
                        Toggle(L10n.tr("tray.systemProxy"), isOn: Binding(
                            get: { model.systemProxyEnabled },
                            set: { on in Task { await model.setSystemProxy(on) } }))
                            .disabled(proxy.isBusy)
                    }
                    ProxySeparator()
                    ProxyRow(symbol: "point.3.filled.connected.trianglepath.dotted", title: L10n.tr("tun.title"),
                             value: tun.deviceName, active: model.tunModeEnabled) {
                        Toggle(L10n.tr("tun.title"), isOn: Binding(
                            get: { model.tunModeEnabled },
                            set: { on in Task { await model.setTunMode(on) } }))
                            .disabled(model.isBusy)
                    }
                    ForEach(endpoints, id: \.id) { e in
                        ProxySeparator()
                        ProxyRow(symbol: e.symbol, title: e.title, value: e.value) {
                            copyButton(e.id, e.value, help: L10n.tr("common.copy"))
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                Spacer(minLength: 0)
            }
        }
    }

    /// Capsule button the same footprint as a small switch, so the trailing column lines up.
    /// Briefly flips to a green checkmark after copying.
    private func copyButton(_ id: String, _ text: String, symbol: String = "doc.on.doc", help: String) -> some View {
        let done = copiedItem == id
        return Button {
            copy(text)
            withAnimation(.snappy) { copiedItem = id }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                if copiedItem == id { withAnimation(.snappy) { copiedItem = nil } }
            }
        } label: {
            Image(systemName: done ? "checkmark" : symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(done ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 19)
                .background(Capsule().fill(done ? Color.green.opacity(0.16) : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
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

// MARK: - Node switch

/// Round menu button in the hero card: pick the node to use. Switches live while connected;
/// otherwise it just selects the node the toolbar's Connect button will use.
private struct NodeSwitch: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    var currentID: UUID?
    var connected: Bool

    private let size: CGFloat = 64

    var body: some View {
        let groups = store.data.groups.filter { !store.profiles(in: $0.id).isEmpty }
        VStack(spacing: 6) {
            Menu {
                if groups.count == 1, let g = groups.first {
                    nodeItems(in: g.id)
                } else {
                    ForEach(groups) { g in
                        Menu {
                            nodeItems(in: g.id)
                        } label: {
                            if let cur = currentID, store.groupOf(profile: cur) == g.id {
                                Label(g.displayName, systemImage: "checkmark")
                            } else {
                                Text(g.displayName)
                            }
                        }
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(connected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(connected ? Color.white : Color.primary)
                }
                .frame(width: size, height: size)
                .shadow(color: connected ? Color.accentColor.opacity(0.45) : .clear, radius: size / 5, y: 2)
                .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isBusy)
            .help(L10n.tr("hero.switchNode"))
            Text(L10n.tr("hero.switchNode"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.25), value: connected)
    }

    @ViewBuilder
    private func nodeItems(in groupID: UUID) -> some View {
        ForEach(store.profiles(in: groupID)) { p in
            Toggle(isOn: Binding(
                get: { p.id == currentID },
                set: { _ in Task { await model.chooseNode(p.id) } })) {
                Text(itemTitle(p))
            }
        }
    }

    private func itemTitle(_ p: ConnectionProfile) -> String {
        guard let latency = store.latencies[p.id] else { return p.displayName }
        return p.displayName + "  ·  " + (latency.map { "\($0) ms" } ?? L10n.tr("conn.timeout"))
    }
}

// MARK: - Local proxy rows

/// Inset, softly filled group of rows (System Settings style).
private struct ProxyGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                shape.fill(Color.primary.opacity(0.035))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.06)))
            }
    }
}

/// Hairline between rows, inset to start under the titles (past the icon tile).
private struct ProxySeparator: View {
    var body: some View { Divider().padding(.leading, 40) }
}

/// One compact line: icon tile · title ··· secondary value · trailing control in a fixed-width column.
/// Only two text styles (callout medium / caption secondary), so every row reads the same.
private struct ProxyRow<Trailing: View>: View {
    var symbol: String
    var title: String
    var value: String? = nil
    var active = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.07))))
                .shadow(color: active ? Color.accentColor.opacity(0.35) : .clear, radius: 3, y: 1)
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            trailing.frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .animation(.snappy, value: active)
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
