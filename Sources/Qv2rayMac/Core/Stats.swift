import Foundation
import Network

// MARK: - Minimal protobuf codec

enum MiniProto {
    static func varint(_ v: UInt64) -> Data {
        var value = v
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
    }

    static func tag(field: Int, wire: Int) -> Data {
        varint(UInt64((field << 3) | wire))
    }

    static func stringField(_ field: Int, _ value: String) -> Data {
        let payload = Data(value.utf8)
        return tag(field: field, wire: 2) + varint(UInt64(payload.count)) + payload
    }

    static func boolField(_ field: Int, _ value: Bool) -> Data {
        tag(field: field, wire: 0) + Data([value ? 1 : 0])
    }

    static func messageField(_ field: Int, _ payload: Data) -> Data {
        tag(field: field, wire: 2) + varint(UInt64(payload.count)) + payload
    }

    /// Generic message walker.
    static func walk(_ data: Data, handler: (Int, Int, Data, inout [UInt64]) -> Void) {
        var i = data.startIndex
        var scratch: [UInt64] = []
        while i < data.endIndex {
            guard let (key, next) = readVarint(data, from: i) else { return }
            i = next
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            switch wire {
            case 0:
                guard let (v, n) = readVarint(data, from: i) else { return }
                scratch = [v]
                handler(field, wire, Data(), &scratch)
                i = n
            case 1:
                guard data.distance(from: i, to: data.endIndex) >= 8 else { return }
                let chunk = data.subdata(in: i..<data.index(i, offsetBy: 8))
                scratch = [UInt64(chunk.reduce(0) { ($0 << 8) | UInt64($1) })]
                handler(field, wire, Data(), &scratch)
                i = data.index(i, offsetBy: 8)
            case 2:
                guard let (len, n) = readVarint(data, from: i) else { return }
                let end = data.index(n, offsetBy: Int(len), limitedBy: data.endIndex) ?? data.endIndex
                handler(field, wire, data.subdata(in: n..<end), &scratch)
                i = end
            case 5:
                guard data.distance(from: i, to: data.endIndex) >= 4 else { return }
                let chunk = data.subdata(in: i..<data.index(i, offsetBy: 4))
                scratch = [UInt64(chunk.reduce(0) { ($0 << 8) | UInt64($1) })]
                handler(field, wire, Data(), &scratch)
                i = data.index(i, offsetBy: 4)
            default:
                return // unsupported wire type
            }
        }
    }

    private static func readVarint(_ data: Data, from index: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = index
        while i < data.endIndex {
            let byte = data[i]
            result |= UInt64(byte & 0x7f) << shift
            i = data.index(after: i)
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

// MARK: - HTTP/2 over plaintext TCP + gRPC unary call

enum H2Error: Error {
    case timeout
    case connectionFailed(String)
    case reset(Int)
    case goAway
    case badFrame
    case emptyResponse
}

/// A minimal one-shot h2c (HTTP/2 cleartext) client used to talk to the
/// v2ray/Xray StatsService over localhost. Opens a fresh connection per call —
/// fine for a 1 Hz local poll and robust across core restarts.
/// All mutable state is touched only on `queue` (or under `lock`).
final class H2GRPCClient: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "qv.h2grpc")
    private let lock = NSLock()

    private var buffer = Data()
    private var collected = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var sentRequest = false
    private let path: String
    private let message: Data
    private let timeout: TimeInterval

    init(port: UInt16, path: String, message: Data, timeout: TimeInterval = 2.5) {
        self.path = path
        self.message = message
        self.timeout = timeout
        conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func call() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            continuation = c
            lock.unlock()
            conn.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(H2Error.timeout))
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendRequest()
        case .failed(let error):
            finish(.failure(H2Error.connectionFailed(error.localizedDescription)))
        case .cancelled:
            finish(.failure(H2Error.connectionFailed("cancelled")))
        default:
            break
        }
    }

    private func sendRequest() {
        guard !sentRequest else { return }
        sentRequest = true

        var out = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        // SETTINGS with large initial window so the tiny stats response never blocks on flow control
        var settingsPayload = Data()
        settingsPayload.append(uint16be: 0x4) // SETTINGS_INITIAL_WINDOW_SIZE
        settingsPayload.append(uint32be: 1 << 20)
        out += Self.frame(type: 4, flags: 0, stream: 0, payload: settingsPayload)
        // Bump the connection-level window too
        out += Self.frame(type: 8, flags: 0, stream: 0, payload: Data(uint32be: 1 << 24))

        // HEADERS (HPACK: indexed static + literal-no-index, no huffman — always valid)
        var block = Data()
        block.append(0x83) // :method POST
        block.append(0x86) // :scheme http
        block += Self.literal(name: ":path", value: path)
        block += Self.literal(name: ":authority", value: "127.0.0.1")
        block += Self.literal(name: "content-type", value: "application/grpc")
        block += Self.literal(name: "te", value: "trailers")
        block += Self.literal(name: "grpc-accept-encoding", value: "identity")
        out += Self.frame(type: 1, flags: 0x4 /* END_HEADERS */, stream: 1, payload: block)

        // DATA: gRPC length-prefixed message
        var msg = Data([0])
        msg.append(uint32be: UInt32(message.count))
        msg += message
        out += Self.frame(type: 0, flags: 0x1 /* END_STREAM */, stream: 1, payload: msg)

        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.receiveLoop()
        })
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer += data }
            if let error {
                self.finish(.failure(H2Error.connectionFailed(error.localizedDescription)))
                return
            }
            self.processFrames()
            if isComplete {
                self.finish(.failure(H2Error.connectionFailed("eof")))
                return
            }
            self.receiveLoop()
        }
    }

    private func processFrames() {
        while buffer.count >= 9 {
            let bytes = [UInt8](buffer.prefix(9))
            let length = (Int(bytes[0]) << 16) | (Int(bytes[1]) << 8) | Int(bytes[2])
            let type = bytes[3]
            let flags = bytes[4]
            let stream = (UInt32(bytes[5] & 0x7f) << 24) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 8) | UInt32(bytes[8])
            guard buffer.count >= 9 + length else { return }
            let payload = buffer.subdata(in: 9..<(9 + length))
            buffer.removeSubrange(0..<(9 + length))

            switch type {
            case 4: // SETTINGS
                if flags & 0x1 == 0 {
                    conn.send(content: Self.frame(type: 4, flags: 0x1, stream: 0, payload: Data()), completion: .contentProcessed { _ in })
                }
            case 6: // PING → ACK
                if flags & 0x1 == 0 {
                    conn.send(content: Self.frame(type: 6, flags: 0x1, stream: 0, payload: payload), completion: .contentProcessed { _ in })
                }
            case 0: // DATA
                if stream == 1 {
                    var p = payload
                    if flags & 0x8 != 0, let pad = p.first { // PADDED
                        p = p.dropFirst().dropLast(Int(pad))
                    }
                    collected += p
                    if flags & 0x1 != 0 { finish(.success(collected)) }
                }
            case 1: // HEADERS (response headers / trailers) — HPACK not decoded, we only need DATA
                if stream == 1, flags & 0x1 != 0 {
                    // END_STREAM on HEADERS = trailers. Without DATA it's a trailers-only
                    // (error) response — fail now instead of waiting for the timeout.
                    finish(collected.isEmpty ? .failure(H2Error.emptyResponse) : .success(collected))
                }
            case 3: // RST_STREAM
                if stream == 1 {
                    let code = payload.count >= 4 ? UInt32(payload.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }) : 0
                    finish(.failure(H2Error.reset(Int(code))))
                }
            case 7: // GOAWAY
                finish(.failure(H2Error.goAway))
            default:
                break
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let already = finished
        finished = true
        lock.unlock()
        guard !already, let cont else { return }
        conn.cancel()
        switch result {
        case .success(let d): cont.resume(returning: d)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    // MARK: frame helpers

    static func frame(type: UInt8, flags: UInt8, stream: UInt32, payload: Data) -> Data {
        var f = Data()
        f.append(UInt8((payload.count >> 16) & 0xff))
        f.append(UInt8((payload.count >> 8) & 0xff))
        f.append(UInt8(payload.count & 0xff))
        f.append(type)
        f.append(flags)
        f.append(UInt8((stream >> 24) & 0x7f))
        f.append(UInt8((stream >> 16) & 0xff))
        f.append(UInt8((stream >> 8) & 0xff))
        f.append(UInt8(stream & 0xff))
        f += payload
        return f
    }

    /// Literal header field without indexing, new name, no huffman.
    static func literal(name: String, value: String) -> Data {
        var d = Data([0x00])
        d += hpackLen(Data(name.utf8).count)
        d += Data(name.utf8)
        d += hpackLen(Data(value.utf8).count)
        d += Data(value.utf8)
        return d
    }

    private static func hpackLen(_ n: Int) -> Data {
        var d = Data()
        var v = n
        if v < 127 {
            d.append(UInt8(v))
        } else {
            d.append(127)
            v -= 127
            while v >= 128 {
                d.append(UInt8(v & 0x7f | 0x80))
                v >>= 7
            }
            d.append(UInt8(v))
        }
        return d
    }
}

private extension Data {
    mutating func append(uint16be v: UInt16) {
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
    mutating func append(uint32be v: UInt32) {
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
    init(uint32be v: UInt32) {
        self.init([
            UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
            UInt8((v >> 8) & 0xff), UInt8(v & 0xff),
        ])
    }
}

// MARK: - Stats service

struct StatsSnapshot {
    var values: [String: Int64] = [:]

    /// Outbound tags that are never "the proxy" (custom configs may use any other tag).
    static let nonProxyTags: Set<String> = ["direct", "block", "api", "dns-out", "blackhole", "freedom"]

    private func sum(_ direction: String, where include: (String) -> Bool) -> Int64 {
        values.reduce(0) { acc, kv in
            let parts = kv.key.components(separatedBy: ">>>")
            guard parts.count == 4, parts[0] == "outbound", parts[3] == direction, include(parts[1]) else { return acc }
            return acc + kv.value
        }
    }

    var proxyUp: Int64 { sum("uplink") { !Self.nonProxyTags.contains($0) } }
    var proxyDown: Int64 { sum("downlink") { !Self.nonProxyTags.contains($0) } }
    var directUp: Int64 { sum("uplink") { $0 == "direct" } }
    var directDown: Int64 { sum("downlink") { $0 == "direct" } }
    var totalUp: Int64 { proxyUp + directUp }
    var totalDown: Int64 { proxyDown + directDown }
}

enum StatsService {
    /// QueryStats(pattern="", reset=true) — one RPC returning every counter.
    static func query(port: UInt16, coreType: CoreType) async throws -> StatsSnapshot {
        var req = MiniProto.stringField(1, "")
        req += MiniProto.boolField(2, true)

        let client = H2GRPCClient(port: port, path: coreType.statsServicePath + "QueryStats", message: req)
        let raw = try await client.call()
        return parseResponse(raw)
    }

    /// Split gRPC length-prefixed messages, then decode QueryStatsResponse.
    static func parseResponse(_ raw: Data) -> StatsSnapshot {
        var snap = StatsSnapshot()
        var rest = raw
        while rest.count >= 5 {
            let len = Int(rest[rest.startIndex + 1]) << 24 | Int(rest[rest.startIndex + 2]) << 16
                | Int(rest[rest.startIndex + 3]) << 8 | Int(rest[rest.startIndex + 4])
            guard rest.count >= 5 + len else { break }
            let msg = rest.subdata(in: rest.startIndex + 5..<rest.startIndex + 5 + len)
            rest = rest.subdata(in: rest.startIndex + 5 + len..<rest.endIndex)

            MiniProto.walk(msg) { field, wire, payload, _ in
                guard field == 1, wire == 2 else { return }
                var name = ""
                var value: Int64 = 0
                MiniProto.walk(payload) { f, w, p, s in
                    if f == 1, w == 2 { name = String(decoding: p, as: UTF8.self) }
                    if f == 2, w == 0, let v = s.first { value = Int64(bitPattern: v) }
                }
                if !name.isEmpty { snap.values[name] = value }
            }
        }
        return snap
    }
}

// MARK: - Speed sampler

@MainActor
final class SpeedSampler: ObservableObject {
    static let shared = SpeedSampler()

    struct Sample: Identifiable, Equatable {
        let id: Int
        let date: Date
        let up: Double
        let down: Double
    }

    @Published private(set) var currentUp: Double = 0      // bytes/s through the proxy
    @Published private(set) var currentDown: Double = 0
    @Published private(set) var directUp: Double = 0
    @Published private(set) var directDown: Double = 0
    @Published private(set) var totalUp: Int64 = 0         // session totals through the proxy
    @Published private(set) var totalDown: Int64 = 0
    @Published private(set) var history: [Sample] = []
    @Published private(set) var apiHealthy = false

    static let historyLength = 120

    private var pollTask: Task<Void, Never>? = nil
    private var lastSampleAt: Date? = nil
    private var nextID = 0

    func start(port: Int, coreType: CoreType) {
        stop()
        totalUp = 0
        totalDown = 0
        history = []
        lastSampleAt = Date()
        let interval = max(200, ProfileStore.shared.preferences.statsIntervalMS)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let snap = try? await StatsService.query(port: UInt16(clamping: port), coreType: coreType) {
                    self?.apply(snap: snap)
                } else {
                    self?.apiHealthy = false
                }
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        currentUp = 0
        currentDown = 0
        directUp = 0
        directDown = 0
        apiHealthy = false
    }

    private func apply(snap: StatsSnapshot) {
        apiHealthy = true
        // Counters are reset on every successful query, so divide by the real time since
        // the previous success (poll interval + RPC time), not the nominal interval.
        let now = Date()
        let dt = max(0.05, now.timeIntervalSince(lastSampleAt ?? now))
        lastSampleAt = now
        currentUp = Double(snap.proxyUp) / dt
        currentDown = Double(snap.proxyDown) / dt
        directUp = Double(snap.directUp) / dt
        directDown = Double(snap.directDown) / dt
        totalUp += snap.proxyUp
        totalDown += snap.proxyDown
        append(up: currentUp, down: currentDown, at: now)
    }

    private func append(up: Double, down: Double, at date: Date) {
        history.append(Sample(id: nextID, date: date, up: up, down: down))
        nextID += 1
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    /// Synthetic traffic for `--snapshot` screenshots.
    func loadDemo() {
        let now = Date()
        history = []
        for i in 0..<Self.historyLength {
            let t = Double(i)
            let down = max(0, 2_600_000 + 1_900_000 * sin(t / 9) + 900_000 * sin(t / 2.7) + Double((i * 7919) % 400_000))
            let up = max(0, 240_000 + 160_000 * sin(t / 6 + 1) + Double((i * 104_729) % 60_000))
            append(up: up, down: down, at: now.addingTimeInterval(Double(i - Self.historyLength)))
        }
        currentDown = history.last?.down ?? 0
        currentUp = history.last?.up ?? 0
        totalDown = 1_842_000_000
        totalUp = 126_000_000
        apiHealthy = true
    }
}
