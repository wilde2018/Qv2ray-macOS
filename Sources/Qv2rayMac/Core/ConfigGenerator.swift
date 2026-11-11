import Foundation

/// Generates full v2ray/Xray JSON config from a profile + preferences + routing scheme.
enum ConfigGenerator {

    /// Private / link-local ranges. Plain CIDRs (not geoip:private) so LAN bypass
    /// works even when no geodata files are installed.
    static let lanCIDRs = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
        "169.254.0.0/16", "100.64.0.0/10", "::1/128", "fc00::/7", "fe80::/10",
    ]

    /// The full config used to launch the core for a normal connection.
    static func fullConfig(profile: ConnectionProfile, prefs: Preferences, scheme: RoutingScheme) -> [String: Any] {
        var config: [String: Any] = [
            "log": ["loglevel": prefs.logLevel],
            "policy": [
                "levels": [
                    "0": ["handshake": 4, "connIdle": 300, "uplinkOnly": 0, "downlinkOnly": 0],
                ],
                "system": [
                    "statsInboundUplink": true,
                    "statsInboundDownlink": true,
                    "statsOutboundUplink": true,
                    "statsOutboundDownlink": true,
                ],
            ] as [String: Any],
            "dns": ["servers": ["1.1.1.1", "8.8.8.8", "localhost"], "queryStrategy": "UseIPv4"] as [String: Any],
        ]

        var inbounds = userInbounds(prefs: prefs)
        if prefs.apiEnabled { inbounds.append(apiInbound(prefs: prefs)) }
        config["inbounds"] = inbounds

        config["outbounds"] = [
            outbound(for: profile),
            ["tag": "direct", "protocol": "freedom", "settings": [String: Any]()],
            ["tag": "block", "protocol": "blackhole", "settings": [String: Any]()],
        ]

        config["routing"] = routingBlock(scheme: scheme, apiEnabled: prefs.apiEnabled, bypassLAN: prefs.bypassLAN)

        if prefs.apiEnabled {
            config["stats"] = [String: Any]()
            config["api"] = ["tag": "api", "services": ["StatsService"]] as [String: Any]
        }
        return config
    }

    static func userInbounds(prefs: Preferences) -> [[String: Any]] {
        var inbounds: [[String: Any]] = []
        let listen = prefs.effectiveListenAddress
        let sniffing: [String: Any] = prefs.sniffingEnabled
            ? ["enabled": true, "destOverride": ["http", "tls"], "routeOnly": false]
            : ["enabled": false]
        if prefs.useSocks {
            var socksSettings: [String: Any] = ["auth": "noauth", "udp": prefs.socksEnableUDP, "userLevel": 0]
            if prefs.socksEnableUDP { socksSettings["ip"] = prefs.systemProxyHost }
            inbounds.append(["tag": "socks_IN", "listen": listen, "port": prefs.socksPort,
                             "protocol": "socks", "settings": socksSettings, "sniffing": sniffing])
        }
        if prefs.useHTTP {
            inbounds.append(["tag": "http_IN", "listen": listen, "port": prefs.httpPort,
                             "protocol": "http", "settings": ["allowTransparent": false] as [String: Any],
                             "sniffing": sniffing])
        }
        return inbounds
    }

    static func apiInbound(prefs: Preferences) -> [String: Any] {
        ["tag": "api", "listen": "127.0.0.1", "port": prefs.apiPort, "protocol": "dokodemo-door",
         "settings": ["address": "127.0.0.1"] as [String: Any]]
    }

    /// Routing block. Unmatched traffic goes to the first outbound (`proxy`), so the
    /// Global / Direct catch-alls use `network: tcp,udp`, which also matches domain
    /// destinations under any domainStrategy (IP-only rules don't under AsIs).
    static func routingBlock(scheme: RoutingScheme, apiEnabled: Bool, bypassLAN: Bool) -> [String: Any] {
        var rules: [[String: Any]] = []
        if apiEnabled {
            rules.append(["type": "field", "inboundTag": ["api"], "outboundTag": "api"])
        }
        if bypassLAN && scheme.mode != .direct {
            rules.append(["type": "field", "ip": lanCIDRs, "outboundTag": "direct"])
        }
        switch scheme.mode {
        case .direct:
            rules.append(["type": "field", "network": "tcp,udp", "outboundTag": "direct"])
        case .global:
            rules.append(["type": "field", "network": "tcp,udp", "outboundTag": "proxy"])
        case .rules:
            for rule in scheme.rules where rule.enabled {
                var r: [String: Any] = ["type": "field", "outboundTag": rule.outboundTag]
                let domains = splitList(rule.domains)
                let ips = splitList(rule.ips)
                if !domains.isEmpty { r["domain"] = domains }
                if !ips.isEmpty { r["ip"] = ips }
                if !rule.port.isEmpty { r["port"] = rule.port }
                if !rule.network.isEmpty { r["network"] = rule.network }
                if r.count > 2 { rules.append(r) }
            }
        }
        return ["domainStrategy": scheme.domainStrategy, "rules": rules]
    }

    /// Build the outbound object for a profile (honors outboundOverrideJSON).
    static func outbound(for profile: ConnectionProfile) -> [String: Any] {
        if let o = overrideOutbound(profile) { return o }
        return generatedOutbound(for: profile)
    }

    static func overrideOutbound(_ profile: ConnectionProfile) -> [String: Any]? {
        guard !profile.outboundOverrideJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let d = profile.outboundOverrideJSON.data(using: .utf8),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        o["tag"] = "proxy"
        return o
    }

    /// The outbound generated purely from the form fields (ignores any override).
    static func generatedOutbound(for profile: ConnectionProfile) -> [String: Any] {
        var out: [String: Any] = ["tag": "proxy", "protocol": profile.proto.rawValue]
        var settings: [String: Any] = [:]
        switch profile.proto {
        case .vmess:
            let user: [String: Any] = ["id": profile.uuid, "alterId": profile.alterId,
                                       "security": profile.security.isEmpty ? "auto" : profile.security, "level": 0]
            settings = ["vnext": [["address": profile.address, "port": profile.port, "users": [user]]]]
        case .vless:
            var user: [String: Any] = ["id": profile.uuid, "encryption": profile.encryption.isEmpty ? "none" : profile.encryption, "level": 0]
            if !profile.flow.isEmpty { user["flow"] = profile.flow }
            settings = ["vnext": [["address": profile.address, "port": profile.port, "users": [user]]]]
        case .shadowsocks:
            settings = ["servers": [["address": profile.address, "port": profile.port, "method": profile.method, "password": profile.password]]]
        case .trojan:
            settings = ["servers": [["address": profile.address, "port": profile.port, "password": profile.password, "level": 0]]]
        case .custom:
            settings = [:]
        }
        out["settings"] = settings
        out["streamSettings"] = streamSettings(for: profile.stream)
        if profile.mux.enabled {
            out["mux"] = ["enabled": true, "concurrency": profile.mux.concurrency]
        }
        return out
    }

    /// streamSettings JSON from the friendly struct.
    static func streamSettings(for s: StreamSettings) -> [String: Any] {
        var stream: [String: Any] = ["network": s.network.rawValue]

        switch s.network {
        case .tcp:
            if s.tcpHeaderType == "http" {
                var headers: [String: Any] = [:]
                if !s.tcpRequestHost.isEmpty { headers["Host"] = splitList(s.tcpRequestHost) }
                let request: [String: Any] = ["version": "1.1", "method": "GET",
                                              "path": splitList(s.tcpPath.isEmpty ? "/" : s.tcpPath),
                                              "headers": headers]
                stream["tcpSettings"] = ["header": ["type": "http", "request": request]]
            } else {
                stream["tcpSettings"] = ["header": ["type": "none"]] as [String: Any]
            }
        case .ws:
            var ws: [String: Any] = [:]
            if !s.wsPath.isEmpty { ws["path"] = s.wsPath }
            if !s.wsHost.isEmpty { ws["headers"] = ["Host": s.wsHost] }
            stream["wsSettings"] = ws
        case .http:
            var h2: [String: Any] = [:]
            let hosts = splitList(s.h2Host)
            if !hosts.isEmpty { h2["host"] = hosts }
            if !s.h2Path.isEmpty { h2["path"] = s.h2Path }
            stream["httpSettings"] = h2
        case .quic:
            var q: [String: Any] = ["security": s.quicSecurity.isEmpty ? "none" : s.quicSecurity,
                                    "header": ["type": s.quicHeaderType.isEmpty ? "none" : s.quicHeaderType]]
            if !(s.quicSecurity.isEmpty || s.quicSecurity == "none") { q["key"] = s.quicKey }
            stream["quicSettings"] = q
        case .kcp:
            var k: [String: Any] = ["mtu": 1350, "tti": 50, "uplinkCapacity": 12, "downlinkCapacity": 100,
                                    "congestion": false, "readBufferSize": 2, "writeBufferSize": 2,
                                    "header": ["type": s.kcpHeaderType.isEmpty ? "none" : s.kcpHeaderType]]
            if !s.kcpSeed.isEmpty { k["seed"] = s.kcpSeed }
            stream["kcpSettings"] = k
        case .grpc:
            stream["grpcSettings"] = ["serviceName": s.grpcServiceName, "multiMode": s.grpcMultiMode,
                                      "idle_timeout": 60, "health_check_timeout": 20] as [String: Any]
        case .httpupgrade:
            var h: [String: Any] = [:]
            if !s.httpupgradePath.isEmpty { h["path"] = s.httpupgradePath }
            if !s.httpupgradeHost.isEmpty { h["host"] = s.httpupgradeHost }
            stream["httpupgradeSettings"] = h
        case .splithttp:
            var h: [String: Any] = ["mode": s.xhttpMode.isEmpty ? "auto" : s.xhttpMode]
            if !s.xhttpPath.isEmpty { h["path"] = s.xhttpPath }
            if !s.xhttpHost.isEmpty { h["host"] = s.xhttpHost }
            stream["splithttpSettings"] = h
        }

        switch s.security {
        case .none:
            break
        case .tls, .xtls, .reality:
            stream["security"] = s.security == .reality ? "reality" : "tls"
            var tls: [String: Any] = [:]
            if !s.sni.isEmpty { tls["serverName"] = s.sni }
            if !s.fingerprint.isEmpty { tls["fingerprint"] = s.fingerprint }
            if s.security == .reality {
                tls["publicKey"] = s.realityPublicKey
                tls["shortId"] = s.realityShortId
                if !s.realitySpiderX.isEmpty { tls["spiderX"] = s.realitySpiderX }
            } else {
                let alpn = splitList(s.alpn)
                if !alpn.isEmpty { tls["alpn"] = alpn }
                if s.allowInsecure { tls["allowInsecure"] = true }
            }
            // Legacy XTLS is emitted as plain TLS; the flow lives on the user object.
            stream[s.security == .reality ? "realitySettings" : "tlsSettings"] = tls
        }

        var sockopt: [String: Any] = [:]
        if s.mark != 0 { sockopt["mark"] = s.mark }
        if s.tcpFastOpen { sockopt["tcpFastOpen"] = true }
        if !sockopt.isEmpty { stream["sockopt"] = sockopt }

        return stream
    }

    // MARK: - TUN mode

    static let tunTag = "tun_IN"
    static let dnsOutTag = "dns-out"
    static let defaultDNSServers = ["1.1.1.1", "8.8.8.8"]

    /// Xray's `tun` inbound. Xray creates the utun device, adds the system routes
    /// (`autoSystemRoutingTable`) and binds every outbound to the physical interface
    /// (`autoOutboundsInterface`) so proxied traffic can't loop back into the tunnel.
    static func tunInbound(prefs: Preferences) -> [String: Any] {
        var settings: [String: Any] = [
            "mtu": min(max(prefs.tunMTU, 576), 9000),
            "autoSystemRoutingTable": ["0.0.0.0/0"],
            "autoOutboundsInterface": "auto",
            "userLevel": 0,
        ]
        let name = prefs.effectiveTunName
        if !name.isEmpty { settings["name"] = name }
        // Sniffing is what makes domain rules (geosite:…) work for raw IP connections.
        return ["tag": tunTag, "protocol": "tun", "settings": settings,
                "sniffing": ["enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false] as [String: Any]]
    }

    /// Turns a generated config into its TUN-mode variant.
    /// - `serverHost` / `serverIPs`: the proxy server's address resolved *before* the tunnel
    ///   comes up. Pinning it in `dns.hosts` (and resolving through Xray's DNS via
    ///   `sockopt.domainStrategy`) means connecting to the server never depends on DNS
    ///   that itself has to go through the server.
    static func withTun(_ config: [String: Any], prefs: Preferences, serverHost: String? = nil, serverIPs: [String] = []) -> [String: Any] {
        var c = config
        var inbounds = c["inbounds"] as? [[String: Any]] ?? []
        inbounds.removeAll { ($0["protocol"] as? String) == "tun" }
        inbounds.insert(tunInbound(prefs: prefs), at: 0)
        c["inbounds"] = inbounds

        let pinServer = serverHost.map { !$0.isEmpty && !isIPAddress($0) } == true && !serverIPs.isEmpty
        var outbounds = c["outbounds"] as? [[String: Any]] ?? []
        for i in outbounds.indices {
            let tag = outbounds[i]["tag"] as? String
            if tag == "direct", (outbounds[i]["protocol"] as? String) == "freedom" {
                // Resolve direct destinations with Xray's DNS instead of the (hijacked) system resolver.
                var s = outbounds[i]["settings"] as? [String: Any] ?? [:]
                if s["domainStrategy"] == nil { s["domainStrategy"] = "UseIP" }
                outbounds[i]["settings"] = s
            } else if tag == "proxy", pinServer {
                var stream = outbounds[i]["streamSettings"] as? [String: Any] ?? [:]
                var sockopt = stream["sockopt"] as? [String: Any] ?? [:]
                if sockopt["domainStrategy"] == nil { sockopt["domainStrategy"] = "UseIP" }
                stream["sockopt"] = sockopt
                outbounds[i]["streamSettings"] = stream
            }
        }
        if prefs.tunHijackDNS && !outbounds.contains(where: { ($0["tag"] as? String) == dnsOutTag }) {
            outbounds.append(["tag": dnsOutTag, "protocol": "dns", "settings": [String: Any]()])
        }
        c["outbounds"] = outbounds

        // "localhost" would ask the system resolver, which TUN mode points back at Xray.
        var dns = c["dns"] as? [String: Any] ?? [:]
        var servers = (dns["servers"] as? [Any] ?? []).filter { ($0 as? String) != "localhost" }
        if servers.isEmpty { servers = defaultDNSServers }
        dns["servers"] = servers
        if pinServer, let host = serverHost {
            var hosts = dns["hosts"] as? [String: Any] ?? [:]
            hosts[host] = serverIPs
            dns["hosts"] = hosts
        }
        c["dns"] = dns

        if prefs.tunHijackDNS {
            var routing = c["routing"] as? [String: Any] ?? [:]
            var rules = routing["rules"] as? [[String: Any]] ?? []
            let afterAPI = (rules.first?["inboundTag"] as? [String]) == ["api"] ? 1 : 0
            rules.insert(["type": "field", "inboundTag": [tunTag], "port": "53", "outboundTag": dnsOutTag], at: afterAPI)
            routing["rules"] = rules
            c["routing"] = routing
        }
        return c
    }

    /// Whether a config asks for a TUN device (and therefore must run as root).
    static func hasTunInbound(_ config: [String: Any]) -> Bool {
        (config["inbounds"] as? [[String: Any]] ?? []).contains { ($0["protocol"] as? String) == "tun" }
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    // MARK: - Custom (full JSON) configs

    /// Fill in what a hand-written config usually lacks, like Qv2ray does: a log level,
    /// the configured inbounds when it has none, and the stats API.
    static func prepareCustom(_ root: [String: Any], prefs: Preferences) -> [String: Any] {
        var c = root
        var log = c["log"] as? [String: Any] ?? [:]
        if log["loglevel"] == nil { log["loglevel"] = prefs.logLevel }
        c["log"] = log

        var inbounds = c["inbounds"] as? [[String: Any]] ?? []
        if inbounds.isEmpty { inbounds = userInbounds(prefs: prefs) }

        if prefs.apiEnabled && c["api"] == nil && !inbounds.contains(where: { ($0["tag"] as? String) == "api" }) {
            if c["stats"] == nil { c["stats"] = [String: Any]() }
            c["api"] = ["tag": "api", "services": ["StatsService"]] as [String: Any]
            var policy = c["policy"] as? [String: Any] ?? [:]
            var system = policy["system"] as? [String: Any] ?? [:]
            system["statsOutboundUplink"] = true
            system["statsOutboundDownlink"] = true
            policy["system"] = system
            c["policy"] = policy
            inbounds.append(apiInbound(prefs: prefs))
            var routing = c["routing"] as? [String: Any] ?? [:]
            var rules = routing["rules"] as? [[String: Any]] ?? []
            rules.insert(["type": "field", "inboundTag": ["api"], "outboundTag": "api"], at: 0)
            routing["rules"] = rules
            c["routing"] = routing
        }
        c["inbounds"] = inbounds
        return c
    }

    struct ProxyPorts: Equatable {
        var socks: Int? = nil
        var http: Int? = nil
        var isEmpty: Bool { socks == nil && http == nil }
    }

    /// The locally reachable SOCKS / HTTP inbounds of a config (what the system proxy should point at).
    static func proxyPorts(in config: [String: Any]) -> ProxyPorts {
        var ports = ProxyPorts()
        let local: Set<String> = ["", "127.0.0.1", "0.0.0.0", "::", "::1", "localhost"]
        for ib in config["inbounds"] as? [[String: Any]] ?? [] {
            guard (ib["tag"] as? String) != "api",
                  local.contains((ib["listen"] as? String) ?? ""),
                  let port = (ib["port"] as? NSNumber)?.intValue else { continue }
            switch ib["protocol"] as? String {
            case "socks": if ports.socks == nil { ports.socks = port }
            case "http": if ports.http == nil { ports.http = port }
            default: break
            }
        }
        return ports
    }

    /// Every numeric port a config's inbounds bind (for the pre-flight "port in use" check).
    static func inboundPorts(in config: [String: Any]) -> [Int] {
        (config["inbounds"] as? [[String: Any]] ?? []).compactMap { ($0["port"] as? NSNumber)?.intValue }
    }

    // MARK: - Latency test

    /// A minimal config used for parallel real-delay testing:
    /// one SOCKS inbound per profile, each routed to its own tagged outbound.
    /// `bindInterface`: while TUN mode is on, test traffic must leave through the physical
    /// interface, or it would be proxied twice and the numbers would be meaningless.
    static func latencyTestConfig(profiles: [ConnectionProfile], basePort: Int, bindInterface: String? = nil) -> (config: [String: Any], ports: [UUID: Int]) {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        var ports: [UUID: Int] = [:]

        for (i, p) in profiles.enumerated() {
            let tag = "test_\(i)"
            let port = basePort + i
            ports[p.id] = port
            inbounds.append([
                "tag": tag, "listen": "127.0.0.1", "port": port, "protocol": "socks",
                "settings": ["auth": "noauth", "udp": false] as [String: Any],
            ])
            var o = outbound(for: p)
            o["tag"] = tag
            if let iface = bindInterface, !iface.isEmpty {
                var stream = o["streamSettings"] as? [String: Any] ?? [:]
                var sockopt = stream["sockopt"] as? [String: Any] ?? [:]
                sockopt["interface"] = iface
                stream["sockopt"] = sockopt
                o["streamSettings"] = stream
            }
            outbounds.append(o)
            rules.append(["type": "field", "inboundTag": [tag], "outboundTag": tag])
        }
        outbounds.append(["tag": "direct", "protocol": "freedom", "settings": [String: Any]()])

        return ([
            "log": ["loglevel": "error"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "AsIs", "rules": rules],
        ], ports)
    }

    static func splitList(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
