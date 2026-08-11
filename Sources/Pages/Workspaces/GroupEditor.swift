import AppKit
import SwiftUI

/// Configuration sheet for a single Gruppe.
struct GroupEditorView: View {
    @EnvironmentObject private var store: GroupStore
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID

    @State private var name = ""
    @State private var dropTargeted = false

    private var group: AppGroup? { store.groups.first { $0.id == groupID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let group {
                content(group)
                footer(group)
            }
        }
        .frame(width: 560, height: 580)
        .background(Theme.panel)
        .onAppear { name = group?.name ?? "" }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Text("GRUPPE")
                    .font(Theme.mono(11, .medium))
                    .tracking(1.3)
                    .foregroundStyle(Theme.textSecondary)
                Chip(text: "KONFIGURATION", tint: Theme.orange, size: 9)
            }
            Spacer()
            Button { commit(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .industrialButton(.ghost)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
    }

    // MARK: Content

    private func content(_ group: AppGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LabeledSection(label: "NAME") {
                    TextField("Gruppe name", text: $name)
                        .textFieldStyle(.plain)
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.input))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 1))
                        .onSubmit(commit)
                }

                LabeledSection(label: "FARBE") {
                    ColorSelector(group: group)
                }

                LabeledSection(label: "GLOBAL SHORTCUT") {
                    ShortcutRecorderRow(group: group)
                }

                LabeledSection(label: "EXECUTION") {
                    SequenceControls(group: group)
                }

                LabeledSection(label: "WHEN PARTLY RUNNING") {
                    PartialBehaviourRow(group: group)
                }

                LabeledSection(label: "APPLIKATIONEN — \(group.apps.count)") {
                    appList(group)
                }
            }
            .padding(20)
        }
    }

    private func appList(_ group: AppGroup) -> some View {
        VStack(spacing: 0) {
            if group.apps.isEmpty {
                VStack(spacing: 10) {
                    Text("Drag applications here, or add them manually")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textMuted)
                    Button("+ Add Applikationen") { addApps(group) }.industrialButton(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else if group.isSequenced {
                // A List is what gives `.onMove` real drag-reordering on macOS.
                List {
                    ForEach(Array(group.apps.enumerated()), id: \.element.id) { position, app in
                        AppRow(app: app,
                               running: store.isRunning(app),
                               step: position + 1,
                               accent: group.color) {
                            store.remove([app.id], from: group)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        store.moveApps(in: group, from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(group.apps.count) * 48 + 8)
            } else {
                ForEach(group.apps) { app in
                    AppRow(app: app, running: store.isRunning(app)) {
                        store.remove([app.id], from: group)
                    }
                    if app.id != group.apps.last?.id {
                        Rectangle().fill(Theme.borderSubtle).frame(height: 1)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .strokeBorder(dropTargeted ? Theme.orange : Theme.borderSubtle,
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1,
                                                 dash: group.apps.isEmpty ? [4, 4] : []))
        )
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls: urls, to: group)
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }

    // MARK: Footer

    private func footer(_ group: AppGroup) -> some View {
        HStack {
            Button("Delete Gruppe") {
                dismiss()
                store.delete(group)
            }
            .industrialButton(.danger)

            Spacer()

            if !group.apps.isEmpty {
                Button("+ Add Applikationen") { addApps(group) }.industrialButton(.secondary)
            }
            Button("Done") { commit(); dismiss() }
                .industrialButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
    }

    private func commit() {
        guard let group else { return }
        store.rename(group, to: name)
    }

    private func addApps(_ group: AppGroup) {
        let panel = NSOpenPanel()
        panel.title = "Add Applikationen"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        store.add(urls: panel.urls, to: group)
    }
}

/// Click to arm, then press the combination you want. Escape abandons,
/// Delete clears. Existing hotkeys are released while listening so pressing an
/// already-bound combination records it instead of firing it.
private struct ShortcutRecorderRow: View {
    @EnvironmentObject private var store: GroupStore
    @StateObject private var recorder = KeyRecorder()
    @State private var hovering = false

    let group: AppGroup

    private var live: AppGroup { store.groups.first { $0.id == group.id } ?? group }
    private var unavailable: Bool { store.unavailableShortcuts.contains(live.id) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    if recorder.isRecording {
                        Circle().fill(Theme.orange).frame(width: 6, height: 6)
                        Text("PRESS KEYS…")
                    } else if let display = live.shortcutDisplay {
                        Text(display)
                    } else {
                        Text("Not bound")
                    }
                }
                .font(Theme.mono(12))
                .foregroundStyle(labelColor)
                .frame(minWidth: 130)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.input))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSm)
                        .strokeBorder(borderColor, lineWidth: recorder.isRecording ? 2 : 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if live.shortcut != nil && !recorder.isRecording {
                Button {
                    store.setShortcut(nil, for: live)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .industrialButton(.ghost)
                .help("Clear shortcut")
            }

            Text(hint)
                .font(Theme.mono(10))
                .foregroundStyle(unavailable ? Theme.red : Theme.textMuted)

            Spacer()
        }
        .animation(.easeOut(duration: 0.12), value: recorder.isRecording)
        .onDisappear {
            if recorder.isRecording { store.resumeHotkeys() }
            recorder.stop()
        }
    }

    private var labelColor: Color {
        if recorder.isRecording { return Theme.orange }
        if live.shortcut == nil { return Theme.textMuted }
        return unavailable ? Theme.red : Theme.textPrimary
    }

    private var borderColor: Color {
        if recorder.isRecording { return Theme.orange }
        if unavailable { return Theme.red.opacity(0.5) }
        return hovering ? Theme.borderStrong : Theme.borderSubtle
    }

    private var hint: String {
        if recorder.isRecording { return "⎋ cancel · ⌫ clear · needs ⌘, ⌥ or ⌃" }
        if unavailable { return "UNAVAILABLE — claimed by another app" }
        return live.shortcut == nil ? "Click to record" : "Toggles from anywhere"
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            store.resumeHotkeys()
            return
        }
        store.suspendHotkeys()
        recorder.start { captured in
            store.setShortcut(captured, for: live)
            store.resumeHotkeys()
        }
    }
}

/// Some apps up, some down, is the one genuinely ambiguous state — this picks
/// what the Gruppe's button does about it.
private struct PartialBehaviourRow: View {
    @EnvironmentObject private var store: GroupStore
    let group: AppGroup

    private var live: AppGroup { store.groups.first { $0.id == group.id } ?? group }

    var body: some View {
        SettingToggle(
            title: live.fillsWhenPartial ? "Launch the remaining apps" : "Terminate the running apps",
            detail: live.fillsWhenPartial
                ? "Fills the Gruppe in — button reads LAUNCH REST"
                : "Closes what is up — button reads TERMINATE",
            isOn: Binding(
                get: { live.fillsWhenPartial },
                set: { store.setFillsWhenPartial($0, for: live) }
            )
        )
    }
}

private struct AppRow: View {
    let app: AppEntry
    let running: Bool
    var step: Int? = nil
    var accent: Color = Theme.orange
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let step {
                StepBadge(number: step, accent: accent, lit: running)
            }
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textPrimary)
                Text(app.bundleID.isEmpty ? app.path : app.bundleID)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if running {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                Text("RUNNING")
                    .font(Theme.mono(9, .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.green)
            }

            Button(action: onRemove) {
                Image(systemName: "minus").font(.system(size: 10, weight: .bold))
            }
            .industrialButton(.ghost)
            .opacity(hovering ? 1 : 0)
            .help("Remove from Gruppe")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hovering ? Theme.surfaceHover : Color.clear)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Illuminated position marker for a sequenced Gruppe. Lights in the Gruppe's
/// own colour once that step's app is up.
private struct StepBadge: View {
    let number: Int
    let accent: Color
    let lit: Bool

    var body: some View {
        Text("\(number)")
            .font(Theme.mono(10, .bold))
            .foregroundStyle(lit ? accent.litCore : Theme.textMuted)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(lit ? accent.opacity(0.16) : Color.black.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(lit ? accent.opacity(0.55) : Theme.borderSubtle, lineWidth: 1)
            )
            .shadow(color: lit ? accent.opacity(0.45) : .clear, radius: 4)
    }
}

/// Quick-select swatches plus a native picker for any other hex.
private struct ColorSelector: View {
    @EnvironmentObject private var store: GroupStore
    let group: AppGroup

    private var live: AppGroup { store.groups.first { $0.id == group.id } ?? group }

    private var customBinding: Binding<Color> {
        Binding(
            get: { live.color },
            set: { newValue in
                let hex = newValue.hexString
                if hex != live.colorHex { store.setColor(hex, for: live) }
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Theme.presetColors) { preset in
                Swatch(hex: preset.hex,
                       selected: live.colorHex.caseInsensitiveCompare(preset.hex) == .orderedSame) {
                    store.setColor(preset.hex, for: live)
                }
                .help(preset.name)
            }

            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(width: 1, height: 20)

            ColorPicker("", selection: customBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Custom colour")

            Text(live.colorHex.uppercased())
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)

            Spacer()
        }
    }
}

/// Strict execution sequence: order matters, and so does the pause between
/// steps — some apps refuse to come up cleanly if their dependency is still
/// starting.
private struct SequenceControls: View {
    @EnvironmentObject private var store: GroupStore
    let group: AppGroup

    private var live: AppGroup { store.groups.first { $0.id == group.id } ?? group }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingToggle(
                title: "Strict Execution Sequence",
                detail: "Launch 1→N in order, terminate N→1 in reverse",
                isOn: Binding(
                    get: { live.isSequenced },
                    set: { store.setSequenced($0, for: live) }
                )
            )

            if live.isSequenced {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("STEP DELAY")
                            .font(Theme.mono(10, .semibold))
                            .tracking(1.1)
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                        Text(String(format: "%.1fs", live.sequenceDelay))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.orange)
                    }
                    IndustrialSlider(
                        value: Binding(
                            get: { live.sequenceDelay },
                            set: { store.setSequenceDelay($0, for: live) }
                        ),
                        range: 0...3,
                        step: 0.1
                    )
                    Text("Drag rows below to set the order.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                }
                .panelRow()
            }
        }
    }
}

private struct Swatch: View {
    let hex: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 20, height: 20)
                .overlay(
                    Circle().strokeBorder(Theme.panel, lineWidth: selected ? 2 : 0)
                )
                .overlay(
                    Circle()
                        .strokeBorder(selected ? Color(hex: hex) : .clear, lineWidth: 1.5)
                        .padding(-3)
                )
                .shadow(color: selected ? Color(hex: hex).opacity(0.6) : .clear, radius: 5)
                .scaleEffect(hovering ? 1.12 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
