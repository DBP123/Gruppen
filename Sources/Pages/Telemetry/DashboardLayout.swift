import Foundation
import SwiftUI

/// Where each dashboard card sits, how big it is, and whether it is pinned down.
///
/// Free placement rather than a flow layout: the point of the dashboard is that
/// you arrange it once, the way you read your machine, and it stays that way.
/// A `LazyVGrid` reshuffles every card the moment the window changes width,
/// which is the opposite of that.
///
/// Positions are in points on a canvas whose origin is the top-left of the
/// scroll area, snapped to `Slot.grid`. Snapping is what keeps a hand-arranged
/// board looking deliberate instead of nearly-aligned.
struct Slot: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var locked: Bool = false

    /// Everything snaps to this. Small enough to feel free, large enough that
    /// two cards dragged to "the same" edge actually line up.
    static let grid: CGFloat = 10
    /// Every card starts identical — same width, same height, no exceptions.
    /// Cards whose content is taller than this are clipped until you resize
    /// them, which is the honest consequence of "the same size initially".
    static let defaultSize = CGSize(width: 380, height: 430)
    static let minSize = CGSize(width: 240, height: 150)
    static let gap: CGFloat = 14

    static func snap(_ value: CGFloat) -> CGFloat {
        (value / grid).rounded() * grid
    }

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// The board, persisted.
///
/// Keyed by `WidgetKind.rawValue` so a module that is added or renamed later
/// simply has no stored slot and gets a default one, rather than corrupting the
/// whole layout.
@MainActor
final class DashboardLayout: ObservableObject {
    @Published private(set) var slots: [WidgetKind: Slot] = [:]

    private static let key = "dashboardLayout"
    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: Slot].self, from: data) {
            slots = Dictionary(uniqueKeysWithValues: stored.compactMap { key, slot in
                WidgetKind(rawValue: key).map { ($0, slot) }
            })
        }
    }

    /// The slot for a card, laying one out if this is the first time it has been
    /// shown. New modules land at the end of the board rather than on top of
    /// something that is already there.
    func slot(for kind: WidgetKind, order: [WidgetKind], width: CGFloat) -> Slot {
        if let slot = slots[kind] { return slot }
        return Self.defaultSlot(for: kind, order: order, width: width)
    }

    /// Uniform tiling: every card the same size, filling as many columns as the
    /// window is wide enough for, left to right and then down.
    static func defaultSlot(for kind: WidgetKind, order: [WidgetKind], width: CGFloat) -> Slot {
        let index = order.firstIndex(of: kind) ?? 0
        let columns = max(1, Int((width + Slot.gap) / (Slot.defaultSize.width + Slot.gap)))
        let column = index % columns
        let row = index / columns
        return Slot(x: CGFloat(column) * (Slot.defaultSize.width + Slot.gap),
                    y: CGFloat(row) * (Slot.defaultSize.height + Slot.gap),
                    width: Slot.defaultSize.width,
                    height: Slot.defaultSize.height)
    }

    func move(_ kind: WidgetKind, to origin: CGPoint, in order: [WidgetKind], width: CGFloat) {
        let original = slot(for: kind, order: order, width: width)
        guard !original.locked else { return }
        var slot = original
        // Negative origins would put a card where the canvas cannot scroll to.
        slot.x = max(0, Slot.snap(origin.x))
        slot.y = max(0, Slot.snap(origin.y))
        slot = magnetised(slot, for: kind, order: order, width: width)
        write(slot, for: kind, unchangedFrom: original)
    }

    func resize(_ kind: WidgetKind, to size: CGSize, in order: [WidgetKind], width: CGFloat) {
        let original = slot(for: kind, order: order, width: width)
        guard !original.locked else { return }
        var slot = original
        slot.width = max(Slot.minSize.width, Slot.snap(size.width))
        slot.height = max(Slot.minSize.height, Slot.snap(size.height))
        slot = magnetisedEdges(slot, for: kind, order: order, width: width)
        write(slot, for: kind, unchangedFrom: original)
    }

    // MARK: Alignment

    /// How close a card has to come to a neighbour's edge before it snaps to it.
    ///
    /// The 10pt grid alone is not enough to keep a board tidy: two cards of
    /// different heights snapped to the grid can still sit 10pt out of line,
    /// which reads as sloppy rather than as a choice. This pulls a dragged card
    /// onto the edges of the cards already placed, so rows and columns line up
    /// exactly without anyone having to aim.
    private static let magnet: CGFloat = 14

    /// Snap a moved card's leading and top edges to its neighbours.
    ///
    /// Four candidates per axis, which between them cover every way two cards
    /// can look aligned: flush left, flush right, and butted up on either side
    /// with one gap between.
    private func magnetised(_ proposed: Slot, for kind: WidgetKind,
                            order: [WidgetKind], width: CGFloat) -> Slot {
        var result = proposed
        var bestX: CGFloat?, bestY: CGFloat?
        var nearestX = Self.magnet, nearestY = Self.magnet

        for other in order where other != kind {
            let neighbour = slot(for: other, order: order, width: width)
            for candidate in [neighbour.x,
                              neighbour.x + neighbour.width - proposed.width,
                              neighbour.x + neighbour.width + Slot.gap,
                              neighbour.x - proposed.width - Slot.gap] {
                let distance = abs(candidate - proposed.x)
                if distance < nearestX { nearestX = distance; bestX = candidate }
            }
            for candidate in [neighbour.y,
                              neighbour.y + neighbour.height - proposed.height,
                              neighbour.y + neighbour.height + Slot.gap,
                              neighbour.y - proposed.height - Slot.gap] {
                let distance = abs(candidate - proposed.y)
                if distance < nearestY { nearestY = distance; bestY = candidate }
            }
        }
        if let bestX { result.x = max(0, bestX) }
        if let bestY { result.y = max(0, bestY) }
        return result
    }

    /// The same idea for a resize: it is the trailing and bottom edges that move,
    /// so those are what should land on a neighbour's edge.
    private func magnetisedEdges(_ proposed: Slot, for kind: WidgetKind,
                                 order: [WidgetKind], width: CGFloat) -> Slot {
        var result = proposed
        var bestRight: CGFloat?, bestBottom: CGFloat?
        var nearestRight = Self.magnet, nearestBottom = Self.magnet
        let right = proposed.x + proposed.width
        let bottom = proposed.y + proposed.height

        for other in order where other != kind {
            let neighbour = slot(for: other, order: order, width: width)
            for candidate in [neighbour.x + neighbour.width, neighbour.x - Slot.gap] {
                let distance = abs(candidate - right)
                if distance < nearestRight { nearestRight = distance; bestRight = candidate }
            }
            for candidate in [neighbour.y + neighbour.height, neighbour.y - Slot.gap] {
                let distance = abs(candidate - bottom)
                if distance < nearestBottom { nearestBottom = distance; bestBottom = candidate }
            }
        }
        if let bestRight { result.width = max(Slot.minSize.width, bestRight - proposed.x) }
        if let bestBottom { result.height = max(Slot.minSize.height, bestBottom - proposed.y) }
        return result
    }

    func isLocked(_ kind: WidgetKind) -> Bool { slots[kind]?.locked ?? false }

    func toggleLock(_ kind: WidgetKind, in order: [WidgetKind], width: CGFloat) {
        let original = slot(for: kind, order: order, width: width)
        var slot = original
        slot.locked.toggle()
        write(slot, for: kind, unchangedFrom: original)
    }

    /// Back to the uniform grid. Locks go with it — a reset that left cards
    /// pinned would not be a reset.
    func reset() {
        guard !slots.isEmpty else { return }
        slots.removeAll()
        defaults.removeObject(forKey: Self.key)
    }

    /// Whether anything has actually been arranged, so the reset button can say
    /// whether it would do anything.
    ///
    /// "Has a stored slot" is the wrong test: locking a card and unlocking it
    /// again leaves an entry behind that is identical to the default, and the
    /// board would then claim to be arranged when it is not. What counts is
    /// whether any stored slot *differs* from where the default would put it.
    func isCustomised(order: [WidgetKind], width: CGFloat) -> Bool {
        slots.contains { kind, slot in
            slot != Self.defaultSlot(for: kind, order: order, width: width)
        }
    }

    /// How tall the canvas has to be to contain the board.
    func canvasHeight(for order: [WidgetKind], width: CGFloat) -> CGFloat {
        let bottom = order.reduce(CGFloat.zero) { tallest, kind in
            let slot = slot(for: kind, order: order, width: width)
            return max(tallest, slot.y + slot.height)
        }
        return bottom + Slot.gap
    }

    /// `unchangedFrom` is the slot the card had before the gesture — its stored
    /// one, or its default if it had never been touched.
    ///
    /// A drag that ends in the same grid cell it started in has not arranged
    /// anything, and neither has one that lands exactly where the default put
    /// it. Without this guard a plain click on a card's header counted as a
    /// layout change: the board read as "ARRANGED", the reset button lit up for
    /// a board identical to the default, and every click cost a write to disk.
    private func write(_ slot: Slot, for kind: WidgetKind, unchangedFrom original: Slot) {
        guard slot != original else { return }
        slots[kind] = slot
        persist()
    }

    /// Drop stored slots that have drifted back to exactly where the default
    /// would put them, so the board does not accumulate entries that say
    /// nothing — and so a widened window can go on reflowing those cards.
    func tidy(order: [WidgetKind], width: CGFloat) {
        let redundant = slots.filter { $0.value == Self.defaultSlot(for: $0.key, order: order, width: width) }
        guard !redundant.isEmpty else { return }
        for key in redundant.keys { slots.removeValue(forKey: key) }
        persist()
    }

    private func persist() {
        let encodable = Dictionary(uniqueKeysWithValues: slots.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
