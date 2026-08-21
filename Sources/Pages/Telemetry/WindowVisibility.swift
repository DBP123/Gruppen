import AppKit
import SwiftUI

/// Whether the window this view is actually in is on screen.
///
/// `scenePhase` is the SwiftUI answer and it is the wrong one here: on macOS it
/// reports the *scene's* activation, which stays `.active` for a window that has
/// been minimised into the Dock or completely covered by another app.
///
/// The first version of this scanned `NSApp.windows` for any visible window, and
/// it did not work: Gruppen owns one `NSStatusBarWindow` per menu bar item, and
/// those are always visible, so minimising the main window changed nothing and
/// the dashboard kept sampling — measured at 2.6% of a core against 0.7% for the
/// same app on another page. Binding to the host view's own window is both
/// correct and simpler, since AppKit already reports miniaturisation and
/// occlusion per window.
@MainActor
final class WindowVisibility: ObservableObject {
    @Published private(set) var isVisible = true

    func update(_ visible: Bool) {
        if isVisible != visible { isVisible = visible }
    }
}

/// A zero-size view whose only job is to find the window it was put in and
/// report when that window comes and goes.
struct WindowVisibilityProbe: NSViewRepresentable {
    let report: (Bool) -> Void
    let reportFocus: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = report
        probe.reportFocus = reportFocus
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.report = report
        probe.reportFocus = reportFocus
    }

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        var reportFocus: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        /// Occlusion, as last *reported*. Deliberately not read straight off the
        /// window at publish time.
        ///
        /// AppKit guarantees it will tell you when occlusion changes; it does not
        /// guarantee the property is settled the moment a view is added. A
        /// hosting view attaches while the window server is still bringing the
        /// window up, so reading `occlusionState` there returns "not visible" for
        /// a window that is about to be on screen — and because no *change*
        /// follows, nothing ever corrects it. That cost the dashboard its
        /// modules on first appearance until the test caught it. So the initial
        /// assumption is "on screen", and only an actual notification moves it.
        private var occluded = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            unhook()
            guard let window else { report?(false); return }

            let center = NotificationCenter.default
            // Per-window, so another window's state cannot answer for this one.
            tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                             object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let window = note.object as? NSWindow
                    self.occluded = !(window?.occlusionState.contains(.visible) ?? false)
                    self.publish()
                }
            })
            tokens.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification,
                                             object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
            // Coming back from the Dock or from ⌘H invalidates the last
            // occlusion reading rather than confirming it: the window was
            // occluded *because* it was away. Clearing the flag lets a genuine
            // occlusion — the window really is behind something — report itself
            // again, instead of a stale `true` keeping the dashboard dark after
            // it is plainly back on screen.
            tokens.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification,
                                             object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restored() }
            })
            // ⌘H hides the app without touching any window's occlusion state.
            tokens.append(center.addObserver(forName: NSApplication.didHideNotification,
                                             object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
            tokens.append(center.addObserver(forName: NSApplication.didUnhideNotification,
                                             object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restored() }
            })
            // Whether Gruppen is the app in use. Not a visibility signal — it
            // only ever changes the rate — so it is reported on its own channel.
            for name in [NSApplication.didBecomeActiveNotification,
                         NSApplication.didResignActiveNotification] {
                tokens.append(center.addObserver(forName: name, object: nil,
                                                 queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportFocus?(NSApp.isActive) }
                })
            }
            reportFocus?(NSApp.isActive)
            occluded = false
            publish()
        }

        deinit { unhook() }

        private func unhook() {
            let center = NotificationCenter.default
            for token in tokens { center.removeObserver(token) }
            tokens.removeAll()
        }

        @MainActor
        private func restored() {
            occluded = false
            publish()
        }

        @MainActor
        private func publish() {
            guard let window else { report?(false); return }
            report?(window.isVisible && !window.isMiniaturized && !NSApp.isHidden && !occluded)
        }
    }
}
