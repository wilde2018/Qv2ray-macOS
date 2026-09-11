import Foundation

/// Encode any JSON-compatible dictionary to pretty-printed data.
func jsonData(from dict: [String: Any], pretty: Bool = true) throws -> Data {
    try JSONSerialization.data(withJSONObject: dict, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
}

extension KeyedDecodingContainer {
    /// Decode a value when present and valid, otherwise keep `fallback`.
    /// Every persisted model decodes through this so files written by older or
    /// newer versions (missing / extra / unknown-enum fields) still load.
    func decode<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - Connection protocol

enum ProfileProto: String, Codable, CaseIterable, Identifiable {
    case vmess
    case vless
    case shadowsocks = "shadowsocks"
    case trojan
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vmess: return "VMess"
        case .vless: return "VLESS"
        case .shadowsocks: return "Shadowsocks"
        case .trojan: return "Trojan"
        case .custom: return "Custom"
        }
    }
}

// MARK: - Stream settings

enum TransportNetwork: String, Codable, CaseIterable, Identifiable {
    case tcp
    case ws
    case http
    case quic
    case grpc
    case kcp
    case httpupgrade
    case splithttp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tcp: return "TCP"
        case .ws: return "WebSocket"
        case .http: return "HTTP/2 (h2)"
        case .quic: return "QUIC"
        case .grpc: return "gRPC"
        case .kcp: return "mKCP"
        case .httpupgrade: return "HTTPUpgrade"
        case .splithttp: return "XHTTP (SplitHTTP)"
        }
    }

    /// Short name used in lists ("h2", "xhttp").
    var shortName: String {
        switch self {
        case .http: return "h2"
        case .splithttp: return "xhttp"
        default: return rawValue
        }
    }

    /// Accepts the aliases found in share links from different clients.
    static func from(linkType raw: String) -> TransportNetwork? {
        switch raw.lowercased() {
        case "tcp", "raw", "": return .tcp
        case "ws", "websocket": return .ws
        case "http", "h2": return .http
        case "quic": return .quic
        case "grpc", "gun": return .grpc
        case "kcp", "mkcp": return .kcp
        case "httpupgrade": return .httpupgrade
        case "splithttp", "xhttp": return .splithttp
        default: return nil
        }
    }
}

enum TlsSecurity: String, Codable, CaseIterable, Identifiable {
    case none
    case tls
    case reality
    case xtls

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .tls: return "TLS"
        case .reality: return "Reality"
        case .xtls: return "XTLS (legacy)"
        }
    }

    var settingsKey: String {
        switch self {
        case .none: return ""
        case .tls: return "tlsSettings"
        case .reality: return "realitySettings"
        case .xtls: return "xtlsSettings"
        }
    }
}

struct StreamSettings: Codable, Equatable {
    var network: TransportNetwork = .tcp
    /// tcp header type: none / http
    var tcpHeaderType: String = "none"
    var tcpRequestHost: String = ""
    var tcpPath: String = ""
    /// ws
    var wsPath: String = ""
    var wsHost: String = ""
    /// grpc
    var grpcServiceName: String = ""
    var grpcMultiMode = false
    /// h2 / http
    var h2Host: String = ""
    var h2Path: String = ""
    /// quic
    var quicSecurity: String = "none"
    var quicKey: String = ""
    var quicHeaderType: String = "none"
    /// kcp
    var kcpHeaderType: String = "none"
    var kcpSeed: String = ""
    /// httpupgrade
    var httpupgradeHost: String = ""
    var httpupgradePath: String = ""
    /// splithttp / xhttp
    var xhttpPath: String = ""
    var xhttpHost: String = ""
    var xhttpMode: String = "auto"

    /// TLS family
    var security: TlsSecurity = .none
    var sni: String = ""
    var alpn: String = ""
    var allowInsecure = false
    var fingerprint: String = ""
    /// Reality
    var realityPublicKey: String = ""
    var realityShortId: String = ""
    var realitySpiderX: String = ""

    /// sockopt
    var mark: Int = 0
    var tcpFastOpen = false

    /// Short "ws · tls" style summary for lists.
    var summary: String {
        security == .none ? network.shortName : "\(network.shortName) · \(security.rawValue)"
    }
}

struct MuxSettings: Codable, Equatable {
    var enabled = false
    var concurrency = -1
}

// MARK: - Connection profile

struct ConnectionProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var proto: ProfileProto = .vmess
    var address: String = ""
    var port: Int = 443

    // vmess
    var uuid: String = ""
    var alterId: Int = 0
    var security: String = "auto"
    // vless
    var encryption: String = "none"
    var flow: String = ""
    // shadowsocks / trojan
    var method: String = "aes-256-gcm"
    var password: String = ""

    var stream: StreamSettings = StreamSettings()
    var mux: MuxSettings = MuxSettings()

    /// Optional full outbound JSON override. When set, the generated outbound is replaced by this object.
    var outboundOverrideJSON: String = ""

    /// For custom proto: the full v2ray config file content.
    var customConfigJSON: String = ""

    /// Display name for lists
    var displayName: String { name.isEmpty ? "\(address):\(port)" : name }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Groups

struct ProfileGroup: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var isSubscription = false
    var subscriptionURL: String = ""
    /// hours; 0 = manual only
    var updateIntervalHours: Int = 12
    var lastUpdated: Date? = nil
    var autoUpdate = true
    var isDefault: Bool { name == "__default__" }

    var displayName: String { isDefault ? L10n.tr("group.default") : name }
}

// MARK: - Routing

enum RoutingMode: String, Codable, CaseIterable {
    case rules
    case global
    case direct

    var displayName: String {
        switch self {
        case .global: return L10n.tr("mode.global")
        case .rules: return L10n.tr("mode.rules")
        case .direct: return L10n.tr("mode.direct")
        }
    }

    var symbol: String {
        switch self {
        case .global: return "globe"
        case .rules: return "arrow.triangle.branch"
        case .direct: return "arrow.right"
        }
    }
}

struct RouteRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var enabled = true
    var outboundTag: String = "direct" // proxy / direct / block
    var domains: String = ""   // comma / newline separated
    var ips: String = ""
    var port: String = ""
    var network: String = ""   // "", tcp, udp
}

struct RoutingScheme: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var isBuiltIn = false
    var mode: RoutingMode = .rules
    var domainStrategy: String = "IPIfNonMatch"
    var rules: [RouteRule] = []

    static let globalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let rulesID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let directID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

    /// Built-in names follow the current UI language instead of whatever was persisted.
    var localizedName: String {
        switch id {
        case Self.globalID: return L10n.tr("route.global")
        case Self.rulesID: return L10n.tr("route.rules")
        case Self.directID: return L10n.tr("route.direct")
        default: return name
        }
    }

    static func builtIns() -> [RoutingScheme] {
        // Stable UUIDs so the selected built-in persists across launches.
        [
            RoutingScheme(id: globalID, name: "Global", isBuiltIn: true, mode: .global),
            RoutingScheme(id: rulesID, name: "Rules", isBuiltIn: true, mode: .rules),
            RoutingScheme(id: directID, name: "Direct", isBuiltIn: true, mode: .direct),
        ]
    }

    static func starterCNBypass() -> RoutingScheme {
        var s = RoutingScheme(name: "CN Bypass")
        s.mode = .rules
        s.rules = [
            RouteRule(outboundTag: "direct", domains: "geosite:cn", ips: ""),
            RouteRule(outboundTag: "direct", domains: "", ips: "geoip:cn"),
        ]
        return s
    }
}

// MARK: - Preferences

struct Preferences: Codable, Equatable {
    // UI
    var language: String = "system" // system / zh-Hans / en
    var theme: String = "system"    // system / dark / light
    var startAtLogin = false
    var startMinimized = false
    var autoConnectLast = false
    var showSpeedInTray = true
    var checkUpdatesOnLaunch = false

    // Inbound
    var useSocks = true
    var socksPort = 1089
    var useHTTP = true
    var httpPort = 8889
    var listenAddress = "127.0.0.1"
    var allowFromLAN = false
    var sniffingEnabled = true
    var socksEnableUDP = true

    // Outbound / tests
    var latencyTestURL = "https://www.google.com/generate_204"
    var latencyTimeoutSec = 6
    var tcpingTimeoutMS = 3000

    // Core
    var corePath: String = ""      // empty = auto-detect
    var assetsPath: String = ""    // empty = auto-detect
    var logLevel = "warning"
    var apiEnabled = true
    var apiPort = 15490
    var extraCoreArgs = ""

    // Subscription
    var subUpdateIntervalHours = 12
    var subUserAgent = "Qv2ray-mac/3.0.0"

    // System proxy
    var setSystemProxyOnConnect = true
    var proxyBypassDomains: [String] = [
        "127.0.0.1", "::1", "localhost", "*.local", "*.lan",
        "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "fe80::/10",
    ]

    // Routing
    var bypassLAN = true
    var currentRoutingSchemeID: UUID? = nil
    /// The rules-mode scheme the quick "Rules" switch returns to.
    var lastRuleSchemeID: UUID? = nil

    // Advanced
    var statsIntervalMS = 1000
    var autoRestartCore = true
    var maxRestartAttempts = 5

    // Update channel ("owner/repo"); empty disables update checks.
    var updateRepo = ""

    /// Address the inbounds listen on.
    var effectiveListenAddress: String { allowFromLAN ? "0.0.0.0" : (listenAddress.isEmpty ? "127.0.0.1" : listenAddress) }

    /// Host macOS should use to reach the local inbounds.
    var systemProxyHost: String {
        let l = effectiveListenAddress
        return (l == "0.0.0.0" || l == "::" || l.isEmpty) ? "127.0.0.1" : l
    }
}

// MARK: - Tolerant decoding
// Declared in extensions so the memberwise / default initializers stay available.

extension StreamSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = c.decode(.network, or: network)
        tcpHeaderType = c.decode(.tcpHeaderType, or: tcpHeaderType)
        tcpRequestHost = c.decode(.tcpRequestHost, or: tcpRequestHost)
        tcpPath = c.decode(.tcpPath, or: tcpPath)
        wsPath = c.decode(.wsPath, or: wsPath)
        wsHost = c.decode(.wsHost, or: wsHost)
        grpcServiceName = c.decode(.grpcServiceName, or: grpcServiceName)
        grpcMultiMode = c.decode(.grpcMultiMode, or: grpcMultiMode)
        h2Host = c.decode(.h2Host, or: h2Host)
        h2Path = c.decode(.h2Path, or: h2Path)
        quicSecurity = c.decode(.quicSecurity, or: quicSecurity)
        quicKey = c.decode(.quicKey, or: quicKey)
        quicHeaderType = c.decode(.quicHeaderType, or: quicHeaderType)
        kcpHeaderType = c.decode(.kcpHeaderType, or: kcpHeaderType)
        kcpSeed = c.decode(.kcpSeed, or: kcpSeed)
        httpupgradeHost = c.decode(.httpupgradeHost, or: httpupgradeHost)
        httpupgradePath = c.decode(.httpupgradePath, or: httpupgradePath)
        xhttpPath = c.decode(.xhttpPath, or: xhttpPath)
        xhttpHost = c.decode(.xhttpHost, or: xhttpHost)
        xhttpMode = c.decode(.xhttpMode, or: xhttpMode)
        security = c.decode(.security, or: security)
        sni = c.decode(.sni, or: sni)
        alpn = c.decode(.alpn, or: alpn)
        allowInsecure = c.decode(.allowInsecure, or: allowInsecure)
        fingerprint = c.decode(.fingerprint, or: fingerprint)
        realityPublicKey = c.decode(.realityPublicKey, or: realityPublicKey)
        realityShortId = c.decode(.realityShortId, or: realityShortId)
        realitySpiderX = c.decode(.realitySpiderX, or: realitySpiderX)
        mark = c.decode(.mark, or: mark)
        tcpFastOpen = c.decode(.tcpFastOpen, or: tcpFastOpen)
    }
}

extension MuxSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decode(.enabled, or: enabled)
        concurrency = c.decode(.concurrency, or: concurrency)
    }
}

extension ConnectionProfile {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: id)
        name = c.decode(.name, or: name)
        proto = c.decode(.proto, or: proto)
        address = c.decode(.address, or: address)
        port = c.decode(.port, or: port)
        uuid = c.decode(.uuid, or: uuid)
        alterId = c.decode(.alterId, or: alterId)
        security = c.decode(.security, or: security)
        encryption = c.decode(.encryption, or: encryption)
        flow = c.decode(.flow, or: flow)
        method = c.decode(.method, or: method)
        password = c.decode(.password, or: password)
        stream = c.decode(.stream, or: stream)
        mux = c.decode(.mux, or: mux)
        outboundOverrideJSON = c.decode(.outboundOverrideJSON, or: outboundOverrideJSON)
        customConfigJSON = c.decode(.customConfigJSON, or: customConfigJSON)
    }
}

extension ProfileGroup {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: id)
        name = c.decode(.name, or: name)
        isSubscription = c.decode(.isSubscription, or: isSubscription)
        subscriptionURL = c.decode(.subscriptionURL, or: subscriptionURL)
        updateIntervalHours = c.decode(.updateIntervalHours, or: updateIntervalHours)
        lastUpdated = c.decode(.lastUpdated, or: lastUpdated)
        autoUpdate = c.decode(.autoUpdate, or: autoUpdate)
    }
}

extension RouteRule {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: id)
        enabled = c.decode(.enabled, or: enabled)
        outboundTag = c.decode(.outboundTag, or: outboundTag)
        domains = c.decode(.domains, or: domains)
        ips = c.decode(.ips, or: ips)
        port = c.decode(.port, or: port)
        network = c.decode(.network, or: network)
    }
}

extension RoutingScheme {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: id)
        name = c.decode(.name, or: name)
        isBuiltIn = c.decode(.isBuiltIn, or: isBuiltIn)
        mode = c.decode(.mode, or: mode)
        domainStrategy = c.decode(.domainStrategy, or: domainStrategy)
        rules = c.decode(.rules, or: rules)
    }
}

extension Preferences {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = c.decode(.language, or: language)
        theme = c.decode(.theme, or: theme)
        startAtLogin = c.decode(.startAtLogin, or: startAtLogin)
        startMinimized = c.decode(.startMinimized, or: startMinimized)
        autoConnectLast = c.decode(.autoConnectLast, or: autoConnectLast)
        showSpeedInTray = c.decode(.showSpeedInTray, or: showSpeedInTray)
        checkUpdatesOnLaunch = c.decode(.checkUpdatesOnLaunch, or: checkUpdatesOnLaunch)
        useSocks = c.decode(.useSocks, or: useSocks)
        socksPort = c.decode(.socksPort, or: socksPort)
        useHTTP = c.decode(.useHTTP, or: useHTTP)
        httpPort = c.decode(.httpPort, or: httpPort)
        listenAddress = c.decode(.listenAddress, or: listenAddress)
        allowFromLAN = c.decode(.allowFromLAN, or: allowFromLAN)
        sniffingEnabled = c.decode(.sniffingEnabled, or: sniffingEnabled)
        socksEnableUDP = c.decode(.socksEnableUDP, or: socksEnableUDP)
        latencyTestURL = c.decode(.latencyTestURL, or: latencyTestURL)
        latencyTimeoutSec = c.decode(.latencyTimeoutSec, or: latencyTimeoutSec)
        tcpingTimeoutMS = c.decode(.tcpingTimeoutMS, or: tcpingTimeoutMS)
        corePath = c.decode(.corePath, or: corePath)
        assetsPath = c.decode(.assetsPath, or: assetsPath)
        logLevel = c.decode(.logLevel, or: logLevel)
        apiEnabled = c.decode(.apiEnabled, or: apiEnabled)
        apiPort = c.decode(.apiPort, or: apiPort)
        extraCoreArgs = c.decode(.extraCoreArgs, or: extraCoreArgs)
        subUpdateIntervalHours = c.decode(.subUpdateIntervalHours, or: subUpdateIntervalHours)
        subUserAgent = c.decode(.subUserAgent, or: subUserAgent)
        setSystemProxyOnConnect = c.decode(.setSystemProxyOnConnect, or: setSystemProxyOnConnect)
        proxyBypassDomains = c.decode(.proxyBypassDomains, or: proxyBypassDomains)
        bypassLAN = c.decode(.bypassLAN, or: bypassLAN)
        currentRoutingSchemeID = c.decode(.currentRoutingSchemeID, or: currentRoutingSchemeID)
        lastRuleSchemeID = c.decode(.lastRuleSchemeID, or: lastRuleSchemeID)
        statsIntervalMS = c.decode(.statsIntervalMS, or: statsIntervalMS)
        autoRestartCore = c.decode(.autoRestartCore, or: autoRestartCore)
        maxRestartAttempts = c.decode(.maxRestartAttempts, or: maxRestartAttempts)
        updateRepo = c.decode(.updateRepo, or: updateRepo)
        // The old default pointed at upstream Qv2ray, which can never report an update for this app.
        if updateRepo == "Qv2ray/Qv2ray" { updateRepo = "" }
    }
}
