import AppKit
import SwiftUI
import UserNotifications
import Combine
import ServiceManagement

let APP_VERSION = "3.0.0"

extension Notification.Name {
    static let openMainWindow = Notification.Name("qv.openMainWindow")
    static let openSettingsWindow = Notification.Name("qv.openSettingsWindow")
}

enum SidebarItem: Hashable {
    case overview
    case group(UUID)
    case routing
    case logs
}

// MARK: - App model (central coordinator)

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = ProfileStore.shared
    let runner = CoreRunner.shared
    let stats = SpeedSampler.shared
    let proxy = SystemProxyManager.shared
    let subs = SubscriptionService.shared

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }
    struct EditorRequest: Identifiable {
        let id = UUID()
        var profile: ConnectionProfile
        var groupID: UUID
        var isNew: Bool
    }
    struct GroupEditorRequest: Identifiable {
        let id = UUID()
        var group: ProfileGroup
        var isNew: Bool
    }

    @Published var recentConnectionIDs: [UUID] = []
    @Published private(set) var testingIDs: Set<UUID> = []
    @Published var banner: Banner?
    @Published var sidebarSelection: SidebarItem? = .overview
    @Published var selectedConnectionIDs: Set<UUID> = []
    @Published var showInspector = true
    @Published var importSheet: ImportTarget? = nil
    @Published var editor: EditorRequest?
    @Published var groupEditor: GroupEditorRequest?

    private var cancellables = Set<AnyCancellable>()
    private var bannerTask: Task<Void, Never>?
    private var launched = false

    init() {
        recentConnectionIDs = UserDefaults.standard.stringArray(forKey: "recentConnections")?.compactMap(UUID.init) ?? []
        // Stats follow the core: start on every (re)start, stop when it goes away.
        runner.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .running:
                let prefs = self.store.preferences
                if prefs.apiEnabled { self.stats.start(port: prefs.apiPort, coreType: self.runner.coreType) }
            case .stopped, .failed:
                self.stats.stop()
            case .starting:
                break
            }
        }.store(in: &cancellables)
        // Re-publish nested changes so views that only observe AppModel stay fresh.
        runner.objectWillChange.merge(with: store.objectWillChange).merge(with: proxy.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func launch() {
        guard !launched else { return }
        launched = true
        runner.onCrash = { [weak self] code, willRestart in self?.handleCrash(code: code, willRestart: willRestart) }
        L10n.languageOverride = store.preferences.language
        applyAppearance()
        // Demo/snapshot mode never probes the core, fetches subscriptions or touches the system proxy.
        guard !SnapshotRunner.isActive else { return }
        runner.refreshCoreInfo()
        subs.startAutoUpdateTimer()
        Task { await proxy.recoverStaleProxy() }

        if !store.loadWarnings.isEmpty {
            showBanner(L10n.tr("store.recovered") + "\n" + store.loadWarnings.joined(separator: "\n"), error: true, sticky: true)
        }
        if store.preferences.autoConnectLast, let id = store.lastConnected, store.profile(id) != nil {
            Task { await connect(profileID: id) }
        }
        if store.preferences.checkUpdatesOnLaunch {
            Task { await checkForUpdates(interactive: false) }
        }
    }

    func shutdown() {
        stats.stop()
        runner.stopSync()
        proxy.clearSync()
    }

    // MARK: - State helpers

    var isConnected: Bool { runner.state.isRunning }
    var isBusy: Bool { runner.state.isStarting || proxy.isBusy }

    /// The routing / preference / profile inputs differ from what the running core was launched with.
    var needsReconnect: Bool {
        guard isConnected, let running = runner.currentProfile else { return false }
        let profile = store.profile(running.id) ?? running
        return CoreRunner.signature(profile: profile, prefs: store.preferences, scheme: store.currentRoutingScheme) != runner.launchSignature
    }

    /// The node "Connect" uses when nothing specific was chosen.
    var preferredProfileID: UUID? {
        if let id = selectedConnectionIDs.first(where: { store.profile($0) != nil }) { return id }
        if let id = store.lastConnected, store.profile(id) != nil { return id }
        return store.profiles(in: store.defaultGroupID).first?.id ?? store.allProfiles.first?.id
    }

    // MARK: - Connect / Disconnect

    func connect(profileID: UUID) async {
        guard let p = store.profile(profileID) else { return }
        do {
            try await runner.start(profile: p)
            if store.preferences.setSystemProxyOnConnect { await applySystemProxy() }
            pushRecent(profileID)
            Notifier.notify(title: L10n.tr("notif.connected.title"),
                            body: String(format: L10n.tr("notif.connected.body"), p.displayName))
        } catch CoreRunner.RunnerError.cancelled {
        } catch {
            let message = error.localizedDescription
            showBanner(message, error: true)
            Notifier.notify(title: L10n.tr("conn.connectionFailed"), body: message)
        }
    }

    func disconnect() async {
        await runner.stop()
        await proxy.clear()
        Notifier.notify(title: L10n.tr("notif.disconnected.title"), body: "")
    }

    func toggleConnection() async {
        if runner.state.isRunning || runner.state.isStarting {
            await disconnect()
        } else if let id = preferredProfileID {
            await connect(profileID: id)
        } else {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
            showBanner(L10n.tr("conn.empty.title"), error: true)
        }
    }

    /// Restart the running core so routing / preference / profile changes take effect.
    func reconnect() async {
        guard let running = runner.currentProfile else { return }
        let profile = store.profile(running.id) ?? running
        let hadProxy = proxy.isActive
        await runner.stop()
        do {
            try await runner.start(profile: profile)
            if hadProxy || store.preferences.setSystemProxyOnConnect { await applySystemProxy() }
        } catch CoreRunner.RunnerError.cancelled {
        } catch {
            await proxy.clear()
            showBanner(error.localizedDescription, error: true)
        }
    }

    // MARK: - System proxy

    /// The single "use system proxy" switch: applies immediately while connected and is
    /// remembered for the next connection either way.
    var systemProxyEnabled: Bool {
        isConnected ? proxy.isActive : store.preferences.setSystemProxyOnConnect
    }

    func setSystemProxy(_ on: Bool) async {
        store.preferences.setSystemProxyOnConnect = on
        store.savePrefs()
        if on {
            if isConnected { await applySystemProxy() }
        } else {
            await proxy.clear()
        }
    }

    private func applySystemProxy() async {
        let ports = runner.proxyPorts
        guard !ports.isEmpty else {
            showBanner(L10n.tr("proxy.noInbound"), error: true)
            return
        }
        let prefs = store.preferences
        await proxy.enable(host: prefs.systemProxyHost, socksPort: ports.socks, httpPort: ports.http,
                           bypass: prefs.proxyBypassDomains)
    }

    // MARK: - Routing mode

    var currentMode: RoutingMode { store.currentRoutingScheme.mode }

    var ruleSchemes: [RoutingScheme] { store.routingSchemes.filter { $0.mode == .rules } }

    func selectMode(_ mode: RoutingMode) async {
        let target: UUID
        switch mode {
        case .global: target = RoutingScheme.globalID
        case .direct: target = RoutingScheme.directID
        case .rules:
            let rules = ruleSchemes
            target = store.preferences.lastRuleSchemeID.flatMap { id in rules.first { $0.id == id }?.id }
                ?? rules.first { !$0.isBuiltIn }?.id ?? RoutingScheme.rulesID
        }
        await activateScheme(target)
    }

    func activateScheme(_ id: UUID) async {
        guard let scheme = store.routingSchemes.first(where: { $0.id == id }),
              store.preferences.currentRoutingSchemeID != id else { return }
        store.preferences.currentRoutingSchemeID = id
        if scheme.mode == .rules { store.preferences.lastRuleSchemeID = id }
        store.savePrefs()
        if isConnected { await reconnect() }
    }

    // MARK: - Latency

    func isTesting(_ id: UUID) -> Bool { testingIDs.contains(id) }

    func testLatency(ids: [UUID]) async {
        let profiles = ids.compactMap { store.profile($0) }.filter { $0.proto != .custom && !testingIDs.contains($0.id) }
        guard !profiles.isEmpty else { return }
        let set = Set(profiles.map(\.id))
        testingIDs.formUnion(set)
        defer { testingIDs.subtract(set) }
        var results = await LatencyTester.realDelay(profiles: profiles)
        if results.isEmpty {
            // No usable core: fall back to a plain TCP handshake time.
            results = await LatencyTester.tcping(profiles: profiles, timeoutMS: store.preferences.tcpingTimeoutMS)
        }
        for (id, ms) in results where store.profile(id) != nil { store.latencies[id] = ms }
        store.saveLatencies()
    }

    // MARK: - Import / editing entry points

    @discardableResult
    func importText(_ text: String, into group: UUID?) -> ShareLinks.ParseResult {
        let result = ShareLinks.parseDetailed(text)
        store.addProfiles(result.profiles, to: group)
        if result.profiles.isEmpty {
            showBanner(result.skipped.first ?? L10n.tr("import.nothingFound"), error: true)
        } else {
            var text = String(format: L10n.tr("import.imported"), result.profiles.count)
            if !result.skipped.isEmpty { text += " · " + String(format: L10n.tr("import.skippedCount"), result.skipped.count) }
            showBanner(text, error: false)
        }
        return result
    }

    var currentGroupID: UUID {
        if case .group(let id) = sidebarSelection, store.group(id) != nil { return id }
        return store.defaultGroupID
    }

    func newConnection() {
        editor = EditorRequest(profile: ConnectionProfile(), groupID: currentGroupID, isNew: true)
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    func edit(_ profile: ConnectionProfile) {
        editor = EditorRequest(profile: profile, groupID: store.groupOf(profile: profile.id) ?? currentGroupID, isNew: false)
    }

    func newGroup(subscription: Bool = false) {
        var g = ProfileGroup(name: "")
        g.isSubscription = subscription
        g.updateIntervalHours = store.preferences.subUpdateIntervalHours
        groupEditor = GroupEditorRequest(group: g, isNew: true)
    }

    func showImport() {
        importSheet = ImportTarget(id: currentGroupID)
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    func duplicate(_ ids: [UUID]) {
        for id in ids {
            guard var copy = store.profile(id) else { continue }
            copy.id = UUID()
            copy.name = copy.displayName + " " + L10n.tr("conn.copySuffix")
            store.addProfile(copy, to: store.groupOf(profile: id))
        }
    }

    // MARK: - Recent

    private func pushRecent(_ id: UUID) {
        recentConnectionIDs.removeAll { $0 == id }
        recentConnectionIDs.insert(id, at: 0)
        if recentConnectionIDs.count > 8 { recentConnectionIDs.removeLast(recentConnectionIDs.count - 8) }
        UserDefaults.standard.set(recentConnectionIDs.map(\.uuidString), forKey: "recentConnections")
    }

    func clearRecent() {
        recentConnectionIDs = []
        UserDefaults.standard.removeObject(forKey: "recentConnections")
    }

    // MARK: - Banners

    func showBanner(_ text: String, error: Bool, sticky: Bool = false) {
        banner = Banner(text: text, isError: error)
        bannerTask?.cancel()
        guard !sticky else { return }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: error ? 7_000_000_000 : 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.banner = nil }
        }
    }

    // MARK: - Crash handling

    private func handleCrash(code: Int32, willRestart: Bool) {
        Notifier.notify(title: L10n.tr("notif.crash.title"),
                        body: String(format: L10n.tr(willRestart ? "notif.crash.body" : "notif.crash.final"), code))
        if !willRestart {
            Task { await proxy.clear() }
        }
    }

    // MARK: - Appearance, login item, updates, about

    func applyAppearance() {
        let theme = store.preferences.theme
        NSApp.appearance = theme == "dark" ? NSAppearance(named: .darkAqua)
            : (theme == "light" ? NSAppearance(named: .aqua) : nil)
    }

    func applyLoginItem() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if store.preferences.startAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showBanner(error.localizedDescription, error: true)
        }
    }

    func checkForUpdates(interactive: Bool) async {
        switch await UpdateChecker.check(repo: store.preferences.updateRepo) {
        case .upToDate:
            if interactive { showBanner(L10n.tr("update.upToDate"), error: false) }
        case .available(let tag, let url):
            showBanner(String(format: L10n.tr("update.available"), tag), error: false, sticky: true)
            Notifier.notify(title: String(format: L10n.tr("update.available"), tag), body: url)
        case .notConfigured:
            if interactive { showBanner(L10n.tr("update.notConfigured"), error: true) }
        case .failed(let err):
            if interactive { showBanner(String(format: L10n.tr("update.failed"), err), error: true) }
        }
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: L10n.tr("about.project") + "\n" + L10n.tr("about.openSource") + "\n\n"
                + L10n.tr("about.core") + ": " + (runner.coreVersion ?? L10n.tr("pref.coreNotFound")),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Qv2ray for Mac",
            .applicationVersion: APP_VERSION,
            .version: "",
            .applicationIcon: AppIconGenerator.icon(size: 256),
            .credits: credits,
        ])
    }

    // MARK: - Window activation policy

    /// Behave like a normal app (Dock icon, ⌘-Tab, menu bar) while the main window is open,
    /// and like a pure menu-bar utility otherwise.
    func mainWindowVisibilityChanged(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAuth() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, !SnapshotRunner.isActive else {
            NSLog("[notify] %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - SwiftUI app

extension View {
    /// Inject the shared models every window needs.
    func qvEnvironment() -> some View {
        self.environmentObject(AppModel.shared)
            .environmentObject(ProfileStore.shared)
            .environmentObject(CoreRunner.shared)
            .environmentObject(SpeedSampler.shared)
            .environmentObject(SubscriptionService.shared)
            .environmentObject(SystemProxyManager.shared)
    }
}

struct Qv2rayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Declared first so SwiftUI doesn't auto-open the main window at launch;
        // TrayLabel opens it unless "Start minimized" is on.
        MenuBarExtra {
            MenuBarPanel().qvEnvironment()
        } label: {
            TrayLabel().qvEnvironment()
        }
        .menuBarExtraStyle(.window)

        Window("Qv2ray", id: "main") {
            MainWindowView().qvEnvironment()
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }

        Settings {
            SettingsView().qvEnvironment()
        }
    }
}

/// The menu bar icon. It is alive for the whole session, so it also acts as the bridge
/// that opens windows on behalf of AppKit code (reopen events, notifications, …).
struct TrayLabel: View {
    @EnvironmentObject private var runner: CoreRunner
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private static var didLaunch = false

    var body: some View {
        Image(nsImage: TrayIcon.image(connected: runner.state.isRunning))
            .onAppear {
                guard !Self.didLaunch else { return }
                Self.didLaunch = true
                if !ProfileStore.shared.preferences.startMinimized || SnapshotRunner.isActive {
                    openWindow(id: "main")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
    }
}

struct AppCommands: Commands {
    @ObservedObject private var model = AppModel.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.tr("tray.about")) { model.showAbout() }
            Button(L10n.tr("tray.checkUpdate")) { Task { await model.checkForUpdates(interactive: true) } }
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("conn.newConnection")) { model.newConnection() }
                .keyboardShortcut("n")
            Button(L10n.tr("import.title") + "…") { model.showImport() }
                .keyboardShortcut("i")
            Button(L10n.tr("group.new")) { model.newGroup() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu(L10n.tr("menu.connection")) {
            Button(model.isConnected ? L10n.tr("conn.disconnect") : L10n.tr("conn.connect")) {
                Task { await model.toggleConnection() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            Button(L10n.tr("conn.reconnect")) { Task { await model.reconnect() } }
                .keyboardShortcut("r")
                .disabled(!model.isConnected)
            Divider()
            Button(L10n.tr("conn.testLatency")) {
                let ids = model.selectedConnectionIDs.isEmpty
                    ? model.store.profiles(in: model.currentGroupID).map(\.id) : Array(model.selectedConnectionIDs)
                Task { await model.testLatency(ids: ids) }
            }
            .keyboardShortcut("t")
            Toggle(L10n.tr("tray.systemProxy"), isOn: Binding(
                get: { model.systemProxyEnabled },
                set: { on in Task { await model.setSystemProxy(on) } }))
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            ForEach(Array(RoutingMode.allCases.enumerated()), id: \.element) { i, mode in
                Toggle(mode.displayName, isOn: Binding(
                    get: { model.currentMode == mode },
                    set: { _ in Task { await model.selectMode(mode) } }))
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotRunner.isActive { SnapshotRunner.seedDemoData() }
        Notifier.requestAuth()
        AppModel.shared.launch()
        if SnapshotRunner.isActive { SnapshotRunner.run() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running in the menu bar
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
