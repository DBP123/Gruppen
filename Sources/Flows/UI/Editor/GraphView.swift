import SwiftUI

/// The same flow as the block view, drawn as nodes and wires.
///
/// Every wire *is* a binding: an input reading another block's output. Drag
/// an output onto an input and the wire is a binding the block view shows as a
/// pill — there is one model and two ways of drawing it. Execution still runs
/// in block order; the numbers on the nodes say what it is.
struct GraphView: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        let flow = model.flow
        let layout = GraphLayout(flow: flow, registry: model.registry)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: layout.size.width, height: layout.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = [] }
                ForEach(layout.nodes, id: \.block.id) { node in
                    GraphNode(block: node.block, order: node.order, origin: node.origin)
                }
            }
            .overlayPreferenceValue(PortAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    Wires(flow: flow, anchors: anchors.mapValues { proxy[$0] }, registry: model.registry)
                }
                .allowsHitTesting(false)
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .scaleEffect(model.zoom, anchor: .topLeading)
            .frame(width: layout.size.width * model.zoom, height: layout.size.height * model.zoom, alignment: .topLeading)
        }
        .background(Theme.panel)
    }
}

/// Where each node sits: where you put it, or laid out in reading order —
/// hats down the left, the body left to right, a container's contents under
/// it.
struct GraphLayout {
    struct Node { let block: Block; let order: Int?; let origin: CGPoint }
    var nodes: [Node] = []
    var size = CGSize(width: 1200, height: 800)

    static let width: CGFloat = 230
    static let gap: CGFloat = 60

    init(flow: Flow, registry: BlockRegistry) {
        var y: CGFloat = 40
        for hat in flow.triggers {
            add(hat, order: nil, at: CGPoint(x: 40, y: y))
            y += Self.height(hat, registry) + 30
        }
        let start: CGFloat = flow.triggers.isEmpty ? 40 : 40 + Self.width + Self.gap * 1.5
        var counter = 0
        _ = place(flow.body, x: start, y: 40, registry: registry, counter: &counter)
        for stack in flow.loose {
            _ = place(stack.blocks, x: stack.position.x + start, y: stack.position.y + 420, registry: registry, counter: &counter)
        }
        let farthest = nodes.reduce(CGPoint.zero) {
            CGPoint(x: max($0.x, $1.origin.x + Self.width), y: max($0.y, $1.origin.y + Self.height($1.block, registry)))
        }
        size = CGSize(width: max(1200, farthest.x + 200), height: max(800, farthest.y + 200))
    }

    /// Lays out a stack left to right from `x`; returns how wide it was.
    private mutating func place(_ stack: [Block], x: CGFloat, y: CGFloat, registry: BlockRegistry,
                                counter: inout Int) -> CGFloat {
        var cursor = x
        for block in stack {
            counter += 1
            add(block, order: counter, at: CGPoint(x: cursor, y: y))
            var width = Self.width
            var slotX = cursor
            for slot in block.children where !slot.isEmpty {
                let used = place(slot, x: slotX, y: y + Self.height(block, registry) + 50, registry: registry, counter: &counter)
                slotX += used + Self.gap
            }
            width = max(width, slotX - cursor - (block.children.contains { !$0.isEmpty } ? Self.gap : 0))
            cursor += width + Self.gap
        }
        return cursor - x - Self.gap
    }

    private mutating func add(_ block: Block, order: Int?, at automatic: CGPoint) {
        nodes.append(Node(block: block, order: order, origin: block.position ?? automatic))
    }

    static func height(_ block: Block, _ registry: BlockRegistry) -> CGFloat {
        let definition = registry.definition(block.definition)
        return 44 + CGFloat(definition.inputs.filter { $0.control != .code }.count) * 27 + CGFloat(definition.outputs.count) * 24
    }
}

/// Port positions, by "in:<block>:<port>" and "out:<block>:<port>" — and
/// "out:trigger:<port>" for whatever a hat hands over.
struct PortAnchorsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [String: Anchor<CGPoint>], nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

private struct GraphNode: View {
    let block: Block
    let order: Int?
    let origin: CGPoint
    @EnvironmentObject private var model: EditorModel
    @State private var drag: CGSize = .zero

    var body: some View {
        let definition = model.definition(block)
        let run = model.runState(block.id)
        let available = FlowCheck.available(at: block.id, in: model.flow.body + model.flow.loose.flatMap(\.blocks),
                                            context: model.checkContext)
        let issues = model.issues(for: block.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if let order {
                    Text("\(order)").font(Theme.mono(9, .bold)).foregroundStyle(Theme.textMuted)
                        .frame(width: 18, height: 16).recessed(cornerRadius: 3)
                }
                Image(systemName: definition.glyph).font(.system(size: 10, weight: .semibold)).foregroundStyle(definition.tint)
                Text(definition.title).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 2)
                RunMark(state: run.state)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(definition.tint.opacity(0.12))
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    drag = .zero
                    model.update(block.id, "Move node") {
                        $0.position = CGPoint(x: max(0, origin.x + value.translation.width),
                                              y: max(0, origin.y + value.translation.height))
                    }
                })

            VStack(alignment: .leading, spacing: 5) {
                ForEach(definition.inputs.filter { $0.control != .code }) { port in
                    HStack(spacing: 6) {
                        PortDot(type: port.type)
                            .anchorPreference(key: PortAnchorsKey.self, value: .center) { ["in:\(block.id):\(port.name)": $0] }
                            .offset(x: -15)
                            .padding(.trailing, -10)
                        Text(port.label).font(Theme.sans(10.5)).foregroundStyle(Theme.textSecondary).frame(width: 64, alignment: .leading).lineLimit(1)
                        InputSlot(block: block, port: port, available: available,
                                  issue: issues.filter { $0.port == port.name }.map(\.severity).max())
                    }
                }
                ForEach(definition.outputs) { port in
                    HStack {
                        Spacer()
                        OutputPill(block: block, port: port, value: run.outputs[port.name])
                        PortDot(type: port.type)
                            .anchorPreference(key: PortAnchorsKey.self, value: .center) {
                                [definition.isHat ? "out:trigger:\(port.name)" : "out:\(block.id):\(port.name)": $0]
                            }
                            .offset(x: 15)
                            .padding(.leading, -10)
                            .onDrag { ValueDrag.provider(definition.isHat ? .trigger(port: port.name) : .output(block: block.id, port: port.name)) }
                    }
                }
            }
            .padding(10)
        }
        .frame(width: GraphLayout.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surfaceTop))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(model.selection.contains(block.id) ? Theme.orange : (run.state == .failed ? Theme.red : Theme.borderStrong),
                          lineWidth: model.selection.contains(block.id) ? 1.6 : 1))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .opacity(block.isDisabled ? 0.45 : 1)
        .onTapGesture { model.selection = [block.id] }
        .contextMenu {
            Button("Delete", role: .destructive) { model.delete([block.id]) }
            if block.position != nil {
                Button("Back to its place") { model.update(block.id, "Lay out") { $0.position = nil } }
            }
        }
        .offset(x: origin.x + drag.width, y: origin.y + drag.height)
    }
}

private struct PortDot: View {
    let type: ValueType
    var body: some View {
        Circle().fill(Theme.surfaceTop).frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(type.tint, lineWidth: 2))
    }
}

/// The wires: one curve per binding, coloured by what flows along it.
private struct Wires: View {
    let flow: Flow
    let anchors: [String: CGPoint]
    let registry: BlockRegistry

    var body: some View {
        Canvas { context, _ in
            for block in flow.allBlocks {
                let definition = registry.definition(block.definition)
                for (name, source) in block.inputs {
                    guard let end = anchors["in:\(block.id):\(name)"] else { continue }
                    for read in source.allReads {
                        let key: String
                        let type: ValueType
                        switch read {
                        case .output(let from, let port):
                            key = "out:\(from):\(port)"
                            type = flow.block(from).flatMap { registry.definition($0.definition).output(port)?.type } ?? .any
                        case .trigger(let port):
                            key = "out:trigger:\(port)"
                            type = flow.triggers.lazy.compactMap { registry.definition($0.definition).output(port)?.type }.first ?? .any
                        default: continue
                        }
                        guard let start = anchors[key] else { continue }
                        var path = Path()
                        path.move(to: start)
                        let pull = max(60, abs(end.x - start.x) / 2)
                        path.addCurve(to: end, control1: CGPoint(x: start.x + pull, y: start.y),
                                      control2: CGPoint(x: end.x - pull, y: end.y))
                        let mismatch = definition.input(name).map { Conversion.from(type, to: $0.type) == .impossible } ?? false
                        context.stroke(path, with: .color(mismatch ? Theme.red : type.tint.opacity(0.75)),
                                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
            }
        }
    }
}
