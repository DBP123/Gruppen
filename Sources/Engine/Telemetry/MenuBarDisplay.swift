import AppKit
import Foundation

/// How one standalone menu bar item draws itself.
///
/// Three genuinely different shapes rather than three variations on one: a
/// figure, a graph, or two figures. Which one is right depends entirely on the
/// module — throughput reads best stacked (down over up), a processor reads best
/// as a line, memory reads best as a number — so it is a per-module choice
/// rather than an app-wide preference.
enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Codable {
    /// One figure. The cheapest of the three: nothing is drawn unless the
    /// rendered string changes, which for a percentage means the integer moved.
    case numeric
    /// A live micro-graph, and nothing else.
    case sparkline
    /// Two figures at half height, one above the other.
    case stacked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .numeric: return "Numeric"
        case .sparkline: return "Graph"
        case .stacked: return "Stacked"
        }
    }

    /// Shown under the picker, so the choice does not have to be made by trying
    /// all three.
    var detail: String {
        switch self {
        case .numeric:
            return "One figure. Redraws only when the number itself changes."
        case .sparkline:
            return "A live line, no figure. Redraws only when the plot moves by a pixel."
        case .stacked:
            return "Two figures at half height, one above the other."
        }
    }
}

extension WidgetKind {
    /// What a module shows in the menu bar before anyone has chosen.
    ///
    /// Throughput is two numbers that mean nothing apart, so it starts stacked.
    /// Everything else starts as the plain figure, which is the quietest of the
    /// three and the one that looks least like a novelty.
    var defaultMenuBarMode: MenuBarDisplayMode {
        switch self {
        case .network, .storage: return .stacked   // two rates, useless apart
        case .power: return .sparkline             // the battery glyph
        default: return .numeric
        }
    }

    /// Widest string this module can produce in a mode, in characters.
    ///
    /// This is what makes the item a fixed width. It is a declared worst case
    /// rather than a measurement of the current reading, precisely so that the
    /// current reading can never change it — see `MenuBarMetrics`.
    func menuBarBudget(_ mode: MenuBarDisplayMode) -> Int {
        switch mode {
        case .sparkline:
            return 0
        case .numeric:
            switch self {
            case .cpu, .silicon: return 5       // "100%" — the badge says which
            case .memory: return 8              // "14.2 GB"
            case .network: return 19            // "↓888 KB/s ↑888 KB/s"
            case .thermal: return 9             // "CPU 100°C" — sensor and value
            case .power: return 8               // "-12.4 W"
            case .storage: return 10            // "888 MB/s"
            case .processes, .footprint: return 8
            }
        case .stacked:
            switch self {
            case .cpu, .silicon: return 8       // "USR 100%" / "12.4 GB"
            case .memory: return 8              // "14.2 GB" / "W 3.1 GB"
            case .network: return 9             // "↓888 KB/s"
            case .thermal: return 8             // "CRITICAL" / "18.4 W"
            case .power: return 8               // "100%" / "-12.4 W"
            case .storage: return 9             // "↓888 MB/s"
            case .processes, .footprint: return 8
            }
        }
    }
}

/// Turning a series of measurements into a series of heights.
///
/// One implementation, used by the micro-graph in the menu bar and by the full
/// sparkline in a panel, so the same reading cannot be drawn two different
/// shapes in two places.
enum PlotScale {
    /// Points across a plot: sixty samples, which is thirty seconds at 2 Hz.
    static let window = 60

    /// `(value − min) / (max − min)` across the window, with the denominator
    /// held at `floor` when the real range is smaller. Returns 0…1.
    static func normalise(_ values: [Double], floor: Double) -> [Double] {
        guard let low = values.min(), let high = values.max() else { return [] }
        let span = max(high - low, floor)
        guard span > 0 else { return values.map { _ in 0 } }
        return values.map { min(max(($0 - low) / span, 0), 1) }
    }
}

/// Fixed sizes for everything in the menu bar.
///
/// **Nothing here is measured from a reading.** A menu bar item that resizes
/// makes every item to its left move, which is a layout pass in the window
/// server for a figure that ticked from 9% to 10% — and the ones sitting next to
/// Gruppen belong to other applications. So an item's width is a pure function
/// of its module and its mode: computed once when the item is created, and only
/// ever recomputed when the user picks a different mode.
///
/// The widths come off the real font rather than a guess, because the whole
/// scheme only works if the declared character budget is genuinely wide enough
/// for the string that lands in it.
enum MenuBarMetrics {
    static let numericSize: CGFloat = 11
    static let stackedSize: CGFloat = 9
    /// Menu bar items have around 22 points of usable height; two stacked lines
    /// of 9pt fit inside it with a point to spare.
    static let height: CGFloat = 18
    static let graph = CGSize(width: 40, height: 13)
    /// Breathing room each side, matching the spacing AppKit gives its own
    /// menu bar text items.
    static let padding: CGFloat = 4
    /// The three-letter domain tag. Kept as tight as it can be and stay
    /// readable: every point spent here is a point of menu bar, and on a
    /// notched display the bar runs out sooner than it looks like it should.
    static let badgeSize: CGFloat = 8.5
    static let badgeWidth: CGFloat = 19
    static let badgeGap: CGFloat = 3
    /// The battery cell drawn in the menu bar.
    ///
    /// Measured from the system's own `battery.100` symbol rather than picked,
    /// so Gruppen's cell is the same size as the one macOS draws two icons
    /// along — and stays the same size if Apple changes it or the user changes
    /// the menu bar size. The symbol includes the terminal nub, which this draws
    /// separately, so the body is the measured width less that.
    static let batterySize: CGSize = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "battery.100", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return CGSize(width: 24, height: 12) }
        return symbol.size
    }()

    static var batteryWidth: CGFloat { max(batterySize.width - 4, 16) }
    static var batteryHeight: CGFloat { max(batterySize.height - 1, 9) }

    /// Vertical resolution of the plot: one step per device pixel on a 2×
    /// display. The quantiser rounds to these, so a change too small to move a
    /// pixel is a change nothing needs to be told about.
    static let plotLevels = Int(graph.height * 2)

    /// Points across the plot, and the line is drawn right-aligned against it,
    /// so a module running for four seconds draws four seconds of line rather
    /// than stretching them across the whole graph.
    static var plotPoints: Int { PlotScale.window }

    private static func advance(_ size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    private static let numericAdvance = advance(numericSize)
    private static let stackedAdvance = advance(stackedSize)

    static func contentWidth(_ kind: WidgetKind, _ mode: MenuBarDisplayMode) -> CGFloat {
        switch mode {
        case .sparkline: return graph.width
        case .numeric: return ceil(numericAdvance * CGFloat(kind.menuBarBudget(.numeric)))
        case .stacked: return ceil(stackedAdvance * CGFloat(kind.menuBarBudget(.stacked)))
        }
    }

    /// What the `NSStatusItem`'s length is set to.
    static func itemLength(_ kind: WidgetKind, _ mode: MenuBarDisplayMode) -> CGFloat {
        // The battery draws itself and wears no badge, so it pays for neither.
        if kind == .power, mode == .sparkline {
            return batteryWidth + 4 + padding * 2
        }
        // badge + gap + content + padding each side.
        return contentWidth(kind, mode) + badgeWidth + badgeGap + padding * 2
    }
}
