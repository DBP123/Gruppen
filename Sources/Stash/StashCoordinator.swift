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
    /// The notch's own shelf. Kept across open/close so minimising kee2ps
    /// whatever was on it.
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
    }


    func enable() {
        guard !isEnabled else { return }
        isEnabled = true

        let sentinels = SentinelCoordinator(
            onNotch: { [weak self] in
                self?.openNotch()
                // Anywhere in the approach band counts as being on the tray, so
                // it does not withdraw while you are lining the drop up.
                self?.notchShelf.isTargeted = true
            },
            onNotchExited: { [weak self] in
                self?.notchShelf.isTargeted = false
                self?.scheduleNotchWithdrawal()
            },
            onNotchItems: { [weak self] items in self?.notchShelf.add(items) },
            onNotchDropAccepted: { [weak self] in self?.isNotchPinned = true },
            onEdge: { [weak self] point in self?.manager.spawnShelf(at: point) }
        )
        self.sentinels = sentinels

        let monitor = DragMonitor(
            onShake: { [weak self] point in self?.manager.spawnShelf(at: point) },
            // Sentinels live only for the duration of a drag.
            onDragBegan: { [weak self] in self?.sentinels?.install() },
            onDragEnded: { [weak self] in
                self?.sentinels?.remove()
                self?.handleDragEnded()
            }
        )
        monitor.start()
        dragMonitor = monitor

        applySummonShortcut()
    }

    /// Binds — or rebinds — the global shortcut that summons a shelf.
    ///
    /// Owned separately from the Gruppe hotkeys so re-syncing those cannot drop
    /// this one, and re-applied whenever the setting changes.
    func applySummonShortcut() {
        HotkeyCenter.shared.unregisterAll(owner: "stash")
        guard isEnabled, let shortcut = AppSettings.shared.stashShortcut else { return }
        HotkeyCenter.shared.register(shortcut, owner: "stash") { [weak self] in
            self?.summonShelf()
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
        HotkeyCenter.shared.unregisterAll(owner: "stash")
        closeNotch()
        manager.destroyAll()
    }

    // MARK: Notch

    func openNotch() {
        guard isEnabled, !isNotchOpen else { return }
        isNotchOpen = true
        isNotchPinned = false
        // The sentinels deliberately stay up: the notch band is now the drop
        // target, and it is much larger than the tray. It comes down when the
        // drag ends, as always.

        guard let screen = NSScreen.main else { return }

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
        notchPresentation = presentation

        let host = StashHostingView(
            rootView: AnyView(
                NotchHUDView(
                    onClose: { [weak self] in self?.closeNotch() },
                    // Taking a file *out* no longer dismisses the tray. It used
                    // to, on the theory that the tray should get out of the way
                    // — but it also meant you got one file per opening, and had
                    // to re-summon it for the next. It closes when you close it.
                    onItemDraggedOut: {}
                )
                .environmentObject(notchShelf)
                .environmentObject(presentation)
                .environmentObject(store)
            ),
            registry: registry
        )
        // Empty tray, pointer gone — and only if nothing was ever dropped in it.
        // A tray you have actually used stays until you close it, even after you
        // drag the last thing back out of it.
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

    var openShelfCount: Int { manager.shelfCount + (isNotchOpen ? 1 : 0) }
}
