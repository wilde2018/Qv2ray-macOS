import SwiftUI
import UniformTypeIdentifiers

/// Native Settings window (⌘,). Every change is saved immediately; changes that affect the
/// running core surface a "Reconnect" bar instead of restarting behind the user's back.
struct SettingsView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var runner: CoreRunner

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L10n.tr("settings.general"), systemImage: "gearshape") }
            NetworkSettings()
                .tabItem { Label(L10n.tr("settings.network"), systemImage: "network") }
            CoreSettings()
                .tabItem { Label(L10n.tr("settings.core"), systemImage: "cpu") }
            SubscriptionSettings()
                .tabItem { Label(L10n.tr("settings.subscriptions"), systemImage: "antenna.radiowaves.left.and.right") }
            AdvancedSettings()
                .tabItem { Label(L10n.tr("settings.advanced"), systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 600, height: 560)
        .onChange(of: store.preferences) { old, new in apply(old: old, new: new) }
    }

    private func apply(old: Preferences, new: Preferences) {
        store.savePrefs()
        if old.language != new.language { L10n.languageOverride = new.language }
        if old.theme != new.theme { model.applyAppearance() }
        if old.startAtLogin != new.startAtLogin { model.applyLoginItem() }
        if old.assetsPath != new.assetsPath { runner.refreshCoreInfo() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var store: ProfileStore

    var body: some View {
        Form {
            Section(L10n.tr("settings.appearance")) {
                Picker(L10n.tr("pref.language"), selection: $store.preferences.language) {
                    Text(L10n.tr("pref.system")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Picker(L10n.tr("pref.theme"), selection: $store.preferences.theme) {
                    Text(L10n.tr("pref.system")).tag("system")
                    Text(L10n.tr("pref.light")).tag("light")
                    Text(L10n.tr("pref.dark")).tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section(L10n.tr("settings.startup")) {
                Toggle(L10n.tr("pref.startAtLogin"), isOn: $store.preferences.startAtLogin)
                Toggle(L10n.tr("pref.startMinimized"), isOn: $store.preferences.startMinimized)
                Toggle(L10n.tr("pref.autoConnect"), isOn: $store.preferences.autoConnectLast)
                Toggle(L10n.tr("pref.checkUpdates"), isOn: $store.preferences.checkUpdatesOnLaunch)
            }
            Section(L10n.tr("settings.menuBar")) {
                Toggle(L10n.tr("pref.showSpeedTray"), isOn: $store.preferences.showSpeedInTray)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Network

private struct NetworkSettings: View {
    @EnvironmentObject private var store: ProfileStore
    @State private var bypassText = ""

    var body: some View {
        Form {
            Section { ReconnectBar() }
            Section(L10n.tr("pref.inbound")) {
                Toggle(L10n.tr("pref.useSocks"), isOn: $store.preferences.useSocks)
                if store.preferences.useSocks {
                    TextField(L10n.tr("pref.socksPort"), value: $store.preferences.socksPort, format: .number.grouping(.never))
                    Toggle(L10n.tr("pref.socksUDP"), isOn: $store.preferences.socksEnableUDP)
                }
                Toggle(L10n.tr("pref.useHTTP"), isOn: $store.preferences.useHTTP)
                if store.preferences.useHTTP {
                    TextField(L10n.tr("pref.httpPort"), value: $store.preferences.httpPort, format: .number.grouping(.never))
                }
                Toggle(L10n.tr("pref.sniffing"), isOn: $store.preferences.sniffingEnabled)
            }
            Section {
                Toggle(L10n.tr("pref.allowLAN"), isOn: $store.preferences.allowFromLAN)
                TextField(L10n.tr("pref.listen"), text: $store.preferences.listenAddress, prompt: Text("127.0.0.1"))
                    .disabled(store.preferences.allowFromLAN)
            } footer: {
                if store.preferences.allowFromLAN {
                    Label(L10n.tr("pref.lanWarning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section(L10n.tr("pref.proxy")) {
                Toggle(L10n.tr("pref.proxyOnConnect"), isOn: $store.preferences.setSystemProxyOnConnect)
                TextField(L10n.tr("pref.bypass"), text: $bypassText, prompt: Text("127.0.0.1, *.local"), axis: .vertical)
                    .lineLimit(2...5)
                    .onChange(of: bypassText) { _, text in
                        store.preferences.proxyBypassDomains = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
            }
            Section(L10n.tr("settings.routing")) {
                Toggle(L10n.tr("pref.bypassLAN"), isOn: $store.preferences.bypassLAN)
            }
            Section(L10n.tr("pref.outbound")) {
                TextField(L10n.tr("pref.testURL"), text: $store.preferences.latencyTestURL)
                Stepper(value: $store.preferences.latencyTimeoutSec, in: 2...30) {
                    LabeledContent(L10n.tr("pref.testTimeout"), value: "\(store.preferences.latencyTimeoutSec) s")
                }
                Stepper(value: $store.preferences.tcpingTimeoutMS, in: 500...10000, step: 500) {
                    LabeledContent(L10n.tr("pref.tcpingTimeout"), value: "\(store.preferences.tcpingTimeoutMS) ms")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { bypassText = store.preferences.proxyBypassDomains.joined(separator: ", ") }
    }
}

// MARK: - Core

private struct CoreSettings: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var runner: CoreRunner

    private var resolvedAssets: String? {
        runner.resolvedCorePath().flatMap { CoreRunner.resolveAssetsDir(corePath: $0, override: store.preferences.assetsPath) }
    }

    var body: some View {
        Form {
            Section { ReconnectBar() }
            Section {
                HStack {
                    TextField(L10n.tr("pref.corePath"), text: $store.preferences.corePath,
                              prompt: Text(runner.detectedCorePath ?? "/opt/homebrew/bin/xray"))
                        .onSubmit { runner.refreshCoreInfo() }
                    Button(L10n.tr("common.choose")) { chooseCore() }
                }
                LabeledContent(L10n.tr("pref.coreVersion")) {
                    if let v = runner.coreVersion {
                        Text(v).font(.callout.monospaced()).lineLimit(1).textSelection(.enabled)
                    } else {
                        Label(L10n.tr("pref.coreNotFound"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                HStack {
                    TextField(L10n.tr("pref.assetsPath"), text: $store.preferences.assetsPath,
                              prompt: Text(L10n.tr("pref.auto")))
                    Button(L10n.tr("common.choose")) { chooseAssets() }
                }
            } header: {
                Text(L10n.tr("pref.core"))
            } footer: {
                Text(resolvedAssets.map { String(format: L10n.tr("pref.assetsResolved"), $0) } ?? L10n.tr("pref.assetsNone"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("settings.logAPI")) {
                Picker(L10n.tr("pref.logLevel"), selection: $store.preferences.logLevel) {
                    ForEach(["debug", "info", "warning", "error", "none"], id: \.self) { Text($0) }
                }
                Toggle(L10n.tr("pref.apiEnabled"), isOn: $store.preferences.apiEnabled)
                if store.preferences.apiEnabled {
                    TextField(L10n.tr("pref.apiPort"), value: $store.preferences.apiPort, format: .number.grouping(.never))
                    Stepper(value: $store.preferences.statsIntervalMS, in: 250...5000, step: 250) {
                        LabeledContent(L10n.tr("pref.statsInterval"), value: "\(store.preferences.statsIntervalMS) ms")
                    }
                }
            }
            Section(L10n.tr("settings.reliability")) {
                Toggle(L10n.tr("pref.autoRestart"), isOn: $store.preferences.autoRestartCore)
                Stepper(value: $store.preferences.maxRestartAttempts, in: 1...50) {
                    LabeledContent(L10n.tr("pref.maxRestarts"), value: "\(store.preferences.maxRestartAttempts)")
                }
                .disabled(!store.preferences.autoRestartCore)
                TextField(L10n.tr("pref.extraArgs"), text: $store.preferences.extraCoreArgs, prompt: Text(L10n.tr("common.none")))
            }
        }
        .formStyle(.grouped)
    }

    private func chooseCore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.preferences.corePath = url.path
        runner.refreshCoreInfo()
    }

    private func chooseAssets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.preferences.assetsPath = url.path
    }
}

// MARK: - Subscriptions

private struct SubscriptionSettings: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var subs: SubscriptionService
    @EnvironmentObject private var model: AppModel
    @State private var updating = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $store.preferences.subUpdateIntervalHours, in: 0...720) {
                    LabeledContent(L10n.tr("pref.subInterval"),
                                   value: store.preferences.subUpdateIntervalHours == 0 ? L10n.tr("group.manual") : "\(store.preferences.subUpdateIntervalHours) h")
                }
                TextField(L10n.tr("pref.subUA"), text: $store.preferences.subUserAgent)
            } footer: {
                Text(L10n.tr("pref.subIntervalHelp")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                let groups = store.data.groups.filter(\.isSubscription)
                if groups.isEmpty {
                    Text(L10n.tr("settings.noSubscriptions")).foregroundStyle(.secondary)
                }
                ForEach(groups) { g in
                    LabeledContent(g.displayName) {
                        if subs.updatingGroupIDs.contains(g.id) {
                            ProgressView().controlSize(.small)
                        } else if let d = g.lastUpdated {
                            Text(d, style: .relative).foregroundStyle(.secondary)
                        } else {
                            Text(L10n.tr("group.never")).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(L10n.tr("group.updateAll")) {
                    updating = true
                    Task {
                        await subs.updateAll()
                        updating = false
                        model.showBanner(L10n.tr("group.updateAllDone"), error: false)
                    }
                }
                .disabled(updating || groups.isEmpty)
            } header: {
                Text(L10n.tr("settings.subscriptions"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                TextField(L10n.tr("pref.updateRepo"), text: $store.preferences.updateRepo, prompt: Text("owner/repo"))
                Button(L10n.tr("about.checkUpdate")) { Task { await model.checkForUpdates(interactive: true) } }
                    .disabled(store.preferences.updateRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text(L10n.tr("settings.updates"))
            } footer: {
                Text(L10n.tr("pref.updateRepoHelp")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("settings.data")) {
                LabeledContent(L10n.tr("settings.dataFolder")) {
                    Text(ProfileStore.appSupport.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button(L10n.tr("settings.showInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([ProfileStore.appSupport])
                }
            }
            Section(L10n.tr("about.title")) {
                LabeledContent(L10n.tr("about.version"), value: APP_VERSION)
                Button(L10n.tr("tray.about")) { model.showAbout() }
            }
        }
        .formStyle(.grouped)
    }
}
