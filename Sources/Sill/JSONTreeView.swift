import SwiftUI

/// developer-tools.md #4 — JSON formatting, native half: a collapsible,
/// highlighted tree for JSON, used by the API client's response viewer. The
/// in-page equivalent (direct navigation to a JSON URL in an ordinary tab)
/// is a separate, JS-based renderer (JSONFormatting.swift) since that one
/// runs inside a WKWebView, not SwiftUI — same visual language, two runtimes.
struct JSONTreeView: View {
    let value: Any

    var body: some View {
        JSONNodeView(key: nil, value: value, depth: 0)
    }
}

private struct JSONNodeView: View {
    let key: String?
    let value: Any
    let depth: Int

    @State private var expanded = true

    var body: some View {
        switch value {
        case let dict as [String: Any]:
            let entries = dict.sorted { $0.key < $1.key }
            container(label: "{ \(entries.count) }", isEmpty: entries.isEmpty) {
                ForEach(entries, id: \.key) { entry in
                    JSONNodeView(key: entry.key, value: entry.value, depth: depth + 1)
                }
            }
        case let array as [Any]:
            container(label: "[ \(array.count) ]", isEmpty: array.isEmpty) {
                ForEach(Array(array.enumerated()), id: \.offset) { index, item in
                    JSONNodeView(key: "\(index)", value: item, depth: depth + 1)
                }
            }
        default:
            leaf
        }
    }

    @ViewBuilder
    private func container<Content: View>(label: String, isEmpty: Bool, @ViewBuilder children: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if !isEmpty { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    if !isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Tokens.inkGhost)
                            .frame(width: 10)
                    } else {
                        Spacer().frame(width: 10)
                    }
                    keyLabel
                    Text(label)
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.inkGhost)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded && !isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    children()
                }
                .padding(.leading, 14)
            }
        }
    }

    private var leaf: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 10)
            keyLabel
            Text(literalText)
                .font(Tokens.font(11.5, .medium))
                .foregroundStyle(literalColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var keyLabel: some View {
        if let key {
            Text("\(key):")
                .font(Tokens.font(11.5, .medium))
                .foregroundStyle(Tokens.inkFaint)
        }
    }

    private var literalText: String {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            return "\"\(string)\""
        case let number as NSNumber:
            return number.stringValue
        default:
            return String(describing: value)
        }
    }

    private var literalColor: Color {
        switch value {
        case is NSNull:
            return Tokens.inkGhost
        case is String:
            return Tokens.accent
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return Tokens.warning
        default:
            return Tokens.ink
        }
    }
}
