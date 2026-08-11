import AppKit
import SwiftUI

/// One shelf's contents. Every floating shelf gets its own, so two shelves on
/// screen never share a bucket.
@MainActor
final class ShelfState: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var items: [StashItem] = []
    /// True while a drag is hovering this shelf — used to hold a shelf open
    /// that would otherwise fade for being empty.
    @Published var isTargeted = false

    /// Which items are picked out. Click selects one, shift-click adds to the
    /// set; zip and convert act on the selection when there is one and on the
    /// whole shelf when there is not.
    @Published var selection: Set<UUID> = []

    /// Called when the shelf goes from holding something to holding nothing —
    /// the last item dragged out, or cleared. Not called for a shelf that was
    /// never filled, which is what lets a speculatively-opened shelf sit there
    /// waiting for a drop instead of closing the instant it appears.
    var onEmptied: (() -> Void)?

    init(id: UUID = UUID(), items: [StashItem] = []) {
        self.id = id
        self.items = items
    }

    var isEmpty: Bool { items.isEmpty }

    func add(_ newItems: [StashItem]) {
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
    }

    func remove(_ item: StashItem) {
        let wasFilled = !items.isEmpty
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        if wasFilled, items.isEmpty { onEmptied?() }
    }

    func clear() {
        let wasFilled = !items.isEmpty
        items.removeAll()
        selection.removeAll()
        if wasFilled { onEmptied?() }
    }

    /// Plain click replaces the selection; shift-click extends it. Clicking the
    /// only selected item clears it, so there is always a way back to "no
    /// selection" without hunting for empty space.
    func select(_ item: StashItem, extending: Bool) {
        if extending {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if selection == [item.id] {
            selection.removeAll()
        } else {
            selection = [item.id]
        }
    }

    /// What an action should act on: the selection if there is one, otherwise
    /// everything.
    var actionable: [StashItem] {
        selection.isEmpty ? items : items.filter { selection.contains($0.id) }
    }
}

/// Owns every floating shelf on screen.
///
/// A shake spawns a *new* shelf with its own window, its own state and its own
/// identity, so you can carry several piles at once. A shelf destroys itself
/// when it is emptied, minimised, or when it was opened speculatively and the
/// drag ended without anything being dropped on it.
@MainActor
final class ShelfWindowManager: ObservableObject {
    static let shared = ShelfWindowManager()

    @Published private(set) var activeShelves: [UUID: FloatingShelfController] = [:]

    /// Set once by the coordinator. Shelves need it for their routing chips;
    /// there is exactly one store in the app and re-reading it per shelf would
    /// mean several objects disagreeing about what is running.
    weak var store: GroupStore?

    var shelfCount: Int { activeShelves.count }

    private init() {}

    @discardableResult
    func spawnShelf(at point: NSPoint, with urls: [URL] = []) -> UUID {
        // Shaking repeatedly used to breed a new empty shelf every time. If one
        // is already open and still empty, move it to the pointer instead —
        // there is nothing on it to keep in its old place.
        if urls.isEmpty,
           let (id, existing) = activeShelves.first(where: { $0.value.state.isEmpty }) {
            existing.move(to: point)
            return id
        }

        let state = ShelfState(items: urls.map { $0.isFileURL ? StashItem.file($0) : StashItem.link($0) })
        let controller = FloatingShelfController(state: state, anchor: point) { [weak self] id in
            self?.destroyShelf(id: id)
        }
        // Emptying a shelf closes it: an empty shelf you have already used is
        // just a box in the way.
        state.onEmptied = { [weak self] in
            Task { @MainActor in self?.destroyShelf(id: state.id, scaling: true) }
        }
        activeShelves[state.id] = controller
        controller.present(store: store)
        return state.id
    }

    func destroyShelf(id: UUID, scaling: Bool = false) {
        guard let controller = activeShelves[id] else { return }
        controller.dismiss(scaling: scaling) { [weak self] in
            self?.activeShelves.removeValue(forKey: id)
        }
    }

    func destroyAll() {
        activeShelves.keys.forEach { destroyShelf(id: $0) }
    }

    /// Called when a drag session ends. A shelf that was opened by a shake but
    /// never received anything fades out rather than lingering.
    func dismissEmptySpeculativeShelves() {
        for (id, controller) in activeShelves where controller.state.isEmpty && !controller.state.isTargeted {
            destroyShelf(id: id)
        }
    }
}

/// One floating shelf window.
@MainActor
final class FloatingShelfController {
    let state: ShelfState

    static let size = NSSize(width: 300, height: 200)

    private var panel: FloatingShelfPanel?
    private var registry: DropZoneRegistry?
    private let anchor: NSPoint
    private let onDestroy: (UUID) -> Void

    init(state: ShelfState, anchor: NSPoint, onDestroy: @escaping (UUID) -> Void) {
        self.state = state
        self.anchor = anchor
        self.onDestroy = onDestroy
    }

    func present(store: GroupStore?) {
        guard panel == nil else { return }

        let registry = DropZoneRegistry()
        registry.onTargetChanged = { [weak state] targeted in state?.isTargeted = targeted }
        registry.onItems = { [weak state] items in state?.add(items) }
        // `onZoneItems` is installed by the routing row itself, so a Gruppe that
        // refuses a file lights its own lamp.
        self.registry = registry

        let host = StashHostingView(
            rootView: AnyView(
                StashTrayView(
                    onMinimize: { [weak self] in
                        guard let self else { return }
                        self.onDestroy(self.state.id)
                    },
                    store: store
                )
                .environmentObject(state)
                .environmentObject(AppSettings.shared)
                .environment(\.dropZones, registry)
                .coordinateSpace(name: stashRootSpace)
            ),
            registry: registry
        )
        let panel = FloatingShelfPanel(size: Self.size, content: host)
        panel.setFrameOrigin(Self.origin(near: anchor, size: Self.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        // Spring in.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Gentle fade, then close. `scaling` collapses the window toward its own
    /// centre on the way out — used when the last item is dragged off, so the
    /// shelf visibly follows the thing that was on it rather than blinking away.
    func dismiss(scaling: Bool = false, completion: @escaping () -> Void) {
        guard let panel else { completion(); return }
        let collapsed = NSRect(x: panel.frame.midX, y: panel.frame.midY,
                               width: 0, height: 0).insetBy(dx: -8, dy: -6)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = scaling ? 0.18 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if scaling { panel.animator().setFrame(collapsed, display: false) }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                self?.panel = nil
                completion()
            }
        }
    }

    /// Repositions an already-open shelf, used when a second shake arrives.
    func move(to point: NSPoint) {
        guard let panel else { return }
        panel.setFrameOrigin(Self.origin(near: point, size: Self.size))
        panel.orderFrontRegardless()
    }

    static func origin(near point: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: point.x + 16, y: point.y - size.height - 16)
        if origin.x + size.width > visible.maxX { origin.x = point.x - size.width - 16 }
        if origin.y < visible.minY { origin.y = point.y + 16 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }
}
