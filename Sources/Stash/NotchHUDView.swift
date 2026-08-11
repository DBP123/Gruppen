import AppKit
import SwiftUI

/// Square at the top so it continues the notch, rounded where it meets the
/// desktop.
///
/// This is `UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 16,
/// bottomTrailingRadius: 16, topTrailingRadius: 0)` — that type is macOS 14 and
/// the app deploys to 13, so the same geometry is drawn by hand. Identical
/// path, three OS versions more reach.
struct BottomRoundedShape: InsettableShape {
    var radius: CGFloat = 16
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> BottomRoundedShape {
        BottomRoundedShape(radius: radius, inset: inset + amount)
    }

    func path(in outerRect: CGRect) -> Path {
        let rect = outerRect.insetBy(dx: inset, dy: inset)
        var path = Path()
        let radius = min(radius, rect.height / 2, rect.width / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Whether the tray is out. Owned by the coordinator rather than the view: the
/// thing that decides to show or retract it is a drag session, which the view
/// never sees.
@MainActor
final class NotchPresentation: ObservableObject {
    @Published var isVisible = false
}

/// The notch tray.
///
/// **The illusion, in one paragraph.** The window's top edge is at
/// `screen.frame.maxY` exactly, so there is no gap by construction. Its top
/// `bandHeight` points — 32 on this Mac, taken from the screen's own safe-area
/// inset — sit *inside* the camera housing, where the display has no pixels, and
/// carry nothing but black. That hidden band is where the square top corners,
/// the window's edge highlight and the first frames of the slide all happen. The
/// tray proper begins at the bottom of the housing, exactly as wide as the
/// notch, so its sides continue the bezel's sides.
struct NotchHUDView: View {
    @EnvironmentObject private var state: ShelfState
    @EnvironmentObject private var presentation: NotchPresentation

    var onClose: () -> Void
    /// The tray gets out of the way the moment something leaves it.
    var onItemDraggedOut: () -> Void

    private var isTargeted: Bool { state.isTargeted }

    /// Exactly the notch. Anything wider would show its square top corners
    /// sticking out either side of the housing, which is the whole illusion
    /// gone.
    static var width: CGFloat {
        guard let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return 200 }
        return max(right.minX - left.maxX, 180)
    }

    /// The part of the panel hidden behind the camera housing.
    static func bandHeight(on screen: NSScreen) -> CGFloat {
        if let aux = screen.auxiliaryTopLeftArea { return aux.height }
        return screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
    }

    /// The part you can actually see: 8pt margin, a 60pt groove, 8pt margin.
    /// Sized to its contents rather than left roomy — the previous tray carried
    /// 24pt of dead black under the files.
    static let trayHeight: CGFloat = 76

    static func panelHeight(on screen: NSScreen) -> CGFloat {
        bandHeight(on: screen) + trayHeight
    }

    /// Invisible margin around the tray, inside the same window.
    ///
    /// The tray is exactly notch-width because that is what makes it look like
    /// hardware, but a 185pt target with a hard boundary is what caused the
    /// flicker: slip a couple of points off it and the pointer had left the
    /// window, which withdrew the tray, which put the pointer back over nothing.
    /// The window now extends past the tray on both sides and below it, and all
    /// the tracking happens against *that* edge. The buffer draws nothing.
    static let buffer: CGFloat = 48

    /// The exact window rect.
    ///
    /// The horizontal edges are taken from the notch's own neighbours rather
    /// than from `midX - width / 2`: on this Mac that centre calculation lands
    /// on 663.5, and rounding it put the tray a point to the right of the
    /// housing — exposing a sliver of bezel down one side and overhanging the
    /// other. `auxiliaryTopLeftArea.maxX` *is* the left edge of the notch, so
    /// using it makes the sides align by definition on any display.
    ///
    /// `maxY` is `screen.frame.maxY` exactly, so there is no gap to get wrong:
    /// origin.y = frame.maxY − (bandHeight + trayHeight).
    static func frame(on screen: NSScreen) -> NSRect {
        let height = panelHeight(on: screen) + buffer
        let trayWidth: CGFloat
        let trayX: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            trayX = left.maxX
            trayWidth = right.minX - left.maxX
        } else {
            trayWidth = width
            trayX = (screen.frame.midX - trayWidth / 2).rounded()
        }
        return NSRect(x: trayX - buffer,
                      y: screen.frame.maxY - height,
                      width: trayWidth + buffer * 2,
                      height: height)
    }

    private var band: CGFloat {
        NSScreen.main.map { Self.bandHeight(on: $0) } ?? 32
    }

    private var totalHeight: CGFloat { band + Self.trayHeight }

    @State private var hovering = false

    private var accent: Color { Theme.ambient }
    private let shape = BottomRoundedShape(radius: 24)

    var body: some View {
        // The wrapper: the whole window, buffer included. Hover, ignition and
        // the ambient glow are all bound to *this*, not to the tray inside it,
        // so a micro-movement off the tray's edge is not an exit.
        trayColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .ignoresSafeArea(.all)
    }

    private var trayColumn: some View {
        VStack(spacing: 0) {
            // Inside the housing. Nothing may live here — it is not on a display.
            Color.clear.frame(height: band)
            tray
        }
        .frame(width: Self.width, height: totalHeight, alignment: .top)
        .background(surface)
        .overlay(lightbar, alignment: .bottom)
        .clipShape(shape)
        .overlay(
            // Inner stroke, so the light runs around the inside of the tray
            // rather than outlining a window.
            // Subtle on purpose: at full strength this is a bright orange
            // outline around a black rectangle, which announces the window
            // rather than lighting the tray. The lightbar carries the signal.
            shape
                .inset(by: 0.5)
                .stroke(isTargeted ? accent.opacity(0.5) : Color.white.opacity(0.05),
                        lineWidth: 1)
        )
        .ambientGlow(isTargeted || hovering)
        .animation(.easeOut(duration: 0.16), value: isTargeted)
        .animation(.easeOut(duration: 0.2), value: hovering)
        // Slides out from behind the bezel, and back up into it. Its own height
        // is the exact distance that hides it; the spec's -300 would spend most
        // of the spring off-screen where nothing can be seen.
        .offset(y: presentation.isVisible ? 0 : -totalHeight)
        .animation(.interpolatingSpring(mass: 1.0, stiffness: 200,
                                        damping: 20, initialVelocity: 0),
                   value: presentation.isVisible)
    }

    /// Absolute black, edge to edge.
    ///
    /// No gradient and no material: any lift at all, anywhere on this panel,
    /// betrays where the bezel stops and the software starts. Black is the one
    /// colour that is optically identical to the housing above it, so the tray
    /// reads as more hardware. The grain is 4% purely as dither — a large flat
    /// #000 field on a retina panel is where banding shows up.
    private var surface: some View {
        Color.black
            .grain(0.04)
            .allowsHitTesting(false)
    }

    /// The lightbar along the bottom lip. Grows out from the centre to 60% of
    /// the tray when a drag is over it, and glows.
    private var lightbar: some View {
        Capsule()
            .fill(accent)
            .frame(width: isTargeted ? Self.width * 0.6 : 0, height: 3)
            .shadow(color: accent.opacity(isTargeted ? 0.85 : 0), radius: 8)
            .padding(.bottom, 5)
            .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isTargeted)
            .allowsHitTesting(false)
    }

    private var tray: some View {
        groove
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(alignment: .topTrailing) {
                // Sits over the groove's top-right corner: there is no header to
                // put it in, and the tray is 76pt tall — a reserved row for one
                // glyph would cost a fifth of it.
                NotchCloseButton(action: onClose)
                    .padding(.trailing, 4)
                    .padding(.top, 2)
            }
    }

    /// The machined recess the files sit in.
    private var groove: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.items) { item in
                    NotchItemChip(item: item, onDragOut: onItemDraggedOut)
                }
            }
            .padding(.leading, 6)
            // The close key sits over the groove's top-right corner; this keeps
            // a scrolled icon from ending up underneath it.
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, alignment: state.items.isEmpty ? .center : .leading)
            .frame(height: 60)
        }
        .frame(height: 60)
        .machined(cornerRadius: 8)
        .overlay(alignment: .center) {
            if state.items.isEmpty {
                Text(isTargeted ? "RELEASE" : "DROP")
                    .font(Theme.mono(9, .semibold))
                    .tracking(2)
                    .foregroundStyle(isTargeted ? accent : Color.white.opacity(0.28))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Close. A real key, and big enough to hit without aiming.
private struct NotchCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
        }
        .hardwareKey(size: 26, tint: Color.white.opacity(0.45))
        .help("Close the tray")
    }
}

/// One held item.
private struct NotchItemChip: View {
    @EnvironmentObject private var state: ShelfState
    let item: StashItem
    var onDragOut: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(nsImage: item.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 34, height: 34)
            .padding(6)
            // Each file in its own socket. Fill only on hover — the icon does
            // not move, grow or gain a border.
            .machined(cornerRadius: 6,
                      fill: hovering ? Color(hex: 0x17171A) : Theme.machined,
                      border: Theme.machinedBorder)
            .onHover { hovering = $0 }
            .onDrag {
                let provider = item.itemProvider
                onDragOut()
                Task { @MainActor in state.remove(item) }
                return provider
            }
            .help(item.title)
    }
}
