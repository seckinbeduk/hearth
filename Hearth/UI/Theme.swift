import SwiftUI

/// Warm accent for "your Mac's own fire"; everything else stays system-native.
enum Theme {
    static let flame = Color(red: 0.95, green: 0.45, blue: 0.17)
    static let ready = Color(red: 0.20, green: 0.68, blue: 0.42)
    static let apple = Color(red: 0.40, green: 0.47, blue: 0.95)
    static let warning = Color(red: 0.90, green: 0.55, blue: 0.15)
    static let card = Color(nsColor: .controlBackgroundColor)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .capsule)
    }
}

struct CopyButton: View {
    let text: String
    var label: String? = nil
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            if let label {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .help("Copy")
    }
}

/// Tappable monospaced endpoint with a copy button.
struct EndpointField: View {
    let url: String

    var body: some View {
        HStack(spacing: 8) {
            Text(url)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer(minLength: 4)
            CopyButton(text: url)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }
}

extension ModelFit.Verdict {
    var color: Color {
        switch self {
        case .comfortable: Theme.ready
        case .tight, .slow: Theme.warning
        case .tooBig, .noDisk, .unsupported: .secondary
        }
    }
}

enum Format {
    static func gb(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }

    static func bytes(_ value: UInt64) -> String {
        gb(Double(value) / 1_073_741_824)
    }

    static func speed(_ tps: Double) -> String {
        "\(Int(tps.rounded())) tok/s"
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: value < 10_000 ? "%.1fK" : "%.0fK", Double(value) / 1_000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    static func ago(_ date: Date) -> String {
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 10 { return "now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3_600))h ago"
    }

    /// Readable small amounts: $0.00042 · $0.013 · $2.40
    static func usd(_ value: Double) -> String {
        guard value > 0 else { return "$0" }
        let digits = value >= 1 ? 2 : value >= 0.01 ? 3 : value >= 0.0001 ? 5 : 6
        return value.formatted(.currency(code: "USD").precision(.fractionLength(0...digits)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let total = Int(seconds.rounded())
        return "\(total / 60)m \(total % 60)s"
    }
}
