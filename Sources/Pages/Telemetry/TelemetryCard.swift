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
    /// Space the three hover controls occupy, including their buffer.
    ///
    /// Three 26pt hit areas (a 20pt chip with 3pt of slack each side) butted
    /// together, 4pt of cluster padding and 7pt of outer buffer on each side.
    /// Computed from those parts rather than guessed — the first version was two
    /// points narrower than the controls actually were, so the freeze button
    /// overhung the drag strip and its presses went to the drag gesture.
    private static let controlsWidth: CGFloat = (20 + 3 * 2) * 3 + 4 * 2 + 7 * 2

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
        .overlay(alignment: .top) { dragStrip }
        .overlay(alignment: .trailing) { resizeEdge(.horizontal) }
        .overlay(alignment: .bottom) { resizeEdge(.vertical) }
        .overlay(alignment: .bottomTrailing) { resizeCorner }
        .overlay(alignment: .topTrailing) { controls }
    }

    private var borderTint: Color {
        if frozen { return Theme.cyan.opacity(0.45) }
        if locked { return Theme.textMuted.opacity(0.30) }
        return hovering ? Color.white.opacity(0.16) : Color.white.opacity(0.07)
    }

    // MARK: Contents

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.glyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.domain(kind.domainIndex))
            Text(kind.header)
                .font(Theme.mono(9, .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            if frozen {
                Text("FROZEN")
                    .font(Theme.mono(8, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.cyan)
            }
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 6)
            // Faded rather than removed while hovering. Taking it out of the
            // layout reflowed the header under the cursor at the exact moment
            // you were reaching for the controls.
            Text(kind.badge)
                .font(Theme.mono(8, .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textMuted)
                .opacity(hovering ? 0 : 1)
        }
        // The controls sit over the trailing end of this row, so the row always
        // keeps that space clear whether they are showing or not — no geometry
        // moves when they fade in.
        .padding(.trailing, Self.controlsWidth)
        .frame(height: Self.headerHeight - 12, alignment: .center)
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
        // Capture first: only freeze if there is actually a picture to show,
        // otherwise the card would go blank and stop sampling at the same time.
        guard let image = CardSnapshot.capture(kind: kind, width: slot.width - 24) else { return }
        frozenImage = image
        manager.setFrozen(kind, true)
    }

    // MARK: Gestures

    /// The top strip moves the card.
    /// The move handle: the header strip, stopping short of the controls.
    ///
    /// Laid out as two boxes rather than one padded box, and that is the whole
    /// fix. `.padding(.trailing, …)` followed by `.contentShape(Rectangle())`
    /// looks like it insets the hit area and does the opposite — `contentShape`
    /// applies to the view *including* its padding, so the strip's tappable
    /// region stretched right back over the buttons and swallowed the press.
    /// An `HStack` with an inert spacer cannot make that mistake: the draggable
    /// rectangle is only as wide as it looks.
    private var dragStrip: some View {
        HStack(spacing: 0) {
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
            // The controls' corner. Reserved and inert, so a press here reaches
            // the buttons above rather than starting a drag.
            Color.clear
                .frame(width: Self.controlsWidth)
                .allowsHitTesting(false)
        }
        .frame(height: Self.headerHeight)
    }

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

/// One of the small round buttons that appear on a card when you hover it.
private struct CardButton: View {
    let glyph: String
    var tint: Color = Theme.textSecondary
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                // 3pt of slack around the chip, and the shape is taken *after*
                // it so the hit and hover region is the full 26pt. With the
                // shape on the bare 20pt chip and 4pt of spacing between
                // buttons, there was a dead gap on either side of every button:
                // one pixel of travel and the highlight dropped.
                .padding(3)
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
