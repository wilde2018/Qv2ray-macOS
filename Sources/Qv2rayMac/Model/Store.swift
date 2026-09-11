import Foundation

/// Persistent profile store: groups, connections, routing schemes, preferences.
/// Files live in ~/Library/Application Support/Qv2ray-mac/ (override with $QV2RAY_HOME).
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    struct ConnectionsFile: Codable {
        var groups: [ProfileGroup] = []
        /// group id -> profile ids (order)
        var order: [String: [UUID]] = [:]
        var profiles: [UUID: ConnectionProfile] = [:]
    }

    @Published var data = ConnectionsFile()
    @Published var routingSchemes: [RoutingScheme] = RoutingScheme.builtIns()
    @Published var preferences = Preferences()
    @Published var lastConnected: UUID? = nil { didSet { saveLastState() } }
    /// nil value = test ran and timed out; missing key = never tested.
    @Published var latencies: [UUID: Int?] = [:]
    /// Files that failed to decode on launch (moved aside, never overwritten).
    private(set) var loadWarnings: [String] = []

    static var appSupport: URL {
        if let home = ProcessInfo.processInfo.environment["QV2RAY_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Qv2ray-mac", isDirectory: true)
    }
    var connectionsFileURL: URL { Self.appSupport.appendingPathComponent("profiles.json") }
    var routingFileURL: URL { Self.appSupport.appendingPathComponent("routing.json") }
    var prefsFileURL: URL { Self.appSupport.appendingPathComponent("preferences.json") }
    var lastStateURL: URL { Self.appSupport.appendingPathComponent("laststate.json") }
    var latencyFileURL: URL { Self.appSupport.appendingPathComponent("latency.json") }
    var runtimeDir: URL { Self.appSupport.appendingPathComponent("runtime", isDirectory: true) }

    private var loading = false

    init() {
        Self.appSupport.createDirIfNeeded()
        runtimeDir.createDirIfNeeded()
        let firstRun = !FileManager.default.fileExists(atPath: routingFileURL.path)
        load()
        ensureDefaultGroup()
        if firstRun && !routingSchemes.contains(where: { !$0.isBuiltIn }) {
            // Seed the CN-bypass scheme once so "rule mode" works out of the box.
            let starter = RoutingScheme.starterCNBypass()
            routingSchemes.append(starter)
            preferences.currentRoutingSchemeID = preferences.currentRoutingSchemeID ?? starter.id
            saveRouting()
        }
        if preferences.currentRoutingSchemeID.flatMap({ id in routingSchemes.first { $0.id == id } }) == nil {
            preferences.currentRoutingSchemeID = routingSchemes.first(where: { $0.mode == .rules && !$0.isBuiltIn })?.id
                ?? RoutingScheme.rulesID
        }
    }

    // MARK: - Load / Save

    private func load() {
        loading = true
        defer { loading = false }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let f: ConnectionsFile = decodeFile(connectionsFileURL, dec) { data = f }
        if let r: [RoutingScheme] = decodeFile(routingFileURL, dec) { routingSchemes = Self.mergeWithBuiltIns(r) }
        if let p: Preferences = decodeFile(prefsFileURL, dec) { preferences = p }
        if let d = try? Data(contentsOf: lastStateURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let idStr = obj["lastConnected"] as? String,
           let id = UUID(uuidString: idStr), data.profiles[id] != nil {
            lastConnected = id
        }
        if let d = try? Data(contentsOf: latencyFileURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Int] {
            for (k, v) in obj {
                if let id = UUID(uuidString: k), data.profiles[id] != nil { latencies[id] = v < 0 ? .some(nil) : v }
            }
        }
    }

    /// nil when the file doesn't exist. A file that exists but can't be decoded is moved
    /// aside so the next save can never silently overwrite the user's data.
    private func decodeFile<T: Decodable>(_ url: URL, _ dec: JSONDecoder) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try dec.decode(T.self, from: d)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingPathExtension().appendingPathExtension("broken-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            loadWarnings.append("\(url.lastPathComponent) → \(backup.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Built-ins always come from code (stable ids, localized names), but keep the
    /// user's rules / domain strategy saved for them.
    static func mergeWithBuiltIns(_ saved: [RoutingScheme]) -> [RoutingScheme] {
        var all = RoutingScheme.builtIns()
        for i in all.indices {
            if let s = saved.first(where: { $0.id == all[i].id }) {
                all[i].rules = s.rules
                all[i].domainStrategy = s.domainStrategy
            }
        }
        let builtinIDs = Set(all.map(\.id))
        all += saved.filter { !$0.isBuiltIn && !builtinIDs.contains($0.id) }
        return all
    }

    func saveAll() {
        saveConnections()
        saveRouting()
        savePrefs()
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(value) { try? d.write(to: url, options: .atomic) }
    }

    func saveConnections() { write(data, to: connectionsFileURL) }
    func saveRouting() { write(routingSchemes, to: routingFileURL) }
    func savePrefs() { write(preferences, to: prefsFileURL) }

    private func saveLastState() {
        guard !loading else { return }
        if let id = lastConnected,
           let d = try? JSONSerialization.data(withJSONObject: ["lastConnected": id.uuidString]) {
            try? d.write(to: lastStateURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: lastStateURL)
        }
    }

    func saveLatencies() {
        var obj: [String: Int] = [:]
        for (id, v) in latencies { obj[id.uuidString] = v ?? -1 }
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: latencyFileURL, options: .atomic) }
    }

    // MARK: - Groups

    func ensureDefaultGroup() {
        if !data.groups.contains(where: { $0.isDefault }) {
            data.groups.insert(ProfileGroup(name: "__default__"), at: 0)
        }
    }

    var defaultGroupID: UUID { data.groups.first { $0.isDefault }?.id ?? data.groups.first!.id }

    func group(_ id: UUID) -> ProfileGroup? { data.groups.first { $0.id == id } }
    func groupOf(profile id: UUID) -> UUID? {
        for (key, ids) in data.order where ids.contains(id) {
            if let uuid = UUID(uuidString: key) { return uuid }
        }
        return nil
    }

    func addGroup(_ g: ProfileGroup) {
        guard group(g.id) == nil else { return updateGroup(g) }
        data.groups.append(g)
        data.order[g.id.uuidString] = data.order[g.id.uuidString] ?? []
        saveConnections()
    }

    func updateGroup(_ g: ProfileGroup) {
        if let i = data.groups.firstIndex(where: { $0.id == g.id }) { data.groups[i] = g }
        saveConnections()
    }

    func deleteGroup(_ id: UUID) {
        guard let g = group(id), !g.isDefault else { return }
        let members = data.order[id.uuidString] ?? []
        let defaultOrder = data.order[defaultGroupID.uuidString] ?? []
        data.order[defaultGroupID.uuidString] = defaultOrder + members
        data.order[id.uuidString] = nil
        data.groups.removeAll { $0.id == id }
        saveConnections()
    }

    // MARK: - Profiles

    func profiles(in group: UUID) -> [ConnectionProfile] {
        (data.order[group.uuidString] ?? []).compactMap { data.profiles[$0] }
    }

    var allProfiles: [ConnectionProfile] { Array(data.profiles.values) }

    func profile(_ id: UUID) -> ConnectionProfile? { data.profiles[id] }

    @discardableResult
    func addProfile(_ p: ConnectionProfile, to group: UUID? = nil) -> UUID {
        addProfiles([p], to: group)
        return p.id
    }

    func addProfiles(_ ps: [ConnectionProfile], to group: UUID? = nil) {
        guard !ps.isEmpty else { return }
        let gid = group.flatMap { self.group($0)?.id } ?? defaultGroupID
        for p in ps {
            data.profiles[p.id] = p
            data.order[gid.uuidString, default: []].append(p.id)
        }
        saveConnections()
    }

    func updateProfile(_ p: ConnectionProfile) {
        data.profiles[p.id] = p
        saveConnections()
    }

    func deleteProfiles(_ ids: [UUID]) {
        let set = Set(ids)
        for id in ids { data.profiles[id] = nil; latencies[id] = nil }
        for (k, v) in data.order { data.order[k] = v.filter { !set.contains($0) } }
        if let cur = lastConnected, set.contains(cur) { lastConnected = nil }
        saveConnections()
        saveLatencies()
    }

    func moveProfiles(_ ids: [UUID], to group: UUID) {
        let set = Set(ids)
        for (k, v) in data.order { data.order[k] = v.filter { !set.contains($0) } }
        data.order[group.uuidString, default: []].append(contentsOf: ids)
        saveConnections()
    }

    /// Replace a subscription group's members with freshly parsed profiles.
    /// Existing ids (and so latency / "last connected") are kept when a node matches
    /// by name, or failing that by protocol + address + port — like Qv2ray.
    @discardableResult
    func replaceSubscriptionProfiles(group gid: UUID, with newProfiles: [ConnectionProfile]) -> (kept: Int, added: Int, removed: Int) {
        let old = data.order[gid.uuidString] ?? []
        // Queues, so duplicate names / endpoints map onto distinct old ids in order.
        var byName: [String: [UUID]] = [:]
        var byEndpoint: [String: [UUID]] = [:]
        for id in old {
            guard let p = data.profiles[id] else { continue }
            byName[p.name, default: []].append(id)
            byEndpoint["\(p.proto.rawValue)|\(p.address)|\(p.port)", default: []].append(id)
        }
        var used = Set<UUID>()
        func take(_ queue: inout [String: [UUID]], _ key: String) -> UUID? {
            while let first = queue[key]?.first {
                queue[key]!.removeFirst()
                if !used.contains(first) { return first }
            }
            return nil
        }
        var newIDs: [UUID] = []
        var kept = 0
        for var p in newProfiles {
            if let id = take(&byName, p.name) ?? take(&byEndpoint, "\(p.proto.rawValue)|\(p.address)|\(p.port)") {
                p.id = id
                kept += 1
            } else if used.contains(p.id) {
                p.id = UUID()
            }
            used.insert(p.id)
            data.profiles[p.id] = p
            newIDs.append(p.id)
        }
        let removed = old.filter { !used.contains($0) }
        for id in removed {
            data.profiles[id] = nil
            latencies[id] = nil
        }
        data.order[gid.uuidString] = newIDs
        if let cur = lastConnected, removed.contains(cur) { lastConnected = nil }
        saveConnections()
        saveLatencies()
        return (kept, newIDs.count - kept, removed.count)
    }

    // MARK: - Routing

    var currentRoutingScheme: RoutingScheme {
        if let id = preferences.currentRoutingSchemeID, let s = routingSchemes.first(where: { $0.id == id }) { return s }
        return routingSchemes.first { $0.id == RoutingScheme.rulesID } ?? RoutingScheme.builtIns()[1]
    }

    // MARK: - Qv2ray migration

    struct MigrationReport {
        var groups = 0
        var connections = 0
        var errors: [String] = []
    }

    /// Import groups & connections from a Qv2ray (v2.x) config directory:
    /// groups.json, connections.json and connections/<id>.qv2ray.json.
    func importFromQv2rayConfig(folder: URL) -> MigrationReport {
        var report = MigrationReport()
        let fm = FileManager.default

        struct QvGroup { var id: String; var name: String; var isSub: Bool; var url: String; var hours: Int; var members: [String] }
        var qvGroups: [QvGroup] = []
        if let gd = try? Data(contentsOf: folder.appendingPathComponent("groups.json")),
           let groups = try? JSONSerialization.jsonObject(with: gd) as? [String: Any] {
            for (gid, raw) in groups {
                guard let g = raw as? [String: Any] else { continue }
                let sub = g["subscriptionOption"] as? [String: Any] ?? [:]
                // v2.x stores the interval in days under subscriptionOption; older builds used hours at top level.
                let hours: Int
                if let days = (sub["updateInterval"] as? NSNumber)?.doubleValue {
                    hours = max(1, Int(days * 24))
                } else {
                    hours = (g["updateInterval"] as? NSNumber)?.intValue ?? 12
                }
                qvGroups.append(QvGroup(id: gid,
                                        name: (g["displayName"] as? String) ?? gid,
                                        isSub: (g["isSubscription"] as? Bool) ?? false,
                                        url: (sub["address"] as? String) ?? (g["address"] as? String) ?? "",
                                        hours: hours,
                                        members: (g["connections"] as? [String]) ?? []))
            }
        } else {
            report.errors.append("groups.json not found / unreadable")
        }

        var qvNames: [String: String] = [:]
        if let cd = try? Data(contentsOf: folder.appendingPathComponent("connections.json")),
           let conns = try? JSONSerialization.jsonObject(with: cd) as? [String: Any] {
            for (cid, raw) in conns {
                if let c = raw as? [String: Any], let n = c["displayName"] as? String { qvNames[cid] = n }
            }
        }

        let connDir = folder.appendingPathComponent("connections", isDirectory: true)
        var imported: [String: ConnectionProfile] = [:]
        for f in (try? fm.contentsOfDirectory(at: connDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension.lowercased() == "json" {
            let cid = f.lastPathComponent.replacingOccurrences(of: ".qv2ray.json", with: "").replacingOccurrences(of: ".json", with: "")
            guard let d = try? Data(contentsOf: f),
                  let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any], !root.isEmpty else {
                report.errors.append("\(f.lastPathComponent): unreadable")
                continue
            }
            if var p = Self.simpleOutbound(of: root).flatMap({ ConnectionProfile(outbound: $0) }) {
                p.name = qvNames[cid] ?? p.name
                imported[cid] = p
            } else {
                var p = ConnectionProfile()
                p.proto = .custom
                p.name = qvNames[cid] ?? cid
                if let pretty = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                    p.customConfigJSON = String(data: pretty, encoding: .utf8) ?? ""
                }
                imported[cid] = p
            }
        }

        for g in qvGroups {
            let isDefault = g.id.allSatisfy { $0 == "0" || $0 == "-" }
            let target: UUID
            if isDefault {
                target = defaultGroupID
            } else {
                let ng = ProfileGroup(name: g.name, isSubscription: g.isSub, subscriptionURL: g.url, updateIntervalHours: g.hours)
                data.groups.append(ng)
                data.order[ng.id.uuidString] = []
                target = ng.id
                report.groups += 1
            }
            for cid in g.members {
                guard let p = imported.removeValue(forKey: cid) else { continue }
                data.profiles[p.id] = p
                data.order[target.uuidString, default: []].append(p.id)
                report.connections += 1
            }
        }
        for (_, p) in imported {
            data.profiles[p.id] = p
            data.order[defaultGroupID.uuidString, default: []].append(p.id)
            report.connections += 1
        }
        saveConnections()
        return report
    }

    /// The single proxy outbound of a "simple" Qv2ray connection (no inbounds, no routing
    /// rules, one outbound), or nil for complex configs that must stay as Custom.
    static func simpleOutbound(of root: [String: Any]) -> [String: Any]? {
        if let o = root["outbound"] as? [String: Any] { return o }
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let inbounds = root["inbounds"] as? [Any] ?? []
        let rules = (root["routing"] as? [String: Any])?["rules"] as? [Any] ?? []
        guard outbounds.count == 1, inbounds.isEmpty, rules.isEmpty else { return nil }
        return outbounds[0]
    }
}

extension ProfileStore.ConnectionsFile {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = c.decode(.groups, or: groups)
        order = c.decode(.order, or: order)
        profiles = c.decode(.profiles, or: profiles)
    }
}

private func intValue(_ any: Any?) -> Int? {
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String { return Int(s) }
    return nil
}

extension ConnectionProfile {
    /// Reverse-engineer a profile from a v2ray outbound JSON object (Qv2ray migration & config-file import).
    init?(outbound: [String: Any]) {
        guard let protoStr = outbound["protocol"] as? String,
              let proto = ProfileProto(rawValue: protoStr), proto != .custom else { return nil }
        self.init()
        self.proto = proto
        if let streamRaw = outbound["streamSettings"] as? [String: Any] {
            self.stream = Self.parseStream(streamRaw)
        }
        if let mux = outbound["mux"] as? [String: Any] {
            self.mux.enabled = (mux["enabled"] as? Bool) ?? false
            self.mux.concurrency = intValue(mux["concurrency"]) ?? -1
        }

        let settings = outbound["settings"] as? [String: Any] ?? [:]
        switch proto {
        case .vmess, .vless:
            guard let vnext = (settings["vnext"] as? [[String: Any]])?.first else { return nil }
            address = (vnext["address"] as? String) ?? ""
            port = intValue(vnext["port"]) ?? 443
            if let user = (vnext["users"] as? [[String: Any]])?.first {
                uuid = (user["id"] as? String) ?? ""
                alterId = intValue(user["alterId"]) ?? 0
                security = (user["security"] as? String) ?? "auto"
                encryption = (user["encryption"] as? String) ?? "none"
                flow = (user["flow"] as? String) ?? ""
            }
        case .shadowsocks, .trojan:
            guard let server = (settings["servers"] as? [[String: Any]])?.first else { return nil }
            address = (server["address"] as? String) ?? ""
            port = intValue(server["port"]) ?? 443
            password = (server["password"] as? String) ?? ""
            method = proto == .shadowsocks ? ((server["method"] as? String) ?? "aes-256-gcm") : ""
        case .custom:
            return nil
        }
        if address.isEmpty { return nil }
    }

    private static func parseStream(_ s: [String: Any]) -> StreamSettings {
        var st = StreamSettings()
        if let net = s["network"] as? String { st.network = TransportNetwork.from(linkType: net) ?? .tcp }
        switch st.network {
        case .tcp:
            let tcp = (s["tcpSettings"] as? [String: Any]) ?? (s["rawSettings"] as? [String: Any])
            if let header = tcp?["header"] as? [String: Any], let type = header["type"] as? String {
                st.tcpHeaderType = type
                if type == "http", let req = header["request"] as? [String: Any] {
                    st.tcpRequestHost = ((req["headers"] as? [String: Any])?["Host"] as? [String])?.joined(separator: ",") ?? ""
                    st.tcpPath = (req["path"] as? [String])?.first ?? ""
                }
            }
        case .ws:
            if let ws = s["wsSettings"] as? [String: Any] {
                st.wsPath = (ws["path"] as? String) ?? ""
                st.wsHost = ((ws["headers"] as? [String: Any])?["Host"] as? String) ?? (ws["host"] as? String) ?? ""
            }
        case .http:
            if let h2 = (s["httpSettings"] as? [String: Any]) ?? (s["h2Settings"] as? [String: Any]) {
                st.h2Host = ((h2["host"] as? [String])?.joined(separator: ",")) ?? ""
                st.h2Path = (h2["path"] as? String) ?? ""
            }
        case .quic:
            if let q = s["quicSettings"] as? [String: Any] {
                st.quicSecurity = (q["security"] as? String) ?? "none"
                st.quicKey = (q["key"] as? String) ?? ""
                if let h = q["header"] as? [String: Any] { st.quicHeaderType = (h["type"] as? String) ?? "none" }
            }
        case .kcp:
            if let k = s["kcpSettings"] as? [String: Any] {
                st.kcpSeed = (k["seed"] as? String) ?? ""
                if let h = k["header"] as? [String: Any] { st.kcpHeaderType = (h["type"] as? String) ?? "none" }
            }
        case .grpc:
            if let g = s["grpcSettings"] as? [String: Any] {
                st.grpcServiceName = (g["serviceName"] as? String) ?? ""
                st.grpcMultiMode = (g["multiMode"] as? Bool) ?? false
            }
        case .httpupgrade:
            if let h = s["httpupgradeSettings"] as? [String: Any] {
                st.httpupgradePath = (h["path"] as? String) ?? ""
                st.httpupgradeHost = (h["host"] as? String) ?? ""
            }
        case .splithttp:
            if let h = (s["splithttpSettings"] as? [String: Any]) ?? (s["xhttpSettings"] as? [String: Any]) {
                st.xhttpPath = (h["path"] as? String) ?? ""
                st.xhttpHost = (h["host"] as? String) ?? ""
                st.xhttpMode = (h["mode"] as? String) ?? "auto"
            }
        }
        if let sec = s["security"] as? String {
            st.security = TlsSecurity(rawValue: sec) ?? .none
            if let tls = s[st.security.settingsKey] as? [String: Any] {
                st.sni = (tls["serverName"] as? String) ?? ""
                st.alpn = ((tls["alpn"] as? [String])?.joined(separator: ",")) ?? ""
                st.allowInsecure = (tls["allowInsecure"] as? Bool) ?? false
                st.fingerprint = (tls["fingerprint"] as? String) ?? ""
                st.realityPublicKey = (tls["publicKey"] as? String) ?? ""
                st.realityShortId = (tls["shortId"] as? String) ?? ""
                st.realitySpiderX = (tls["spiderX"] as? String) ?? ""
            }
        }
        if let sockopt = s["sockopt"] as? [String: Any] {
            st.mark = intValue(sockopt["mark"]) ?? 0
            st.tcpFastOpen = (sockopt["tcpFastOpen"] as? Bool) ?? false
        }
        return st
    }
}

extension URL {
    func createDirIfNeeded() {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
