import SwiftUI

/// Routing schemes: list on the left, grouped-form editor on the right. Edits save immediately;
/// if they affect the running connection a "Reconnect" bar appears.
struct RoutingEditorView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var model: AppModel

    @State private var selectedID: UUID?

    private var effectiveID: UUID {
        selectedID.flatMap { id in store.routingSchemes.first { $0.id == id }?.id }
            ?? store.currentRoutingScheme.id
    }

    private var schemeIndex: Int? { store.routingSchemes.firstIndex { $0.id == effectiveID } }

    var body: some View {
        HStack(spacing: 0) {
            schemeList
                .frame(width: 240)
            Divider()
            if let idx = schemeIndex {
                SchemeEditor(scheme: $store.routingSchemes[idx])
                    .id(store.routingSchemes[idx].id)
            } else {
                ContentUnavailableView(L10n.tr("routing.title"), systemImage: "arrow.triangle.branch")
            }
        }
        .navigationTitle(L10n.tr("sidebar.routing"))
        .onChange(of: store.routingSchemes) { _, _ in store.saveRouting() }
    }

    // MARK: list

    private var schemeList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { effectiveID }, set: { selectedID = $0 })) {
                Section(L10n.tr("routing.builtin")) {
                    ForEach(store.routingSchemes.filter(\.isBuiltIn)) { row($0) }
                }
                Section(L10n.tr("routing.custom")) {
                    ForEach(store.routingSchemes.filter { !$0.isBuiltIn }) { row($0) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            Divider()
            HStack(spacing: 2) {
                Button {
                    let s = RoutingScheme(name: String(format: L10n.tr("routing.defaultName"), store.routingSchemes.count - 2))
                    store.routingSchemes.append(s)
                    selectedID = s.id
                } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                    .help(L10n.tr("routing.newScheme"))
                Button {
                    guard let idx = schemeIndex else { return }
                    var copy = store.routingSchemes[idx]
                    copy.id = UUID()
                    copy.isBuiltIn = false
                    copy.name = copy.localizedName + " " + L10n.tr("conn.copySuffix")
                    store.routingSchemes.append(copy)
                    selectedID = copy.id
                } label: { Image(systemName: "plus.square.on.square").frame(width: 22, height: 18) }
                    .help(L10n.tr("routing.dupScheme"))
                Button {
                    deleteSelected()
                } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .help(L10n.tr("routing.delScheme"))
                    .disabled(schemeIndex.map { store.routingSchemes[$0].isBuiltIn } ?? true)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ s: RoutingScheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.mode.symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.localizedName).lineLimit(1)
                if s.mode == .rules || !s.isBuiltIn {
                    Text(s.mode == .rules ? String(format: L10n.tr("routing.ruleCount"), s.rules.filter(\.enabled).count) : s.mode.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.preferences.currentRoutingSchemeID == s.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .help(L10n.tr("routing.active"))
            }
        }
        .tag(s.id)
        .padding(.vertical, 2)
    }

    private func deleteSelected() {
        guard let idx = schemeIndex, !store.routingSchemes[idx].isBuiltIn else { return }
        let s = store.routingSchemes[idx]
        guard confirmDestructive(String(format: L10n.tr("routing.delSchemeConfirm"), s.localizedName), button: L10n.tr("common.delete")) else { return }
        let wasActive = store.preferences.currentRoutingSchemeID == s.id
        store.routingSchemes.remove(at: idx)
        selectedID = nil
        if wasActive {
            Task { await model.activateScheme(RoutingScheme.rulesID) }
        }
    }
}

// MARK: - Scheme editor

private struct SchemeEditor: View {
    @Binding var scheme: RoutingScheme
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var model: AppModel

    private var isActive: Bool { store.preferences.currentRoutingSchemeID == scheme.id }

    var body: some View {
        Form {
            Section {
                ReconnectBar()
                HStack {
                    if scheme.isBuiltIn {
                        Text(scheme.localizedName).font(.title3.weight(.semibold))
                        Image(systemName: "lock.fill").foregroundStyle(.tertiary).help(L10n.tr("routing.builtinHelp"))
                    } else {
                        TextField(L10n.tr("routing.name"), text: $scheme.name)
                            .labelsHidden()
                            .font(.title3.weight(.semibold))
                            .textFieldStyle(.plain)
                    }
                    Spacer()
                    if isActive {
                        Label(L10n.tr("routing.active"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button(L10n.tr("routing.useScheme")) { Task { await model.activateScheme(scheme.id) } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                if !scheme.isBuiltIn {
                    Picker(L10n.tr("routing.mode"), selection: $scheme.mode) {
                        ForEach(RoutingMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Picker(L10n.tr("routing.domainStrategy"), selection: $scheme.domainStrategy) {
                    ForEach(["AsIs", "IPIfNonMatch", "IPOnDemand"], id: \.self) { Text($0) }
                }
            } footer: {
                Text(modeHelp).font(.caption).foregroundStyle(.secondary)
            }

            if scheme.mode == .rules {
                ForEach(Array(scheme.rules.enumerated()), id: \.element.id) { index, _ in
                    ruleSection(index)
                }
                Section {
                    Button {
                        withAnimation { scheme.rules.append(RouteRule()) }
                    } label: {
                        Label(L10n.tr("routing.addRule"), systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text(L10n.tr("routing.syntaxHelp")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modeHelp: String {
        switch scheme.mode {
        case .rules: return L10n.tr("mode.rules.help")
        case .global: return L10n.tr("mode.global.help")
        case .direct: return L10n.tr("mode.direct.help")
        }
    }

    private func ruleSection(_ index: Int) -> some View {
        let rule = $scheme.rules[index]
        return Section {
            Picker(L10n.tr("routing.rule.outbound"), selection: rule.outboundTag) {
                Label(L10n.tr("outbound.proxy"), systemImage: "paperplane").tag("proxy")
                Label(L10n.tr("outbound.direct"), systemImage: "arrow.right").tag("direct")
                Label(L10n.tr("outbound.block"), systemImage: "nosign").tag("block")
            }
            TextField(L10n.tr("routing.rule.domains"), text: rule.domains,
                      prompt: Text("geosite:cn, domain:apple.com"), axis: .vertical)
                .lineLimit(1...4)
            TextField(L10n.tr("routing.rule.ips"), text: rule.ips,
                      prompt: Text("geoip:cn, 8.8.8.8/32"), axis: .vertical)
                .lineLimit(1...4)
            TextField(L10n.tr("routing.rule.port"), text: rule.port, prompt: Text("80, 443, 1000-2000"))
            Picker(L10n.tr("routing.rule.network"), selection: rule.network) {
                Text("TCP + UDP").tag("")
                Text("TCP").tag("tcp")
                Text("UDP").tag("udp")
            }
        } header: {
            HStack {
                Toggle(isOn: rule.enabled) {
                    Text(String(format: L10n.tr("routing.ruleN"), index + 1)).font(.headline)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Group {
                    Button { move(index, -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { move(index, 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == scheme.rules.count - 1)
                    Button(role: .destructive) {
                        _ = withAnimation { scheme.rules.remove(at: index) }
                    } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
            }
        }
        .opacity(scheme.rules[index].enabled ? 1 : 0.55)
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard scheme.rules.indices.contains(target) else { return }
        withAnimation { scheme.rules.swapAt(index, target) }
    }
}
