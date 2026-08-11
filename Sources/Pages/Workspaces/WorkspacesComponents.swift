import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Views that make up the Workspaces grid.

// MARK: - Search

struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? Theme.orange : Theme.textMuted)
            TextField("Search Gruppen or Applikation...", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 280)
        .recessed()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSm)
                .strokeBorder(focused ? Theme.orange : .clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
        .onExitCommand { text = "" }
        .background(
            Button("") { focused = true }
                .keyboardShortcut("f").opacity(0).frame(width: 0, height: 0)
        )
    }
}

// MARK: - Card

struct GruppeCard: View {
    @EnvironmentObject private var store: GroupStore
    let group: AppGroup
    let onEdit: () -> Void

    @State private var hovering = false

    private var live: AppGroup { store.groups.first { $0.id == group.id } ?? group }
    private var running: Int { store.runningCount(in: live) }
    private var action: GroupStore.PrimaryAction { store.primaryAction(for: live) }

    private var actionHelp: String {
        switch action {
        case .launch: return "Launch every app in this Gruppe"
        case .terminate:
            return running < live.apps.count
                ? "Force close the \(running) running app(s) in this Gruppe"
                : "Force close every app in this Gruppe"
        case .fillRemaining: return "Launch the \(live.apps.count - running) app(s) that aren't running yet"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            top
            iconStack
            Spacer(minLength: 0)
            bottom
        }
        .padding(18)
        .frame(minHeight: 176, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: hovering
                            ? [Theme.surfaceHover, Theme.surface]
                            : [Theme.surfaceTop, Theme.surface],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .grain(0.17, cornerRadius: Theme.radiusMd)
                // Gradient + tiled grain + shadow is the most expensive static
                // stack in the app; rasterise it once instead of recompositing
                // it on every pass.
                .drawingGroup()
                .shadow(color: .black.opacity(0.45), radius: 9, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .strokeBorder(hovering ? Theme.borderStrong : Theme.borderSubtle, lineWidth: 1)
        )
        .bezel()
        // Active rail, clipped to the card's rounded corners.
        .overlay(alignment: .leading) {
            if live.isActive {
                Rectangle()
                    .fill(live.color)
                    .frame(width: 3)
                    .shadow(color: live.color.opacity(0.55), radius: 5, x: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: live.isActive)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(action.label) { store.toggle(live) }
            Button("Edit…", action: onEdit)
            Divider()
            Button("Duplicate") { store.duplicate(live) }
            Button("Delete", role: .destructive) { store.delete(live) }
        }
    }

    private var top: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    LED(color: live.color, lit: live.isActive || running > 0)
                    Text(live.name)
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                if live.isActive {
                    Chip(text: "AKTIV · \(running)/\(live.apps.count)", tint: Theme.green)
                } else if running > 0 {
                    Chip(text: "\(running) RUNNING", tint: Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = live.shortcutDisplay {
                KeyBadge(text: shortcut, enabled: !store.unavailableShortcuts.contains(live.id))
                    .help(store.unavailableShortcuts.contains(live.id)
                          ? "This shortcut is already claimed by macOS or another app"
                          : "Toggles this Gruppe from anywhere")
            }
        }
    }

    private var iconStack: some View {
        HStack(spacing: 8) {
            ForEach(live.apps.prefix(6)) { app in
                AppIconTile(app: app, running: store.isRunning(app))
            }
            if live.apps.count > 6 {
                Text("+\(live.apps.count - 6)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 32, height: 32)
                    .recessed(cornerRadius: 7, fill: .black.opacity(0.38))
            }
            if live.apps.isEmpty {
                Text("NO APPLIKATIONEN")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .frame(height: 32)
            }
        }
    }

    private var bottom: some View {
        VStack(spacing: 12) {
            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
            HStack {
                Text("\(live.apps.count) Applikationen")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                HStack(spacing: 6) {
                    Button("Edit", action: onEdit).industrialButton(.secondary)
                    Button(action.label) { store.toggle(live) }
                        .industrialButton(action == .terminate ? .danger : .primary)
                        .disabled(live.apps.isEmpty)
                        .help(actionHelp)
                }
            }
        }
    }
}

/// App icon in a bordered well. A running app gets a dot in the corner, which
/// is what makes the card readable at a glance without reading any text.
struct AppIconTile: View {
    let app: AppEntry
    var running: Bool
    @State private var hovering = false

    var body: some View {
        Image(nsImage: app.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 20, height: 20)
            .padding(6)
            .recessed(cornerRadius: 7, fill: .black.opacity(0.38))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(hovering ? Theme.borderStrong : .clear, lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if running {
                    LED(color: Theme.green, size: 7)
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            .saturation(running ? 1 : 0.55)
            .opacity(running ? 1 : (hovering ? 0.85 : 0.7))
            // Deliberately no offset/scale on hover: moving a small tile under
            // the cursor can bounce it in and out of its own hover region.
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .help("\(app.name)\(running ? " — running" : "")")
    }
}

// MARK: - Empty states

struct EmptyState: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text("KEINE GRUPPEN")
                .font(Theme.mono(12, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Text("Create a Gruppe, add applications, launch them as one.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textMuted)
            Button("+ New Gruppe", action: action).industrialButton(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .strokeBorder(Theme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }
}

struct NoResults: View {
    let query: String

    var body: some View {
        VStack(spacing: 8) {
            Text("NO MATCH")
                .font(Theme.mono(12, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Text("Nothing matches “\(query)”")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}


// MARK: - Suggested Gruppen

/// Deterministic preset matches. Nothing is inferred from behaviour — a chip
/// appears only because at least two of a rule's apps are installed.
struct SuggestionStrip: View {
    @EnvironmentObject private var store: GroupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUGGESTED GRUPPEN")
                .font(Theme.mono(10, .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.textMuted)

            HStack(spacing: 8) {
                ForEach(store.suggestions) { match in
                    SuggestionChip(match: match) { store.createGroup(from: match) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct SuggestionChip: View {
    let match: Presets.Match
    let action: () -> Void

    @State private var hovering = false

    private var accent: Color { Color(hex: match.colorHex) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LED(color: accent, lit: hovering, size: 8)
                Text(match.name)
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(match.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? accent : Theme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                    .fill(hovering ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                    .strokeBorder(hovering ? accent.opacity(0.5) : Theme.borderSubtle, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("Create \"\(match.name)\" from \(match.count) installed app(s)")
    }
}
