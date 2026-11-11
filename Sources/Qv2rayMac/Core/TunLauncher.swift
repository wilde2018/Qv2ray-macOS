import Foundation

/// Runs the core as root for TUN mode (creating a utun device and changing routes needs it).
///
/// There is no helper tool to install: each connect asks for an administrator password via
/// `osascript … with administrator privileges`, which runs `wrapperScript` as root. The
/// wrapper owns everything privileged for the lifetime of the session:
///   1. optionally swaps the system DNS (backing up the original servers to a file),
///   2. starts the core with its output appended to a log file the app tails,
///   3. writes the core's pid to the "ready" file (the app waits for it — the user may take
///      a while to type the password),
///   4. stops the core when the "stop" file appears or the app process disappears, so
///      disconnecting never needs a second password and a crashed app can't leave the Mac
///      routed into a dead tunnel,
///   5. restores the DNS on exit.
/// The `osascript` process stays alive exactly as long as the wrapper does, so it stands in
/// for the core process in `CoreRunner` (termination handler = core exited).
enum TunLauncher {

    /// Files shared between the app (user) and the wrapper (root), all in the runtime dir.
    struct Paths {
        let dir: URL
        var log: URL { dir.appendingPathComponent("tun-core.out") }
        var ready: URL { dir.appendingPathComponent("tun.ready") }
        var stop: URL { dir.appendingPathComponent("tun.stop") }
        var dnsBackup: URL { dir.appendingPathComponent("tun-dns.backup") }
    }

    /// POSIX sh, executed as root. Positional args:
    /// core cfg log ready stop app-pid dns-servers dns-backup assets-dir -- core-args…
    static let wrapperScript = #"""
set -u
set -f
core="$1"; cfg="$2"; log="$3"; ready="$4"; stop="$5"; app="$6"; dns="$7"; backup="$8"; assets="$9"
shift 9
umask 022
NS=/usr/sbin/networksetup
TAB="$(printf '\t')"
services() { "$NS" -listallnetworkservices 2>/dev/null | sed 1d | grep -v '^\*'; }
flush_dns() { /usr/bin/dscacheutil -flushcache 2>/dev/null; /usr/bin/killall -HUP mDNSResponder 2>/dev/null; }
restore_dns() {
  [ -f "$backup" ] || return 0
  while IFS="$TAB" read -r svc servers; do
    [ -n "$svc" ] || continue
    if [ -n "$servers" ]; then "$NS" -setdnsservers "$svc" $servers; else "$NS" -setdnsservers "$svc" Empty; fi
  done < "$backup"
  rm -f "$backup"
  flush_dns
}
set_dns() {
  [ -n "$dns" ] || return 0
  # Keep an existing backup: it holds the real servers from a session that never restored them.
  if [ ! -f "$backup" ]; then
    : > "$backup.tmp"
    services | while IFS= read -r svc; do
      cur="$("$NS" -getdnsservers "$svc" 2>/dev/null | grep -E '^[0-9A-Fa-f.:]+$' | tr '\n' ' ' | sed 's/ *$//')"
      printf '%s\t%s\n' "$svc" "$cur" >> "$backup.tmp"
    done
    mv "$backup.tmp" "$backup"
  fi
  services | while IFS= read -r svc; do "$NS" -setdnsservers "$svc" $dns; done
  flush_dns
}
[ -e "$stop" ] && exit 0
set_dns
trap 'restore_dns' EXIT
trap 'exit 143' TERM INT HUP
cd "$(dirname "$cfg")" || exit 1
if [ -n "$assets" ]; then
  /usr/bin/env XRAY_LOCATION_ASSET="$assets" V2RAY_LOCATION_ASSET="$assets" "$core" "$@" >>"$log" 2>&1 &
else
  "$core" "$@" >>"$log" 2>&1 &
fi
cp=$!
echo "$cp" > "$ready"
while kill -0 "$cp" 2>/dev/null; do
  if [ -e "$stop" ] || ! kill -0 "$app" 2>/dev/null; then
    kill -TERM "$cp" 2>/dev/null
    i=0
    while kill -0 "$cp" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
    kill -KILL "$cp" 2>/dev/null
    break
  fi
  sleep 0.25
done
wait "$cp" 2>/dev/null
rc=$?
echo "[tun] core exited (code $rc)" >> "$log"
exit "$rc"
"""#

    /// Single-quote a string for POSIX sh.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Escape a string for an AppleScript string literal.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The shell command `do shell script` runs as root.
    static func shellCommand(corePath: String, coreArgs: [String], configPath: String, paths: Paths,
                             appPID: Int32, dnsServers: [String], assetsDir: String?) -> String {
        let args = [corePath, configPath, paths.log.path, paths.ready.path, paths.stop.path,
                    String(appPID), dnsServers.joined(separator: " "), paths.dnsBackup.path, assetsDir ?? ""] + coreArgs
        return "/bin/sh -c " + shellQuote(wrapperScript) + " qv2ray-tun " + args.map(shellQuote).joined(separator: " ")
    }

    /// The AppleScript source that asks for the password and runs `command` as root.
    /// `admin: false` is for the self-test only (exercises the same quoting without a password).
    static func appleScript(command: String, prompt: String, admin: Bool = true) -> String {
        let script = "do shell script \"\(appleScriptEscape(command))\""
        return admin ? script + " with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges" : script
    }

    /// A not-yet-started `osascript` process that runs the wrapper as root.
    static func makeProcess(corePath: String, coreArgs: [String], configPath: String, paths: Paths,
                            dnsServers: [String], assetsDir: String?, prompt: String) -> Process {
        let command = shellCommand(corePath: corePath, coreArgs: coreArgs, configPath: configPath, paths: paths,
                                   appPID: getpid(), dnsServers: dnsServers, assetsDir: assetsDir)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript(command: command, prompt: prompt)]
        return p
    }

    /// Reset the shared files before a new session (the log is created by us so it stays user-owned).
    static func prepare(_ paths: Paths) {
        let fm = FileManager.default
        try? fm.removeItem(at: paths.ready)
        try? fm.removeItem(at: paths.stop)
        try? fm.removeItem(at: paths.log)
        fm.createFile(atPath: paths.log.path, contents: nil)
    }

    static func isReady(_ paths: Paths) -> Bool {
        FileManager.default.fileExists(atPath: paths.ready.path)
    }

    /// Ask the wrapper to stop the core — no privileges needed.
    static func requestStop(_ paths: Paths) {
        FileManager.default.createFile(atPath: paths.stop.path, contents: nil)
    }

    /// The interface carrying the default route right now (e.g. "en0"), via `route -n get default`.
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
            if parts.count == 2, parts[0] == "interface", !parts[1].hasPrefix("utun") { return parts[1] }
        }
        return nil
    }

    /// IPv4 (preferred) or IPv6 addresses of a host name, resolved with the current system DNS.
    nonisolated static func resolve(host: String) -> [String] {
        guard !host.isEmpty, !ConfigGenerator.isIPAddress(host) else { return [] }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var v4: [String] = [], v6: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if ai.pointee.ai_family == AF_INET { if !v4.contains(ip) { v4.append(ip) } }
                else if !v6.contains(ip) { v6.append(ip) }
            }
            cur = ai.pointee.ai_next
        }
        return v4.isEmpty ? v6 : v4
    }

    /// A DNS backup left behind means a TUN session ended without restoring the system DNS
    /// (e.g. the wrapper was killed). Best effort, unprivileged: networksetup normally lets
    /// an admin user change DNS. The file is kept if that fails, so the next TUN session
    /// (which runs as root) restores the original servers when it ends.
    nonisolated static func recoverStaleDNS(_ paths: Paths) -> Bool {
        guard let text = try? String(contentsOf: paths.dnsBackup, encoding: .utf8) else { return false }
        var ok = true
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let svc = parts.first, !svc.isEmpty else { continue }
            let servers = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            p.arguments = ["-setdnsservers", svc] + (servers.isEmpty ? ["Empty"] : servers)
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit() } catch { ok = false; continue }
            if p.terminationStatus != 0 { ok = false }
        }
        if ok { try? FileManager.default.removeItem(at: paths.dnsBackup) }
        return ok
    }
}

/// Follows the log file the root wrapper appends the core's output to.
@MainActor
final class LogTailer {
    private let url: URL
    private var offset: UInt64 = 0
    private var timer: Timer?
    private let onText: (String) -> Void

    init(url: URL, onText: @escaping (String) -> Void) {
        self.url = url
        self.onText = onText
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }
    }

    /// Read everything appended since the last call (complete lines only, unless `flush`).
    func drain(flush: Bool = false) {
        if let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            if (try? h.seek(toOffset: offset)) != nil, let data = try? h.readToEnd(), !data.isEmpty {
                offset += UInt64(data.count)
                pending.append(data)
            }
        }
        let cut = flush ? pending.endIndex : (pending.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? pending.startIndex)
        guard cut > pending.startIndex else { return }
        let chunk = pending[pending.startIndex..<cut]
        pending = Data(pending[cut...])
        onText(String(decoding: chunk, as: UTF8.self))
    }
    private var pending = Data()

    func stop() {
        timer?.invalidate()
        timer = nil
        drain(flush: true)
    }
}
