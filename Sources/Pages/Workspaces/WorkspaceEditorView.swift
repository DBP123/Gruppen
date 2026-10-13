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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("WORKSPACE PROFILES")
                Spacer()
                Button { editing = engine.add() } label: { Label("New Profile", systemImage: "plus") }
                    .industrialButton(.secondary)
            }
            if engine.profiles.isEmpty {
                empty
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16)], spacing: 16) {
                    ForEach(engine.profiles) { profile in
                        ProfileCard(profile: profile, onEdit: { editing = profile })
                    }
                }
                if let report = engine.lastReport { ActivationReceipt(report: report) }
            }
        }
        .sheet(item: $editing) { profile in
            WorkspaceEditorView(profileID: profile.id).environmentObject(engine)
        }
    }

    private var empty: some View {
        Text("KEINE PROFILE")
            .font(Theme.mono(11, .semibold)).tracking(1.2)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .strokeBorder(Theme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .help("A profile switches the whole environment at once — telemetry, Dock, apps, links, folders, desktop and a script — from one shortcut")
    }
}

/// One profile, as a raised card you can fire: what it launches as icons,
/// everything else it changes as small glyphs, and the key that runs it.
private struct ProfileCard: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    @EnvironmentObject private var store: GroupStore
    let profile: WorkspaceProfile
    var onEdit: () -> Void

    private var isActive: Bool { engine.activeProfileID == profile.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LED(color: profile.color, lit: isActive)
                Text(profile.name)
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if isActive { Chip(text: "AKTIV", tint: Theme.green, size: 9) }
                Spacer(minLength: 8)
                if let display = profile.shortcutDisplay {
                    KeyBadge(text: display, enabled: !engine.unavailableShortcuts.contains(profile.id))
                }
            }

            HStack(spacing: 8) {
                ForEach(profile.launches.prefix(5)) { app in
                    AppIconTile(app: app, running: store.isRunning(app))
                }
                if profile.launches.count > 5 {
                    Text("+\(profile.launches.count - 5)")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 32, height: 32)
                        .recessed(cornerRadius: 7, fill: .black.opacity(0.38))
                }
                ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                    Image(systemName: stage.glyph)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .recessed(cornerRadius: 7, fill: .black.opacity(0.38))
                        .help(stage.help)
                }
                if profile.isEmpty {
                    Text("NICHTS KONFIGURIERT")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                        .frame(height: 32)
                }
            }

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
            HStack(spacing: 6) {
                Spacer()
                Button("Edit", action: onEdit).industrialButton(.secondary)
                Button(engine.isActivating && isActive ? "Activating…" : "Activate") { engine.activate(profile) }
                    .industrialButton(.primary)
                    .disabled(engine.isActivating || profile.isEmpty)
            }
        }
        .padding(18)
        .raisedPanel(rail: isActive ? profile.color : nil)
        .contextMenu {
            Button("Activate") { engine.activate(profile) }.disabled(profile.isEmpty)
            Button("Edit…", action: onEdit)
            Divider()
            Button("Delete", role: .destructive) { engine.remove(profile) }
        }
    }

    /// Every stage besides launching apps, as a glyph and what it does.
    private var stages: [(glyph: String, help: String)] {
        var stages: [(String, String)] = []
        if let telemetry = profile.telemetry { stages.append(("gauge.with.dots.needle.33percent", "Telemetry: \(telemetry.summary)")) }
        if profile.replacesDock { stages.append(("dock.rectangle", "Sets the Dock to \(profile.dockApps.count) app(s)")) }
        if !profile.terminates.isEmpty { stages.append(("xmark.app", "Quits \(profile.terminates.map(\.name).joined(separator: ", "))")) }
        if !profile.links.isEmpty { stages.append(("link", profile.links.joined(separator: "\n"))) }
        if !profile.folders.isEmpty { stages.append(("folder", profile.folders.joined(separator: "\n"))) }
        if let space = profile.spaceIndex { stages.append(("rectangle.split.3x1", "Switches to desktop \(space)")) }
        if profile.scriptID != nil { stages.append(("chevron.left.forwardslash.chevron.right", "Runs a script last")) }
        return stages
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .raisedPanel(rail: failures == 0 ? nil : Theme.red)
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

/// The profile editor sheet: who the profile is, then what it does when it
/// runs, in the order it does it.
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
                SheetHeader(title: "PROFIL", badge: "KONFIGURATION", tint: profile.color)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Identity(profile: profile)
                        LabeledSection(label: "WHEN ACTIVATED") { Stages(profile: profile) }
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
                footer(profile)
            } else {
                Text("This profile no longer exists.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 700)
        .background(Theme.panel.grain(0.26))
    }

    private func footer(_ profile: WorkspaceProfile) -> some View {
        SheetFooter {
            Button("Delete Profile") {
                dismiss()
                engine.remove(profile)
            }
            .industrialButton(.danger)
            Spacer()
            Button("Test Run") { engine.activate(profile) }
                .industrialButton(.secondary)
                .disabled(engine.isActivating || profile.isEmpty)
                .help("Activate this profile now, without closing the editor")
            Button("Done") { dismiss() }
                .industrialButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: Identity

/// Name, colour and shortcut — one card, since together they are what you
/// recognise the profile by.
private struct Identity: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    let profile: WorkspaceProfile

    var body: some View {
        SettingsCard(rail: profile.color) {
            TextField("Profile name", text: Binding(
                get: { profile.name },
                set: { var next = profile; next.name = $0; engine.update(next) }
            ))
            .textFieldStyle(.plain)
            .font(Theme.sans(15, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .cardRow()
            CardDivider()
            HStack(spacing: 12) {
                Text("Colour").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 12)
                SwatchRow(hex: profile.colorHex) { hex in
                    var next = profile; next.colorHex = hex; engine.update(next)
                }
            }
            .cardRow()
            CardDivider()
            HStack(spacing: 8) {
                Text("Shortcut").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 12)
                ShortcutKeys(shortcut: profile.shortcut,
                             unavailable: engine.unavailableShortcuts.contains(profile.id),
                             onRecordingChange: { $0 ? engine.suspendHotkeys() : engine.resumeHotkeys() },
                             onRecord: { engine.setShortcut($0, for: profile) })
            }
            .cardRow()
        }
    }
}

// MARK: Stages

/// Everything a profile does, top to bottom in the order activation does it.
private struct Stages: View {
    @EnvironmentObject private var engine: WorkspaceEngine
    @EnvironmentObject private var scripts: ScriptLibrary
    let profile: WorkspaceProfile

    var body: some View {
        SettingsCard {
            telemetry
            CardDivider()
            dock
            CardDivider()
            StageApps(title: "Launch", apps: profile.launches, empty: "Nothing to launch",
                      help: "Apps already running are left exactly as they are — nothing is brought to the front") { apps in
                var next = profile; next.launches = apps; engine.update(next)
            }
            CardDivider()
            StageApps(title: "Quit", apps: profile.terminates, empty: "Nothing to quit",
                      help: "Each app is asked to quit, so anything with unsaved work still gets to ask you. Gruppen never quits itself") { apps in
                var next = profile; next.terminates = apps; engine.update(next)
            }
            CardDivider()
            StageList(title: "Open links", role: .links, values: profile.links) { values in
                var next = profile; next.links = values; engine.update(next)
            }
            CardDivider()
            StageList(title: "Open folders", role: .folders, values: profile.folders) { values in
                var next = profile; next.folders = values; engine.update(next)
            }
            CardDivider()
            desktop
            CardDivider()
            script
        }
    }

    private var telemetry: some View {
        HStack(spacing: 8) {
            Text("Telemetry layout").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                .help("Arrange the monitor the way you want it, then capture: which modules run, which are in the dropdown, and which are in the menu bar")
            if let captured = profile.telemetry {
                Chip(text: captured.summary.uppercased(), tint: Theme.textSecondary, size: 8.5)
            }
            Spacer(minLength: 12)
            if profile.telemetry != nil {
                Button("Clear") { var next = profile; next.telemetry = nil; engine.update(next) }
                    .industrialButton(.ghost)
            }
            Button(profile.telemetry == nil ? "Capture current" : "Recapture") { engine.captureTelemetry(into: profile) }
                .industrialButton(.secondary)
        }
        .cardRow()
    }

    @ViewBuilder private var dock: some View {
        SwitchRow(title: "Replace the Dock's apps", isOn: Binding(
            get: { profile.replacesDock },
            set: { var next = profile; next.replacesDock = $0; engine.update(next) }
        ))
        .help("Restarts the Dock, which flashes once. The Dock you had first is kept, and Settings on the Workspaces page can put it back")
        if profile.replacesDock {
            AppList(apps: profile.dockApps, empty: "No apps yet — the Dock is left alone until you add some") { apps in
                var next = profile; next.dockApps = apps; engine.update(next)
            } extra: {
                Button("Use current Dock") {
                    var next = profile
                    next.dockApps = DockManager.currentPaths().compactMap { AppEntry(url: URL(fileURLWithPath: $0)) }
                    engine.update(next)
                }
                .industrialButton(.ghost)
            }
            .padding([.horizontal, .bottom], 12)
        }
    }

    @ViewBuilder private var desktop: some View {
        HStack(spacing: 12) {
            Text("Switch to desktop").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                .help("macOS has no API for going to a numbered desktop, so this presses the \"Switch to Desktop N\" shortcut for you")
            Spacer(minLength: 12)
            Menu {
                Button("Stay put") { setSpace(nil) }
                Divider()
                ForEach(1...SpaceManager.maximumDesktop, id: \.self) { index in
                    Button("Desktop \(index)") { setSpace(index) }
                }
            } label: {
                MenuKeyLabel(title: profile.spaceIndex.map { "Desktop \($0)" } ?? "Stay put", compact: false)
            }
            .menuKey()
        }
        .cardRow()
        if let readiness = profile.spaceIndex.map(SpaceManager.readiness(for:)), readiness != .ready {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.amber)
                Text(readiness.explanation)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if readiness == .needsAccessibility {
                    Button("Grant Accessibility…") { SpaceManager.requestAccessibility() }
                        .industrialButton(.secondary)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
    }

    private var script: some View {
        HStack(spacing: 12) {
            Text("Run a script").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                .help("Runs last, once everything else is in place, and shows up in that script's history")
            Spacer(minLength: 12)
            Menu {
                Button("None") { setScript(nil) }
                Divider()
                ForEach(scripts.scripts) { script in
                    Button(script.name) { setScript(script.id) }
                }
            } label: {
                MenuKeyLabel(title: scripts.scripts.first { $0.id == profile.scriptID }?.name ?? "None",
                             compact: false)
            }
            .menuKey()
        }
        .cardRow()
    }

    private func setSpace(_ index: Int?) {
        var next = profile; next.spaceIndex = index; engine.update(next)
    }

    private func setScript(_ id: UUID?) {
        var next = profile; next.scriptID = id; engine.update(next)
    }
}

/// A stage that is a list of apps: its title, then the list.
private struct StageApps: View {
    let title: String
    let apps: [AppEntry]
    let empty: String
    let help: String
    let onChange: ([AppEntry]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary).help(help)
            AppList(apps: apps, empty: empty, onChange: onChange) { EmptyView() }
        }
        .cardRow()
    }
}

/// Links or folders: a title, the entries, and a field to add one.
private struct StageList: View {
    enum Role { case links, folders }

    let title: String
    let role: Role
    let values: [String]
    let onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    ListRow(glyph: role == .links ? "link" : "folder",
                            title: value,
                            warning: role == .folders && !exists(value) ? "NOT FOUND" : nil) {
                        var next = values; next.remove(at: index); onChange(next)
                    }
                }
                HStack(spacing: 8) {
                    TextField(role == .links ? "docs.example.com/dashboard" : "~/Documents/Project",
                              text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .recessed(cornerRadius: Theme.radiusSm)
                        .onSubmit(commit)
                    if role == .folders {
                        Button("Browse…", action: browse).industrialButton(.ghost)
                    }
                    Button("Add", action: commit)
                        .industrialButton(.ghost)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, values.isEmpty ? 0 : 4)
            }
        }
        .cardRow()
    }

    private func exists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onChange(values + [trimmed])
        draft = ""
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        // Written back with the home directory as `~` so a profile stays
        // portable between machines and readable in the saved file.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        onChange(values + panel.urls.map { url -> String in
            url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        })
    }
}

// MARK: - Shared editor parts

/// A list of apps in a recess: icon and name per row, remove on hover, drop
/// apps on it or add them from a panel.
struct AppList<Extra: View>: View {
    let apps: [AppEntry]
    let empty: String
    let onChange: ([AppEntry]) -> Void
    @ViewBuilder let extra: Extra

    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if apps.isEmpty {
                Text(empty)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            ForEach(apps) { app in
                ListRow(icon: app.icon, title: app.name,
                        warning: FileManager.default.fileExists(atPath: app.path) ? nil : "MISSING",
                        help: app.bundleID.isEmpty ? app.path : app.bundleID) {
                    onChange(apps.filter { $0.id != app.id })
                }
            }
            HStack(spacing: 6) {
                Button { choose() } label: { Label("Add Apps…", systemImage: "plus") }
                    .industrialButton(.ghost)
                extra
            }
            .padding(.top, 2)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .recessed(cornerRadius: Theme.radiusSm)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                .strokeBorder(targeted ? Theme.orange.opacity(0.7) : .clear, lineWidth: 1)
        )
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func add(_ urls: [URL]) {
        let existing = Set(apps.map(\.id))
        let new = urls.compactMap(AppEntry.init(url:)).filter { !existing.contains($0.id) }
        if !new.isEmpty { onChange(apps + new) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }
}

/// One entry in an editor list: an icon or glyph, a name, a warning when it is
/// gone, and a remove key that shows on hover.
struct ListRow: View {
    var icon: NSImage? = nil
    var glyph: String? = nil
    let title: String
    var warning: String? = nil
    var help: String? = nil
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
            } else if let glyph {
                Image(systemName: glyph).font(.system(size: 10)).foregroundStyle(Theme.textMuted).frame(width: 18)
            }
            Text(title)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help ?? title)
            Spacer(minLength: 6)
            if let warning {
                Text(warning).font(Theme.mono(8.5, .semibold)).tracking(0.6).foregroundStyle(Theme.red)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .industrialButton(.ghost)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.white.opacity(0.04) : .clear))
        .onHover { hovering = $0 }
    }
}

/// The colour swatches every editor shares, plus a well for any other colour.
struct SwatchRow: View {
    let hex: String
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Theme.presetColors) { preset in
                let selected = hex.caseInsensitiveCompare(preset.hex) == .orderedSame
                Button { pick(preset.hex) } label: {
                    Circle()
                        .fill(Color(hex: preset.hex))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Theme.panel, lineWidth: selected ? 2 : 0))
                        .overlay(Circle().strokeBorder(selected ? Color(hex: preset.hex) : .clear, lineWidth: 1.5).padding(-3))
                        .shadow(color: selected ? Color(hex: preset.hex).opacity(0.6) : .clear, radius: 5)
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
            ColorPicker("", selection: Binding(get: { Color(hex: hex) },
                                               set: { pick($0.hexString) }),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .help("Any other colour")
        }
    }
}

/// The plate across the top of a sheet: what it edits, in the German badge.
struct SheetHeader: View {
    let title: String
    let badge: String
    var tint: Color = Theme.orange

    var body: some View {
        HStack(spacing: 8) {
            LED(color: tint, lit: true, size: 8)
            Text(title)
                .font(Theme.mono(11, .medium)).tracking(1.3)
                .foregroundStyle(Theme.textSecondary)
            Chip(text: badge, tint: Theme.orange, size: 9)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .background(LinearGradient(colors: [Theme.surfaceTop, Theme.panel], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
    }
}

/// The key row along the bottom of a sheet.
struct SheetFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(Theme.panel)
            .overlay(alignment: .top) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
    }
}
