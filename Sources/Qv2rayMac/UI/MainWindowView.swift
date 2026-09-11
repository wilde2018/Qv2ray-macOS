import SwiftUI

struct ImportTarget: Identifiable, Equatable {
    let id: UUID // target group
}

/// Ask for confirmation of a destructive action (native sheet-less alert).
@MainActor
func confirmDestructive(_ title: String, message: String? = nil, button: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    if let message { alert.informativeText = message }
    alert.alertStyle = .warning
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: L10n.tr("common.cancel"))
    alert.buttons.first?.hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
}

struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .principal) { ActivityCapsule() }
            ToolbarItem(placement: .primaryAction) { connectButton }
        }
        .overlay(alignment: .top) {
            if let b = model.banner {
                BannerView(banner: b) { withAnimation { model.banner = nil } }
                    .padding(.top, 10)
                    .padding(.horizontal, 20)
            }
        }
        .animation(.spring(duration: 0.35), value: model.banner)
        .sheet(item: $model.editor) { req in
            ConnectionEditorView(request: req).qvEnvironment()
        }
        .sheet(item: $model.groupEditor) { req in
            GroupEditorView(request: req).qvEnvironment()
        }
        .sheet(item: $model.importSheet) { target in
            ImportView(targetGroup: target.id).qvEnvironment()
        }
        .onAppear { model.mainWindowVisibilityChanged(true) }
        .onDisappear { model.mainWindowVisibilityChanged(false) }
        .frame(minWidth: 880, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection ?? .overview {
        case .overview:
            DashboardView()
        case .group(let id):
            if store.group(id) != nil {
                ConnectionsView(groupID: id).id(id)
            } else {
                DashboardView()
            }
        case .routing:
            RoutingEditorView()
        case .logs:
            LogView()
        }
    }

    private var connectButton: some View {
        Button {
            Task { await model.toggleConnection() }
        } label: {
            Label(runner.state.isRunning || runner.state.isStarting ? L10n.tr("conn.disconnect") : L10n.tr("conn.connect"),
                  systemImage: "power")
        }
        .help(L10n.tr("conn.toggleHelp"))
    }
}

// MARK: - Toolbar activity capsule (Xcode-style status)

struct ActivityCapsule: View {
    @EnvironmentObject private var runner: CoreRunner
    @EnvironmentObject private var stats: SpeedSampler

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: runner.state.tint, size: 7)
            switch runner.state {
            case .running:
                Text(runner.currentProfile?.displayName ?? "").fontWeight(.medium).lineLimit(1)
                Divider().frame(height: 12)
                Label(fmtSpeed(stats.currentDown), systemImage: "arrow.down")
                    .foregroundStyle(.blue)
                Label(fmtSpeed(stats.currentUp), systemImage: "arrow.up")
                    .foregroundStyle(.orange)
            case .starting:
                Text(L10n.tr("status.connecting"))
                ProgressView().controlSize(.mini)
            case .failed(let why):
                Text(L10n.tr("status.failed")).foregroundStyle(.red)
                Text(why).foregroundStyle(.secondary).lineLimit(1)
            case .stopped:
                Text(L10n.tr("status.idle")).foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minWidth: 300, maxWidth: 440)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .animation(.easeInOut(duration: 0.2), value: runner.state)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner
    @EnvironmentObject private var subs: SubscriptionService

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Label(L10n.tr("sidebar.overview"), systemImage: "gauge.with.dots.needle.33percent")
                .tag(SidebarItem.overview)

            Section(L10n.tr("sidebar.connections")) {
                ForEach(store.data.groups) { g in
                    groupRow(g)
                        .tag(SidebarItem.group(g.id))
                        .contextMenu { groupMenu(g) }
                }
            }

            Section(L10n.tr("sidebar.network")) {
                Label(L10n.tr("sidebar.routing"), systemImage: "arrow.triangle.branch")
                    .tag(SidebarItem.routing)
                Label(L10n.tr("sidebar.log"), systemImage: "text.alignleft")
                    .badge(runner.logLines.suffix(500).filter { $0.level == .error }.count)
                    .tag(SidebarItem.logs)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func groupRow(_ g: ProfileGroup) -> some View {
        let count = store.data.order[g.id.uuidString]?.count ?? 0
        let hasCurrent = runner.currentProfile.map { store.groupOf(profile: $0.id) == g.id } ?? false
        return Label {
            HStack(spacing: 6) {
                Text(g.displayName).lineLimit(1)
                if hasCurrent && runner.state.isRunning { StatusDot(color: .green, size: 6) }
                Spacer(minLength: 0)
                if subs.updatingGroupIDs.contains(g.id) {
                    ProgressView().controlSize(.mini)
                } else if let err = subs.lastErrors[g.id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(err)
                }
            }
        } icon: {
            Image(systemName: g.isSubscription ? "antenna.radiowaves.left.and.right" : (g.isDefault ? "tray.full" : "folder"))
        }
        .badge(count)
    }

    @ViewBuilder
    private func groupMenu(_ g: ProfileGroup) -> some View {
        if g.isSubscription {
            Button(L10n.tr("group.updateNow")) {
                Task {
                    let r = await subs.update(groupID: g.id)
                    if !r.message.isEmpty { model.showBanner(r.message, error: !r.ok) }
                }
            }
        }
        Button(L10n.tr("conn.testAll")) {
            Task { await model.testLatency(ids: store.profiles(in: g.id).map(\.id)) }
        }
        Divider()
        Button(L10n.tr("group.edit") + "…") { model.groupEditor = .init(group: g, isNew: false) }
        if !g.isDefault {
            Button(L10n.tr("group.delete"), role: .destructive) {
                if confirmDestructive(String(format: L10n.tr("group.deleteConfirm"), g.displayName), button: L10n.tr("group.delete")) {
                    if case .group(g.id) = model.sidebarSelection { model.sidebarSelection = .group(store.defaultGroupID) }
                    store.deleteGroup(g.id)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L10n.tr("group.new")) { model.newGroup() }
                Button(L10n.tr("group.newSubscription")) { model.newGroup(subscription: true) }
                Divider()
                Button(L10n.tr("group.updateAll")) {
                    Task { await subs.updateAll(); model.showBanner(L10n.tr("group.updateAllDone"), error: false) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.tr("group.new"))

            Spacer()
            Text(runner.coreVersion.map { $0.components(separatedBy: " (").first ?? $0 } ?? L10n.tr("pref.coreNotFoundShort"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
