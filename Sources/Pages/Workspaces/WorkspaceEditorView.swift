import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The profile deck: every workspace profile, and the editor for one.
///
/// Sits under the Gruppe grid on the Workspaces page rather than in a route of
/// its own. A profile is the environment a Gruppe runs in, and splitting the two
/// across separate pages would mean configuring one context in two places.
struct WorkspaceProfileDeck: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    @State private var editing: WorkspaceProfile?

    var body: some View {
        LabeledSection(label: "WORKSPACE PROFILES", spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                if engine.profiles.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 12)], spacing: 12) {
                        ForEach(engine.profiles) { profile in
                            ProfileCard(profile: profile, onEdit: { editing = profile })
                        }
                    }
                    if let report = engine.lastReport { ActivationReceipt(report: report) }
                }

                HStack(spacing: 10) {
                    Button { editing = engine.add() } label: { Text("+ New Profile") }
                        .industrialButton(.secondary)
                    Spacer()
                    if DockManager.hasBackup {
                        Button { _ = DockManager.restoreOriginal() } label: { Text("Restore Original Dock") }
                            .industrialButton(.ghost)
                            .help("Puts the Dock back to how it was before any profile changed it")
                    }
                }
            }
        }
        .sheet(item: $editing) { profile in
            WorkspaceEditorView(profileID: profile.id).environmentObject(engine)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No profiles yet")
                .font(Theme.mono(12, .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("A profile switches the whole environment at once — telemetry layout, Dock, apps, links and folders — from one shortcut.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelRow()
    }
}

/// One profile, as a card you can fire.
private struct ProfileCard: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    let profile: WorkspaceProfile
    var onEdit: () -> Void

    private var isActive: Bool { engine.activeProfileID == profile.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                LED(color: profile.color, lit: isActive, size: 8)
                Text(profile.name)
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let display = profile.shortcutDisplay {
                    Text(display)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(engine.unavailableShortcuts.contains(profile.id)
                                         ? Theme.red : Theme.textMuted)
                        .fixedSize()
                }
            }

            Text(profile.summary)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button { engine.activate(profile) } label: {
                    Text(engine.isActivating && isActive ? "Activating…" : "Activate")
                }
                .industrialButton(.primary)
                .disabled(engine.isActivating || profile.isEmpty)

                Button(action: onEdit) { Text("Edit") }
                    .industrialButton(.secondary)
                Spacer()
                Button { engine.remove(profile) } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .industrialButton(.danger)
                .help("Delete this profile")
            }
        }
        .padding(12)
        .machined(cornerRadius: Theme.radiusMd,
                  fill: Theme.machined,
                  border: isActive ? profile.color.opacity(0.55) : Theme.machinedBorder)
    }
}

/// What the last activation actually did. Shown rather than logged away: a
/// context switch that half-worked should say so on the spot.
private struct ActivationReceipt: View {
    let report: WorkspaceActivationReport
    @State private var expanded = false

    private var failures: Int { report.failures.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("LAST ACTIVATION")
                        .font(Theme.mono(9, .semibold)).tracking(1.1)
                        .foregroundStyle(Theme.textMuted)
                    Text(report.profileName)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 6)
                    Text(failures == 0
                         ? String(format: "OK · %.2fs", report.duration)
                         : "\(failures) FAILED")
                        .font(Theme.mono(9, .semibold))
                        .foregroundStyle(failures == 0 ? Theme.green : Theme.red)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                DashedRule()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.stage.uppercased())
                                .font(Theme.mono(9, .semibold)).tracking(0.6)
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 74, alignment: .leading)
                            Text(line.outcome.text)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(tint(line.outcome))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelRow()
    }

    private func tint(_ outcome: WorkspaceActivationReport.Outcome) -> Color {
        switch outcome {
        case .done: return Theme.textPrimary
        case .skipped: return Theme.textMuted
        case .failed: return Theme.red
        }
    }
}

// MARK: - Editor

/// The profile editor sheet.
///
/// Edits are written straight through to the engine rather than staged in local
/// state and applied on close: the profile list is the source of truth, and a
/// draft copy would go stale the moment a hotkey rebind touched the same record.
struct WorkspaceEditorView: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    @EnvironmentObject private var scripts: ScriptLibrary
    @Environment(\.dismiss) private var dismiss

    let profileID: UUID

    private var profile: WorkspaceProfile? {
        engine.profiles.first { $0.id == profileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let profile {
                header(profile)
                Divider().overlay(Theme.borderSubtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        NameAndColor(profile: profile)
                        ShortcutRow(profile: profile)
                        TelemetrySection(profile: profile)
                        DockSection(profile: profile)
                        AppListSection(profile: profile, role: .launch)
                        AppListSection(profile: profile, role: .terminate)
                        TextListSection(profile: profile, role: .links)
                        TextListSection(profile: profile, role: .folders)
                        DesktopSection(profile: profile)
                        ScriptSection(profile: profile)
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
            } else {
                Text("This profile no longer exists.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .padding(40)
            }
        }
        .frame(width: 620, height: 680)
        .background(Theme.panel.grain(0.26))
    }

    private func header(_ profile: WorkspaceProfile) -> some View {
        HStack(spacing: 10) {
            LED(color: profile.color, lit: true, size: 9)
            Text(profile.name.isEmpty ? "Untitled" : profile.name)
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { engine.activate(profile) } label: { Text("Test Run") }
                .industrialButton(.secondary)
                .disabled(engine.isActivating || profile.isEmpty)
                .help("Activate this profile now, without closing the editor")
            Button { dismiss() } label: { Text("Done") }
                .industrialButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }
}

// MARK: Sections

private struct NameAndColor: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    let profile: WorkspaceProfile

    var body: some View {
        LabeledSection(label: "IDENTITY") {
            HStack(spacing: 10) {
                TextField("Profile name", text: Binding(
                    get: { profile.name },
                    set: { var next = profile; next.name = $0; engine.update(next) }
                ))
                .textFieldStyle(.plain)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .recessed(cornerRadius: Theme.radiusSm)

                ForEach(Theme.presetColors) { preset in
                    let selected = profile.colorHex == preset.hex
                    Button {
                        var next = profile; next.colorHex = preset.hex; engine.update(next)
                    } label: {
                        Circle()
                            .fill(Color(hex: preset.hex))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(.white.opacity(selected ? 0.9 : 0.15),
                                                      lineWidth: selected ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }
        }
    }
}

/// Click to arm, then press. Mirrors the Gruppe recorder exactly — the same
/// interaction should not feel different in two places in one app.
private struct ShortcutRow: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    @StateObject private var recorder = KeyRecorder()
    let profile: WorkspaceProfile

    private var unavailable: Bool { engine.unavailableShortcuts.contains(profile.id) }

    var body: some View {
        LabeledSection(label: "GLOBAL SHORTCUT") {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        if recorder.isRecording {
                            Circle().fill(Theme.orange).frame(width: 6, height: 6)
                            Text("PRESS KEYS…")
                        } else {
                            Text(profile.shortcutDisplay ?? "Not bound")
                        }
                    }
                    .font(Theme.mono(12))
                    .foregroundStyle(labelColor)
                    .frame(minWidth: 130)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .recessed(cornerRadius: Theme.radiusSm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if profile.shortcut != nil && !recorder.isRecording {
                    Button { engine.setShortcut(nil, for: profile) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .industrialButton(.ghost)
                }

                Text(hint)
                    .font(Theme.mono(10))
                    .foregroundStyle(unavailable ? Theme.red : Theme.textMuted)
                Spacer()
            }
        }
        .onDisappear {
            if recorder.isRecording { engine.resumeHotkeys() }
            recorder.stop()
        }
    }

    private var labelColor: Color {
        if recorder.isRecording { return Theme.orange }
        if profile.shortcut == nil { return Theme.textMuted }
        return unavailable ? Theme.red : Theme.textPrimary
    }

    private var hint: String {
        if recorder.isRecording { return "⎋ cancel · ⌫ clear · needs ⌘, ⌥ or ⌃" }
        if unavailable { return "UNAVAILABLE — claimed elsewhere" }
        return profile.shortcut == nil ? "Click to record" : "Activates from anywhere"
    }

    private func toggle() {
        if recorder.isRecording {
            recorder.stop()
            engine.resumeHotkeys()
            return
        }
        engine.suspendHotkeys()
        recorder.start { captured in
            engine.setShortcut(captured, for: profile)
            engine.resumeHotkeys()
        }
    }
}

private struct TelemetrySection: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    let profile: WorkspaceProfile

    var body: some View {
        LabeledSection(label: "TELEMETRY LAYOUT") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(profile.telemetry?.summary ?? "Left as it is")
                        .font(Theme.mono(11))
                        .foregroundStyle(profile.telemetry == nil ? Theme.textMuted : Theme.textPrimary)
                    Spacer()
                    Button { engine.captureTelemetry(into: profile) } label: { Text("Capture Current") }
                        .industrialButton(.secondary)
                    if profile.telemetry != nil {
                        Button {
                            var next = profile; next.telemetry = nil; engine.update(next)
                        } label: { Text("Clear") }
                            .industrialButton(.ghost)
                    }
                }
                .panelRow()

                FootNote("Arrange the monitor the way you want it, then capture. Stores which modules are armed, which are in the dropdown, and which are pinned to the menu bar with what display mode.")
            }
        }
    }
}

private struct DockSection: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    let profile: WorkspaceProfile

    var body: some View {
        LabeledSection(label: "DOCK") {
            VStack(alignment: .leading, spacing: 8) {
                SettingToggle(title: "Replace the Dock's pinned apps",
                              detail: "Restarts the Dock, which flashes once",
                              isOn: Binding(
                                get: { profile.replacesDock },
                                set: { var next = profile; next.replacesDock = $0; engine.update(next) }
                              ))

                if profile.replacesDock {
                    AppRows(apps: profile.dockApps,
                            empty: "No apps — the Dock is left alone until you add some",
                            onRemove: { id in
                                var next = profile
                                next.dockApps.removeAll { $0.id == id }
                                engine.update(next)
                            },
                            onAdd: { urls in
                                var next = profile
                                let existing = Set(next.dockApps.map(\.id))
                                next.dockApps += urls.compactMap(AppEntry.init(url:))
                                    .filter { !existing.contains($0.id) }
                                engine.update(next)
                            },
                            onMove: { source, destination in
                                var next = profile
                                next.dockApps.move(fromOffsets: source, toOffset: destination)
                                engine.update(next)
                            })

                    Button {
                        var next = profile
                        next.dockApps = DockManager.currentPaths()
                            .compactMap { AppEntry(url: URL(fileURLWithPath: $0)) }
                        engine.update(next)
                    } label: { Text("Capture Current Dock") }
                        .industrialButton(.secondary)

                    FootNote("The Dock as it was before Gruppen first changed it is saved to Application Support, and \"Restore Original Dock\" on the Workspaces page puts it back.")
                }
            }
        }
    }
}

private struct AppListSection: View {
    enum Role { case launch, terminate }

    @EnvironmentObject private var engine: WorkspaceEngine
    let profile: WorkspaceProfile
    let role: Role

    private var apps: [AppEntry] { role == .launch ? profile.launches : profile.terminates }
    private var label: String { role == .launch ? "LAUNCH" : "QUIT" }
    private var note: String {
        role == .launch
            ? "Apps already running are left exactly as they are — nothing is brought to the front."
            : "Each app is asked to quit, so anything with unsaved work still gets to ask you about it. Gruppen never quits itself."
    }

    var body: some View {
        LabeledSection(label: label) {
            VStack(alignment: .leading, spacing: 8) {
                AppRows(apps: apps,
                        empty: role == .launch ? "Nothing to launch" : "Nothing to quit",
                        onRemove: { id in
                            var next = profile
                            if role == .launch { next.launches.removeAll { $0.id == id } }
                            else { next.terminates.removeAll { $0.id == id } }
                            engine.update(next)
                        },
                        onAdd: { urls in
                            var next = profile
                            let entries = urls.compactMap(AppEntry.init(url:))
                            if role == .launch {
                                let existing = Set(next.launches.map(\.id))
                                next.launches += entries.filter { !existing.contains($0.id) }
                            } else {
                                let existing = Set(next.terminates.map(\.id))
                                next.terminates += entries.filter { !existing.contains($0.id) }
                            }
                            engine.update(next)
                        },
                        onMove: { source, destination in
                            var next = profile
                            if role == .launch { next.launches.move(fromOffsets: source, toOffset: destination) }
                            else { next.terminates.move(fromOffsets: source, toOffset: destination) }
                            engine.update(next)
                        })
                FootNote(note)
            }
        }
    }
}

/// Shared app list: rows with icons, drag to reorder, drop to add.
private struct AppRows: View {
    let apps: [AppEntry]
    let empty: String
    var onRemove: (AppEntry.ID) -> Void
    var onAdd: ([URL]) -> Void
    var onMove: (IndexSet, Int) -> Void

    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if apps.isEmpty {
                Text(empty)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(Theme.mono(9)).foregroundStyle(Theme.textMuted)
                            .frame(width: 14, alignment: .trailing)
                        Image(nsImage: app.icon)
                            .resizable().frame(width: 18, height: 18)
                        Text(app.name)
                            .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if !FileManager.default.fileExists(atPath: app.path) {
                            Text("MISSING")
                                .font(Theme.mono(8.5, .semibold))
                                .foregroundStyle(Theme.red)
                        }
                        Button { onRemove(app.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .industrialButton(.ghost)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .onMove(perform: onMove)
            }

            Button { choose() } label: { Text("+ Add Apps…") }
                .industrialButton(.ghost)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .machined(fill: targeted ? Theme.machined.mixed(with: .white, amount: 0.06) : Theme.machined,
                  border: targeted ? Theme.orange.opacity(0.6) : Theme.machinedBorder)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                          let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { continue }
                    urls.append(url)
                }
                if !urls.isEmpty { onAdd(urls) }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        onAdd(panel.urls)
    }
}

/// Links and folders: same shape, different validation.
private struct TextListSection: View {
    enum Role { case links, folders }

    @EnvironmentObject private var engine: WorkspaceEngine
    let profile: WorkspaceProfile
    let role: Role
    @State private var draft = ""

    private var values: [String] { role == .links ? profile.links : profile.folders }
    private var label: String { role == .links ? "LINKS" : "FOLDERS" }
    private var placeholder: String {
        role == .links ? "docs.example.com/dashboard" : "~/Documents/Chem Lab"
    }

    var body: some View {
        LabeledSection(label: label) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(spacing: 8) {
                        Image(systemName: role == .links ? "link" : "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                        Text(value)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        if role == .folders, !exists(value) {
                            Text("NOT FOUND")
                                .font(Theme.mono(8.5, .semibold))
                                .foregroundStyle(Theme.red)
                        }
                        Button { remove(at: index) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .industrialButton(.ghost)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }

                HStack(spacing: 8) {
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .recessed(cornerRadius: Theme.radiusSm)
                        .onSubmit(commit)
                    if role == .folders {
                        Button { browse() } label: { Text("Browse…") }
                            .industrialButton(.ghost)
                    }
                    Button(action: commit) { Text("Add") }
                        .industrialButton(.ghost)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .machined()
        }
    }

    private func exists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var next = profile
        if role == .links { next.links.append(trimmed) } else { next.folders.append(trimmed) }
        engine.update(next)
        draft = ""
    }

    private func remove(at index: Int) {
        var next = profile
        if role == .links { next.links.remove(at: index) } else { next.folders.remove(at: index) }
        engine.update(next)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var next = profile
        // Written back with the home directory as `~` so a profile stays
        // portable between machines and readable in the saved file.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        next.folders += panel.urls.map { url -> String in
            url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
        engine.update(next)
    }
}

/// The desktop stage, with its preconditions stated up front rather than
/// discovered when it silently does nothing.
private struct DesktopSection: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    let profile: WorkspaceProfile

    private var readiness: SpaceManager.Readiness? {
        profile.spaceIndex.map(SpaceManager.readiness(for:))
    }

    var body: some View {
        LabeledSection(label: "DESKTOP") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Switch to desktop")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                    Picker("", selection: Binding(
                        get: { profile.spaceIndex ?? 0 },
                        set: {
                            var next = profile
                            next.spaceIndex = $0 == 0 ? nil : $0
                            engine.update(next)
                        }
                    )) {
                        Text("Stay put").tag(0)
                        ForEach(1...SpaceManager.maximumDesktop, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Spacer()
                }
                .panelRow()

                if let readiness, readiness != .ready {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.amber)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(readiness.explanation)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                            if readiness == .needsAccessibility {
                                Button { SpaceManager.requestAccessibility() } label: {
                                    Text("Grant Accessibility…")
                                }
                                .industrialButton(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .panelRow()
                }

                FootNote("macOS has no API for going to a numbered desktop, so this presses the \"Switch to Desktop N\" shortcut for you. That shortcut ships switched off, and synthetic keystrokes need Accessibility — both are checked before anything is sent, and reported if missing.")
            }
        }
    }
}

private struct ScriptSection: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    @EnvironmentObject private var scripts: ScriptLibrary
    let profile: WorkspaceProfile

    var body: some View {
        LabeledSection(label: "SCRIPT") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(
                    get: { profile.scriptID ?? Self.none },
                    set: {
                        var next = profile
                        next.scriptID = $0 == Self.none ? nil : $0
                        engine.update(next)
                    }
                )) {
                    Text("None").tag(Self.none)
                    ForEach(scripts.scripts) { script in
                        Text(script.name).tag(script.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
                .panelRow()

                FootNote("Runs last, after everything else is in place. Scripts come from the Scripts page, so a profile's script gets the same transcript, feedback setting and argument safety as any other.")
            }
        }
    }

    /// A sentinel rather than an optional tag: SwiftUI's `Picker` cannot match
    /// `nil` against a `UUID` tag, so "None" needs a real value of its own.
    private static let none = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
