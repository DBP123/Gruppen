import AppKit
import SwiftUI

// MARK: - The card
//
// Split out of `TelemetryDashboardView.swift`: the page decides *which* cards
// exist and when they may sample; a card owns its own chrome, its gestures and
// its controls. They were one file and the page's lifecycle rules kept getting
// read as if they were the card's.

/// One module, as a card you can move, resize, lock and freeze.
///
/// The readout is the same view the module's menu bar popover shows — extracted
/// so there is exactly one description of what a processor readout looks like,
/// and the card and the popover cannot drift apart.
struct TelemetryCard: View {
    let kind: WidgetKind
    let slot: Slot
    @ObservedObject var layout: DashboardLayout
    let order: [WidgetKind]
    let canvasWidth: CGFloat

    @ObservedObject private var manager = WidgetManager.shared
    @State private var hovering = false
    /// Live offsets while a gesture is in flight. Committed to the layout on
    /// release, so a drag is one write to disk rather than one per frame.
    @State private var dragOffset: CGSize = .zero
    @State private var sizeOffset: CGSize = .zero
    /// The captured picture of the readout, taken at the moment of freezing.
    @State private var frozenImage: NSImage?

    private var locked: Bool { slot.locked }
    private var frozen: Bool { manager.isFrozen(kind) }

    /// The drag handle. Deliberately the whole header strip, so "grab the top of
    /// the widget" is literally true.
    private static let headerHeight: CGFloat = 26
    /// How far in from an edge still counts as the edge.
    private static let edge: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            DashedRule()
            // A readout taller than the card scrolls inside it rather than being
            // cut off with no way to see the rest. The scroll view only takes
            // over the wheel when its content actually overflows, so on a card
            // big enough for its readout the page still scrolls normally.
            ScrollView(.vertical, showsIndicators: false) {
                readout.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: slot.width + sizeOffset.width,
               height: slot.height + sizeOffset.height,
               alignment: .topLeading)
        // The card is the size you set it to; nothing inside it pushes it open.
        .clipped()
        .machined(cornerRadius: Theme.radiusMd, fill: Theme.housing)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .strokeBorder(borderTint, lineWidth: 1)
        }
        .offset(dragOffset)
        .zIndex(dragOffset == .zero && sizeOffset == .zero ? 0 : 1)
        .onHover { hovering = $0 }
        // Order matters, and it is the reason the controls used to slip away as
        // you reached for them. The drag strip and the resize edges all carry
        // gestures, and a later overlay sits *on top* of an earlier one — so
        // with the controls added first, the strip covered them and the press
        // landed on the drag gesture instead of the button. The controls go
        // last, so nothing is ever in front of them.
        // The resize edges stay overlays — they belong on the card's border and
        // nothing else wants those pixels. The trailing one is held clear of the
        // header, because that 7pt strip runs the full height and would
        // otherwise sit on top of the rightmost button.
        .overlay(alignment: .trailing) {
            resizeEdge(.horizontal).padding(.top, Self.headerHeight)
        }
        .overlay(alignment: .bottom) { resizeEdge(.vertical) }
        .overlay(alignment: .bottomTrailing) { resizeCorner }
    }

    private var borderTint: Color {
        if frozen { return Theme.cyan.opacity(0.45) }
        if locked { return Theme.textMuted.opacity(0.30) }
        return hovering ? Color.white.opacity(0.16) : Color.white.opacity(0.07)
    }

    // MARK: Contents

    /// Title on the left, controls on the right, and the move handle *behind*
    /// both.
    ///
    /// This is the third attempt at making these buttons clickable, and the
    /// first two failed for the same reason: the controls were an `overlay`,
    /// competing for hit testing with two other overlays that carry gestures —
    /// the move strip and the trailing resize edge — while being gated on a
    /// hover flag that had to propagate before they would accept a press.
    /// Tuning z-order and padding only moved which of those won.
    ///
    /// So none of that is load-bearing any more. The buttons are ordinary views
    /// in an `HStack`, exactly like every other button in the app, and the drag
    /// gesture lives in the row's `background` — behind them by construction, so
    /// a press on a button reaches the button and a press anywhere else in the
    /// row starts a move. There is no ordering to get wrong.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.glyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.domain(kind.domainIndex))
            Text(kind.header)
                .font(Theme.mono(9, .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if frozen {
                Text("FROZEN")
                    .font(Theme.mono(8, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.cyan)
                    .fixedSize()
            }
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            controls
        }
        .frame(height: Self.headerHeight)
        .background(moveHandle)
    }

    /// The move handle: the whole header row, *behind* its contents.
    private var moveHandle: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onHover { inside in
                guard !locked else { return }
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard !locked else { return }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        guard !locked else { return }
                        dragOffset = .zero
                        layout.move(kind,
                                    to: CGPoint(x: slot.x + value.translation.width,
                                                y: slot.y + value.translation.height),
                                    in: order, width: canvasWidth)
                    }
            )
            .disabled(locked)
    }

    @ViewBuilder
    private var readout: some View {
        if frozen, let frozenImage {
            // A picture, not a paused view: the module behind this card may still
            // be running for a menu bar item, and a frozen card has to stay
            // frozen either way.
            Image(nsImage: frozenImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .saturation(0.85)
                .opacity(0.9)
        } else {
            ModuleDetailContent(kind: kind)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 0) {
            Group {
                CardButton(glyph: frozen ? "play.fill" : "snowflake",
                           tint: frozen ? Theme.cyan : Theme.textSecondary,
                           help: frozen ? "Resume sampling" : "Freeze this widget and stop sampling it") {
                    toggleFreeze()
                }
                CardButton(glyph: locked ? "lock.fill" : "lock.open",
                           tint: locked ? Theme.orange : Theme.textSecondary,
                           help: locked ? "Unlock — allow moving and resizing" : "Lock position and size") {
                    layout.toggleLock(kind, in: order, width: canvasWidth)
                }
                CardButton(glyph: "slider.horizontal.3",
                           tint: Theme.textMuted,
                           help: "Widget settings (not yet built)") {
                    // Deliberately inert. This is where the per-widget
                    // configuration page will hang; a button that silently does
                    // nothing is better than one that opens an empty sheet.
                }
                .disabled(true)
            }
            // Faded, never removed. A control that is only *built* while
            // hovering is a control that can vanish out from under the cursor
            // the instant a redraw disagrees about where the pointer is; one
            // that is always there and merely invisible cannot.
            .opacity(hovering ? 1 : 0)
        }
        // The cluster reads as one control rather than three loose chips, which
        // is most of why moving between them used to look like flickering: three
        // separate backgrounds lighting and unlighting across the dead gaps
        // between them.
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.housing.opacity(hovering ? 0.9 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.09 : 0), lineWidth: 1)
        )
        // Buffer. The hover region extends a clear 7pt past the visible cluster
        // on every side, so the pointer has somewhere to be that is neither "on
        // a button" nor "off the controls entirely" — without it a single pixel
        // of travel at the edge flipped the whole group off and on.
        .padding(7)
        .contentShape(Rectangle())
        // Deliberately *not* gated on `hovering`. Gating it meant the buttons
        // were only hit-testable once the hover state had propagated, and a
        // press that arrived first fell through to the drag gesture underneath.
        // The pointer has to be over the card to click anything here anyway, so
        // the gate bought nothing and cost the click.
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func toggleFreeze() {
        if frozen {
            frozenImage = nil
            manager.setFrozen(kind, false)
            return
        }
        // The freeze applies whether or not the snapshot succeeds.
        //
        // It used to be `guard let image = … else { return }`, which made the
        // button a silent no-op any time `ImageRenderer` came back nil — you
        // press it, nothing happens, and there is no way to tell that from the
        // button not working at all. A control must never do nothing quietly.
        frozenImage = CardSnapshot.capture(kind: kind, width: slot.width - 24)
        manager.setFrozen(kind, true)
    }

    // MARK: Gestures
    private enum Axis { case horizontal, vertical }

    private func resizeEdge(_ axis: Axis) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: axis == .horizontal ? Self.edge : nil,
                   height: axis == .vertical ? Self.edge : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                guard !locked else { return }
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(resizeGesture(axis: axis))
            .disabled(locked)
    }

    private var resizeCorner: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .onHover { inside in
                guard !locked else { return }
                // AppKit has no public diagonal resize cursor, so the corner
                // borrows the crosshair rather than lying with a one-axis arrow.
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(resizeGesture(axis: nil))
            .disabled(locked)
    }

    /// `axis == nil` resizes both ways.
    private func resizeGesture(axis: Axis?) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !locked else { return }
                sizeOffset = CGSize(width: axis == .vertical ? 0 : value.translation.width,
                                    height: axis == .horizontal ? 0 : value.translation.height)
            }
            .onEnded { value in
                guard !locked else { return }
                sizeOffset = .zero
                layout.resize(kind,
                              to: CGSize(width: slot.width + (axis == .vertical ? 0 : value.translation.width),
                                         height: slot.height + (axis == .horizontal ? 0 : value.translation.height)),
                              in: order, width: canvasWidth)
            }
    }
}

/// One of the small buttons on a card's header.
///
/// A 24pt chip inside a 32pt hit area, and the shape is taken *after* the slack
/// so the whole 32pt is pressable. The visual can stay small — it sits in a
/// dense header — but the target should not: 20pt chips with the hit region
/// stopping at the ink is what made these so hard to hit.
private struct CardButton: View {
    let glyph: String
    var tint: Color = Theme.textSecondary
    let help: String
    let action: () -> Void

    @State private var hovering = false

    private static let chip: CGFloat = 24
    private static let slack: CGFloat = 4

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Self.chip, height: Self.chip)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.18) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovering ? 0.20 : 0.10), lineWidth: 1)
                )
                .padding(Self.slack)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Renders a module's readout to a still image.
///
/// `ImageRenderer` runs the view once, off the live hierarchy, so what comes
/// back is genuinely a picture of the numbers at that instant — which is the
/// whole point. It cannot go stale and it cannot be revived by the module
/// underneath continuing to publish for some other surface.
enum CardSnapshot {
    @MainActor
    static func capture(kind: WidgetKind, width: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content:
            ModuleDetailContent(kind: kind)
                .frame(width: max(width, 200), alignment: .topLeading)
                .padding(0)
                .background(Theme.housing))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}
