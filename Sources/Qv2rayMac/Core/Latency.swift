import Foundation
import Network

/// Latency testing: TCP connect time (tcping) and real HTTP delay through a temporary core instance.
enum LatencyTester {

    // MARK: TCPing

    static func tcping(host: String, port: Int, timeoutMS: Int) async -> Int? {
        await withCheckedContinuation { c in
            // One serial queue for the connection callbacks *and* the timeout, so `resumed`
            // is never touched concurrently.
            let queue = DispatchQueue(label: "qv.tcping")
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 443, using: .tcp)
            let start = Date()
            var resumed = false
            let resume: (Int?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                c.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(max(1, Int(Date().timeIntervalSince(start) * 1000)))
                case .failed, .cancelled: resume(nil)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMS)) { resume(nil) }
        }
    }

    static func tcping(profiles: [ConnectionProfile], timeoutMS: Int) async -> [UUID: Int?] {
        await withTaskGroup(of: (UUID, Int?).self) { group in
            for p in profiles {
                group.addTask { (p.id, await tcping(host: p.address, port: p.port, timeoutMS: timeoutMS)) }
            }
            var dict: [UUID: Int?] = [:]
            for await (id, ms) in group { dict[id] = ms }
            return dict
        }
    }

    // MARK: Real delay

    private struct TestContext {
        var corePath: String
        var arguments: [String]
        var configURL: URL
        var runtimeDir: URL
        var assetsPath: String?
        var testURL: String
        var timeout: Int
    }

    @MainActor
    private static func prepareContext() -> TestContext? {
        let store = ProfileStore.shared
        let runner = CoreRunner.shared
        guard let corePath = runner.resolvedCorePath(), FileManager.default.isExecutableFile(atPath: corePath) else { return nil }
        let prefs = store.preferences
        let configURL = store.runtimeDir.appendingPathComponent("latency-test.json")
        return TestContext(corePath: corePath,
                           arguments: runner.legacyCLI ? ["-config", configURL.path] : ["run", "-c", configURL.path],
                           configURL: configURL, runtimeDir: store.runtimeDir,
                           assetsPath: CoreRunner.resolveAssetsDir(corePath: corePath, override: prefs.assetsPath),
                           testURL: prefs.latencyTestURL, timeout: prefs.latencyTimeoutSec)
    }

    /// Runs a temporary core instance with one inbound per profile and measures the
    /// HTTP round-trip through each proxy, in parallel (Qv2ray's "real delay").
    /// Returns [:] when no core is available.
    static func realDelay(profiles: [ConnectionProfile]) async -> [UUID: Int?] {
        guard !profiles.isEmpty else { return [:] }
        let basePort = findFreePortBlock(count: profiles.count)
        guard basePort > 0, let ctx = await prepareContext() else { return [:] }

        let (config, ports) = ConfigGenerator.latencyTestConfig(profiles: profiles, basePort: basePort)
        guard let data = try? jsonData(from: config), (try? data.write(to: ctx.configURL, options: .atomic)) != nil else { return [:] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ctx.corePath)
        proc.arguments = ctx.arguments
        proc.currentDirectoryURL = ctx.runtimeDir
        var env = ProcessInfo.processInfo.environment
        if let assets = ctx.assetsPath {
            env["XRAY_LOCATION_ASSET"] = assets
            env["V2RAY_LOCATION_ASSET"] = assets
        }
        proc.environment = env
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        do { try proc.run() } catch { return [:] }
        defer { if proc.isRunning { proc.terminate() } }

        // Give the core a moment to bind
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard proc.isRunning else { return [:] }

        return await withTaskGroup(of: (UUID, Int?).self) { group in
            for p in profiles {
                guard let port = ports[p.id] else { continue }
                group.addTask {
                    (p.id, await httpThroughSOCKS(urlString: ctx.testURL, socksPort: port, timeout: ctx.timeout))
                }
            }
            var dict: [UUID: Int?] = [:]
            for await (id, ms) in group { dict[id] = ms }
            return dict
        }
    }

    static func httpThroughSOCKS(urlString: String, socksPort: Int, timeout: Int) async -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(timeout)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSProxyPort": socksPort,
        ]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (100..<500).contains(http.statusCode) else { return nil }
            return max(1, Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return nil
        }
    }

    private static func findFreePortBlock(count: Int) -> Int {
        for base in stride(from: 30000, through: 60000, by: 200) {
            if (base..<base + max(count, 1)).allSatisfy({ !PortChecker.isOccupied($0) }) {
                return base
            }
        }
        return 0
    }
}
