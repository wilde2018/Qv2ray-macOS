import Foundation

/// Pure-logic smoke tests, run with `Qv2rayMac --selftest`. Uses a throwaway data folder.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("qv2ray-selftest-\(getpid())")
        try? FileManager.default.removeItem(at: home)
        setenv("QV2RAY_HOME", home.path, 1)
        defer { try? FileManager.default.removeItem(at: home) }

        var failures = 0
        var total = 0
        func check(_ cond: Bool, _ name: String) {
            total += 1
            if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)") }
        }
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"

        print("[1] Share links — parse")
        let vmessJSON: [String: Any] = ["v": "2", "ps": "东京节点", "add": "1.2.3.4", "port": "443", "id": uuid,
                                        "aid": "0", "scy": "auto", "net": "ws", "type": "none",
                                        "host": "cdn.example.com", "path": "/ray", "tls": "tls", "sni": "sni.example.com"]
        let vmessLink = "vmess://" + (try! JSONSerialization.data(withJSONObject: vmessJSON)).base64EncodedString()
        let vmessP = ShareLinks.parseOne(vmessLink)
        check(vmessP?.proto == .vmess && vmessP?.address == "1.2.3.4" && vmessP?.port == 443, "vmess basic fields")
        check(vmessP?.stream.network == .ws && vmessP?.stream.wsPath == "/ray" && vmessP?.stream.wsHost == "cdn.example.com", "vmess ws stream")
        check(vmessP?.stream.security == .tls && vmessP?.stream.sni == "sni.example.com", "vmess tls")
        check(vmessP?.name == "东京节点", "vmess name")

        let vlessLink = "vless://\(uuid)@example.com:443?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=a1b2c3d4&spx=%2Fx&type=tcp&flow=xtls-rprx-vision#Reality%E8%8A%82%E7%82%B9"
        let vlessP = ShareLinks.parseOne(vlessLink)
        check(vlessP?.proto == .vless && vlessP?.uuid == uuid, "vless uuid")
        check(vlessP?.stream.security == .reality && (vlessP?.stream.realityPublicKey ?? "").hasPrefix("SbVK") && vlessP?.stream.realitySpiderX == "/x", "vless reality")
        check(vlessP?.flow == "xtls-rprx-vision" && vlessP?.name == "Reality节点", "vless flow+name")
        check(ShareLinks.parseOne("vless://\(uuid)@example.com:443?type=ws&security=tls#东京 01")?.name == "东京 01", "raw unicode/space fragment")

        let ssSIP002 = "ss://" + Data("aes-256-gcm:pass word".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            + "@5.6.7.8:8388#SS%20node"
        let ssP = ShareLinks.parseOne(ssSIP002)
        check(ssP?.proto == .shadowsocks && ssP?.method == "aes-256-gcm" && ssP?.password == "pass word", "ss sip002 userinfo")
        check(ssP?.address == "5.6.7.8" && ssP?.port == 8388 && ssP?.name == "SS node", "ss host+name")
        let ssLegacy = ShareLinks.parseOne("ss://" + Data("chacha20-ietf-poly1305:pw@9.9.9.9:1234".utf8).base64EncodedString())
        check(ssLegacy?.method == "chacha20-ietf-poly1305" && ssLegacy?.address == "9.9.9.9" && ssLegacy?.port == 1234, "ss legacy base64")
        let ss2022 = ShareLinks.parseOne("ss://2022-blake3-aes-128-gcm:YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y%2BuKlW2qjlI%3D@5.6.7.8:443#SS2022")
        check(ss2022?.method == "2022-blake3-aes-128-gcm" && ss2022?.password == "YctPZ6U7xPPcU+gp3u+0tx/tRizJN9K8y+uKlW2qjlI=", "ss 2022 plain userinfo")

        let trojanLink = "trojan://pass123@tj.example.net:443?security=tls&sni=tj.example.net&type=ws&path=%2Ftj#TrojanNode"
        let trojanP = ShareLinks.parseOne(trojanLink)
        check(trojanP?.proto == .trojan && trojanP?.password == "pass123" && trojanP?.stream.network == .ws && trojanP?.stream.wsPath == "/tj", "trojan link")
        let trojanInsecure = ShareLinks.parseOne("trojan://pw@h.example:443?allowInsecure=1#t")
        check(trojanInsecure?.stream.security == .tls && trojanInsecure?.stream.allowInsecure == true, "trojan default tls + allowInsecure")

        let subBody = Data([vmessLink, trojanLink].joined(separator: "\r\n").utf8).base64EncodedString()
        check(ShareLinks.parse(subBody).count == 2, "base64 subscription body (CRLF)")

        print("[2] Share links — formats fixed in this release")
        let qvNew = ShareLinks.parseOne("vmess://ws+tls:\(uuid)-0@example.com:443/?path=%2Fws&host=cdn.example.com&tlsServerName=sni.example.com#Qv%20Node")
        check(qvNew?.stream.network == .ws && qvNew?.stream.security == .tls && qvNew?.stream.wsPath == "/ws"
              && qvNew?.stream.sni == "sni.example.com" && qvNew?.uuid == uuid && qvNew?.name == "Qv Node", "vmess_new (Qv2ray URL format)")
        let xrayVmess = ShareLinks.parseOne("vmess://\(uuid)@example.com:8443?type=grpc&serviceName=gun&security=tls&sni=a.example#X")
        check(xrayVmess?.stream.network == .grpc && xrayVmess?.port == 8443 && xrayVmess?.stream.grpcServiceName == "gun", "vmess Xray URL format")
        let xhttp = ShareLinks.parseOne("vless://\(uuid)@h.example:443?type=xhttp&path=%2Fx&mode=stream-one&security=tls#n")
        check(xhttp?.stream.network == .splithttp && xhttp?.stream.xhttpPath == "/x" && xhttp?.stream.xhttpMode == "stream-one", "vless type=xhttp alias")

        func roundTrip(_ p: ConnectionProfile) -> ConnectionProfile? { ShareLinks.serialize(p).flatMap(ShareLinks.parseOne) }
        var base = vmessP!
        base.stream = StreamSettings()
        var h2 = base; h2.stream.network = .http; h2.stream.h2Host = "a.example"; h2.stream.h2Path = "/h2"
        check(roundTrip(h2)?.stream.network == .http && roundTrip(h2)?.stream.h2Path == "/h2", "vmess h2 round-trip (was TCP)")
        var up = base; up.stream.network = .httpupgrade; up.stream.httpupgradePath = "/up"; up.stream.httpupgradeHost = "u.example"
        check(roundTrip(up)?.stream.httpupgradePath == "/up" && roundTrip(up)?.stream.httpupgradeHost == "u.example", "vmess httpupgrade round-trip")
        var sh = base; sh.stream.network = .splithttp; sh.stream.xhttpPath = "/x"; sh.stream.xhttpMode = "packet-up"
        check(roundTrip(sh)?.stream.xhttpPath == "/x" && roundTrip(sh)?.stream.xhttpMode == "packet-up", "vmess xhttp round-trip")
        var quic = base; quic.stream.network = .quic; quic.stream.quicSecurity = "aes-128-gcm"; quic.stream.quicKey = "k"; quic.stream.quicHeaderType = "srtp"
        let quicRT = roundTrip(quic)
        check(quicRT?.stream.quicSecurity == "aes-128-gcm" && quicRT?.stream.quicKey == "k" && quicRT?.stream.quicHeaderType == "srtp", "vmess quic round-trip")
        if let p = vmessP { check(roundTrip(p)?.uuid == p.uuid && roundTrip(p)?.stream.network == .ws, "vmess ws round-trip") }
        if let p = vlessP {
            let r = roundTrip(p)
            check(r?.stream.realityShortId == "a1b2c3d4" && r?.stream.realitySpiderX == "/x" && r?.flow == p.flow && r?.name == p.name, "vless reality round-trip")
        }
        var tj = trojanP!; tj.password = "p@ss:w/rd#1"
        check(roundTrip(tj)?.password == "p@ss:w/rd#1", "trojan special-char password round-trip")
        if let p = ss2022 { check(roundTrip(p)?.password == p.password, "ss 2022 round-trip") }
        if let p = ssP { check(roundTrip(p)?.method == p.method && roundTrip(p)?.password == p.password, "ss round-trip") }

        let plugin = ShareLinks.parseDetailed("ss://YWVzLTEyOC1nY206cGFzcw@1.2.3.4:8388/?plugin=obfs-local%3Bobfs%3Dhttp#Obfs")
        check(plugin.profiles.isEmpty && plugin.skipped.count == 1, "ss SIP003 plugin link skipped with reason")
        let sip008 = #"{"version":1,"servers":[{"server":"1.1.1.1","server_port":8388,"method":"aes-256-gcm","password":"p","remarks":"A"},{"server":"2.2.2.2","server_port":8389,"method":"aes-256-gcm","password":"p","plugin":"obfs-local"}]}"#
        let sip = ShareLinks.parseDetailed(sip008)
        check(sip.profiles.count == 1 && sip.profiles.first?.name == "A" && sip.skipped.count == 1, "SIP008 subscription")
        check(ShareLinks.parseDetailed("ssr://abc\n" + trojanLink).skipped.count == 1, "unsupported scheme reported")

        print("[3] Config generation")
        var profile = vmessP!
        profile.stream.security = .tls
        let prefs = Preferences()
        var scheme = RoutingScheme.builtIns()[1]
        scheme.rules = [RouteRule(outboundTag: "direct", domains: "geosite:cn", ips: "geoip:private")]
        let cfg = ConfigGenerator.fullConfig(profile: profile, prefs: prefs, scheme: scheme)
        let inbounds = cfg["inbounds"] as? [[String: Any]] ?? []
        check(inbounds.count == 3, "3 inbounds (socks/http/api)")
        let socks = inbounds.first { ($0["tag"] as? String) == "socks_IN" }
        check((socks?["port"] as? Int) == 1089 && ((socks?["sniffing"] as? [String: Any])?["enabled"] as? Bool) == true, "socks inbound ok")
        let outbounds = cfg["outbounds"] as? [[String: Any]] ?? []
        check((outbounds.first?["tag"] as? String) == "proxy" && (outbounds.first?["protocol"] as? String) == "vmess", "proxy outbound first")
        let rules = ((cfg["routing"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? []
        check((rules.first?["inboundTag"] as? [String]) == ["api"], "api routing rule first")
        check((rules[1]["ip"] as? [String])?.contains("192.168.0.0/16") == true && (rules[1]["outboundTag"] as? String) == "direct",
              "LAN bypass rule (CIDRs, no geodata needed)")
        check(rules.contains { ($0["outboundTag"] as? String) == "direct" && ($0["domain"] as? [String]) == ["geosite:cn"] }, "custom rule present")
        let stream = outbounds.first?["streamSettings"] as? [String: Any]
        check(stream?["security"] as? String == "tls" && (stream?["tlsSettings"] as? [String: Any])?["serverName"] as? String == "sni.example.com", "streamSettings tls")
        check((try? jsonData(from: cfg)).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil, "generated config is valid JSON")

        var direct = scheme; direct.mode = .direct; direct.domainStrategy = "AsIs"
        let dRules = (ConfigGenerator.routingBlock(scheme: direct, apiEnabled: true, bypassLAN: true)["rules"] as? [[String: Any]]) ?? []
        check((dRules.last?["network"] as? String) == "tcp,udp" && (dRules.last?["outboundTag"] as? String) == "direct"
              && !dRules.contains { $0["ip"] != nil }, "direct mode catch-all matches domains too")
        var global = scheme; global.mode = .global
        let gRules = (ConfigGenerator.routingBlock(scheme: global, apiEnabled: false, bypassLAN: true)["rules"] as? [[String: Any]]) ?? []
        check((gRules.last?["network"] as? String) == "tcp,udp" && (gRules.last?["outboundTag"] as? String) == "proxy"
              && (gRules.first?["outboundTag"] as? String) == "direct", "global mode: LAN direct, rest proxy")

        var overridden = profile
        overridden.outboundOverrideJSON = #"{"protocol":"freedom","settings":{}}"#
        check(ConfigGenerator.outbound(for: overridden)["protocol"] as? String == "freedom"
              && ConfigGenerator.outbound(for: overridden)["tag"] as? String == "proxy"
              && ConfigGenerator.generatedOutbound(for: overridden)["protocol"] as? String == "vmess", "outbound override vs generated")

        print("[4] Custom configs")
        let custom = ConfigGenerator.prepareCustom(["outbounds": [["protocol": "freedom", "tag": "my-out"]]], prefs: prefs)
        let cIn = custom["inbounds"] as? [[String: Any]] ?? []
        let cRules = ((custom["routing"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? []
        check(cIn.count == 3 && (cRules.first?["outboundTag"] as? String) == "api" && custom["api"] != nil, "custom config gets inbounds + stats API")
        check(ConfigGenerator.proxyPorts(in: custom) == .init(socks: 1089, http: 8889), "proxy ports detected from config")
        let own = ConfigGenerator.prepareCustom(["inbounds": [["protocol": "socks", "port": 7890, "listen": "127.0.0.1"]]], prefs: prefs)
        check(ConfigGenerator.proxyPorts(in: own).socks == 7890 && ConfigGenerator.proxyPorts(in: own).http == nil, "custom inbounds kept")

        print("[5] Persistence robustness")
        let dec = JSONDecoder()
        let p1 = try? dec.decode(Preferences.self, from: Data(#"{"socksPort": 7890, "updateRepo": "Qv2ray/Qv2ray"}"#.utf8))
        check(p1?.socksPort == 7890 && p1?.httpPort == 8889 && p1?.updateRepo == "", "preferences with missing keys decode (defaults kept)")
        let c1 = try? dec.decode(ConnectionProfile.self, from: Data(#"{"name":"x","stream":{"network":"future-transport"}}"#.utf8))
        check(c1?.name == "x" && c1?.stream.network == .tcp, "profile with unknown enum value decodes")
        var s1 = StreamSettings(), s2 = StreamSettings()
        s2.tcpHeaderType = "http"
        check(s1 != s2, "StreamSettings equality covers every field")
        s1.tcpHeaderType = "http"
        check(s1 == s2, "StreamSettings equal when identical")
        var savedBuiltin = RoutingScheme(id: RoutingScheme.rulesID, name: "Rules", isBuiltIn: true, mode: .rules)
        savedBuiltin.rules = [RouteRule(domains: "example.com")]
        let merged = ProfileStore.mergeWithBuiltIns([savedBuiltin, RoutingScheme(name: "Global", mode: .rules)])
        check(merged.first { $0.id == RoutingScheme.rulesID }?.rules.count == 1 && merged.count == 4,
              "built-in scheme rules persist; custom scheme named like a built-in kept")

        print("[6] Store operations")
        let store = ProfileStore.shared
        let g = ProfileGroup(name: "G")
        store.addGroup(g)
        store.addProfiles([vmessP!], to: g.id)
        store.addGroup(g) // what the old group editor did on every edit
        check(store.data.groups.filter { $0.id == g.id }.count == 1 && store.profiles(in: g.id).count == 1, "re-adding a group doesn't duplicate / orphan it")
        var a = ConnectionProfile(); a.name = "A"; a.address = "a.example"; a.proto = .trojan
        var b = ConnectionProfile(); b.name = "B"; b.address = "b.example"; b.proto = .trojan
        var dupA = a; dupA.id = UUID()
        store.replaceSubscriptionProfiles(group: g.id, with: [a, dupA, b])
        let firstA = store.profiles(in: g.id).first { $0.name == "A" }?.id
        var a2 = a; a2.id = UUID()
        var dupA2 = a; dupA2.id = UUID()
        let r = store.replaceSubscriptionProfiles(group: g.id, with: [a2, dupA2, b, a])
        check(store.profiles(in: g.id).count == 4 && store.profiles(in: g.id).first?.id == firstA && r.removed == 0,
              "subscription update with duplicate nodes (was a crash)")
        store.lastConnected = firstA
        store.deleteProfiles([firstA!])
        check(store.lastConnected == nil && store.profile(firstA!) == nil, "delete clears last-connected")

        let qv = FileManager.default.temporaryDirectory.appendingPathComponent("qv-migrate-\(getpid())")
        try? FileManager.default.createDirectory(at: qv.appendingPathComponent("connections"), withIntermediateDirectories: true)
        let out = ConfigGenerator.outbound(for: vmessP!)
        func write(_ obj: Any, _ name: String) { try? JSONSerialization.data(withJSONObject: obj).write(to: qv.appendingPathComponent(name)) }
        write(["000000000000": ["displayName": "Default", "connections": ["c1"]],
               "g2": ["displayName": "Sub", "isSubscription": true,
                      "subscriptionOption": ["address": "https://s.example", "updateInterval": 1.5], "connections": ["c2"]]], "groups.json")
        write(["c1": ["displayName": "One"], "c2": ["displayName": "Two"]], "connections.json")
        write(["outbounds": [out]], "connections/c1.qv2ray.json")
        write(["outbounds": [out], "routing": ["rules": [["type": "field", "outboundTag": "proxy"]]]], "connections/c2.qv2ray.json")
        let report = store.importFromQv2rayConfig(folder: qv)
        let one = store.allProfiles.first { $0.name == "One" }
        let two = store.allProfiles.first { $0.name == "Two" }
        let subGroup = store.data.groups.first { $0.name == "Sub" }
        check(report.connections == 2 && report.groups == 1 && one?.proto == .vmess && two?.proto == .custom
              && subGroup?.updateIntervalHours == 36 && subGroup?.subscriptionURL == "https://s.example",
              "Qv2ray v2.x migration (outbounds[], .qv2ray.json, interval in days)")
        try? FileManager.default.removeItem(at: qv)

        print("[7] Stats / gRPC")
        var req = MiniProto.stringField(1, "")
        req += MiniProto.boolField(2, true)
        check(req == Data([0x0a, 0x00, 0x10, 0x01]), "QueryStatsRequest wire bytes")
        func grpcFrame(_ message: Data) -> Data {
            var f = Data([0])
            f.append(contentsOf: [UInt8((message.count >> 24) & 0xff), UInt8((message.count >> 16) & 0xff),
                                  UInt8((message.count >> 8) & 0xff), UInt8(message.count & 0xff)])
            return f + message
        }
        func stat(_ name: String, _ v: UInt64) -> Data {
            MiniProto.messageField(1, MiniProto.stringField(1, name) + MiniProto.tag(field: 2, wire: 0) + MiniProto.varint(v))
        }
        let snap = StatsService.parseResponse(grpcFrame(stat("outbound>>>proxy>>>traffic>>>uplink", 12345))
                                              + grpcFrame(stat("outbound>>>proxy>>>traffic>>>downlink", 999)))
        check(snap.proxyUp == 12345 && snap.proxyDown == 999, "QueryStatsResponse parse")
        let customSnap = StatsSnapshot(values: ["outbound>>>my-out>>>traffic>>>uplink": 10,
                                                "outbound>>>direct>>>traffic>>>uplink": 5,
                                                "outbound>>>api>>>traffic>>>uplink": 99])
        check(customSnap.proxyUp == 10 && customSnap.directUp == 5, "custom outbound tags count as proxy traffic")
        check(H2GRPCClient.frame(type: 0, flags: 1, stream: 1, payload: Data([0x01, 0x02])) == Data([0, 0, 2, 0, 1, 0, 0, 0, 1, 1, 2]), "http2 frame encoding")

        print("[8] Misc")
        let (tcfg, ports) = ConfigGenerator.latencyTestConfig(profiles: [profile, trojanP!], basePort: 30000)
        check((tcfg["inbounds"] as? [[String: Any]])?.count == 2 && ports.count == 2, "latency test config structure")
        let sigA = CoreRunner.signature(profile: profile, prefs: prefs, scheme: scheme)
        var prefsPort = prefs; prefsPort.socksPort = 1090
        var prefsLang = prefs; prefsLang.language = "en"
        check(sigA == CoreRunner.signature(profile: profile, prefs: prefsLang, scheme: scheme)
              && sigA != CoreRunner.signature(profile: profile, prefs: prefsPort, scheme: scheme), "reconnect-needed signature")
        check(QRService.generate(for: vmessLink) != nil, "QR code generated")
        check(UpdateChecker.isNewer("v2.8.0", than: "v2.7.0") && !UpdateChecker.isNewer("v2.7.0", than: "v2.7.0")
              && UpdateChecker.isNewer("v10.0.0", than: "v2.7.0"), "semver compare")

        print("[9] Localization")
        func specs(_ s: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(@|d|ld|%)")
            return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }.sorted()
        }
        let mismatched = L10n.en.keys.filter { key in specs(L10n.en[key]!) != specs(L10n.zh[key] ?? L10n.en[key]!) }
        check(mismatched.isEmpty, "format specifiers match between en/zh" + (mismatched.isEmpty ? "" : " \(mismatched.sorted())"))
        check(Set(L10n.zh.keys).subtracting(L10n.en.keys).isEmpty, "no zh-only keys")
        check(String(format: L10n.tr("import.imported"), 3).contains("3"), "integer format keys use %d")

        print(failures == 0 ? "ALL \(total) TESTS PASSED" : "\(failures) OF \(total) TESTS FAILED")
        return failures == 0 ? 0 : 1
    }
}
