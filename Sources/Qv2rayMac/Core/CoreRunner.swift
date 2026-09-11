import Foundation
import AppKit

enum CoreType: String {
    case v2ray
    case xray

    /// gRPC service path prefix used by the stats API.
    var statsServicePath: String {
        switch self {
        case .v2ray: return "/v2ray.core.app.stats.command.StatsService/"
        case .xray: return "/xray.app.stats.command.StatsService/"
        }
    }
}

enum CoreState: Equatable {
    case stopped
    case starting
    case running(pid: Int32, name: String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
    var isStarting: Bool { self == .starting }
    var failure: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}

struct LogLine: Identifiable, Equatable {
    enum Level { case info, warning, error, app }
    let id: Int
    let time: String
    let text: String
    let level: Level

    static func classify(_ text: String) -> Level {
        if let first = text.first, "→✓■✗↻".contains(first) { return .app }
        let l = text.lowercased()
        if l.contains("[error]") || l.contains("failed") || l.contains("panic") { return .error }
        if l.contains("[warning]") || l.contains("warn") { return .warning }
        return .info
    }
}

/// Launches and supervises the v2ray/Xray core process, captures logs,
/// performs crash-restart, and detects the core binary & type.
@MainActor
final class CoreRunner: ObservableObject {
    static let shared = CoreRunner()

    @Published private(set) var state: CoreState = .stopped
    @Published private(set) var currentProfile: ConnectionProfile? = nil
    @Published private(set) var coreType: CoreType = .v2ray
    @Published private(set) var detectedCorePath: String? = CoreRunner.autoDetectCore()
    @Published private(set) var coreVersion: String? = nil
    @Published private(set) var logLines: [LogLine] = []
    @Published private(set) var startedAt: Date? = nil
    /// Where the running config's local SOCKS / HTTP inbounds listen.
    @Published private(set) var proxyPorts = ConfigGenerator.ProxyPorts()
    /// Fingerprint of the inputs the running core was launched with.
    private(set) var launchSignature = ""

    /// Called when the core dies unexpectedly. `willRestart` = an automatic restart is scheduled.
    var onCrash: ((_ code: Int32, _ willRestart: Bool) -> Void)?

    private var process: Process? = nil
    private var generation = 0
    private var restartCount = 0
    private var intendedRunning = false
    /// v2ray 4.x takes `-config <path>` instead of `run -c <path>`.
    private(set) var legacyCLI = false
    private var logFileHandle: FileHandle? = nil
    private var nextLogID = 0
    private let maxLogLines = 5000

    init() {
        pruneOldLogs()
    }

    nonisolated static let candidatePaths: [String] = [
        "/opt/homebrew/bin/xray",
        "/opt/homebrew/bin/v2ray",
        "/usr/local/bin/xray",
        "/usr/local/bin/v2ray",
        "/usr/bin/xray",
        "/usr/bin/v2ray",
    ]

    nonisolated static func autoDetectCore() -> String? {
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) { return p }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            for name in ["xray", "v2ray"] {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// The geodata directory: the explicit setting, else the first known location that
    /// actually holds geoip.dat / geosite.dat (Homebrew keeps them under share/, not next
    /// to the binary). nil = let the core use its own default.
    nonisolated static func resolveAssetsDir(corePath: String, override: String) -> String? {
        if !override.isEmpty { return override }
        let fm = FileManager.default
        let binDir = URL(fileURLWithPath: corePath).resolvingSymlinksInPath().deletingLastPathComponent()
        var candidates = [binDir, binDir.appendingPathComponent("dat")]
        for name in ["xray", "v2ray"] {
            candidates.append(binDir.deletingLastPathComponent().appendingPathComponent("share/\(name)"))
            candidates.append(URL(fileURLWithPath: "/opt/homebrew/share/\(name)"))
            candidates.append(URL(fileURLWithPath: "/usr/local/share/\(name)"))
        }
        for dir in candidates {
            if fm.fileExists(atPath: dir.appendingPathComponent("geoip.dat").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("geosite.dat").path) {
                return dir.path
            }
        }
        return nil
    }

    nonisolated static func queryVersion(path: String) async -> (String, CoreType)? {
        for args in [["version"], ["-version"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let s = String(data: data, encoding: .utf8) ?? ""
            guard let first = s.split(separator: "\n").first.map(String.init), first.contains(where: \.isNumber) else { continue }
            return (first, s.contains("Xray") ? .xray : .v2ray)
        }
        return nil
    }

    func refreshCoreInfo(pathOverride: String? = nil) {
        detectedCorePath = Self.autoDetectCore()
        guard let path = resolvedCorePath(prefsPath: pathOverride) else {
            coreVersion = nil
            return
        }
        Task {
            if let (v, t) = await Self.queryVersion(path: path) {
                self.coreVersion = v
                self.coreType = t
                self.legacyCLI = v.hasPrefix("V2Ray 4.")
            } else {
                self.coreVersion = nil
            }
        }
    }

    func resolvedCorePath(prefsPath: String? = nil) -> String? {
        let p = prefsPath ?? ProfileStore.shared.preferences.corePath
        if !p.isEmpty { return p }
        return detectedCorePath
    }

    // MARK: - Start / Stop

    func start(profile: ConnectionProfile) async throws {
        if state.isRunning && currentProfile?.id == profile.id { return }
        if process != nil { await stop() }
        generation &+= 1
        let gen = generation

        let store = ProfileStore.shared
        let prefs = store.preferences
        guard let corePath = resolvedCorePath(), FileManager.default.isExecutableFile(atPath: corePath) else {
            state = .failed(L10n.tr("common.coreMissing"))
            throw RunnerError.coreMissing
        }

        // Generate config
        let config: [String: Any]
        if profile.proto == .custom {
            guard let d = profile.customConfigJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                state = .failed(L10n.tr("common.invalidJSON"))
                throw RunnerError.invalidConfig
            }
            config = ConfigGenerator.prepareCustom(obj, prefs: prefs)
        } else {
            config = ConfigGenerator.fullConfig(profile: profile, prefs: prefs, scheme: store.currentRoutingScheme)
        }

        // Pre-flight: every inbound port must be free
        for port in ConfigGenerator.inboundPorts(in: config) where PortChecker.isOccupied(port) {
            state = .failed(String(format: L10n.tr("common.portInUse"), port))
            throw RunnerError.portInUse(port)
        }

        let configURL = store.runtimeDir.appendingPathComponent("config.json")
        do {
            try jsonData(from: config).write(to: configURL, options: .atomic)
        } catch {
            state = .failed(error.localizedDescription)
            throw RunnerError.invalidConfig
        }

        appendLog("→ Starting core for «\(profile.displayName)»")
        let logMark = nextLogID
        let p = Process()
        p.executableURL = URL(fileURLWithPath: corePath)
        var args = legacyCLI ? ["-config", configURL.path] : ["run", "-c", configURL.path]
        args += prefs.extraCoreArgs.split(separator: " ").map(String.init)
        p.arguments = args
        p.currentDirectoryURL = store.runtimeDir
        var env = ProcessInfo.processInfo.environment
        if let assets = Self.resolveAssetsDir(corePath: corePath, override: prefs.assetsPath) {
            env["XRAY_LOCATION_ASSET"] = assets
            env["V2RAY_LOCATION_ASSET"] = assets
        }
        p.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { self?.handleTermination(of: proc, code: code) }
        }

        do {
            try p.run()
        } catch {
            state = .failed(error.localizedDescription)
            throw RunnerError.launchFailed
        }

        process = p
        state = .starting
        intendedRunning = true
        currentProfile = profile
        store.lastConnected = profile.id
        startLogPipe(stdout.fileHandleForReading)
        startLogPipe(stderr.fileHandleForReading)
        openLogFile()

        // Config errors usually make the core exit within a second.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard gen == generation else { throw RunnerError.cancelled }
        guard p.isRunning else {
            intendedRunning = false
            process = nil
            currentProfile = nil
            closeLogFile()
            let detail = logLines.filter { $0.id >= logMark && $0.level != .app }.suffix(3).map(\.text).joined(separator: "\n")
            state = .failed(detail.isEmpty ? L10n.tr("conn.connectionFailed") : detail)
            throw RunnerError.exitedEarly(detail)
        }

        state = .running(pid: p.processIdentifier, name: profile.displayName)
        startedAt = Date()
        proxyPorts = ConfigGenerator.proxyPorts(in: config)
        launchSignature = Self.signature(profile: profile, prefs: prefs, scheme: store.currentRoutingScheme)
        appendLog("✓ Core started (pid \(p.processIdentifier))")

        // Only a run that stays up for a minute counts as "recovered" for the restart budget.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, self.process === p, p.isRunning else { return }
            self.restartCount = 0
        }
    }

    /// Stops the core without blocking the main thread (SIGTERM, then SIGKILL after 3 s).
    func stop() async {
        generation &+= 1
        intendedRunning = false
        restartCount = 0
        let wasActive = process != nil || state.isRunning || state.isStarting
        if let p = process {
            process = nil
            if p.isRunning {
                p.terminate()
                for _ in 0..<60 where p.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        finishStop(wasActive: wasActive)
    }

    /// Blocking variant for app termination only.
    func stopSync() {
        generation &+= 1
        intendedRunning = false
        let wasActive = process != nil
        if let p = process {
            process = nil
            if p.isRunning {
                p.terminate()
                let deadline = Date().addingTimeInterval(2)
                while p.isRunning && Date() < deadline { usleep(20_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        finishStop(wasActive: wasActive)
    }

    private func finishStop(wasActive: Bool) {
        if wasActive { appendLog("■ Core stopped") }
        state = .stopped
        currentProfile = nil
        startedAt = nil
        proxyPorts = ConfigGenerator.ProxyPorts()
        launchSignature = ""
        closeLogFile()
    }

    private func handleTermination(of proc: Process, code: Int32) {
        // Ignore processes we already replaced/stopped, and exits during the startup
        // window (start() reports those itself — no spurious "crashed" notification).
        guard proc === process, intendedRunning, state.isRunning else { return }
        process = nil
        let prefs = ProfileStore.shared.preferences
        appendLog("✗ Core exited unexpectedly (code \(code))")
        let willRestart = prefs.autoRestartCore && restartCount < prefs.maxRestartAttempts
        onCrash?(code, willRestart)
        guard willRestart, let profile = currentProfile else {
            intendedRunning = false
            currentProfile = nil
            startedAt = nil
            closeLogFile()
            state = .failed(String(format: L10n.tr("notif.crash.final"), code))
            return
        }
        restartCount += 1
        appendLog("↻ Restarting core (\(restartCount)/\(prefs.maxRestartAttempts))…")
        state = .starting
        currentProfile = nil
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.intendedRunning, self.process == nil else { return }
            do {
                try await self.start(profile: profile)
            } catch RunnerError.cancelled {
            } catch {
                self.onCrash?(code, false)
            }
        }
    }

    /// Inputs that change the generated config; used to tell the user a reconnect is needed.
    static func signature(profile: ConnectionProfile, prefs: Preferences, scheme: RoutingScheme) -> String {
        var p = prefs
        // Fields that don't affect the running core.
        p.language = ""; p.theme = ""; p.startAtLogin = false; p.startMinimized = false
        p.autoConnectLast = false; p.showSpeedInTray = false; p.checkUpdatesOnLaunch = false
        p.latencyTestURL = ""; p.latencyTimeoutSec = 0; p.tcpingTimeoutMS = 0
        p.subUpdateIntervalHours = 0; p.subUserAgent = ""; p.setSystemProxyOnConnect = false
        p.proxyBypassDomains = []; p.statsIntervalMS = 0; p.autoRestartCore = false
        p.maxRestartAttempts = 0; p.updateRepo = ""; p.lastRuleSchemeID = nil
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let parts = [try? enc.encode(profile), try? enc.encode(p), try? enc.encode(scheme)]
        return parts.map { $0.map { String(decoding: $0, as: UTF8.self) } ?? "" }.joined(separator: "|")
    }

    // MARK: - Demo (snapshot mode only)

    func debugSimulate(running profile: ConnectionProfile?, version: String?) {
        if let profile {
            let store = ProfileStore.shared
            currentProfile = profile
            state = .running(pid: 0, name: profile.displayName)
            startedAt = Date().addingTimeInterval(-754)
            let prefs = store.preferences
            proxyPorts = .init(socks: prefs.useSocks ? prefs.socksPort : nil, http: prefs.useHTTP ? prefs.httpPort : nil)
            launchSignature = Self.signature(profile: profile, prefs: prefs, scheme: store.currentRoutingScheme)
        } else {
            finishStop(wasActive: false)
        }
        if let version {
            coreVersion = version
            coreType = .xray
        }
    }

    // MARK: - Logs

    private func startLogPipe(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.appendLog(text) }
        }
    }

    func appendLog(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return }
        let ts = DateFormatter.logTime.string(from: Date())
        var buffer = logLines
        for line in lines {
            buffer.append(LogLine(id: nextLogID, time: ts, text: line, level: LogLine.classify(line)))
            nextLogID += 1
            logFileHandle?.write(Data("\(ts) \(line)\n".utf8))
        }
        if buffer.count > maxLogLines { buffer.removeFirst(buffer.count - maxLogLines) }
        logLines = buffer
    }

    func clearLog() {
        logLines = []
    }

    private func openLogFile() {
        closeLogFile()
        let url = ProfileStore.shared.runtimeDir.appendingPathComponent("core-\(Int(Date().timeIntervalSince1970)).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFileHandle = try? FileHandle(forWritingTo: url)
        _ = try? logFileHandle?.seekToEnd()
    }

    private func closeLogFile() {
        try? logFileHandle?.close()
        logFileHandle = nil
    }

    /// Keep only the 10 most recent per-run log files.
    private func pruneOldLogs() {
        let dir = ProfileStore.shared.runtimeDir
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("core-") && $0.hasSuffix(".log") }
            .sorted()
        for f in files.dropLast(10) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    enum RunnerError: LocalizedError {
        case coreMissing
        case portInUse(Int)
        case invalidConfig
        case launchFailed
        case exitedEarly(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .coreMissing: return L10n.tr("common.coreMissing")
            case .portInUse(let p): return String(format: L10n.tr("common.portInUse"), p)
            case .invalidConfig: return L10n.tr("common.invalidJSON")
            case .launchFailed: return L10n.tr("common.launchFailed")
            case .exitedEarly(let detail): return detail.isEmpty ? L10n.tr("conn.connectionFailed") : detail
            case .cancelled: return nil
            }
        }
    }
}

extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

enum PortChecker {
    static func isOccupied(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // If we can connect, something is listening.
        return result == 0
    }
}
