import SwiftUI

/// A line drawing of the machine, one per Mac family.
///
/// SF Symbols covers some of this — `laptopcomputer`, `macmini`, `macstudio` —
/// but not consistently: there is no MacBook Air distinct from a Pro, the
/// weights do not match each other at a shared size, and none of them sit right
/// next to the hand-drawn instruments in the rest of this app. These are drawn
/// from primitives at a single stroke weight, on one 100×72 grid, so a laptop
/// and a tower read as the same family of drawing at the same optical weight.
///
/// Stroke rather than fill throughout: the panel is near-black, and a filled
/// silhouette at this size becomes a blob. An outline keeps the proportions of
/// the machine legible, which is the only reason to draw it at all.
struct MacGlyph: View {
    let family: MacFamily
    var size: CGFloat = 46
    var tint: Color = Theme.textSecondary

    /// Everything is drawn on this grid and scaled once, so proportions hold at
    /// any size and the stroke stays optically constant.
    private static let grid = CGSize(width: 100, height: 72)

    private var scale: CGFloat { size / Self.grid.width }
    /// Chosen so the line reads as drawn rather than hairline at the banner's
    /// 46pt and still holds together on the 22pt settings row.
    private var line: CGFloat { max(size * 0.038, 1.1) }

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width / Self.grid.width,
                        canvasSize.height / Self.grid.height)
            let dx = (canvasSize.width - Self.grid.width * s) / 2
            let dy = (canvasSize.height - Self.grid.height * s) / 2
            context.translateBy(x: dx, y: dy)
            context.scaleBy(x: s, y: s)

            let width = max(line / s, 0.8)
            for path in Self.paths(for: family) {
                context.stroke(path, with: .color(tint),
                               style: StrokeStyle(lineWidth: width,
                                                  lineCap: .round, lineJoin: .round))
            }
            for path in Self.fills(for: family) {
                context.fill(path, with: .color(tint.opacity(0.55)))
            }
        }
        .frame(width: size, height: size * (Self.grid.height / Self.grid.width))
        .accessibilityLabel(family.marketingName)
    }

    // MARK: Drawings

    /// The outline strokes for one family, on the 100×72 grid.
    private static func paths(for family: MacFamily) -> [Path] {
        switch family {
        case .macBookPro, .macBookAir, .unknown: return laptop(thin: family == .macBookAir)
        case .iMac: return allInOne()
        case .macMini: return mini()
        case .macStudio: return studio()
        case .macPro: return tower()
        }
    }

    /// Small solid details — a camera, a power light — that read better filled
    /// than outlined at this size.
    private static func fills(for family: MacFamily) -> [Path] {
        switch family {
        case .macBookPro, .macBookAir, .unknown:
            return [Path(ellipseIn: CGRect(x: 49, y: 12, width: 2, height: 2))]
        case .iMac:
            return [Path(ellipseIn: CGRect(x: 49, y: 9, width: 2, height: 2))]
        case .macMini, .macStudio:
            return [Path(ellipseIn: CGRect(x: 20, y: 45, width: 2.4, height: 2.4))]
        case .macPro:
            return []
        }
    }

    /// A screen on a base.
    ///
    /// Drawn front-on, where the two laptops are genuinely hard to tell apart —
    /// the Air's defining taper is a side view. So the difference is carried by
    /// the proportions that *do* survive this angle: the Air is the smaller
    /// machine on a noticeably thinner base, the Pro is wider on a deeper one
    /// with feet. Enough to tell them apart in a row; not so much that either
    /// stops looking like the machine it is.
    private static func laptop(thin: Bool) -> [Path] {
        let lidWidth: CGFloat = thin ? 58 : 66
        let lid = CGRect(x: (100 - lidWidth) / 2, y: 11, width: lidWidth, height: thin ? 37 : 39)
        let baseTop = lid.maxY + 4
        let baseHeight: CGFloat = thin ? 3 : 5
        let baseHalf = lidWidth / 2 + 8
        var paths: [Path] = []

        var screen = Path(roundedRect: lid, cornerRadius: 3)
        screen.addRoundedRect(in: lid.insetBy(dx: 3.5, dy: 3.5),
                              cornerSize: CGSize(width: 1.5, height: 1.5))
        paths.append(screen)

        // A shallow trapezoid, so the base reads as seen slightly from above
        // rather than as a second rectangle stacked under the lid.
        var base = Path()
        base.move(to: CGPoint(x: 50 - baseHalf, y: baseTop))
        base.addLine(to: CGPoint(x: 50 + baseHalf, y: baseTop))
        base.addLine(to: CGPoint(x: 50 + baseHalf - 4, y: baseTop + baseHeight))
        base.addLine(to: CGPoint(x: 50 - baseHalf + 4, y: baseTop + baseHeight))
        base.closeSubpath()
        paths.append(base)

        // The lip you open the lid with, cut into the *front* edge. It used to
        // sit on the base's top edge, where it drew a second line directly over
        // the first and read as a rendering fault rather than a detail.
        var lip = Path()
        lip.move(to: CGPoint(x: 44, y: baseTop + baseHeight))
        lip.addLine(to: CGPoint(x: 56, y: baseTop + baseHeight))
        paths.append(lip)

        // Feet, on the Pro only — the deeper chassis is the thing being shown.
        if !thin {
            var feet = Path()
            for x in [50 - baseHalf + 9, 50 + baseHalf - 9] {
                feet.move(to: CGPoint(x: x, y: baseTop + baseHeight))
                feet.addLine(to: CGPoint(x: x, y: baseTop + baseHeight + 2.5))
            }
            paths.append(feet)
        }
        return paths
    }

    /// Screen and chin on a stand.
    private static func allInOne() -> [Path] {
        var paths: [Path] = []
        let body = CGRect(x: 12, y: 6, width: 76, height: 46)
        var shell = Path(roundedRect: body, cornerRadius: 3.5)
        // The display area stops above the chin, which is the whole shape of an
        // iMac.
        shell.addRoundedRect(in: CGRect(x: 15.5, y: 9.5, width: 69, height: 33),
                             cornerSize: CGSize(width: 1.5, height: 1.5))
        paths.append(shell)

        var stand = Path()
        stand.move(to: CGPoint(x: 43, y: 52))
        stand.addLine(to: CGPoint(x: 43, y: 61))
        stand.addLine(to: CGPoint(x: 57, y: 61))
        stand.addLine(to: CGPoint(x: 57, y: 52))
        paths.append(stand)

        var foot = Path()
        foot.move(to: CGPoint(x: 30, y: 63))
        foot.addLine(to: CGPoint(x: 70, y: 63))
        paths.append(foot)
        return paths
    }

    /// A wide, flat slab.
    private static func mini() -> [Path] {
        [Path(roundedRect: CGRect(x: 14, y: 24, width: 72, height: 24), cornerRadius: 4)]
    }

    /// The mini's footprint, twice the height, with the intake ring at the base.
    private static func studio() -> [Path] {
        var paths: [Path] = [
            Path(roundedRect: CGRect(x: 18, y: 16, width: 64, height: 40), cornerRadius: 5)
        ]
        var vent = Path()
        vent.move(to: CGPoint(x: 18, y: 48))
        vent.addLine(to: CGPoint(x: 82, y: 48))
        paths.append(vent)
        return paths
    }

    /// A tower with the lattice front, drawn as a grid rather than a texture so
    /// it survives being scaled down.
    private static func tower() -> [Path] {
        // Body starts at y = 10, not 6: the handles sit above it, and at y = 6
        // they ran to y = 2 where the round line cap was clipped by the top of
        // the grid.
        var paths: [Path] = [
            Path(roundedRect: CGRect(x: 28, y: 10, width: 44, height: 56), cornerRadius: 5)
        ]
        var lattice = Path()
        for row in 0..<4 {
            let y = 21 + CGFloat(row) * 10.5
            lattice.move(to: CGPoint(x: 34, y: y))
            lattice.addLine(to: CGPoint(x: 66, y: y))
        }
        for column in 0..<3 {
            let x = 39 + CGFloat(column) * 11
            lattice.move(to: CGPoint(x: x, y: 17))
            lattice.addLine(to: CGPoint(x: x, y: 57))
        }
        paths.append(lattice)

        var handles = Path()
        handles.move(to: CGPoint(x: 36, y: 10))
        handles.addLine(to: CGPoint(x: 36, y: 5))
        handles.move(to: CGPoint(x: 64, y: 10))
        handles.addLine(to: CGPoint(x: 64, y: 5))
        paths.append(handles)
        return paths
    }
}
