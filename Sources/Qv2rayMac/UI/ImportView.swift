import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Import entry points shared by the sheet, drag & drop and the toolbar.
@MainActor
enum ImportActions {
    static func handleDrop(_ providers: [NSItemProvider], into group: UUID) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in importFile(url, into: group) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in importImage(image, into: group) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String else { return }
                    Task { @MainActor in AppModel.shared.importText(text, into: group) }
                }
            }
        }
    }

    /// JSON configs, QR images or text files full of links.
    @discardableResult
    static func importFile(_ url: URL, into group: UUID) -> String {
        let model = AppModel.shared
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url) else {
                model.showBanner(L10n.tr("import.cannotDecodeQR"), error: true)
                return L10n.tr("import.cannotDecodeQR")
            }
            return importImage(image, into: group)
        }
        guard let data = try? Data(contentsOf: url) else {
            model.showBanner(L10n.tr("import.unreadable"), error: true)
            return L10n.tr("import.unreadable")
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return importConfig(root, name: url.deletingPathExtension().lastPathComponent, into: group)
        }
        let result = model.importText(String(decoding: data, as: UTF8.self), into: group)
        return summary(result)
    }

    static func importConfig(_ root: [String: Any], name: String, into group: UUID) -> String {
        let model = AppModel.shared
        // SIP008 subscription document
        if root["servers"] != nil && root["outbounds"] == nil,
           let text = try? jsonData(from: root, pretty: false) {
            return summary(model.importText(String(decoding: text, as: UTF8.self), into: group))
        }
        var p: ConnectionProfile
        if let simple = ProfileStore.simpleOutbound(of: root).flatMap({ ConnectionProfile(outbound: $0) }) {
            p = simple
        } else {
            p = ConnectionProfile()
            p.proto = .custom
            p.customConfigJSON = (try? jsonData(from: root)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        p.name = name
        ProfileStore.shared.addProfile(p, to: group)
        let message = String(format: L10n.tr("import.imported"), 1)
        model.showBanner(message, error: false)
        return message
    }

    @discardableResult
    static func importImage(_ image: NSImage, into group: UUID) -> String {
        guard let content = QRService.decode(image: image) else {
            AppModel.shared.showBanner(L10n.tr("import.cannotDecodeQR"), error: true)
            return L10n.tr("import.cannotDecodeQR")
        }
        return summary(AppModel.shared.importText(content, into: group))
    }

    /// Hide the app, let the user drag over a QR code anywhere on screen, then import it.
    @discardableResult
    static func scanScreen(into group: UUID) async -> String {
        NSApp.hide(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let image = await QRService.captureFromScreen()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let image else { return "" } // cancelled
        return importImage(image, into: group)
    }

    static func summary(_ r: ShareLinks.ParseResult) -> String {
        if r.profiles.isEmpty { return r.skipped.first ?? L10n.tr("import.nothingFound") }
        var s = String(format: L10n.tr("import.imported"), r.profiles.count)
        if !r.skipped.isEmpty { s += " · " + String(format: L10n.tr("import.skippedCount"), r.skipped.count) }
        return s
    }
}

/// Import sheet: links, subscription, QR, files and Qv2ray migration.
struct ImportView: View {
    let targetGroup: UUID

    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var subs: SubscriptionService
    @Environment(\.dismiss) private var dismiss

    @State private var group: UUID
    @State private var mode: Mode = .links
    @State private var linksText = ""
    @State private var subURL = ""
    @State private var subName = ""
    @State private var status: (text: String, isError: Bool)?
    @State private var skipped: [String] = []
    @State private var working = false
    @State private var dropTargeted = false

    enum Mode: String, CaseIterable, Identifiable {
        case links, subscription, qr, file, qv2ray
        var id: String { rawValue }
        var title: String { L10n.tr("import.mode.\(rawValue)") }
        var symbol: String {
            switch self {
            case .links: return "link"
            case .subscription: return "antenna.radiowaves.left.and.right"
            case .qr: return "qrcode.viewfinder"
            case .file: return "doc"
            case .qv2ray: return "arrow.triangle.2.circlepath"
            }
        }
    }

    init(targetGroup: UUID) {
        self.targetGroup = targetGroup
        _group = State(initialValue: targetGroup)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("import.title")).font(.title3.weight(.semibold))
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Group {
                switch mode {
                case .links: linksPane
                case .subscription: subscriptionPane
                case .qr: qrPane
                case .file: filePane
                case .qv2ray: qv2rayPane
                }
            }
            .padding(20)
            .frame(maxHeight: .infinity)

            statusArea
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        .onChange(of: mode) { _, _ in status = nil; skipped = [] }
        .onDrop(of: [.fileURL, .plainText, .image], isTargeted: $dropTargeted) { providers in
            ImportActions.handleDrop(providers, into: group)
            dismiss()
            return true
        }
    }

    // MARK: panes

    private var linksPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("import.linksHint")).font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $linksText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if linksText.isEmpty {
                    Text("vmess://…\nvless://…\ntrojan://…\nss://…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            Button {
                linksText = NSPasteboard.general.string(forType: .string) ?? linksText
            } label: {
                Label(L10n.tr("import.pasteClipboard"), systemImage: "doc.on.clipboard")
            }
            .controlSize(.small)
        }
    }

    private var subscriptionPane: some View {
        Form {
            Section {
                TextField(L10n.tr("group.subURL"), text: $subURL, prompt: Text("https://example.com/sub?token=…"))
                TextField(L10n.tr("group.name"), text: $subName, prompt: Text(URL(string: subURL)?.host ?? L10n.tr("group.namePrompt")))
            } footer: {
                Text(L10n.tr("import.subHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(-20)
    }

    private var qrPane: some View {
        HStack(spacing: 14) {
            ImportTile(symbol: "viewfinder", title: L10n.tr("import.qrScreen"), subtitle: L10n.tr("import.qrScreenHint")) {
                Task {
                    let msg = await ImportActions.scanScreen(into: group)
                    if !msg.isEmpty { finish(msg) }
                }
            }
            ImportTile(symbol: "photo", title: L10n.tr("import.qrFile"), subtitle: L10n.tr("import.qrFileHint")) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                finish(ImportActions.importFile(url, into: group))
            }
            ImportTile(symbol: "doc.on.clipboard", title: L10n.tr("import.qrClipboard"), subtitle: L10n.tr("import.qrClipboardHint")) {
                guard let image = NSImage(pasteboard: .general) else {
                    status = (L10n.tr("import.cannotDecodeQR"), true)
                    return
                }
                finish(ImportActions.importImage(image, into: group))
            }
        }
    }

    private var filePane: some View {
        ImportTile(symbol: dropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down",
                   title: L10n.tr("import.fileDrop"), subtitle: L10n.tr("import.fileHint")) {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json, .plainText, .image, .data]
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return }
            let messages = panel.urls.map { ImportActions.importFile($0, into: group) }
            finish(messages.joined(separator: "\n"))
        }
    }

    private var qv2rayPane: some View {
        ImportTile(symbol: "arrow.triangle.2.circlepath", title: L10n.tr("import.qv2ray"), subtitle: L10n.tr("import.qv2rayHint")) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = L10n.tr("import.qv2rayHint")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let report = store.importFromQv2rayConfig(folder: url)
            skipped = report.errors
            let text = String(format: L10n.tr("import.migrated"), report.connections, report.groups)
            status = (text, report.connections == 0)
        }
    }

    // MARK: status & footer

    @ViewBuilder
    private var statusArea: some View {
        if let status {
            VStack(alignment: .leading, spacing: 4) {
                Label(status.text, systemImage: status.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(status.isError ? .red : .green)
                    .font(.callout)
                if !skipped.isEmpty {
                    DisclosureGroup(String(format: L10n.tr("import.skippedCount"), skipped.count)) {
                        ScrollView {
                            Text(skipped.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 70)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private var footer: some View {
        HStack {
            if mode != .subscription && mode != .qv2ray {
                Picker(L10n.tr("group.importTo"), selection: $group) {
                    ForEach(store.data.groups) { Text($0.displayName).tag($0.id) }
                }
                .fixedSize()
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button(L10n.tr("common.close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if mode == .links || mode == .subscription {
                Button(L10n.tr("import.importBtn")) { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || (mode == .links ? linksText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                          : URL(string: subURL)?.scheme == nil))
            }
        }
        .padding(16)
    }

    private func finish(_ message: String) {
        status = (message, message == L10n.tr("import.cannotDecodeQR") || message == L10n.tr("import.nothingFound"))
    }

    private func runImport() {
        switch mode {
        case .links:
            let r = ShareLinks.parseDetailed(linksText)
            store.addProfiles(r.profiles, to: group)
            skipped = r.skipped
            status = (ImportActions.summary(r), r.profiles.isEmpty)
            if !r.profiles.isEmpty { linksText = "" }
        case .subscription:
            var g = ProfileGroup(name: subName.isEmpty ? (URL(string: subURL)?.host ?? L10n.tr("group.subscription")) : subName)
            g.isSubscription = true
            g.subscriptionURL = subURL.trimmingCharacters(in: .whitespaces)
            g.updateIntervalHours = store.preferences.subUpdateIntervalHours
            store.addGroup(g)
            working = true
            Task {
                let r = await subs.update(groupID: g.id)
                working = false
                status = (r.message, !r.ok)
                if r.ok {
                    model.sidebarSelection = .group(g.id)
                    model.showBanner(r.message, error: false)
                    dismiss()
                }
            }
        case .qr, .file, .qv2ray:
            break
        }
    }
}

struct ImportTile: View {
    var symbol: String
    var title: String
    var subtitle: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
