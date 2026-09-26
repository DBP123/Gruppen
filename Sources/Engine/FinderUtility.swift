import AppKit
import Foundation

/// Shows a file in Finder, and makes sure Finder is the app you are looking at.
///
/// ## Why this is not one line
///
/// `NSWorkspace.activateFileViewerSelecting(_:)` does two things — it asks Finder
/// to open a window on the file's folder and highlight the file, and it *asks*
/// for Finder to come forward. The second half is a request, not a guarantee, and
/// there are two situations in this app where it does not land:
///
/// 1. **Finder was not running.** The call launches it, and a launching app's
///    first window arrives some time after the call returns. Whatever activation
///    happened at call time happened before there was a window to raise.
/// 2. **The caller is a panel.** Every stash is an `NSPanel` that deliberately
///    never becomes key (see `FloatingShelfPanel`), and the menu bar popover is
///    another. Reveal is pressed from inside one of those, so Gruppen is often
///    mid-activation itself at the moment it asks Finder to activate — two apps
///    both claiming the foreground, and the last writer wins.
///
/// So the activation is stated explicitly rather than left implicit, and stated
/// twice: once now, and once after a beat for the case where Finder had to start
/// first. The second call is cheap and idempotent — activating the app that is
/// already frontmost does nothing.
///
/// ## What it does not do
///
/// It does not use Apple events, `osascript`, or an `NSAppleScript` to drive
/// Finder. Those need Automation consent, which means a permission dialog the
/// first time and a silent failure ever after if it is declined — an enormous
/// price for raising a window. `activateFileViewerSelecting` plus
/// `NSRunningApplication.activate` needs no entitlement and no consent.
enum FinderUtility {
    /// Finder's bundle identifier. Fixed since Mac OS X 10.0 and not worth a
    /// lookup, but named rather than inlined so the two uses cannot drift.
    static let finderBundleID = "com.apple.finder"

    /// How long to wait before the second activation.
    ///
    /// Only load-bearing in the cold-Finder case, where it covers the gap
    /// between "Finder has been asked to launch" and "Finder has a window".
    /// Short enough not to read as a delay, long enough to be after a launch
    /// that was already in flight.
    private static let settle: TimeInterval = 0.15

    /// What a reveal request comes down to once the filesystem has had its say.
    ///
    /// Separated from the act of doing it so the decision can be tested: driving
    /// Finder is a side effect on another process, and "did it pick the right
    /// files" is a question that should not require one.
    enum Outcome: Equatable {
        /// Highlight these, in one window.
        case reveal([URL])
        /// Nothing asked for still exists, but its folder does — which is where
        /// it was, and usually where the reason it is gone is visible.
        case openFolder(URL)
        /// Neither the files nor the folder are there. Say so; do not open the
        /// user's home directory as a consolation prize.
        case nothing
    }

    /// Decides what should happen, touching nothing.
    ///
    /// `standardizedFileURL` resolves `..`, collapses `//` and strips the
    /// trailing slash a directory URL carries. Finder matches the file it is
    /// asked to highlight by path, so `/tmp/./a.txt` and `/tmp/a.txt` are the
    /// same file to the filesystem and two different requests to Finder.
    ///
    /// Files that have since been moved or deleted are dropped rather than
    /// failing the batch: revealing the four extracted archives that are still
    /// there beats revealing none of them because a fifth was cleaned up.
    static func resolve(_ urls: [URL]) -> Outcome {
        let standardized = urls.map(\.standardizedFileURL)
        let existing = standardized.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { return .reveal(existing) }

        guard let parent = standardized.first?.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath: parent.path) else { return .nothing }
        return .openFolder(parent)
    }

    /// Reveals one file and brings Finder to the front.
    @MainActor @discardableResult
    static func revealAndFocus(url: URL) -> Bool {
        revealAndFocus(urls: [url])
    }

    /// Reveals several files — one window, all of them highlighted — and brings
    /// Finder to the front.
    ///
    /// Returns false when there was nothing left to highlight. The caller is the
    /// only thing that can say something useful about that, so it is reported
    /// rather than swallowed.
    @MainActor @discardableResult
    static func revealAndFocus(urls: [URL]) -> Bool {
        switch resolve(urls) {
        case .reveal(let existing):
            NSWorkspace.shared.activateFileViewerSelecting(existing)
            focusFinder()
            return true
        case .openFolder(let parent):
            NSWorkspace.shared.open(parent)
            focusFinder()
            return false
        case .nothing:
            return false
        }
    }

    /// Brings Finder forward now, and again once it has had time to appear.
    @MainActor
    private static func focusFinder() {
        activateFinder()
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { activateFinder() }
    }

    /// One activation attempt. Silent when Finder is not running yet — the
    /// deferred second attempt is what covers that.
    @MainActor
    private static func activateFinder() {
        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: finderBundleID).first else { return }
        // `activate(options:)` is deprecated from macOS 14, where the
        // no-argument form does the same job. Both are kept because the app
        // ships back to macOS 13, and calling the deprecated spelling there is
        // not a warning — it is the only spelling that exists.
        if #available(macOS 14.0, *) {
            finder.activate()
        } else {
            finder.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
