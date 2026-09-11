import AppKit
import SwiftUI

/// `--snapshot <dir>`: runs the real app against demo data in a throwaway data folder,
/// captures every screen in light and dark appearance, then quits. Used for visual QA.
enum SnapshotRunner {
    static var isActive = false
    private static var outputDir = URL(fileURLWithPath: ".")
    private static var demoIDs: [String: UUID] = [:]

    /// Must run before anything touches `ProfileStore.shared`.
    static func prepare(outputDir path: String) {
        isActive = true
        outputDir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("qv2ray-snapshot-\(getpid())")
        try? FileManager.default.removeItem(at: home)
        setenv("QV2RAY_HOME", home.path, 1)
    }

    // MARK: demo data

    @MainActor
    static func seedDemoData() {
        let store = ProfileStore.shared
        store.preferences.apiEnabled = false        // no real core: keep the demo traffic
        store.preferences.corePath = "/usr/bin/true" // pretend a core is installed
        store.preferences.startMinimized = false

        func profile(_ name: String, _ proto: ProfileProto, _ host: String, _ port: Int,
                     net: TransportNetwork, sec: TlsSecurity) -> ConnectionProfile {
            var p = ConnectionProfile()
            p.name = name; p.proto = proto; p.address = host; p.port = port
            p.uuid = UUID().uuidString.lowercased()
            p.password = "demo-password"
            p.method = proto == .shadowsocks ? "2022-blake3-aes-128-gcm" : ""
            p.stream.network = net
            p.stream.security = sec
            if sec != .none { p.stream.sni = host; p.stream.fingerprint = "chrome" }
            if sec == .reality { p.stream.realityPublicKey = "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"; p.flow = "xtls-rprx-vision" }
            if net == .ws { p.stream.wsPath = "/ray" }
            return p
        }

        let mine = [
            profile("Tokyo 01", .vless, "tokyo-01.example.net", 443, net: .tcp, sec: .reality),
            profile("Hong Kong 02", .vmess, "hk-02.example.net", 443, net: .ws, sec: .tls),
            profile("Singapore Premium", .trojan, "sg.example.net", 443, net: .grpc, sec: .tls),
            profile("Los Angeles", .shadowsocks, "la.example.net", 8388, net: .tcp, sec: .none),
            profile("Frankfurt Relay", .vless, "fra.example.net", 443, net: .splithttp, sec: .tls),
        ]
        store.addProfiles(mine, to: store.defaultGroupID)

        var sub = ProfileGroup(name: "Nebula Cloud")
        sub.isSubscription = true
        sub.subscriptionURL = "https://sub.example.com/api/v1/client/subscribe?token=3f9c…"
        sub.lastUpdated = Date().addingTimeInterval(-2 * 3600)
        store.addGroup(sub)
        let subNodes = [
            ("🇯🇵 Tokyo 01", ProfileProto.vless), ("🇯🇵 Osaka 02", .vless), ("🇭🇰 Hong Kong 03", .vmess),
            ("🇸🇬 Singapore 02", .trojan), ("🇺🇸 San Jose 01", .vless), ("🇩🇪 Frankfurt 01", .shadowsocks),
            ("🇬🇧 London 02", .vmess), ("🇰🇷 Seoul 01", .trojan), ("🇦🇺 Sydney 01", .vless),
        ].enumerated().map { i, item in
            profile(item.0, item.1, "node\(i + 1).nebula.example", 443,
                    net: [.tcp, .ws, .grpc][i % 3], sec: item.1 == .shadowsocks ? .none : (i % 2 == 0 ? .reality : .tls))
        }
        store.addProfiles(subNodes, to: sub.id)

        let work = ProfileGroup(name: "Work")
        store.addGroup(work)
        store.addProfiles([profile("Office Gateway", .vmess, "gw.corp.example", 10086, net: .tcp, sec: .none)], to: work.id)

        let latencies = [38, 71, 164, 212, 488]
        for (i, p) in mine.enumerated() { store.latencies[p.id] = latencies[i] }
        for (i, p) in subNodes.enumerated() where i != 4 { store.latencies[p.id] = i == 6 ? .some(nil) : 42 + i * 37 }
        store.lastConnected = mine[0].id

        var cn = RoutingScheme.starterCNBypass()
        cn.rules.append(RouteRule(outboundTag: "block", domains: "geosite:category-ads-all"))
        store.routingSchemes.removeAll { !$0.isBuiltIn }
        store.routingSchemes.append(cn)
        store.preferences.currentRoutingSchemeID = cn.id

        demoIDs = ["tokyo": mine[0].id, "sub": sub.id, "default": store.defaultGroupID]

        let runner = CoreRunner.shared
        runner.debugSimulate(running: mine[0], version: "Xray 25.8.3 (Xray, Penetrates Everything.) 1b0d7c4")
        for line in [
            "→ Starting core for «Tokyo 01»",
            "Xray 25.8.3 (Xray, Penetrates Everything.) 1b0d7c4 (go1.24.6 darwin/arm64)",
            "2026/09/11 13:05:44 [Info] infra/conf/serial: Reading config: runtime/config.json",
            "2026/09/11 13:05:44 [Warning] core: Xray 25.8.3 started",
            "✓ Core started (pid 48211)",
            "2026/09/11 13:06:02 [Info] [2745501] proxy/http: request to Method [CONNECT] Host [www.apple.com:443]",
            "2026/09/11 13:06:03 [Info] [2745501] app/dispatcher: taking detour [direct] for [tcp:www.apple.com:443]",
            "2026/09/11 13:06:09 [Info] [3129377] app/dispatcher: taking detour [proxy] for [tcp:github.com:443]",
            "2026/09/11 13:06:31 [Error] [1022917] app/proxyman/outbound: failed to process outbound traffic > i/o timeout",
            "↻ Subscription updated: Nebula Cloud (9 nodes)",
        ] { runner.appendLog(line) }
        SpeedSampler.shared.loadDemo()
        SystemProxyManager.shared.debugSetActive(true)
    }

    // MARK: capture sequence

    @MainActor
    static func run() {
        Task { @MainActor in
            let model = AppModel.shared
            func step(_ seconds: Double = 1.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

            await step(2.5)
            // Tall enough to show the whole Overview without scrolling.
            if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                main.setContentSize(NSSize(width: 1180, height: 880))
                main.center()
            }
            captureStatusItem("00-menubar-connected")
            for appearance in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                model.sidebarSelection = .overview
                await step()
                capture("01-overview-\(appearance)")

                model.sidebarSelection = .group(demoIDs["default"]!)
                model.selectedConnectionIDs = [demoIDs["tokyo"]!]
                await step()
                capture("02-connections-\(appearance)")

                model.sidebarSelection = .group(demoIDs["sub"]!)
                model.selectedConnectionIDs = []
                await step()
                capture("03-subscription-\(appearance)")

                model.sidebarSelection = .routing
                await step()
                capture("04-routing-\(appearance)")

                model.sidebarSelection = .logs
                await step()
                capture("05-logs-\(appearance)")

                if let p = ProfileStore.shared.profile(demoIDs["tokyo"]!) {
                    model.editor = .init(profile: p, groupID: demoIDs["default"]!, isNew: false)
                    await step()
                    capture("06-editor-\(appearance)")
                    model.editor = nil
                    await step(0.6)
                }

                model.importSheet = ImportTarget(id: demoIDs["default"]!)
                await step()
                capture("07-import-\(appearance)")
                model.importSheet = nil
                await step(0.6)

                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                await step()
                capture("08-settings-\(appearance)")
                NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }.forEach { $0.close() }

                clickStatusItem()
                await step(1.5)
                capture("09-panel-\(appearance)", onlyPanels: true)
                clickStatusItem()
                await step(0.6)
            }

            // Disconnected state
            CoreRunner.shared.debugSimulate(running: nil, version: nil)
            SystemProxyManager.shared.debugSetActive(false)
            model.sidebarSelection = .overview
            await step()
            capture("10-overview-idle-dark")
            captureStatusItem("00-menubar-idle")
            clickStatusItem()
            await step(1.5)
            capture("11-panel-idle-dark", onlyPanels: true)

            print("snapshots written to \(outputDir.path)")
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func capture(_ name: String, onlyPanels: Bool = false) {
        let windows = NSApp.windows.filter { w in
            let cls = String(describing: type(of: w))
            guard w.isVisible, w.frame.width > 80, !cls.contains("StatusBar") else { return false }
            return onlyPanels ? (w.level.rawValue > NSWindow.Level.normal.rawValue) : true
        }
        for (i, w) in windows.enumerated() {
            let suffix = windows.count > 1 ? "-\(i)" : ""
            let url = outputDir.appendingPathComponent("\(name)\(suffix).png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(w.windowNumber), url.path]
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// Our menu bar item exactly as macOS renders it (real size, real menu bar tint).
    @MainActor
    private static func captureStatusItem(_ name: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("StatusBar") }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), outputDir.appendingPathComponent("\(name).png").path]
        try? p.run()
        p.waitUntilExit()
    }

    /// Open / close the MenuBarExtra panel by clicking our status item button.
    @MainActor
    private static func clickStatusItem() {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let button = findButton(in: w.contentView) { button.performClick(nil); return }
        }
    }

    private static func findButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton { return b }
        for sub in view.subviews { if let b = findButton(in: sub) { return b } }
        return nil
    }
}
