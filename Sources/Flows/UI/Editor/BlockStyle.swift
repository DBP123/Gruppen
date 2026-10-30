import SwiftUI

/// The colour of each kind of block, and of each kind of value. One table, so
/// a Files pill is the same blue on a block, in the inspector and on a wire.
extension BlockCategory {
    var tint: Color {
        switch self {
        case .triggers: return Theme.ambient
        case .files: return Theme.blue
        case .text: return Theme.purple
        case .logic: return Theme.amber
        case .apps: return Theme.cyan
        case .system: return Theme.cellShell
        case .gruppen: return Theme.orange
        case .clipboard: return Theme.green
        case .web: return Theme.cellWall
        case .code: return Theme.trace
        case .custom: return Theme.crimson
        }
    }
}

extension ValueType {
    var tint: Color {
        switch self {
        case .files: return Theme.blue
        case .text: return Theme.purple
        case .number: return Theme.cyan
        case .bool: return Theme.amber
        case .list: return Theme.green
        case .record: return Theme.crimson
        case .any: return Theme.cellShell
        }
    }

    var glyph: String {
        switch self {
        case .files: return "doc"
        case .text: return "textformat"
        case .number: return "number"
        case .bool: return "checkmark.circle"
        case .list: return "list.bullet"
        case .record: return "curlybraces"
        case .any: return "circle.dotted"
        }
    }
}

extension BlockDefinition {
    var tint: Color { category.tint }
}

/// Lays its children out left to right, wrapping onto new rows — a block's
/// phrase, which reads as a sentence however narrow it gets.
struct WrapLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// A small coloured capsule naming a value: an output to drag, or a value
/// dropped into an input.
struct ValuePill: View {
    let label: String
    let type: ValueType
    var source: String? = nil
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: type.glyph).font(.system(size: compact ? 7.5 : 8.5, weight: .bold))
            Text(label).font(Theme.mono(compact ? 9 : 10, .semibold)).lineLimit(1)
        }
        .foregroundStyle(type.tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 1.5 : 2.5)
        .background(Capsule().fill(type.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(type.tint.opacity(0.45), lineWidth: 1))
        .help(source.map { "\(label) · \($0) — \(type.label)" } ?? "\(label) — \(type.label)")
    }
}

/// The run state of a block, drawn small: a dot that pulses while running, a
/// tick, a cross.
struct RunMark: View {
    let state: BlockTrace.State?

    var body: some View {
        switch state {
        case .running?:
            Circle().fill(Theme.orange).frame(width: 7, height: 7).pulsing(true, to: 0.25, duration: 0.6)
        case .finished?:
            Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.green)
        case .failed?:
            Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.red)
        case .skipped?:
            Image(systemName: "forward.end").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textMuted)
        case nil:
            EmptyView()
        }
    }
}

/// A flow's lamp: lit when it is switched on and armed, amber when it is on
/// but something stops it working.
struct FlowLamp: View {
    let flow: Flow
    var size: CGFloat = 8
    @EnvironmentObject private var library: FlowLibrary

    var body: some View {
        let runnable = flow.isRunnable(registry: library.registry)
        LED(color: runnable ? Theme.ambient : Theme.amber, lit: flow.isEnabled && !flow.triggers.isEmpty, size: size)
    }
}
