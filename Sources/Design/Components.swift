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
    /// Optional on purpose: a switch whose title says everything gets no
    /// second line, rather than an empty one holding the row's height open.
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.industrial)
        }
        .panelRow()
    }
}

/// One machined card holding several rows, so related settings read as a
/// group instead of a column of identical boxes.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .machined(cornerRadius: 10)
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Theme.machinedBorder).frame(height: 1).padding(.leading, 12)
    }
}

/// A title and its switch, sized to sit inside a card.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.industrial)
        }
        .cardRow()
    }
}

/// A choice that belongs to a switch: a check and a label, lit when chosen.
///
/// For options *of* a setting, as opposed to settings of their own — the ways
/// a stash opens, where a telemetry module appears. Stretches to share a row
/// with its siblings; give it a fixed frame instead to line pills up in columns.
struct OptionPill: View {
    let title: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.orange : Theme.textMuted)
                Text(title)
                    .font(Theme.sans(12))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Theme.orange.opacity(0.10)
                               : Color.white.opacity(hovering ? 0.05 : 0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn ? Theme.orange.opacity(0.55) : Theme.borderStrong.opacity(0.5),
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// The padding every row inside a `SettingsCard` shares.
    func cardRow() -> some View {
        padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// A menu key's title with its chevron, drawn as part of the label.
///
/// The system's own menu indicator is not drawn once a menu takes a custom
/// button style — measured: a bare "Convert" key, indistinguishable from one
/// that converts on the spot, to an unstated format. The chevron is what says
/// "this opens a list".
struct MenuKeyLabel: View {
    let title: String
    var compact = true

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: compact ? 6.5 : 8, weight: .bold))
        }
    }
}

extension View {
    /// A `Menu` drawn as one of the app's keys, so a key that opens a list
    /// looks like the keys beside it. `compact` for the stash's half-size row.
    ///
    /// macOS 14 lets a menu take a button style; 13 does not, and gets the
    /// plain borderless menu, which still reads as a key in a row of them. The
    /// system indicator is hidden on both, since the label carries its own.
    @ViewBuilder
    func menuKey(compact: Bool = false) -> some View {
        if #available(macOS 14.0, *) {
            menuStyle(.button)
                .buttonStyle(IndustrialButtonStyle(kind: .secondary, compact: compact))
                .menuIndicator(.hidden)
                .fixedSize()
        } else {
            menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }
}

/// The keys that record a global shortcut: the current one, a way to clear
/// it, and Record / Change. Recording happens in the key itself and the
/// modifier rule is its tooltip, so the row it sits in needs no second line.
///
/// Escape abandons, delete clears, and anything without ⌘/⌥/⌃ keeps listening
/// rather than binding a bare key system-wide — see `KeyRecorder`.
struct ShortcutKeys: View {
    let shortcut: Shortcut?
    let onRecord: (Shortcut?) -> Void
    @StateObject private var recorder = KeyRecorder()

    var body: some View {
        HStack(spacing: 8) {
            if let shortcut, !recorder.isRecording {
                KeyBadge(text: shortcut.display)
                Button("Clear") { onRecord(nil) }
                    .industrialButton(.ghost)
            }
            Button(recorder.isRecording ? "Press keys…" : (shortcut == nil ? "Record" : "Change")) {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start(onRecord)
                }
            }
            .industrialButton(recorder.isRecording ? .danger : .secondary)
            .help(recorder.isRecording ? "Click to cancel" : "Use ⌘, ⌥ or ⌃ with a key")
        }
        .onDisappear { recorder.stop() }
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
