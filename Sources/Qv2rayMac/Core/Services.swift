import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

// MARK: - Subscription updater

@MainActor
final class SubscriptionService: ObservableObject {
    static let shared = SubscriptionService()

    @Published private(set) var updatingGroupIDs: Set<UUID> = []
    /// Last failure per group (cleared on success), shown in the sidebar / group header.
    @Published private(set) var lastErrors: [UUID: String] = [:]

    private var timer: Timer? = nil

    func startAutoUpdateTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAndAutoUpdate() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self.checkAndAutoUpdate()
        }
    }

    func checkAndAutoUpdate() {
        for group in ProfileStore.shared.data.groups
        where group.isSubscription && group.autoUpdate && !group.subscriptionURL.isEmpty && group.updateIntervalHours > 0 {
            if let last = group.lastUpdated,
               Date().timeIntervalSince(last) < TimeInterval(group.updateIntervalHours) * 3600 {
                continue
            }
            Task { await self.update(groupID: group.id) }
        }
    }

    func updateAll() async {
        let ids = ProfileStore.shared.data.groups.filter { $0.isSubscription && !$0.subscriptionURL.isEmpty }.map(\.id)
        await withTaskGroup(of: Void.self) { tg in
            for id in ids { tg.addTask { _ = await self.update(groupID: id) } }
        }
    }

    /// Fetches and applies one subscription. Returns a user-facing summary and whether it succeeded.
    @discardableResult
    func update(groupID: UUID) async -> (ok: Bool, message: String) {
        let store = ProfileStore.shared
        guard let group = store.group(groupID), group.isSubscription, !updatingGroupIDs.contains(groupID) else {
            return (false, "")
        }
        guard let url = URL(string: group.subscriptionURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            return fail(groupID, name: group.displayName, L10n.tr("sub.err.badURL"))
        }
        updatingGroupIDs.insert(groupID)
        defer { updatingGroupIDs.remove(groupID) }

        var request = URLRequest(url: url)
        request.setValue(store.preferences.subUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return fail(groupID, name: group.displayName, "HTTP \(http.statusCode)")
            }
            data = d
        } catch {
            return fail(groupID, name: group.displayName, error.localizedDescription)
        }

        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let parsed = ShareLinks.parseDetailed(text)
        guard !parsed.profiles.isEmpty else {
            return fail(groupID, name: group.displayName, parsed.skipped.first ?? L10n.tr("sub.err.empty"))
        }
        // Re-read the group: it may have been edited while the request was in flight.
        guard var current = store.group(groupID) else { return (false, "") }
        let r = store.replaceSubscriptionProfiles(group: groupID, with: parsed.profiles)
        current.lastUpdated = Date()
        store.updateGroup(current)
        lastErrors[groupID] = nil
        let message = String(format: L10n.tr("sub.updated"), current.displayName, parsed.profiles.count, r.added, r.removed)
        CoreRunner.shared.appendLog("↻ " + message)
        return (true, message)
    }

    private func fail(_ id: UUID, name: String, _ reason: String) -> (ok: Bool, message: String) {
        lastErrors[id] = reason
        let message = String(format: L10n.tr("sub.failed"), name, reason)
        CoreRunner.shared.appendLog("✗ " + message)
        return (false, message)
    }
}

// MARK: - QR code service

enum QRService {
    /// Detect & decode a QR code from an NSImage (file, clipboard or screen capture).
    static func decode(image: NSImage) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: cg)) ?? []
        let messages = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        return messages.first { ShareLinks.isShareLink($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? messages.first
    }

    /// Let the user drag out a screen region (like ⌘⇧4) and return it as an image.
    /// Uses a temp file, so the clipboard is left alone.
    static func captureFromScreen() async -> NSImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qv-qr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let launched: Bool = await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", url.path]
            p.terminationHandler = { _ in c.resume(returning: true) }
            do { try p.run() } catch { c.resume(returning: false) }
        }
        guard launched else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Generate a QR code NSImage for a string.
    static func generate(for string: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: transformed)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - Update checker

enum UpdateResult {
    case upToDate
    case available(tag: String, url: String)
    case notConfigured
    case failed(String)
}

enum UpdateChecker {
    static func check(repo: String) async -> UpdateResult {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty else { return .notConfigured }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed("invalid repo")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let htmlURL = obj["html_url"] as? String else {
                return .failed("bad response")
            }
            return isNewer(tag, than: "v\(APP_VERSION)") ? .available(tag: tag, url: htmlURL) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        func nums(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "v" }).compactMap { Int($0.prefix(while: \.isNumber)) }
        }
        let a = nums(tag), b = nums(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
