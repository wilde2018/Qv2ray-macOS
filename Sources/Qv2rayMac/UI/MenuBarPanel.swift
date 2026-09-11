import SwiftUI

/// The menu bar popover: a Control Center-style panel with the connection switch,
/// live traffic, routing mode, system proxy and a quick node picker.
struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner
    @EnvironmentObject private var stats: SpeedSampler
    @EnvironmentObject private var proxy: SystemProxyManager

    @State private var groupID: UUID?
    @State private var hovered: UUID?

    private var shownGroup: UUID {
        if let g = groupID, store.group(g) != nil { return g }
        if let cur = runner.currentProfile?.id ?? store.lastConnected, let g = store.groupOf(profile: cur) { return g }
        return store.defaultGroupID
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            if runner.state.isRunning {
                trafficCard
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let failure = runner.state.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            controlsCard
            nodesCard
            footer
        }
        .padding(12)
        .frame(width: 340)
        .animation(.spring(duration: 0.35), value: runner.state)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            RocketBadge(connected: runner.state.isRunning, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Qv2ray").font(.headline)
                HStack(spacing: 5) {
                    StatusDot(color: runner.state.tint, size: 7)
                    if runner.state.isRunning, let start = runner.startedAt {
                        Text(L10n.tr("status.connected")) + Text(" · ") + Text(start, style: .timer)
                    } else {
                        Text(runner.state.title)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            PowerButton(state: runner.state, size: 40) {
                Task { await model.toggleConnection() }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: traffic

    private var trafficCard: some View {
        Card(style: .panel, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let p = runner.currentProfile {
                    HStack(spacing: 6) {
                        ProtocolBadge(proto: p.proto)
                        Text(p.displayName).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        LatencyPill(ms: store.latencies[p.id], testing: model.isTesting(p.id))
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        SpeedReadout(symbol: "arrow.down", value: fmtSpeed(stats.currentDown),
                                     caption: L10n.tr("speed.down"), tint: .blue)
                        SpeedReadout(symbol: "arrow.up", value: fmtSpeed(stats.currentUp),
                                     caption: L10n.tr("speed.up"), tint: .orange)
                    }
                    .frame(width: 118, alignment: .leading)
                    ThroughputChart(samples: Array(stats.history.suffix(60)), compact: true)
                        .frame(height: 58)
                }
            }
        }
    }

    // MARK: controls

    private var controlsCard: some View {
        Card(style: .panel, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.tr("panel.mode"), selection: Binding(
                    get: { model.currentMode },
                    set: { mode in Task { await model.selectMode(mode) } })) {
                    ForEach(RoutingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.currentMode == .rules && model.ruleSchemes.count > 1 {
                    Menu {
                        ForEach(model.ruleSchemes) { s in
                            Button {
                                Task { await model.activateScheme(s.id) }
                            } label: {
                                if s.id == store.currentRoutingScheme.id {
                                    Label(s.localizedName, systemImage: "checkmark")
                                } else {
                                    Text(s.localizedName)
                                }
                            }
                        }
                    } label: {
                        Label(store.currentRoutingScheme.localizedName, systemImage: "arrow.triangle.branch")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Divider()

                Toggle(isOn: Binding(get: { model.systemProxyEnabled },
                                     set: { on in Task { await model.setSystemProxy(on) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.tr("tray.systemProxy")).font(.callout)
                        Text(proxySubtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(proxy.isBusy)
            }
        }
    }

    private var proxySubtitle: String {
        let prefs = store.preferences
        var parts = [prefs.systemProxyHost]
        if prefs.useSocks { parts.append("SOCKS \(prefs.socksPort)") }
        if prefs.useHTTP { parts.append("HTTP \(prefs.httpPort)") }
        return parts.joined(separator: " · ")
    }

    // MARK: nodes

    private var nodesCard: some View {
        let profiles = store.profiles(in: shownGroup)
        return Card(style: .panel, padding: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Menu {
                        ForEach(store.data.groups) { g in
                            Button(g.displayName) { groupID = g.id }
                        }
                    } label: {
                        Text(store.group(shownGroup)?.displayName ?? "").font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    Button {
                        Task { await model.testLatency(ids: profiles.map(\.id)) }
                    } label: {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("conn.testAll"))
                    .disabled(profiles.isEmpty || !model.testingIDs.isEmpty)
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)

                if profiles.isEmpty {
                    VStack(spacing: 6) {
                        Text(L10n.tr("conn.empty.title")).font(.callout).foregroundStyle(.secondary)
                        Button(L10n.tr("import.title") + "…") { model.showImport() }
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(profiles) { p in nodeRow(p) }
                        }
                    }
                    .frame(height: min(CGFloat(profiles.count) * 42, 252))
                }
            }
        }
    }

    private func nodeRow(_ p: ConnectionProfile) -> some View {
        let isCurrent = runner.currentProfile?.id == p.id && (runner.state.isRunning || runner.state.isStarting)
        return Button {
            Task { await model.connect(profileID: p.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.displayName).font(.callout).lineLimit(1)
                    Text(p.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                LatencyPill(ms: store.latencies[p.id], testing: model.isTesting(p.id))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovered == p.id ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? p.id : (hovered == p.id ? nil : hovered) }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton(L10n.tr("tray.show"), symbol: "macwindow") {
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            }
            footerButton(L10n.tr("tray.preferences"), symbol: "gearshape") {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
            footerButton(L10n.tr("tray.quit"), symbol: "power.circle") {
                NSApp.terminate(nil)
            }
        }
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
