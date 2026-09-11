import Foundation

/// Share-link parsing & serialization for vmess/vless/ss/trojan and SIP008 subscriptions.
/// Covers the v2rayN vmess JSON format, Qv2ray's vmess_new URL format, the Xray URL
/// standard (VLESS/VMess/Trojan) and SIP002 / legacy Shadowsocks links.
enum ShareLinks {

    struct ParseResult {
        var profiles: [ConnectionProfile] = []
        /// Human-readable reasons for links that were recognised but not imported.
        var skipped: [String] = []
    }

    private enum Outcome {
        case ok(ConnectionProfile)
        case skip(String)
    }

    // MARK: - Parse

    static func parse(_ text: String) -> [ConnectionProfile] { parseDetailed(text).profiles }

    /// Parse plain share links (one per line), a base64 subscription body, or SIP008 JSON.
    static func parseDetailed(_ text: String) -> ParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let sip = parseSIP008(trimmed) { return sip }
        var lines = splitLines(trimmed)
        if !lines.contains(where: isShareLink), let decoded = decodeBase64Loose(trimmed),
           let inner = String(data: decoded, encoding: .utf8) {
            let innerTrimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if innerTrimmed.hasPrefix("{"), let sip = parseSIP008(innerTrimmed) { return sip }
            let innerLines = splitLines(innerTrimmed)
            if innerLines.contains(where: isShareLink) { lines = innerLines }
        }
        var result = ParseResult()
        for line in lines {
            if isShareLink(line) {
                switch parseOutcome(line) {
                case .ok(let p): result.profiles.append(p)
                case .skip(let reason): result.skipped.append(reason)
                }
            } else if line.contains("://") {
                result.skipped.append(String(format: L10n.tr("link.err.unsupported"), preview(line)))
            }
        }
        return result
    }

    static func isShareLink(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("vmess://") || l.hasPrefix("vless://") || l.hasPrefix("ss://") || l.hasPrefix("trojan://")
    }

    static func parseOne(_ link: String) -> ConnectionProfile? {
        if case .ok(let p) = parseOutcome(link) { return p }
        return nil
    }

    private static func parseOutcome(_ raw: String) -> Outcome {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = link.lowercased()
        let result: Outcome
        if lower.hasPrefix("vmess://") { result = parseVMESS(link) }
        else if lower.hasPrefix("vless://") { result = parseVLESS(link) }
        else if lower.hasPrefix("ss://") { result = parseSS(link) }
        else if lower.hasPrefix("trojan://") { result = parseTrojan(link) }
        else { result = .skip(String(format: L10n.tr("link.err.unsupported"), preview(link))) }
        return result
    }

    private static func invalid(_ link: String) -> Outcome {
        .skip(String(format: L10n.tr("link.err.invalid"), preview(link)))
    }

    // MARK: vmess

    private static func parseVMESS(_ uri: String) -> Outcome {
        let body = String(uri.dropFirst("vmess://".count))
        // base64 never contains '@', so this is one of the URL-style formats.
        if body.contains("@") { return parseVMESSURL(uri) }
        guard let data = decodeBase64Loose(body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return invalid(uri) }

        var p = ConnectionProfile()
        p.proto = .vmess
        p.name = str(json["ps"])
        p.address = str(json["add"])
        p.port = int(json["port"]) ?? 443
        p.uuid = str(json["id"])
        p.alterId = int(json["aid"]) ?? 0
        p.security = str(json["scy"]).isEmpty ? "auto" : str(json["scy"])

        var s = StreamSettings()
        s.network = TransportNetwork.from(linkType: str(json["net"])) ?? .tcp
        let type = str(json["type"])
        let host = str(json["host"])
        let path = str(json["path"])
        switch s.network {
        case .tcp:
            s.tcpHeaderType = type == "http" ? "http" : "none"
            if type == "http" { s.tcpRequestHost = host; s.tcpPath = path }
        case .ws: s.wsPath = path; s.wsHost = host
        case .http: s.h2Host = host; s.h2Path = path
        case .quic:
            // v2rayN convention: host = QUIC security, path = key, type = header.
            s.quicSecurity = host.isEmpty ? "none" : host
            s.quicKey = path
            s.quicHeaderType = type.isEmpty ? "none" : type
        case .kcp: s.kcpHeaderType = type.isEmpty ? "none" : type; s.kcpSeed = path
        case .grpc: s.grpcServiceName = path; s.grpcMultiMode = type == "multi"
        case .httpupgrade: s.httpupgradePath = path; s.httpupgradeHost = host
        case .splithttp:
            s.xhttpPath = path; s.xhttpHost = host
            if !type.isEmpty && type != "none" { s.xhttpMode = type }
        }

        switch str(json["tls"]).lowercased() {
        case "reality":
            s.security = .reality
            s.realityPublicKey = str(json["pbk"])
            s.realityShortId = str(json["sid"])
            s.realitySpiderX = str(json["spx"])
        case "tls": s.security = .tls
        case "xtls": s.security = .xtls
        default: s.security = .none
        }
        s.sni = str(json["sni"])
        s.alpn = str(json["alpn"])
        s.fingerprint = str(json["fp"])
        s.allowInsecure = truthy(json["allowInsecure"]) || truthy(json["insecure"])
        p.stream = s

        if p.address.isEmpty || p.uuid.isEmpty { return invalid(uri) }
        return .ok(p)
    }

    /// `vmess://ws+tls:uuid-aid@host:port/?path=…#name` (Qv2ray) or
    /// `vmess://uuid@host:port?type=ws&security=tls#name` (Xray URL standard).
    private static func parseVMESSURL(_ uri: String) -> Outcome {
        guard let comps = components(uri), let host = comps.host, !host.isEmpty else { return invalid(uri) }
        let q = comps.queryItems ?? []
        func param(_ k: String) -> String? { q.first { $0.name == k }?.value }

        var p = ConnectionProfile()
        p.proto = .vmess
        p.address = host
        p.port = comps.port ?? 443
        p.name = comps.fragment ?? ""
        var s = StreamSettings()

        if let pw = comps.password, !pw.isEmpty {
            // Qv2ray vmess_new
            var net = "tcp"
            var tls = false
            for part in (comps.user ?? "").split(separator: "+") {
                if part == "tls" { tls = true } else { net = String(part) }
            }
            guard let network = TransportNetwork.from(linkType: net) else { return invalid(uri) }
            s.network = network
            if let dash = pw.lastIndex(of: "-") {
                p.uuid = String(pw[..<dash])
                p.alterId = Int(pw[pw.index(after: dash)...]) ?? 0
            } else {
                p.uuid = pw
            }
            switch network {
            case .tcp: s.tcpHeaderType = param("type") == "http" ? "http" : "none"
            case .http: s.h2Host = param("host") ?? ""; s.h2Path = param("path") ?? "/"
            case .ws: s.wsHost = param("host") ?? ""; s.wsPath = param("path") ?? "/"
            case .kcp: s.kcpSeed = param("seed") ?? ""; s.kcpHeaderType = param("type") ?? "none"
            case .quic:
                s.quicSecurity = param("security") ?? "none"
                s.quicKey = param("key") ?? ""
                s.quicHeaderType = param("headers") ?? param("type") ?? "none"
            case .grpc: s.grpcServiceName = param("serviceName") ?? ""
            case .httpupgrade, .splithttp: break
            }
            if tls {
                s.security = .tls
                s.sni = param("tlsServerName") ?? ""
                s.allowInsecure = truthy(param("allowInsecure"))
            }
        } else {
            p.uuid = comps.user ?? ""
            if let err = applyTransport(param, to: &s) { return .skip(String(format: L10n.tr("link.err.transport"), err)) }
            applySecurity(param, to: &s, defaultSecurity: "none")
            if let enc = param("encryption"), !enc.isEmpty, enc != "none" { p.security = enc }
        }
        p.stream = s
        if p.uuid.isEmpty { return invalid(uri) }
        return .ok(p)
    }

    // MARK: vless

    private static func parseVLESS(_ str: String) -> Outcome {
        guard let comps = components(str), let host = comps.host, !host.isEmpty else { return invalid(str) }
        let q = comps.queryItems ?? []
        func param(_ k: String) -> String? { q.first { $0.name == k }?.value }

        var p = ConnectionProfile()
        p.proto = .vless
        p.address = host
        p.port = comps.port ?? 443
        p.name = comps.fragment ?? ""
        p.uuid = comps.user ?? ""
        guard !p.uuid.isEmpty else { return invalid(str) }
        p.encryption = (param("encryption") ?? "none").isEmpty ? "none" : (param("encryption") ?? "none")
        p.flow = param("flow") ?? ""

        var s = StreamSettings()
        if let err = applyTransport(param, to: &s) { return .skip(String(format: L10n.tr("link.err.transport"), err)) }
        applySecurity(param, to: &s, defaultSecurity: "none")
        p.stream = s
        return .ok(p)
    }

    // MARK: ss

    private static func parseSS(_ uri: String) -> Outcome {
        var p = ConnectionProfile()
        p.proto = .shadowsocks
        var body = String(uri.dropFirst("ss://".count))

        var fragment = ""
        if let hashIdx = body.lastIndex(of: "#") {
            fragment = String(body[body.index(after: hashIdx)...])
            body = String(body[..<hashIdx])
        }
        p.name = fragment.removingPercentEncoding ?? fragment

        if let qIdx = body.firstIndex(of: "?") {
            let query = body[body.index(after: qIdx)...]
            body = String(body[..<qIdx])
            // SIP003 plugins (obfs, v2ray-plugin, …) can't run inside the v2ray/Xray core.
            if query.split(separator: "&").contains(where: { $0.hasPrefix("plugin=") && $0.count > "plugin=".count }) {
                return .skip(String(format: L10n.tr("link.err.ssPlugin"), p.name.isEmpty ? preview(uri) : p.name))
            }
        }
        if body.hasSuffix("/") { body.removeLast() }

        if let atIdx = body.lastIndex(of: "@") {
            // SIP002: ss://base64url(method:password)@host:port, or percent-encoded plain userinfo (2022 ciphers)
            let userInfoRaw = String(body[..<atIdx])
            guard let (host, port) = splitHostPort(String(body[body.index(after: atIdx)...])) else { return invalid(uri) }
            p.address = host
            p.port = port
            var userInfo = userInfoRaw.removingPercentEncoding ?? userInfoRaw
            if let d = decodeBase64Loose(userInfoRaw), let s = String(data: d, encoding: .utf8), s.contains(":") {
                userInfo = s
            }
            guard let colonIdx = userInfo.firstIndex(of: ":") else { return invalid(uri) }
            p.method = String(userInfo[..<colonIdx])
            p.password = String(userInfo[userInfo.index(after: colonIdx)...])
        } else {
            // Legacy: whole body is base64(method:password@host:port)
            guard let data = decodeBase64Loose(body),
                  let decoded = String(data: data, encoding: .utf8),
                  let atIdx = decoded.lastIndex(of: "@") else { return invalid(uri) }
            let userInfo = String(decoded[..<atIdx])
            guard let colonIdx = userInfo.firstIndex(of: ":"),
                  let (host, port) = splitHostPort(String(decoded[decoded.index(after: atIdx)...])) else { return invalid(uri) }
            p.method = String(userInfo[..<colonIdx])
            p.password = String(userInfo[userInfo.index(after: colonIdx)...])
            p.address = host
            p.port = port
        }
        if p.address.isEmpty || p.method.isEmpty { return invalid(uri) }
        return .ok(p)
    }

    // MARK: trojan

    private static func parseTrojan(_ str: String) -> Outcome {
        guard let comps = components(str), let host = comps.host, !host.isEmpty else { return invalid(str) }
        let q = comps.queryItems ?? []
        func param(_ k: String) -> String? { q.first { $0.name == k }?.value }

        var p = ConnectionProfile()
        p.proto = .trojan
        p.address = host
        p.port = comps.port ?? 443
        p.name = comps.fragment ?? ""
        p.password = comps.user ?? ""
        p.method = ""
        guard !p.password.isEmpty else { return invalid(str) }

        var s = StreamSettings()
        if let err = applyTransport(param, to: &s) { return .skip(String(format: L10n.tr("link.err.transport"), err)) }
        applySecurity(param, to: &s, defaultSecurity: "tls")
        p.stream = s
        return .ok(p)
    }

    // MARK: SIP008

    private static func parseSIP008(_ text: String) -> ParseResult? {
        guard let d = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let servers = root["servers"] as? [[String: Any]] else { return nil }
        var r = ParseResult()
        for s in servers {
            let remarks = str(s["remarks"])
            if !str(s["plugin"]).isEmpty {
                r.skipped.append(String(format: L10n.tr("link.err.ssPlugin"), remarks.isEmpty ? str(s["server"]) : remarks))
                continue
            }
            guard !str(s["server"]).isEmpty, let port = int(s["server_port"]), !str(s["method"]).isEmpty else { continue }
            var p = ConnectionProfile()
            p.proto = .shadowsocks
            p.name = remarks
            p.address = str(s["server"])
            p.port = port
            p.method = str(s["method"])
            p.password = str(s["password"])
            r.profiles.append(p)
        }
        return r
    }

    // MARK: shared query handling (Xray URL standard)

    /// Returns the offending transport name when it isn't supported.
    private static func applyTransport(_ param: (String) -> String?, to s: inout StreamSettings) -> String? {
        let typeRaw = param("type") ?? "tcp"
        guard let net = TransportNetwork.from(linkType: typeRaw) else { return typeRaw }
        s.network = net
        switch net {
        case .tcp:
            s.tcpHeaderType = param("headerType") == "http" ? "http" : "none"
            if s.tcpHeaderType == "http" { s.tcpRequestHost = param("host") ?? ""; s.tcpPath = param("path") ?? "" }
        case .ws: s.wsPath = param("path") ?? ""; s.wsHost = param("host") ?? ""
        case .http: s.h2Path = param("path") ?? ""; s.h2Host = param("host") ?? ""
        case .quic:
            s.quicSecurity = param("quicSecurity") ?? "none"
            s.quicKey = param("key") ?? ""
            s.quicHeaderType = param("headerType") ?? "none"
        case .kcp: s.kcpSeed = param("seed") ?? ""; s.kcpHeaderType = param("headerType") ?? "none"
        case .grpc: s.grpcServiceName = param("serviceName") ?? ""; s.grpcMultiMode = param("mode") == "multi"
        case .httpupgrade: s.httpupgradePath = param("path") ?? ""; s.httpupgradeHost = param("host") ?? ""
        case .splithttp:
            s.xhttpPath = param("path") ?? ""
            s.xhttpHost = param("host") ?? ""
            s.xhttpMode = param("mode") ?? "auto"
        }
        return nil
    }

    private static func applySecurity(_ param: (String) -> String?, to s: inout StreamSettings, defaultSecurity: String) {
        switch (param("security") ?? defaultSecurity).lowercased() {
        case "reality":
            s.security = .reality
            s.realityPublicKey = param("pbk") ?? ""
            s.realityShortId = param("sid") ?? ""
            s.realitySpiderX = param("spx") ?? ""
        case "tls": s.security = .tls
        case "xtls": s.security = .xtls
        default: s.security = .none
        }
        s.sni = param("sni") ?? param("peer") ?? ""
        s.alpn = param("alpn") ?? ""
        s.fingerprint = param("fp") ?? ""
        s.allowInsecure = truthy(param("allowInsecure")) || truthy(param("insecure"))
    }

    // MARK: - Serialize

    static func serialize(_ p: ConnectionProfile) -> String? {
        switch p.proto {
        case .vmess: return serializeVMESS(p)
        case .vless: return serializeVLESS(p)
        case .shadowsocks: return serializeSS(p)
        case .trojan: return serializeTrojan(p)
        case .custom: return nil
        }
    }

    /// v2rayN "v2" JSON format — the most widely understood vmess link.
    private static func serializeVMESS(_ p: ConnectionProfile) -> String {
        let s = p.stream
        var net = s.network.rawValue
        var type = "none"
        var host = ""
        var path = ""
        switch s.network {
        case .tcp:
            type = s.tcpHeaderType
            if type == "http" { host = s.tcpRequestHost; path = s.tcpPath }
        case .ws: host = s.wsHost; path = s.wsPath
        case .http: net = "h2"; host = s.h2Host; path = s.h2Path
        case .quic: type = s.quicHeaderType; host = s.quicSecurity; path = s.quicKey
        case .kcp: type = s.kcpHeaderType; path = s.kcpSeed
        case .grpc: type = s.grpcMultiMode ? "multi" : "gun"; path = s.grpcServiceName
        case .httpupgrade: host = s.httpupgradeHost; path = s.httpupgradePath
        case .splithttp: net = "xhttp"; type = s.xhttpMode; host = s.xhttpHost; path = s.xhttpPath
        }
        let tls: String
        switch s.security {
        case .none: tls = ""
        case .tls, .xtls: tls = "tls"
        case .reality: tls = "reality"
        }
        var d: [String: Any] = [
            "v": "2", "ps": p.name, "add": p.address, "port": String(p.port),
            "id": p.uuid, "aid": String(p.alterId), "scy": p.security,
            "net": net, "type": type, "host": host, "path": path,
            "tls": tls, "sni": s.sni, "alpn": s.alpn, "fp": s.fingerprint,
        ]
        d = d.filter { !(($0.value as? String)?.isEmpty ?? false) }
        if s.security == .reality {
            d["pbk"] = s.realityPublicKey
            d["sid"] = s.realityShortId
            if !s.realitySpiderX.isEmpty { d["spx"] = s.realitySpiderX }
        }
        let json = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        return "vmess://" + json.base64EncodedString()
    }

    private static func serializeVLESS(_ p: ConnectionProfile) -> String {
        var items = transportItems(p.stream) + securityItems(p.stream)
        if !p.flow.isEmpty { items.append(("flow", p.flow)) }
        items.append(("encryption", p.encryption.isEmpty ? "none" : p.encryption))
        return "vless://\(encodeStrict(p.uuid))@\(hostPort(p))?\(encodeQuery(items))\(fragment(p.name))"
    }

    private static func serializeSS(_ p: ConnectionProfile) -> String {
        let userInfo: String
        if p.method.hasPrefix("2022-") {
            // SIP002 requires plain, percent-encoded userinfo for SS-2022 ciphers.
            userInfo = encodeStrict(p.method) + ":" + encodeStrict(p.password)
        } else {
            userInfo = Data("\(p.method):\(p.password)".utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        return "ss://\(userInfo)@\(hostPort(p))\(fragment(p.name))"
    }

    private static func serializeTrojan(_ p: ConnectionProfile) -> String {
        let items = transportItems(p.stream) + securityItems(p.stream)
        return "trojan://\(encodeStrict(p.password))@\(hostPort(p))?\(encodeQuery(items))\(fragment(p.name))"
    }

    private static func transportItems(_ s: StreamSettings) -> [(String, String)] {
        var q: [(String, String)] = [("type", s.network == .splithttp ? "xhttp" : s.network.rawValue)]
        func add(_ k: String, _ v: String) { if !v.isEmpty { q.append((k, v)) } }
        switch s.network {
        case .tcp:
            if s.tcpHeaderType == "http" {
                q.append(("headerType", "http"))
                add("host", s.tcpRequestHost)
                add("path", s.tcpPath)
            }
        case .ws: add("path", s.wsPath); add("host", s.wsHost)
        case .http: add("path", s.h2Path); add("host", s.h2Host)
        case .quic:
            q.append(("quicSecurity", s.quicSecurity))
            if s.quicSecurity != "none" { add("key", s.quicKey) }
            if s.quicHeaderType != "none" { add("headerType", s.quicHeaderType) }
        case .kcp:
            add("seed", s.kcpSeed)
            if s.kcpHeaderType != "none" { add("headerType", s.kcpHeaderType) }
        case .grpc:
            add("serviceName", s.grpcServiceName)
            if s.grpcMultiMode { q.append(("mode", "multi")) }
        case .httpupgrade: add("path", s.httpupgradePath); add("host", s.httpupgradeHost)
        case .splithttp:
            add("path", s.xhttpPath); add("host", s.xhttpHost)
            if s.xhttpMode != "auto" { add("mode", s.xhttpMode) }
        }
        return q
    }

    private static func securityItems(_ s: StreamSettings) -> [(String, String)] {
        var q: [(String, String)] = []
        func add(_ k: String, _ v: String) { if !v.isEmpty { q.append((k, v)) } }
        switch s.security {
        case .none:
            q.append(("security", "none"))
        case .tls, .xtls:
            q.append(("security", s.security.rawValue))
            add("sni", s.sni); add("alpn", s.alpn); add("fp", s.fingerprint)
            if s.allowInsecure { q.append(("allowInsecure", "1")) }
        case .reality:
            q.append(("security", "reality"))
            add("sni", s.sni); add("fp", s.fingerprint)
            add("pbk", s.realityPublicKey); add("sid", s.realityShortId); add("spx", s.realitySpiderX)
        }
        return q
    }

    // MARK: - Helpers

    /// URLComponents after normalising the fragment (raw spaces / CJK names are common in the wild).
    private static func components(_ link: String) -> URLComponents? {
        var base = link
        var frag: String?
        if let hashIdx = link.firstIndex(of: "#") {
            base = String(link[..<hashIdx])
            let raw = String(link[link.index(after: hashIdx)...])
            frag = (raw.removingPercentEncoding ?? raw).addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
        }
        return URLComponents(string: base + (frag.map { "#" + $0 } ?? ""))
    }

    private static let strictAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))

    private static func encodeStrict(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? s
    }

    private static func encodeQuery(_ items: [(String, String)]) -> String {
        items.map { k, v in "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? v)" }
            .joined(separator: "&")
    }

    private static func fragment(_ name: String) -> String {
        guard !name.isEmpty else { return "" }
        return "#" + (name.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? name)
    }

    private static func hostPort(_ p: ConnectionProfile) -> String {
        (p.address.contains(":") ? "[\(p.address)]" : p.address) + ":\(p.port)"
    }

    private static func splitLines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func preview(_ s: String) -> String {
        s.count > 48 ? String(s.prefix(48)) + "…" : s
    }

    private static func str(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func truthy(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        return ["1", "true", "yes", "on"].contains(str(any).lowercased())
    }

    static func splitHostPort(_ s: String) -> (String, Int)? {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...])
            guard rest.hasPrefix(":") else { return (host, 443) }
            return (host, Int(rest.dropFirst()) ?? 443)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        let port = Int(s[s.index(after: colon)...]) ?? 443
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    static func decodeBase64Loose(_ s: String) -> Data? {
        var t = s.components(separatedBy: .whitespacesAndNewlines).joined()
        t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
