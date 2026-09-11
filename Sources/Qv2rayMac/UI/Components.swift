import SwiftUI
import AppKit

// MARK: - JSON editor (NSTextView wrapper with live validation)

struct JSONEditorView: View {
    @Binding var text: String
    var readOnly = false

    private var validation: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let d = trimmed.data(using: .utf8) else { return "UTF-8" }
        do {
            _ = try JSONSerialization.jsonObject(with: d)
            return nil
        } catch {
            return (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            TextViewWrapper(text: $text, readOnly: readOnly)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            HStack(spacing: 8) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L10n.tr("json.empty")).foregroundStyle(.secondary)
                } else if let error = validation {
                    Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).lineLimit(1)
                } else {
                    Label(L10n.tr("json.valid"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                if !readOnly {
                    Button(L10n.tr("json.format")) {
                        if let d = text.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
                           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                            text = String(decoding: pretty, as: UTF8.self)
                        }
                    }
                    .controlSize(.small)
                    .disabled(validation != nil)
                }
            }
            .font(.caption)
        }
    }
}

struct TextViewWrapper: NSViewRepresentable {
    @Binding var text: String
    var readOnly: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isEditable = !readOnly
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.backgroundColor = .textBackgroundColor
        tv.string = text
        tv.delegate = context.coordinator
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        tv.isEditable = !readOnly
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextViewWrapper
        init(_ parent: TextViewWrapper) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
