import AppKit
import SwiftUI

/// Shared control chrome.
///
/// Every settings row, editor field and preference toggle used to hand-roll the
/// same surface/hover/border stack. They all come from here now, so the panel
/// look is defined once and a tool's settings pane is a few lines of content.

// MARK: - Layout

/// Mono uppercase caption above a block of content — the only section header
/// used anywhere in the app.
struct LabeledSection<Content: View>: View {
    let label: String
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(label)
                .font(Theme.mono(10, .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.textMuted)
            content
        }
    }
}

/// The standard row: a machined recess, with the surface lifting very slightly
/// under the pointer.
///
/// Hover changes the fill and the border only. No padding, no scale, no
/// inserted views — the row cannot move under the cursor, which is the
/// difference between a control panel and a web page.
private struct PanelRow: ViewModifier {
    var accent: Color?
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .machined(fill: hovering ? Theme.machined.mixed(with: .white, amount: 0.045) : Theme.machined,
                      border: accent ?? Theme.machinedBorder)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func panelRow(accent: Color? = nil) -> some View {
        modifier(PanelRow(accent: accent))
    }
}

// MARK: - Controls

/// Labelled switch. Takes a plain `Binding`, so it works equally for an
/// `AppSettings` property and a per-Gruppe value routed through the store.
struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.industrial)
        }
        .panelRow()
    }
}

struct RadioRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Theme.orange : Theme.borderStrong, lineWidth: 1)
                        .frame(width: 14, height: 14)
                    if selected { Circle().fill(Theme.orange).frame(width: 6, height: 6) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }
            .panelRow(accent: selected ? Theme.orange.opacity(0.5) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Fixed-width key with selectable value — the About tab's build details.
struct KeyValue: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Explanatory line under a group of controls.
struct FootNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Build info

extension Bundle {
    static var versionString: String {
        let short = main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// Marketing version alone, for tight spaces like the collapsed rail.
    static var shortVersion: String {
        main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
