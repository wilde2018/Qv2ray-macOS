import SwiftUI
import UniformTypeIdentifiers

/// One group's connections: sortable native table + detail inspector.
struct ConnectionsView: View {
    let groupID: UUID

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner
    @EnvironmentObject private var subs: SubscriptionService

    @State private var search = ""
    @State private var sortOrder: [KeyPathComparator<Row>] = []
    @State private var dropTargeted = false

    struct Row: Identifiable {
        let profile: ConnectionProfile
        let latencyKey: Int
        var id: UUID { profile.id }
        var name: String { profile.displayName }
        var protoName: String { profile.proto.displayName }
        var endpoint: String { profile.proto == .custom ? "—" : "\(profile.address):\(profile.port)" }
        var transport: String { profile.proto == .custom ? "—" : profile.stream.summary }
    }

    private var group: ProfileGroup? { store.group(groupID) }

    private var rows: [Row] {
        var list = store.profiles(in: groupID).map { p -> Row in
            let key: Int
            switch store.latencies[p.id] {
            case .none: key = Int.max - 1           // never tested
            case .some(.none): key = Int.max         // timed out
            case .some(.some(let v)): key = v
            }
            return Row(profile: p, latencyKey: key)
        }
        if !search.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(search) || $0.profile.address.localizedCaseInsensitiveContains(search)
                    || $0.protoName.localizedCaseInsensitiveContains(search)
            }
        }
        if !sortOrder.isEmpty { list.sort(using: sortOrder) }
        return list
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            if let g = group, g.isSubscription { subscriptionHeader(g) }
            ReconnectBar().padding(.horizontal, 12).padding(.top, model.needsReconnect ? 8 : 0)
            if rows.isEmpty {
                emptyState
            } else {
                table(rows)
            }
        }
        .navigationTitle(group?.displayName ?? "")
        .navigationSubtitle(String(format: L10n.tr("conn.count"), store.profiles(in: groupID).count))
        .searchable(text: $search, placement: .toolbar, prompt: L10n.tr("conn.search"))
        .toolbar { toolbarItems }
        .inspector(isPresented: $model.showInspector) {
            ConnectionInspector(profileID: model.selectedConnectionIDs.count == 1 ? model.selectedConnectionIDs.first : nil)
                .inspectorColumnWidth(min: 270, ideal: 300, max: 400)
        }
        .onPasteCommand(of: [.plainText, .utf8PlainText, .text]) { _ in
            if let text = NSPasteboard.general.string(forType: .string) { model.importText(text, into: groupID) }
        }
        .onDrop(of: [.fileURL, .plainText, .image], isTargeted: $dropTargeted) { providers in
            ImportActions.handleDrop(providers, into: groupID)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label(L10n.tr("import.dropHint"), systemImage: "square.and.arrow.down")
                        .font(.title3.weight(.medium)).foregroundStyle(Color.accentColor))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: table

    private func table(_ rows: [Row]) -> some View {
        Table(rows, selection: $model.selectedConnectionIDs, sortOrder: $sortOrder) {
            TableColumn(L10n.tr("col.name"), value: \.name) { row in
                HStack(spacing: 8) {
                    let isCurrent = runner.currentProfile?.id == row.id
                    Image(systemName: isCurrent ? "bolt.fill" : "circle.fill")
                        .font(.system(size: isCurrent ? 11 : 5))
                        .foregroundStyle(isCurrent ? runner.state.tint : Color.secondary.opacity(0.35))
                        .frame(width: 14)
                    Text(row.name).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 170)
            TableColumn(L10n.tr("col.protocol"), value: \.protoName) { row in
                HStack(spacing: 6) {
                    ProtocolBadge(proto: row.profile.proto)
                    Text(row.transport).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 150, ideal: 160, max: 220)
            TableColumn(L10n.tr("col.address"), value: \.endpoint) { row in
                Text(row.endpoint).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 100, ideal: 140)
            TableColumn(L10n.tr("col.latency"), value: \.latencyKey) { row in
                LatencyPill(ms: store.latencies[row.id], testing: model.isTesting(row.id))
            }
            .width(76)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(Array(ids))
        } primaryAction: { ids in
            if let id = ids.first { Task { await model.connect(profileID: id) } }
        }
    }

    // MARK: header / empty

    private func subscriptionHeader(_ g: ProfileGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.subscriptionURL).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Group {
                    if let err = subs.lastErrors[g.id] {
                        Text(err).foregroundStyle(.orange)
                    } else if let d = g.lastUpdated {
                        Text(L10n.tr("group.updated")) + Text(" ") + Text(d, style: .relative) + Text(" " + L10n.tr("group.ago"))
                    } else {
                        Text(L10n.tr("group.neverUpdated"))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if subs.updatingGroupIDs.contains(g.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task {
                        let r = await subs.update(groupID: g.id)
                        if !r.message.isEmpty { model.showBanner(r.message, error: !r.ok) }
                    }
                } label: {
                    Label(L10n.tr("group.updateNow"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            Button(L10n.tr("group.edit") + "…") { model.groupEditor = .init(group: g, isNew: false) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView {
                Label(L10n.tr("conn.empty.title"), systemImage: "tray")
            } description: {
                Text(L10n.tr("conn.empty.body"))
            } actions: {
                Button(L10n.tr("import.title") + "…") { model.showImport() }
                    .buttonStyle(.borderedProminent)
                Button(L10n.tr("conn.newConnection")) { model.newConnection() }
            }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                let ids = model.selectedConnectionIDs.isEmpty ? store.profiles(in: groupID).map(\.id) : Array(model.selectedConnectionIDs)
                Task { await model.testLatency(ids: ids) }
            } label: {
                Label(L10n.tr("conn.testLatency"), systemImage: "gauge.with.dots.needle.67percent")
            }
            .help(L10n.tr("conn.testHelp"))
            .disabled(!model.testingIDs.isEmpty)

            Menu {
                Button(L10n.tr("conn.newConnection") + "…") { model.newConnection() }
                Button(L10n.tr("import.title") + "…") { model.showImport() }
                Divider()
                Button(L10n.tr("import.qrScreen")) { Task { await ImportActions.scanScreen(into: groupID) } }
                Button(L10n.tr("import.pasteClipboard")) {
                    if let text = NSPasteboard.general.string(forType: .string) { model.importText(text, into: groupID) }
                }
            } label: {
                Label(L10n.tr("common.add"), systemImage: "plus")
            }
            .help(L10n.tr("conn.addHelp"))

            Button {
                withAnimation { model.showInspector.toggle() }
            } label: {
                Label(L10n.tr("conn.inspector"), systemImage: "sidebar.trailing")
            }
            .help(L10n.tr("conn.inspector"))
        }
    }

    // MARK: context menu

    @ViewBuilder
    private func contextMenu(_ ids: [UUID]) -> some View {
        let profiles = ids.compactMap { store.profile($0) }
        if profiles.count == 1, let p = profiles.first {
            if runner.currentProfile?.id == p.id && runner.state.isRunning {
                Button(L10n.tr("conn.disconnect")) { Task { await model.disconnect() } }
            } else {
                Button(L10n.tr("conn.connect")) { Task { await model.connect(profileID: p.id) } }
            }
        }
        if !profiles.isEmpty {
            Button(L10n.tr("conn.testLatency")) { Task { await model.testLatency(ids: ids) } }
            Divider()
            if profiles.count == 1, let p = profiles.first {
                Button(L10n.tr("conn.edit")) { model.edit(p) }
            }
            Button(L10n.tr("conn.duplicate")) { model.duplicate(ids) }
            let links = profiles.compactMap(ShareLinks.serialize)
            if !links.isEmpty {
                Button(L10n.tr("conn.copyLink")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
                    model.showBanner(String(format: L10n.tr("conn.copiedLinks"), links.count), error: false)
                }
            }
            if profiles.count == 1, let p = profiles.first {
                Button(L10n.tr("conn.exportJSON")) { exportJSON(p) }
            }
            Menu(L10n.tr("conn.moveToGroup")) {
                ForEach(store.data.groups.filter { $0.id != groupID }) { g in
                    Button(g.displayName) { store.moveProfiles(ids, to: g.id) }
                }
            }
            Divider()
            Button(L10n.tr("conn.delete"), role: .destructive) {
                if confirmDestructive(String(format: L10n.tr("conn.deleteConfirm"), ids.count), button: L10n.tr("conn.delete")) {
                    store.deleteProfiles(ids)
                    model.selectedConnectionIDs.subtract(ids)
                }
            }
        }
    }

    private func exportJSON(_ p: ConnectionProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(p.displayName).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root: [String: Any]
        if p.proto == .custom, let d = p.customConfigJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            root = obj
        } else {
            root = ["outbounds": [ConfigGenerator.outbound(for: p)]]
        }
        try? jsonData(from: root).write(to: url, options: .atomic)
    }
}

// MARK: - Inspector

struct ConnectionInspector: View {
    let profileID: UUID?

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner

    var body: some View {
        if let id = profileID, let p = store.profile(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(p)
                    shareCard(p)
                    details(p)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(L10n.tr("inspector.none"), systemImage: "sidebar.trailing",
                                   description: Text(L10n.tr("inspector.noneBody")))
        }
    }

    private func header(_ p: ConnectionProfile) -> some View {
        let isCurrent = runner.currentProfile?.id == p.id && (runner.state.isRunning || runner.state.isStarting)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProtocolBadge(proto: p.proto)
                Spacer()
                LatencyPill(ms: store.latencies[p.id], testing: model.isTesting(p.id))
            }
            Text(p.displayName).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
            Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    Task {
                        if isCurrent { await model.disconnect() } else { await model.connect(profileID: p.id) }
                    }
                } label: {
                    Label(isCurrent ? L10n.tr("conn.disconnect") : L10n.tr("conn.connect"), systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.tr("conn.editShort")) { model.edit(p) }
                Button {
                    Task { await model.testLatency(ids: [p.id]) }
                } label: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                }
                .help(L10n.tr("conn.testLatency"))
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private func shareCard(_ p: ConnectionProfile) -> some View {
        if let link = ShareLinks.serialize(p) {
            VStack(spacing: 10) {
                if let img = QRService.generate(for: link, scale: 6) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(maxWidth: 210)
                }
                Text(link)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    model.showBanner(L10n.tr("common.copied"), error: false)
                } label: {
                    Label(L10n.tr("conn.copyLink"), systemImage: "link")
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text(L10n.tr("inspector.noShare")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func details(_ p: ConnectionProfile) -> some View {
        let s = p.stream
        var rows: [(String, String)] = []
        if p.proto != .custom {
            rows.append((L10n.tr("editor.address"), p.address))
            rows.append((L10n.tr("editor.port"), String(p.port)))
            rows.append((L10n.tr("editor.transport"), s.network.displayName))
            rows.append((L10n.tr("editor.tls"), s.security.displayName))
            if !s.sni.isEmpty { rows.append(("SNI", s.sni)) }
            if !s.fingerprint.isEmpty { rows.append((L10n.tr("editor.fingerprint"), s.fingerprint)) }
            if p.proto == .vless, !p.flow.isEmpty { rows.append((L10n.tr("editor.flow"), p.flow)) }
            if p.proto == .shadowsocks { rows.append((L10n.tr("editor.method"), p.method)) }
            if p.proto == .vmess { rows.append((L10n.tr("editor.security"), p.security)) }
            if p.mux.enabled { rows.append(("Mux", String(p.mux.concurrency))) }
            if !p.outboundOverrideJSON.isEmpty { rows.append((L10n.tr("editor.override"), L10n.tr("common.on"))) }
        }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { k, v in
                GridRow {
                    Text(k).foregroundStyle(.secondary)
                    Text(v).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout)
            }
        }
    }
}
