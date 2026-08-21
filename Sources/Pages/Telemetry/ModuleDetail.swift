import SwiftUI

/// What one menu bar item's popover shows.
///
/// Each standalone item owns its own popover and its own module: the processor
/// item opens processor data and nothing else. That is the whole point of
/// having separate items — a single shared dropdown makes the items decorative,
/// because whichever one you click you get the same thing.
///
/// These are denser than the shared panel's wells on purpose. A popover opened
/// deliberately, about one subsystem, is where the diagnostics go.

import SwiftUI

/// What one menu bar item's popover shows.
///
/// Each standalone item owns its own popover and its own module: the processor
/// item opens processor data and nothing else. That is the whole point of
/// having separate items — a single shared dropdown makes the items decorative,
/// because whichever one you click you get the same thing.
///
/// These are denser than the shared panel's wells on purpose. A popover opened
/// deliberately, about one subsystem, is where the diagnostics go.
struct ModuleDetail: View {
    let kind: WidgetKind
    @ObservedObject private var manager = WidgetManager.shared

    init(kind: WidgetKind) { self.kind = kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            DetailHeader(kind: kind)
            ModuleDetailContent(kind: kind)
        }
        .padding(12)
        .frame(width: 292, alignment: .leading)
        .background(Theme.housing.grain(0.2))
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.housingEdge, Theme.housingEdge.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
        }
    }
}

/// The readout itself, without any chrome around it.
///
/// Split out of `ModuleDetail` so the dashboard card and the menu bar popover
/// render the *same* view rather than two copies of it. The chrome differs —
/// a popover is a fixed 292pt slab, a card is a flexible grid cell — but what a
/// processor readout contains must not.
struct ModuleDetailContent: View {
    let kind: WidgetKind
    @ObservedObject private var manager = WidgetManager.shared

    init(kind: WidgetKind) { self.kind = kind }

    @ViewBuilder
    var body: some View {
        switch kind {
        case .cpu:
            if let widget = manager.module(CPUTelemetryWidget.self, .cpu) { CPUDetail(widget: widget) }
            else { Waiting() }
        case .memory:
            if let widget = manager.module(MemoryTelemetryWidget.self, .memory) { MemoryDetail(widget: widget) }
            else { Waiting() }
        case .network:
            if let widget = manager.module(NetworkTelemetryWidget.self, .network) { NetworkDetail(widget: widget) }
            else { Waiting() }
        case .thermal:
            if let widget = manager.module(ThermalTelemetryWidget.self, .thermal) { ThermalDetail(widget: widget) }
            else { Waiting() }
        case .power:
            if let widget = manager.module(PowerTelemetryWidget.self, .power) { PowerDetail(widget: widget) }
            else { Waiting() }
        case .storage:
            if let widget = manager.module(StorageTelemetryWidget.self, .storage) { StorageDetail(widget: widget) }
            else { Waiting() }
        case .silicon:
            if let widget = manager.module(SiliconTelemetryWidget.self, .silicon) { SiliconDetail(widget: widget) }
            else { Waiting() }
        case .processes:
            if let widget = manager.module(ProcessTelemetryWidget.self, .processes) { ProcessDetail(widget: widget) }
            else { Waiting() }
        case .footprint:
            // Gruppen's own line has a home already, at the foot of the
            // dropdown. Repeating it as a card would be the app taking up a
            // whole cell to talk about itself.
            Waiting()
        }
    }
}

// MARK: - Chrome

private struct DetailHeader: View {
    let kind: WidgetKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: kind.glyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                Text(kind.header)
                    .font(Theme.mono(10, .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            DashedRule()
        }
    }
}

struct Waiting: View {
    var body: some View {
        Text("Waiting for the first reading…")
            .font(Theme.mono(10))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

/// A label and a figure on one line, mono throughout and monospaced-digit, so a
/// column of these never shifts as the numbers change.
struct StatRow: View {
    let label: String
    let value: String
    var tint: Color = Theme.textPrimary
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Theme.mono(9.5))
                .tracking(0.5)
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
            Spacer(minLength: 6)
            if let detail {
                Text(detail)
                    .font(Theme.mono(9.5).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            // A long value shrinks rather than truncating. "7 days, 8 hours,
            // 7 minutes" is a few points wider than this popover, and a figure
            // cut off at "7 minut…" is worse than one set slightly small.
            Text(value)
                .font(Theme.mono(11, .medium).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}

/// The one big number at the top of a popover.
struct Headline: View {
    let value: String
    let unit: String
    var tint: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 26, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(tint)
            Text(unit)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
        }
    }
}

struct Well<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .machined(cornerRadius: Theme.radiusMd, fill: Theme.well)
    }
}

/// Explicit column headers. Every table in here gets them — a column of numbers
/// with no heading is a column you have to guess at, which is what "connections
/// · bytes carried on them" was really admitting.
struct TableHeader: View {
    let columns: [(String, HorizontalAlignment, CGFloat?)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                if column.1 == .leading {
                    Text(column.0)
                        .font(Theme.mono(8, .semibold)).tracking(0.7)
                        .foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 6)
                } else {
                    Text(column.0)
                        .font(Theme.mono(8, .semibold)).tracking(0.7)
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: column.2, alignment: .trailing)
                }
            }
        }
    }
}

/// A colour chip and its name, for a stacked bar's legend.
struct Key: View {
    let label: String
    let tint: Color

    init(_ label: String, _ tint: Color) { self.label = label; self.tint = tint }

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(Theme.mono(8)).tracking(0.3)
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
        }
        .padding(.trailing, 7)
    }
}

struct Dot: View {
    var body: some View {
        Text("•")
            .font(Theme.mono(8))
            .foregroundStyle(Theme.textMuted.opacity(0.6))
            .padding(.horizontal, 4)
            .fixedSize()
    }
}

/// A label and a figure side by side. `leading` puts the label first — right for
/// a percentage — and false puts the figure first, which is how a count reads.
struct Legend: View {
    let label: String
    let value: String
    var tint: Color = Theme.textPrimary
    var leading = true

    var body: some View {
        HStack(spacing: 3) {
            if leading { name }
            Text(value)
                .font(Theme.mono(9.5, .medium).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
            if !leading { name }
        }
    }

    private var name: some View {
        Text(label)
            .font(Theme.mono(8)).tracking(0.4)
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A well that folds away, with its title as the hinge.
///
/// The whole header is the hit target, not just the chevron — a 9pt glyph is not
/// something to ask anyone to aim at.
struct Fold<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Well {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                        .font(Theme.mono(9, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                DashedRule()
                content
            }
        }
    }
}
