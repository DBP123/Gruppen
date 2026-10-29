import AppKit
import SwiftUI

// Animations that run for as long as something is true — a fan turning, a
// battery charging — on Core Animation's clock rather than SwiftUI's.
//
// A SwiftUI `repeatForever` is driven from this process: every display frame,
// 120 a second on a ProMotion screen, SwiftUI re-evaluates the animated value
// and commits a new frame. Measured on the thermal card with one fan spinning:
// 5.48% of a core against 0.25% with it still — twenty times the card's whole
// cost, for as long as the fans run, which is exactly when anyone looks at
// thermals. A `CABasicAnimation` added to a layer is run by the window server
// and costs this process nothing per frame. Same picture, same motion.

/// A shape turning about its centre, once every `period` seconds; still at 0.
struct SpinningShape<S: Shape>: NSViewRepresentable {
    let shape: S
    let period: Double
    let color: Color

    func makeNSView(context: Context) -> SpinningShapeView {
        SpinningShapeView { shape.path(in: $0).cgPath }
    }

    func updateNSView(_ view: SpinningShapeView, context: Context) {
        view.update(period: period, color: NSColor(color))
    }
}

final class SpinningShapeView: NSView {
    private let layerShape = CAShapeLayer()
    private let makePath: (CGRect) -> CGPath
    private var period: Double = 0
    private static let key = "spin"

    /// Flipped, so the path draws exactly as SwiftUI drew it, and a positive
    /// rotation turns clockwise as `rotationEffect` did.
    override var isFlipped: Bool { true }

    init(path: @escaping (CGRect) -> CGPath) {
        makePath = path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(layerShape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerShape.bounds = bounds
        layerShape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layerShape.path = makePath(bounds)
        CATransaction.commit()
    }

    func update(period: Double, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerShape.fillColor = color.cgColor
        CATransaction.commit()
        guard period != self.period else { return }
        self.period = period
        spin()
    }

    /// A layer leaving its window can lose its animations; coming back starts
    /// the turn again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { spin() }
    }

    private func spin() {
        layerShape.removeAnimation(forKey: Self.key)
        guard period > 0 else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = period
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        layerShape.add(turn, forKey: Self.key)
    }
}

extension View {
    /// Fades between full and `low` opacity and back, every `duration`
    /// seconds each way, for as long as `active` — on Core Animation's clock.
    func pulsing(_ active: Bool, to low: Double = 0.5, duration: Double = 1.1) -> some View {
        Pulsing(content: self, active: active, low: low, duration: duration)
    }
}

private struct Pulsing<Content: View>: NSViewRepresentable {
    let content: Content
    let active: Bool
    let low: Double
    let duration: Double

    func makeNSView(context: Context) -> PulsingHost<Content> {
        PulsingHost(rootView: content)
    }

    func updateNSView(_ view: PulsingHost<Content>, context: Context) {
        view.rootView = content
        view.update(active: active, low: low, duration: duration)
    }
}

final class PulsingHost<Content: View>: NSHostingView<Content> {
    private var pulse: (low: Double, duration: Double)?
    private static var key: String { "pulse" }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(active: Bool, low: Double, duration: Double) {
        let wanted = active ? (low, duration) : nil
        guard wanted?.0 != pulse?.low || wanted?.1 != pulse?.duration else { return }
        pulse = wanted
        start()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() }
    }

    private func start() {
        layer?.removeAnimation(forKey: Self.key)
        guard let pulse else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = pulse.low
        fade.duration = pulse.duration
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.isRemovedOnCompletion = false
        layer?.add(fade, forKey: Self.key)
    }
}
