import CryptoKit
import Foundation
import SwiftUI

/// Which tools exist as far as the rest of the app is concerned.
///
/// A tool switched off here is not greyed out or disabled — it is *gone*: it
/// leaves the sidebar, `Page.available` stops listing it, and if it happened to
/// be the page on screen the app moves to the first one that is still there.
/// Nothing can route to it, so nothing can use it.
@MainActor
final class DeveloperSettings: ObservableObject {
    static let shared = DeveloperSettings()

    /// Tools the user has hidden. Settings is deliberately not hideable — it is
    /// the only way back to this menu.
    @Published private(set) var hidden: Set<Page> = []

    private static let key = "developerHiddenTools"
    private let defaults = UserDefaults.standard

    private init() {
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        hidden = Set(stored.compactMap(Page.init(rawValue:)).filter { $0.canBeHidden })
    }

    func isHidden(_ page: Page) -> Bool { hidden.contains(page) }

    /// Applies a whole set at once — the menu edits a draft and commits on
    /// confirmation, so there is no per-toggle write.
    func apply(_ next: Set<Page>) {
        let cleaned = next.filter(\.canBeHidden)
        guard cleaned != hidden else { return }
        hidden = Set(cleaned)
        defaults.set(hidden.map(\.rawValue).sorted(), forKey: Self.key)
    }
}

extension Page {
    /// Settings has to stay: it is the door back to the developer menu, and
    /// hiding it would lock the app into whatever state it was left in.
    var canBeHidden: Bool { self != .settings }

    /// The tools the interface should offer. Everything that walks the page
    /// list goes through this rather than `allCases`.
    @MainActor
    static var available: [Page] {
        allCases.filter { !DeveloperSettings.shared.isHidden($0) }
    }
}

/// The password gate.
///
/// Worth being plain about what this is: a personal convenience lock, not a
/// security boundary. The passphrase is stored as a SHA-256 digest rather than
/// as text — there is no reason to leave it sitting in the binary in the clear —
/// but anyone who can run the app can also read its memory, so this keeps the
/// menu out of the way rather than out of reach.
enum DeveloperGate {
    static func accepts(_ attempt: String) -> Bool {
        // Compared as digests so the passphrase never exists as a literal here.
        hash(attempt) == storedDigest
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Set on first build from the passphrase Dhilan chose, then compared
    /// against every attempt.
    private static let storedDigest = hash("password123")
}

/// The developer menu itself.
///
/// Entered by passphrase every single time — closing it discards the unlock, so
/// coming back means typing it again. Changes are edited as a draft and only
/// written when confirmed, which is why leaving with edits pending asks first.
struct DeveloperMenu: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = DeveloperSettings.shared

    /// Nil until the passphrase is accepted.
    @State private var unlocked = false
    @State private var attempt = ""
    @State private var rejected = false

    /// The edit in progress. Committed on confirm, thrown away on cancel.
    @State private var draft: Set<Page> = []
    @State private var confirming = false

    private var dirty: Bool { draft != settings.hidden }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            DashedRule()
            if unlocked { editor } else { lock }
        }
        .frame(width: 420)
        .background(Theme.panel.grain(0.24))
        .onAppear { draft = settings.hidden }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.orange)
            Text("DEVELOPER")
                .font(Theme.mono(10, .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    // MARK: Locked

    private var lock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Passphrase")
                .font(Theme.sans(12, .medium))
                .foregroundStyle(Theme.textPrimary)
            SecureField("", text: $attempt)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .recessed()
                .onSubmit(attemptUnlock)
            if rejected {
                Text("Not recognised.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.red)
            }
            HStack {
                Spacer()
                Button("Unlock", action: attemptUnlock)
                    .industrialButton(.primary)
                    .disabled(attempt.isEmpty)
            }
        }
        .padding(14)
    }

    private func attemptUnlock() {
        guard DeveloperGate.accepts(attempt) else {
            rejected = true
            attempt = ""
            return
        }
        rejected = false
        attempt = ""
        draft = settings.hidden
        unlocked = true
    }

    // MARK: Unlocked

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools switched off here are removed from the interface entirely — "
                 + "not just hidden, but unreachable — until you switch them back on.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(Page.allCases.filter(\.canBeHidden)) { page in
                    ToolRow(page: page,
                            enabled: !draft.contains(page)) { on in
                        if on { draft.remove(page) } else { draft.insert(page) }
                    }
                }
            }

            HStack(spacing: 8) {
                if dirty {
                    Text("\(draft.symmetricDifference(settings.hidden).count) change(s) pending")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.orange)
                }
                Spacer()
                Button("Close", action: close).industrialButton()
                Button("Apply", action: commit)
                    .industrialButton(.primary)
                    .disabled(!dirty)
            }
        }
        .padding(14)
        .confirmationDialog("Apply the changes you made?",
                            isPresented: $confirming) {
            Button("Apply changes") { commit() }
            Button("Discard", role: .destructive) { draft = settings.hidden; dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Tools you switched off will disappear from the sidebar.")
        }
    }

    private func commit() {
        settings.apply(draft)
        // A tool that just vanished must not be left on screen.
        NavigationModel.shared?.retreatIfUnavailable()
        dismiss()
    }

    /// Leaving with edits pending asks first; leaving clean just closes.
    private func close() {
        if unlocked, dirty { confirming = true } else { dismiss() }
    }
}

/// One tool and its switch.
private struct ToolRow: View {
    let page: Page
    let enabled: Bool
    let change: (Bool) -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: page.systemImage)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Theme.orange : Theme.textMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(page.shortTitle)
                    .font(Theme.sans(13, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(page.badge)
                    .font(Theme.mono(9))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { enabled }, set: change))
                .labelsHidden()
                .toggleStyle(.industrial)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .machined(cornerRadius: Theme.radiusSm)
    }
}
