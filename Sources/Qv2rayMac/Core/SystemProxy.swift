import Foundation

/// Sets/clears the macOS system proxy via `networksetup` (every enabled network service,
/// like Qv2ray's macOS backend). All process spawning happens off the main thread.
@MainActor
final class SystemProxyManager: ObservableObject {
    static let shared = SystemProxyManager()

    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    private var services: [String] = []

    /// Persisted so a crashed session's proxy settings can be undone on next launch.
    private static let setByUsKey = "systemProxySetByQv2ray"

    /// Snapshot/demo mode only: flip the published state without touching the system.
    func debugSetActive(_ on: Bool) { isActive = on }

    func enable(host: String, socksPort: Int?, httpPort: Int?, bypass: [String]) async {
        guard !SnapshotRunner.isActive, socksPort != nil || httpPort != nil else { return }
        isBusy = true
        defer { isBusy = false }
        let list = await Task.detached(priority: .userInitiated) { () -> [String] in
            let list = Self.enabledServices()
            for svc in list {
                if let http = httpPort {
                    Self.run(["-setwebproxy", svc, host, String(http)])
                    Self.run(["-setsecurewebproxy", svc, host, String(http)])
                    Self.run(["-setwebproxystate", svc, "on"])
                    Self.run(["-setsecurewebproxystate", svc, "on"])
                } else {
                    Self.run(["-setwebproxystate", svc, "off"])
                    Self.run(["-setsecurewebproxystate", svc, "off"])
                }
                if let socks = socksPort {
                    Self.run(["-setsocksfirewallproxy", svc, host, String(socks)])
                    Self.run(["-setsocksfirewallproxystate", svc, "on"])
                } else {
                    Self.run(["-setsocksfirewallproxystate", svc, "off"])
                }
                Self.run(["-setproxybypassdomains", svc] + (bypass.isEmpty ? ["Empty"] : bypass))
            }
            return list
        }.value
        services = list
        isActive = !list.isEmpty
        UserDefaults.standard.set(isActive, forKey: Self.setByUsKey)
    }

    func clear(force: Bool = false) async {
        guard !SnapshotRunner.isActive, isActive || force else { return }
        isBusy = true
        defer { isBusy = false }
        let known = services
        await Task.detached(priority: .userInitiated) {
            Self.clearServices(known.isEmpty ? Self.enabledServices() : known)
        }.value
        services = []
        isActive = false
        UserDefaults.standard.set(false, forKey: Self.setByUsKey)
    }

    /// Blocking variant for app termination only.
    func clearSync() {
        guard !SnapshotRunner.isActive, isActive else { return }
        Self.clearServices(services.isEmpty ? Self.enabledServices() : services)
        services = []
        isActive = false
        UserDefaults.standard.set(false, forKey: Self.setByUsKey)
    }

    /// If the previous session ended without restoring the proxy (crash / force quit),
    /// the Mac would be left pointing at a dead local port — undo it.
    func recoverStaleProxy() async {
        if UserDefaults.standard.bool(forKey: Self.setByUsKey) {
            await clear(force: true)
        }
    }

    nonisolated private static func clearServices(_ list: [String]) {
        for svc in list {
            run(["-setwebproxystate", svc, "off"])
            run(["-setsecurewebproxystate", svc, "off"])
            run(["-setsocksfirewallproxystate", svc, "off"])
        }
    }

    nonisolated static func enabledServices() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallnetworkservices"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            // First line is an explanatory header; a leading '*' marks a disabled service.
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n").dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("*") }
        } catch {
            return []
        }
    }

    nonisolated private static func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }
}
