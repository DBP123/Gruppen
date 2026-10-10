import AppKit
import SwiftUI

/// Ties the passive triggers to the windows they open.
///
/// The notch has one persistent shelf (there is only one notch); shakes and
/// screen edges spawn independent floating shelves through
/// `ShelfWindowManager`. Nothing here runs on a schedule — every method below
/// is called from a system event.
@MainActor
final class StashCoordinator: ObservableObject {
    /// The notch's own stash. Kept across open and close unless the close key
    /// is set to clear it — see `dismissNotch`.
    let notchShelf = ShelfState()
    /// Needed by the routing chips inside the HUD.
    private let store: GroupStore
    @Published private(set) var isNotchOpen = false
    /// Set once something has been dropped in. A loaded HUD stays put — losing
    /// it the instant a file lands reads as the file having been taken away.
    private var isNotchPinned = false

    private let manager = ShelfWindowManager.shared
    private var sentinels: SentinelCoordinator?
    private var dragMonitor: DragMonitor?
    private var notchPanel: StashPanel?
    /// Held for the lifetime of the panel: the hosting view's drop callbacks
    /// live here.
    private var notchRegistry: DropZoneRegistry?
    /// Drives the slide. Held here because the drag session that decides to show
    /// or retract the tray is something only the coordinator can see.
    private var notchPresentation: NotchPresentation?
    /// The pending "you have left, so I will close" — cancellable, because
    /// coming back within the grace period means you never left.
    private var withdrawalTask: Task<Void, Never>?

    private(set) var isEnabled = false

    init(store: GroupStore) {
        self.store = store
        // Shelves render routing chips, which need the one true store.
        ShelfWindowManager.shared.store = store
        // Anything left in scratch belongs to a previous run: shelves do not
        // survive a relaunch, so nothing still there is referenced.
        IngestionManager.purgeScratch()
        // A notch stash with nothing left on it has nothing left to show, so it
        // slides away by itself — the same retraction as its close key. Only
        // on *becoming* empty: a tray opened by a drag and not yet dropped on
        // is empty too, and that one is governed by the withdrawal below.
        notchShelf.onEmptied = { [weak self] in self?.closeNotch() }
    }


    func enable() {
        guard !isEnabled else { return }
        isEnabled = true

        let sentinels = SentinelCoordinator(
            // Approaching the notch slides the tray out and does nothing else.
            // It deliberately does *not* mark the shelf as targeted: that is the
            // "release here" state, and being somewhere in a 190pt band is not
            // being on the tray. Lighting it up from across the screen was how
            // the approach came to feel like a claim on the drag.
            onNotch: { [weak self] in self?.openNotch() },
            onEdge: { [weak self] point in self?.manager.spawnShelf(at: point) },
            notchWanted: { AppSettings.shared.stashNotchEnabled },
            edgesWanted: { AppSettings.shared.stashEdgeEnabled }
        )
        self.sentinels = sentinels

        let monitor = DragMonitor(
            onShake: { [weak self] point in self?.manager.spawnShelf(at: point) },
            // Sentinels live only for the duration of a drag.
            onDragBegan: { [weak self] in
                self?.sentinels?.install()
                // A tray left open with files on it becomes a full drop
                // target again for the length of the new drag.
                self?.notchPresentation?.isDragging = true
            },
            onDragEnded: { [weak self] in
                self?.sentinels?.remove()
                self?.notchPresentation?.isDragging = false
                self?.handleDragEnded()
            },
            shakeWanted: { AppSettings.shared.stashShakeEnabled }
        )
        monitor.start()
        dragMonitor = monitor

        // An iPad arriving or leaving moves where the notch is. The manager
        // coalesces the burst of parameter changes and reports once.
        NotchGeometryManager.shared.onChange = { [weak self] _ in self?.reanchorNotch() }

        applyShortcuts()
    }

    /// Binds — or rebinds — the stash's two global shortcuts: one summons a
    /// shelf, the other hides or shows them all.
    ///
    /// Owned separately from the Gruppe hotkeys so re-syncing those cannot drop
    /// these, and re-applied whenever either setting changes.
    func applyShortcuts() {
        HotkeyCenter.shared.unregisterAll(owner: "stash")
        guard isEnabled else { return }
        if let summon = AppSettings.shared.stashShortcut {
            HotkeyCenter.shared.register(summon, owner: "stash") { [weak self] in self?.summonShelf() }
        }
        if let toggle = AppSettings.shared.stashToggleShortcut {
            HotkeyCenter.shared.register(toggle, owner: "stash") { [weak self] in self?.manager.toggleHidden() }
        }
    }

    /// Puts a shelf under the pointer, in front of everything.
    ///
    /// Floating shelves sit at `.floating` level, so this comes up over full
    /// screen apps and anything else on the desktop. An empty shelf that is
    /// already open moves to the pointer rather than a second one appearing.
    func summonShelf() {
        guard isEnabled else { return }
        manager.spawnShelf(at: NSEvent.mouseLocation)
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        sentinels?.remove()
        sentinels = nil
        dragMonitor?.stop()
        dragMonitor = nil
        NotchGeometryManager.shared.onChange = nil
        HotkeyCenter.shared.unregisterAll(owner: "stash")
        closeNotch()
        manager.destroyAll()
    }

    // MARK: Notch

    func openNotch() {
        guard isEnabled, !isNotchOpen else { return }
        isNotchOpen = true
        isNotchPinned = false
        // The band that summoned this has already retired itself, so the tray
        // below is now the only thing near the notch that can take a drop.

        guard let screen = NotchGeometryManager.shared.screen else { return }

        let registry = DropZoneRegistry()
        registry.onTargetChanged = { [weak self] targeted in
            guard let self else { return }
            self.notchShelf.isTargeted = targeted
            // Leaving the tray withdraws it; there is nothing to keep on screen
            // once the drag has moved on. Coming back cancels it.
            if targeted { self.cancelNotchWithdrawal() } else { self.scheduleNotchWithdrawal() }
        }
        // Synchronously, before any bytes are read: the drag ends the moment the
        // mouse comes up, and a loaded tray has to survive that.
        registry.onDropAccepted = { [weak self] in self?.isNotchPinned = true }
        registry.onItems = { [weak self] items in self?.notchShelf.add(items) }
        notchRegistry = registry

        let presentation = NotchPresentation()
        // Only ever opened by a drag crossing the notch tripwire, so one is in
        // progress by definition.
        presentation.isDragging = true
        notchPresentation = presentation

        let host = StashHostingView(
            rootView: AnyView(
                // Taking a file *out* does not dismiss the tray while anything
                // is left on it — dismissing on every drag-out meant one file
                // per opening. It closes when you close it, or when the last
                // item leaves (see `onEmptied` in `init`).
                NotchHUDView(onClose: { [weak self] in self?.dismissNotch() })
                .environmentObject(notchShelf)
                .environmentObject(presentation)
                .environmentObject(store)
            ),
            registry: registry
        )
        // Empty tray, pointer gone — and only if nothing was ever dropped in it.
        // A tray you have actually used is closed by its last item leaving, not
        // by the pointer.
        //
        // Deferred, and cancelled by coming back. Acting on the exit itself is
        // what made the tray flicker: every twitch across the boundary was a
        // withdrawal, and the next twitch back was a re-open.
        host.onMouseExited = { [weak self] in
            guard let self, self.notchShelf.isEmpty, !self.isNotchPinned else { return }
            self.scheduleNotchWithdrawal()
        }
        host.onMouseEntered = { [weak self] in self?.cancelNotchWithdrawal() }

        // maxY == screen.frame.maxY, exactly, and the sides taken from the notch
        // itself. See `NotchHUDView.frame(on:)`.
        let rect = NotchHUDView.frame(on: screen)
        let panel = StashPanel(size: rect.size, content: host, attachedToScreenTop: true)
        panel.setFrameOrigin(rect.origin)
        panel.orderFrontRegardless()
        notchPanel = panel

        // Ordered front retracted, then released on the next runloop turn so the
        // spring has a state change to animate from. Without the hop, SwiftUI
        // sees only the final value and the tray is simply *there*.
        DispatchQueue.main.async { presentation.isVisible = true }
    }

    /// The close key: put the tray away, emptying it first if that is what
    /// the setting asks for.
    ///
    /// Clearing a stash that holds something closes it by itself, through
    /// `onEmptied`; the explicit close after it covers an empty tray, which has
    /// no emptying to report, and is a no-op otherwise.
    private func dismissNotch() {
        if AppSettings.shared.notchCloseClearsStash { notchShelf.clear() }
        closeNotch()
    }

    func closeNotch() {
        cancelNotchWithdrawal()
        guard let panel = notchPanel, let presentation = notchPresentation else { return }
        isNotchOpen = false
        isNotchPinned = false
        notchPanel = nil
        notchPresentation = nil
        notchRegistry = nil

        // Slides back up behind the bezel; the window is only ordered out once
        // it is out of sight, so the retraction is visible rather than a
        // disappearance. It stops taking mouse events immediately, though —
        // for that half second it is an invisible window sitting over the menu
        // bar, and it must not swallow a click or a drag meant for the sentinel.
        panel.ignoresMouseEvents = true
        presentation.isVisible = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 520_000_000)
            panel.orderOut(nil)
        }
    }

    /// The display topology changed while the tray was out.
    ///
    /// The window is moved rather than rebuilt: the tray may be holding files,
    /// and closing it to re-open it somewhere else would read as the shelf
    /// having thrown them away. The contents redraw on their own — the tray's
    /// width comes from the manager's `@Published` anchor — so this only has to
    /// put the window where the notch now is.
    ///
    /// If the anchor display is gone outright (lid closed, built-in asleep with
    /// only the iPad left), the tray closes. A panel pinned to coordinates that
    /// no longer map to a screen is not recoverable by moving it.
    private func reanchorNotch() {
        guard isNotchOpen, let panel = notchPanel else { return }
        guard let screen = NotchGeometryManager.shared.screen else {
            GroupStore.log("NOTCH anchor display gone — closing tray")
            closeNotch()
            return
        }
        let rect = NotchHUDView.frame(on: screen)
        guard panel.frame != rect else { return }
        panel.setFrame(rect, display: true)
        GroupStore.log("NOTCH re-anchored -> \(rect) — "
                       + NotchGeometryManager.shared.topologyDescription)
    }

    /// The pointer or the drag left the notch.
    ///
    /// Held for a moment rather than acted on, and cancelled if whatever left
    /// comes back. A boundary crossing is not an intention: skimming the edge,
    /// overshooting into the bezel and dropping back, or the few pixels between
    /// the tray and the buffer all used to read as "gone" and close the tray,
    /// which is exactly the flicker.
    private static let withdrawalGrace: TimeInterval = 0.35

    private func scheduleNotchWithdrawal() {
        withdrawalTask?.cancel()
        withdrawalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.withdrawalGrace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isNotchOpen, !self.isNotchPinned, !self.notchShelf.isTargeted else { return }
            self.withdrawalTask = nil
            self.closeNotch()
            self.rearmSentinels()
        }
    }

    private func cancelNotchWithdrawal() {
        withdrawalTask?.cancel()
        withdrawalTask = nil
    }

    /// Puts the invisible triggers back after the HUD withdraws.
    ///
    /// Opening the notch takes the sentinels down so the HUD itself receives the
    /// drop. Nothing used to put them back, so leaving the HUD and returning to
    /// the notch within the same drag hit nothing at all — the trigger had been
    /// spent. The guard is what keeps this safe: sentinels are only restored
    /// while the button is still down, so they can never outlive the drag and
    /// start swallowing menu bar clicks.
    private func rearmSentinels() {
        guard isEnabled, dragMonitor?.isDragging == true else { return }
        sentinels?.install()
    }

    /// A drag finished. Anything opened speculatively that never received a
    /// drop fades away rather than sitting there.
    private func handleDragEnded() {
        manager.dismissEmptySpeculativeShelves()
        if isNotchOpen, !isNotchPinned, !notchShelf.isTargeted { closeNotch() }
    }
}
