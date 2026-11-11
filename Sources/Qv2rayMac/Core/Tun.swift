import Foundation

/// TUN mode: captures all of the Mac's IPv4 traffic with a utun device and feeds it into the
/// core's local SOCKS inbound through an external `tun2socks` binary
/// (github.com/xjasonlyu/tun2socks).
///
/// Creating a utun device and changing routes needs root, so a small supervisor shell script is
/// launched once per session through the standard macOS administrator prompt. It starts
/// tun2socks, configures the device, routes 0.0.0.0/1 + 128.0.0.0/1 into it and then waits; it
/// tears everything down when the app asks (a stop file), when tun2socks dies, or when the app
/// itself goes away — so a crash or force quit never leaves the Mac routed into a dead tunnel.
///
/// Loop prevention: while TUN is on, the core binds every outbound to the physical interface
/// (Xray `sockopt.interface`), so the proxy's own traffic never re-enters the tunnel.
@MainActor
final class TunManager: ObservableObject {
    static let shared = TunManager()

    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var deviceName: String? = nil

    static let tunAddress = "198.18.0.1"

    private var supervisorPID: pid_t = 0
    private var socksPort: Int? = nil
    private var watchTask: Task<Void, Never>? = nil

    /// Called when the tunnel goes down without being asked to (tun2socks crashed / was killed).
    var onUnexpectedStop: (() -> Void)?

    enum TunError: LocalizedError {
        case binaryMissing, needsXray, needsSocks, noNetwork, cancelled, failed(String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing: return L10n.tr("tun.err.binary")
            case .needsXray: return L10n.tr("tun.err.xray")
            case .needsSocks: return L10n.tr("tun.err.socks")
            case .noNetwork: return L10n.tr("tun.err.network")
            case .cancelled: return nil
            case .failed(let detail): return String(format: L10n.tr("tun.err.failed"), detail)
            }
        }
    }

    private var stateDir: URL { ProfileStore.shared.runtimeDir.appendingPathComponent("tun", isDirectory: true) }
    private var stopFile: URL { stateDir.appendingPathComponent("tun.stop") }
    private var readyFile: URL { stateDir.appendingPathComponent("tun.ready") }
    private var failedFile: URL { stateDir.appendingPathComponent("tun.failed") }
    var logFile: URL { stateDir.appendingPathComponent("tun.log") }

    /// Snapshot/demo mode only.
    func debugSetActive(_ on: Bool) {
        isActive = on
        deviceName = on ? "utun123" : nil
    }

    // MARK: - Binary detection

    nonisolated static let candidatePaths = [
        "/opt/homebrew/bin/tun2socks",
        "/usr/local/bin/tun2socks",
    ]

    nonisolated static func autoDetectBinary() -> String? {
        if let bundled = BundledTools.tun2socks { return bundled }
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) { return p }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/tun2socks"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func resolvedBinaryPath() -> String? {
        let p = ProfileStore.shared.preferences.tunBinaryPath
        if !p.isEmpty { return FileManager.default.isExecutableFile(atPath: p) ? p : nil }
        return Self.autoDetectBinary()
    }

    // MARK: - Network helpers

    /// The interface carrying the default route (e.g. "en0"). TUN only adds the two /1 routes,
    /// so this keeps returning the physical interface while the tunnel is up.
    nonisolated static func defaultInterface() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "interface", !parts[1].isEmpty, !parts[1].hasPrefix("utun") {
                return parts[1]
            }
        }
        return nil
    }

    /// A utun name not currently in use (tun2socks creates it).
    nonisolated static func freeDeviceName() -> String {
        let existing = interfaceNames()
        for n in 123..<200 where !existing.contains("utun\(n)") { return "utun\(n)" }
        return "utun233"
    }

    nonisolated private static func interfaceNames() -> Set<String> {
        var names = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return names }
        defer { freeifaddrs(head) }
        var cur = head
        while let p = cur {
            names.insert(String(cString: p.pointee.ifa_name))
            cur = p.pointee.ifa_next
        }
        return names
    }

    // MARK: - Start / Stop

    /// Brings the tunnel up in front of the core's SOCKS inbound. Prompts for an administrator
    /// password. No-op when already up for the same port.
    func start(socksHost: String, socksPort: Int) async throws {
        guard !SnapshotRunner.isActive else { return }
        if isActive && self.socksPort == socksPort { return }
        if isActive { await stop() }
        guard let binary = resolvedBinaryPath() else { throw TunError.binaryMissing }

        isBusy = true
        defer { isBusy = false }

        let fm = FileManager.default
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        for f in [stopFile, readyFile, failedFile] { try? fm.removeItem(at: f) }

        let device = Self.freeDeviceName()
        let host = socksHost.contains(":") ? "[\(socksHost)]" : socksHost
        let args = [binary, device, Self.tunAddress, "socks5://\(host):\(socksPort)",
                    String(getpid()), stateDir.path, logFile.path]

        let launch = await Task.detached(priority: .userInitiated) { Self.launchPrivileged(args: args) }.value
        switch launch {
        case .cancelled: throw TunError.cancelled
        case .error(let msg): throw TunError.failed(msg)
        case .ok: break
        }

        // The supervisor reports back through files in the state directory.
        for _ in 0..<100 {
            if let s = try? String(contentsOf: readyFile, encoding: .utf8),
               let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                supervisorPID = pid
                self.socksPort = socksPort
                deviceName = device
                isActive = true
                CoreRunner.shared.appendLog("✓ TUN up on \(device) → SOCKS \(socksPort)")
                watch()
                return
            }
            if let s = try? String(contentsOf: failedFile, encoding: .utf8) {
                throw TunError.failed(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Never became ready: make sure a late supervisor still tears itself down.
        fm.createFile(atPath: stopFile.path, contents: nil)
        throw TunError.failed(lastLogLines() ?? L10n.tr("tun.err.timeout"))
    }

    func stop() async {
        guard isActive || supervisorPID != 0 else { return }
        isBusy = true
        defer { isBusy = false }
        watchTask?.cancel()
        watchTask = nil
        FileManager.default.createFile(atPath: stopFile.path, contents: nil)
        let pid = supervisorPID
        for _ in 0..<40 where Self.isAlive(pid) { try? await Task.sleep(nanoseconds: 100_000_000) }
        markStopped()
        CoreRunner.shared.appendLog("■ TUN stopped")
    }

    /// App termination: ask the supervisor to clean up (it also notices our exit by itself).
    func stopSync() {
        guard isActive || supervisorPID != 0 else { return }
        watchTask?.cancel()
        FileManager.default.createFile(atPath: stopFile.path, contents: nil)
        let deadline = Date().addingTimeInterval(2)
        while Self.isAlive(supervisorPID) && Date() < deadline { usleep(50_000) }
        markStopped()
    }

    private func markStopped() {
        supervisorPID = 0
        socksPort = nil
        deviceName = nil
        isActive = false
    }

    private func watch() {
        watchTask?.cancel()
        let pid = supervisorPID
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if !Self.isAlive(pid) {
                    self.markStopped()
                    self.watchTask = nil
                    CoreRunner.shared.appendLog("✗ TUN exited unexpectedly" + (self.lastLogLines().map { ": \($0)" } ?? ""))
                    self.onUnexpectedStop?()
                    return
                }
            }
        }
    }

    private func lastLogLines() -> String? {
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return nil }
        let lines = s.split(separator: "\n").suffix(2).joined(separator: "\n")
        return lines.isEmpty ? nil : lines
    }

    /// The supervisor runs as root, so kill(0) answers EPERM while it's alive.
    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Privileged launch

    enum LaunchResult { case ok, cancelled, error(String) }

    /// Positional args: tun2socks, device, address, proxy URL, app pid, state dir, log file.
    /// The script travels inline (never as a file a user process could swap before it runs as root).
    nonisolated static let supervisorScript = #"""
    BIN="$1"; DEV="$2"; ADDR="$3"; PROXY="$4"; APP_PID="$5"; DIR="$6"; LOG="$7"
    STOP="$DIR/tun.stop"; READY="$DIR/tun.ready"; FAILED="$DIR/tun.failed"
    rm -f "$STOP" "$READY" "$FAILED"
    echo "$(date '+%H:%M:%S') starting $BIN on $DEV -> $PROXY" >> "$LOG"
    "$BIN" -device "$DEV" -proxy "$PROXY" -loglevel warning >> "$LOG" 2>&1 &
    T=$!
    i=0
    until ifconfig "$DEV" >/dev/null 2>&1; do
      i=$((i+1))
      if [ $i -gt 50 ] || ! kill -0 "$T" 2>/dev/null; then
        kill "$T" 2>/dev/null
        echo "tun2socks could not create $DEV (see $LOG)" > "$FAILED"
        exit 1
      fi
      sleep 0.1
    done
    ifconfig "$DEV" "$ADDR" "$ADDR" up
    route -q -n add -net 0.0.0.0/1 "$ADDR"
    route -q -n add -net 128.0.0.0/1 "$ADDR"
    echo $$ > "$READY"
    while [ ! -e "$STOP" ] && kill -0 "$APP_PID" 2>/dev/null && kill -0 "$T" 2>/dev/null; do
      sleep 1
    done
    route -q -n delete -net 0.0.0.0/1 "$ADDR"
    route -q -n delete -net 128.0.0.0/1 "$ADDR"
    kill "$T" 2>/dev/null
    wait "$T" 2>/dev/null
    rm -f "$READY" "$STOP"
    echo "$(date '+%H:%M:%S') stopped" >> "$LOG"
    """#

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The full `do shell script` command: the supervisor detached in the background so the
    /// administrator prompt returns as soon as it has started.
    nonisolated static func privilegedCommand(args: [String]) -> String {
        let cmd = (["/bin/sh", "-c", supervisorScript, "qv2ray-tun"] + args).map(shellQuote).joined(separator: " ")
        return cmd + " </dev/null >/dev/null 2>&1 &"
    }

    nonisolated static func launchPrivileged(args: [String]) -> LaunchResult {
        let script = "do shell script " + appleScriptQuote(privilegedCommand(args: args))
            + " with prompt " + appleScriptQuote(L10n.tr("tun.authPrompt")) + " with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardOutput = Pipe()
        p.standardError = err
        do { try p.run() } catch { return .error(error.localizedDescription) }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .ok }
        let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.contains("-128") ? .cancelled : .error(msg)
    }
}
