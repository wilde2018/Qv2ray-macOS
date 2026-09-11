import SwiftUI

/// Connection editor sheet: System Settings-style grouped form, plus a JSON tab.
struct ConnectionEditorView: View {
    let request: AppModel.EditorRequest

    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ConnectionProfile
    @State private var groupID: UUID
    @State private var tab: Tab = .form
    /// What the JSON tab shows, and what it showed before the user touched it.
    @State private var jsonText = ""
    @State private var jsonBaseline = ""
    @State private var errorText: String?

    enum Tab: Hashable { case form, json }

    init(request: AppModel.EditorRequest) {
        self.request = request
        _profile = State(initialValue: request.profile)
        _groupID = State(initialValue: request.groupID)
    }

    private var hasOverride: Bool {
        !profile.outboundOverrideJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if profile.proto == .custom {
                    customEditor
                } else if tab == .form {
                    form
                } else {
                    jsonEditor
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 620, height: 680)
        .onChange(of: tab) { old, new in
            if new == .json { loadJSON() }
            if old == .json { commitJSONIfEdited() }
        }
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 10) {
            ProtocolBadge(proto: profile.proto)
            Text(request.isNew ? L10n.tr("editor.newTitle") : L10n.tr("editor.editTitle"))
                .font(.title3.weight(.semibold))
            Spacer()
            if profile.proto != .custom {
                Picker("", selection: $tab) {
                    Text(L10n.tr("editor.formTab")).tag(Tab.form)
                    Text(L10n.tr("editor.jsonTab")).tag(Tab.json)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(2)
            }
            Spacer()
            Button(L10n.tr("common.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.tr("common.save")) { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
        }
        .padding(16)
    }

    private var isValid: Bool {
        switch profile.proto {
        case .custom: return true
        case .vmess, .vless:
            return !profile.address.isEmpty && (1...65535).contains(profile.port) && !profile.uuid.isEmpty
        case .shadowsocks, .trojan:
            return !profile.address.isEmpty && (1...65535).contains(profile.port) && !profile.password.isEmpty
        }
    }

    // MARK: form

    private var form: some View {
        Form {
            if hasOverride {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "curlybraces.square.fill").foregroundStyle(.orange).font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("editor.overrideActive")).font(.callout.weight(.medium))
                            Text(L10n.tr("editor.overrideActiveBody")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("editor.removeOverride")) { profile.outboundOverrideJSON = "" }
                            .controlSize(.small)
                    }
                }
            }

            Section(L10n.tr("editor.general")) {
                TextField(L10n.tr("editor.name"), text: $profile.name, prompt: Text(L10n.tr("editor.namePrompt")))
                Picker(L10n.tr("editor.protocol"), selection: $profile.proto) {
                    ForEach([ProfileProto.vmess, .vless, .shadowsocks, .trojan]) { Text($0.displayName).tag($0) }
                }
                Picker(L10n.tr("editor.group"), selection: $groupID) {
                    ForEach(store.data.groups) { Text($0.displayName).tag($0.id) }
                }
            }

            Section(L10n.tr("editor.server")) {
                TextField(L10n.tr("editor.address"), text: $profile.address, prompt: Text("server.example.com"))
                TextField(L10n.tr("editor.port"), value: $profile.port, format: .number.grouping(.never), prompt: Text("443"))
                credentials
            }

            Section(L10n.tr("editor.transport")) {
                Picker(L10n.tr("editor.network"), selection: $profile.stream.network) {
                    ForEach(TransportNetwork.allCases) { Text($0.displayName).tag($0) }
                }
                transportFields
            }

            Section(L10n.tr("editor.tls")) {
                Picker(L10n.tr("editor.securityLayer"), selection: $profile.stream.security) {
                    ForEach(TlsSecurity.allCases) { Text($0.displayName).tag($0) }
                }
                securityFields
            }

            Section(L10n.tr("editor.mux")) {
                Toggle(L10n.tr("editor.muxEnabled"), isOn: $profile.mux.enabled)
                if profile.mux.enabled {
                    Stepper(value: $profile.mux.concurrency, in: -1...1024) {
                        LabeledContent(L10n.tr("editor.muxConcurrency"), value: String(profile.mux.concurrency))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var credentials: some View {
        switch profile.proto {
        case .vmess:
            TextField(L10n.tr("editor.uuid"), text: $profile.uuid, prompt: Text("00000000-0000-0000-0000-000000000000"))
                .font(.body.monospaced())
            Stepper(value: $profile.alterId, in: 0...65535) {
                LabeledContent(L10n.tr("editor.alterId"), value: String(profile.alterId))
            }
            Picker(L10n.tr("editor.security"), selection: $profile.security) {
                ForEach(options(["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"], current: profile.security), id: \.self) { Text($0) }
            }
        case .vless:
            TextField(L10n.tr("editor.uuid"), text: $profile.uuid, prompt: Text("00000000-0000-0000-0000-000000000000"))
                .font(.body.monospaced())
            Picker(L10n.tr("editor.flow"), selection: $profile.flow) {
                ForEach(options(["", "xtls-rprx-vision"], current: profile.flow), id: \.self) { Text($0.isEmpty ? L10n.tr("common.none") : $0) }
            }
        case .shadowsocks:
            Picker(L10n.tr("editor.method"), selection: $profile.method) {
                ForEach(options(["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
                                 "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305", "none"],
                                current: profile.method), id: \.self) { Text($0) }
            }
            SecureField(L10n.tr("editor.password"), text: $profile.password)
        case .trojan:
            SecureField(L10n.tr("editor.password"), text: $profile.password)
        case .custom:
            EmptyView()
        }
    }

    @ViewBuilder
    private var transportFields: some View {
        switch profile.stream.network {
        case .tcp:
            Picker(L10n.tr("editor.headerType"), selection: $profile.stream.tcpHeaderType) {
                Text("none").tag("none")
                Text("http").tag("http")
            }
            if profile.stream.tcpHeaderType == "http" {
                TextField(L10n.tr("editor.host"), text: $profile.stream.tcpRequestHost, prompt: Text("host1, host2"))
                TextField(L10n.tr("editor.path"), text: $profile.stream.tcpPath, prompt: Text("/"))
            }
        case .ws:
            TextField(L10n.tr("editor.path"), text: $profile.stream.wsPath, prompt: Text("/"))
            TextField(L10n.tr("editor.host"), text: $profile.stream.wsHost)
        case .http:
            TextField(L10n.tr("editor.host"), text: $profile.stream.h2Host, prompt: Text("host1, host2"))
            TextField(L10n.tr("editor.path"), text: $profile.stream.h2Path, prompt: Text("/"))
        case .quic:
            Picker(L10n.tr("editor.security"), selection: $profile.stream.quicSecurity) {
                ForEach(options(["none", "aes-128-gcm", "chacha20-poly1305"], current: profile.stream.quicSecurity), id: \.self) { Text($0) }
            }
            if profile.stream.quicSecurity != "none" {
                SecureField(L10n.tr("editor.key"), text: $profile.stream.quicKey)
            }
            headerTypePicker($profile.stream.quicHeaderType)
        case .kcp:
            headerTypePicker($profile.stream.kcpHeaderType)
            TextField(L10n.tr("editor.seed"), text: $profile.stream.kcpSeed)
        case .grpc:
            TextField(L10n.tr("editor.serviceName"), text: $profile.stream.grpcServiceName, prompt: Text("GunService"))
            Toggle(L10n.tr("editor.multiMode"), isOn: $profile.stream.grpcMultiMode)
        case .httpupgrade:
            TextField(L10n.tr("editor.path"), text: $profile.stream.httpupgradePath, prompt: Text("/"))
            TextField(L10n.tr("editor.host"), text: $profile.stream.httpupgradeHost)
        case .splithttp:
            TextField(L10n.tr("editor.path"), text: $profile.stream.xhttpPath, prompt: Text("/"))
            TextField(L10n.tr("editor.host"), text: $profile.stream.xhttpHost)
            Picker(L10n.tr("editor.mode"), selection: $profile.stream.xhttpMode) {
                ForEach(options(["auto", "packet-up", "stream-up", "stream-one"], current: profile.stream.xhttpMode), id: \.self) { Text($0) }
            }
        }
    }

    private func headerTypePicker(_ binding: Binding<String>) -> some View {
        Picker(L10n.tr("editor.headerType"), selection: binding) {
            ForEach(options(["none", "srtp", "utp", "wechat-video", "dtls", "wireguard"], current: binding.wrappedValue), id: \.self) { Text($0) }
        }
    }

    @ViewBuilder
    private var securityFields: some View {
        if profile.stream.security != .none {
            TextField(L10n.tr("editor.sni"), text: $profile.stream.sni, prompt: Text(profile.address.isEmpty ? "example.com" : profile.address))
            Picker(L10n.tr("editor.fingerprint"), selection: $profile.stream.fingerprint) {
                ForEach(options(["", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"],
                                current: profile.stream.fingerprint), id: \.self) {
                    Text($0.isEmpty ? L10n.tr("common.default") : $0)
                }
            }
            if profile.stream.security == .reality {
                TextField(L10n.tr("editor.pbk"), text: $profile.stream.realityPublicKey).font(.body.monospaced())
                TextField(L10n.tr("editor.sid"), text: $profile.stream.realityShortId).font(.body.monospaced())
                TextField(L10n.tr("editor.spx"), text: $profile.stream.realitySpiderX, prompt: Text("/"))
            } else {
                TextField(L10n.tr("editor.alpn"), text: $profile.stream.alpn, prompt: Text("h2, http/1.1"))
                Toggle(L10n.tr("editor.allowInsecure"), isOn: $profile.stream.allowInsecure)
            }
        }
    }

    /// Picker options that always include the current value (imported links can carry anything).
    private func options(_ base: [String], current: String) -> [String] {
        base.contains(current) ? base : base + [current]
    }

    // MARK: JSON

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("editor.jsonHint")).font(.caption).foregroundStyle(.secondary)
            JSONEditorView(text: $jsonText)
            if hasOverride {
                HStack {
                    Spacer()
                    Button(L10n.tr("editor.removeOverride")) {
                        profile.outboundOverrideJSON = ""
                        loadJSON()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var customEditor: some View {
        Form {
            Section(L10n.tr("editor.general")) {
                TextField(L10n.tr("editor.name"), text: $profile.name)
                Picker(L10n.tr("editor.group"), selection: $groupID) {
                    ForEach(store.data.groups) { Text($0.displayName).tag($0.id) }
                }
            }
            Section {
                JSONEditorView(text: $profile.customConfigJSON)
                    .frame(minHeight: 380)
            } header: {
                Text(L10n.tr("editor.customJSON"))
            } footer: {
                Text(L10n.tr("editor.customHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func loadJSON() {
        let outbound = ConfigGenerator.overrideOutbound(profile) ?? ConfigGenerator.generatedOutbound(for: profile)
        jsonText = (try? jsonData(from: outbound)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        jsonBaseline = jsonText
    }

    /// JSON edits become the outbound override — but only when the text was actually
    /// changed, so merely viewing the tab never freezes the form.
    @discardableResult
    private func commitJSONIfEdited() -> Bool {
        guard jsonText != jsonBaseline else { return true }
        guard let d = jsonText.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) != nil else {
            errorText = L10n.tr("common.invalidJSON")
            return false
        }
        profile.outboundOverrideJSON = jsonText
        jsonBaseline = jsonText
        errorText = nil
        return true
    }

    // MARK: save

    private func save() {
        if tab == .json && profile.proto != .custom {
            guard commitJSONIfEdited() else { return }
        }
        if profile.proto == .custom {
            guard let d = profile.customConfigJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) != nil else {
                errorText = L10n.tr("common.invalidJSON")
                return
            }
        }
        if store.profile(profile.id) == nil {
            store.addProfile(profile, to: groupID)
        } else {
            store.updateProfile(profile)
            if store.groupOf(profile: profile.id) != groupID { store.moveProfiles([profile.id], to: groupID) }
        }
        dismiss()
    }
}

// MARK: - Group editor

struct GroupEditorView: View {
    let request: AppModel.GroupEditorRequest

    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var subs: SubscriptionService
    @Environment(\.dismiss) private var dismiss
    @State private var group: ProfileGroup

    init(request: AppModel.GroupEditorRequest) {
        self.request = request
        _group = State(initialValue: request.group)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(request.isNew ? (group.isSubscription ? L10n.tr("group.newSubscription") : L10n.tr("group.new")) : L10n.tr("group.edit"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                Section {
                    if group.isDefault {
                        LabeledContent(L10n.tr("group.name"), value: group.displayName)
                    } else {
                        TextField(L10n.tr("group.name"), text: $group.name, prompt: Text(L10n.tr("group.namePrompt")))
                    }
                    Toggle(L10n.tr("group.subscription"), isOn: $group.isSubscription)
                }
                if group.isSubscription {
                    Section(L10n.tr("group.subscription")) {
                        TextField(L10n.tr("group.subURL"), text: $group.subscriptionURL, prompt: Text("https://…"))
                        Stepper(value: $group.updateIntervalHours, in: 0...720) {
                            LabeledContent(L10n.tr("group.subInterval"),
                                           value: group.updateIntervalHours == 0 ? L10n.tr("group.manual") : "\(group.updateIntervalHours) h")
                        }
                        Toggle(L10n.tr("group.subAuto"), isOn: $group.autoUpdate)
                        if let d = group.lastUpdated {
                            LabeledContent(L10n.tr("group.lastUpdatedLabel")) { Text(d, style: .relative) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L10n.tr("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? L10n.tr("common.create") : L10n.tr("common.save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(group.isSubscription && URL(string: group.subscriptionURL)?.scheme == nil)
            }
            .padding(16)
        }
        .frame(width: 480, height: group.isSubscription ? 430 : 260)
    }

    private func save() {
        if group.name.trimmingCharacters(in: .whitespaces).isEmpty && !group.isDefault {
            group.name = group.isSubscription
                ? (URL(string: group.subscriptionURL)?.host ?? L10n.tr("group.subscription"))
                : String(format: L10n.tr("group.defaultName"), store.data.groups.count)
        }
        if request.isNew {
            store.addGroup(group)
            model.sidebarSelection = .group(group.id)
        } else {
            store.updateGroup(group)
        }
        let shouldFetch = group.isSubscription && !group.subscriptionURL.isEmpty
            && (request.isNew || group.subscriptionURL != request.group.subscriptionURL)
        dismiss()
        if shouldFetch {
            let id = group.id
            Task {
                let r = await subs.update(groupID: id)
                if !r.message.isEmpty { model.showBanner(r.message, error: !r.ok) }
            }
        }
    }
}
