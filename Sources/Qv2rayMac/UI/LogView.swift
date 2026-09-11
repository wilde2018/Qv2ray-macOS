import SwiftUI

/// Core + app log with level filter, search, follow-tail and export.
struct LogView: View {
    @EnvironmentObject private var runner: CoreRunner
    @EnvironmentObject private var model: AppModel

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var follow = true

    enum Filter: String, CaseIterable, Identifiable {
        case all, warnings, errors
        var id: String { rawValue }
        var title: String { L10n.tr("log.filter.\(rawValue)") }
    }

    private var lines: [LogLine] {
        runner.logLines.filter { line in
            switch filter {
            case .all: break
            case .warnings: guard line.level == .warning || line.level == .error else { return false }
            case .errors: guard line.level == .error else { return false }
            }
            return search.isEmpty || line.text.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        let lines = self.lines
        Group {
            if lines.isEmpty {
                ContentUnavailableView(runner.logLines.isEmpty ? L10n.tr("log.empty") : L10n.tr("log.noMatch"),
                                       systemImage: "text.alignleft",
                                       description: Text(runner.logLines.isEmpty ? L10n.tr("log.emptyBody") : ""))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                row(line).id(line.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: runner.logLines.last?.id) { _, _ in
                        if follow, let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle(L10n.tr("sidebar.log"))
        .searchable(text: $search, placement: .toolbar, prompt: L10n.tr("log.search"))
        .toolbar {
            ToolbarItemGroup {
                Picker(L10n.tr("log.level"), selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle(isOn: $follow) {
                    Label(L10n.tr("log.follow"), systemImage: "arrow.down.to.line")
                }
                .help(L10n.tr("log.follow"))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.map { "\($0.time) \($0.text)" }.joined(separator: "\n"), forType: .string)
                    model.showBanner(L10n.tr("common.copied"), error: false)
                } label: {
                    Label(L10n.tr("common.copy"), systemImage: "doc.on.doc")
                }
                .help(L10n.tr("log.copy"))
                Button { saveLog() } label: {
                    Label(L10n.tr("log.save"), systemImage: "square.and.arrow.down")
                }
                .help(L10n.tr("log.save"))
                Button { runner.clearLog() } label: {
                    Label(L10n.tr("log.clear"), systemImage: "trash")
                }
                .help(L10n.tr("log.clear"))
            }
        }
    }

    private func row(_ line: LogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time).foregroundStyle(.tertiary)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color(line.level))
                .frame(width: 3, height: 11)
            Text(line.text)
                .foregroundStyle(line.level == .info ? Color.primary : color(line.level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 1.5)
    }

    private func color(_ level: LogLine.Level) -> Color {
        switch level {
        case .info: return .secondary.opacity(0.35)
        case .warning: return .orange
        case .error: return .red
        case .app: return .accentColor
        }
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "qv2ray-mac-core.log"
        if panel.runModal() == .OK, let url = panel.url {
            try? runner.logLines.map { "\($0.time) \($0.text)" }.joined(separator: "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
