import SwiftUI

import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Accepts `#RGB`, `#RRGGBB`, `#RRGGBBAA`, with or without the hash.
    /// Anything unparseable falls back to the default Gruppe orange rather
    /// than crashing on data that came off disk.
    init(hex string: String, opacity: Double = 1) {
        let cleaned = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(hex: 0xFF6B00, opacity: opacity)
            return
        }
        switch cleaned.count {
        case 3:
            let r = Double((value >> 8) & 0xF) / 15
            let g = Double((value >> 4) & 0xF) / 15
            let b = Double(value & 0xF) / 15
            self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
        case 6:
            self.init(hex: UInt32(value & 0xFFFFFF), opacity: opacity)
        case 8:
            let alpha = Double(value & 0xFF) / 255
            self.init(hex: UInt32((value >> 8) & 0xFFFFFF), opacity: opacity * alpha)
        default:
            self.init(hex: 0xFF6B00, opacity: opacity)
        }
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return (Double(resolved.redComponent),
                Double(resolved.greenComponent),
                Double(resolved.blueComponent))
    }

    var hexString: String {
        let (r, g, b) = rgb
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }

    /// Blends toward another colour. `amount` 0 returns self.
    func mixed(with other: Color, amount: Double) -> Color {
        let a = rgb, b = other.rgb
        let t = min(max(amount, 0), 1)
        return Color(.sRGB,
                     red: a.red + (b.red - a.red) * t,
                     green: a.green + (b.green - a.green) * t,
                     blue: a.blue + (b.blue - a.blue) * t,
                     opacity: 1)
    }
}

// MARK: - Lamp optics

/// Everything the `LED` needs, derived from one hex so a Gruppe can be any
/// colour and still light up like the hardware: a dark lens when off, a hot
/// near-white core when on, and a bloom that falls off around it.
extension Color {
    /// Unlit lens — the colour seen through dark smoked plastic.
    var lensTint: Color {
        mixed(with: Color(hex: 0x050607), amount: 0.72)
    }

    /// The filament itself: pushed toward white so bright and dark hues both
    /// read as genuinely lit rather than merely coloured.
    var litCore: Color {
        mixed(with: .white, amount: 0.45)
    }

    /// Lens gradient for a lit lamp — hot centre, saturated rim.
    var lensGradient: RadialGradient {
        RadialGradient(colors: [litCore, self, mixed(with: .black, amount: 0.25)],
                       center: UnitPoint(x: 0.38, y: 0.32),
                       startRadius: 0,
                       endRadius: 7)
    }

    /// Halo drawn behind a lit lamp.
    func bloom(radius: CGFloat) -> RadialGradient {
        RadialGradient(colors: [opacity(0.55), opacity(0.18), .clear],
                       center: .center,
                       startRadius: 0,
                       endRadius: radius)
    }
}

/// Industrial Dark design tokens.
enum Theme {
    // Surfaces
    static let root = Color(hex: 0x0A0B0D)
    static let panel = Color(hex: 0x121417)
    static let surface = Color(hex: 0x181B20)
    /// Slightly lifted top edge for card gradients — light falls from above.
    static let surfaceTop = Color(hex: 0x1E222A)
    static let surfaceHover = Color(hex: 0x21252C)
    static let surfacePressed = Color(hex: 0x282D36)
    static let input = Color(hex: 0x0E1013)

    /// Machined recess: the surface a file or an option is stamped into.
    static let machined = Color(hex: 0x0D0D0F)
    static let machinedBorder = Color(hex: 0x1A1A1C)

    /// Milled-aluminium housing, and the lit edge along its top lip. Used by
    /// the menu bar monitor, which is a piece of equipment rather than a page.
    static let housing = Color(hex: 0x09090B)
    static let housingEdge = Color(hex: 0x2C2C2E)
    /// A data well: instrument glass, darker than anything around it.
    static let well = Color.black
    /// The trace colour every plot is drawn in. Emerald rather than the panel's
    /// orange: orange is what this app uses for *controls the user has armed*,
    /// and a line that is merely reporting should not read as a switch being on.
    static let trace = Color(hex: 0x10B981)
    /// Performance cores, and anything else that wants to read as the *fast*
    /// half of a pair next to `trace`.
    static let cyan = Color(hex: 0x00F0FF)
    /// The two warning steps for threshold gating. Amber is "working", crimson
    /// is "past where you want it".
    static let purple = Color(hex: 0xA855F7)
    static let blue = Color(hex: 0x3B82F6)
    static let amber = Color(hex: 0xF5A524)
    /// The battery's own palette, from the state matrix: a neutral shell, and
    /// three fill steps that say how much is left without reading the number.
    static let cellShell = Color(hex: 0x8E8E93)
    static let cellLow = Color(hex: 0xEF4444)

    // MARK: Battery scale
    //
    // Five discharge bands and one wall-power colour. Kept apart from the
    // general palette because they are a *scale*: the whole point is that a
    // glance at the colour tells you the level, so nothing else in the app may
    // borrow them and no band may be reused for a different meaning.
    //
    // `cellWall` is not `Theme.cyan` (0x00F0FF) on purpose — that one is the
    // processor's domain colour, and a battery that turned processor-cyan while
    // charging would collide with it in the menu bar.
    static let cellWall = Color(hex: 0x06B6D4)
    static let cellFull = Color(hex: 0x22C55E)
    static let cellHalf = Color(hex: 0xF4F4F5)
    static let cellWarn = Color(hex: 0xF97316)
    static let cellCritical = Color(hex: 0xEF4444)
    static let cellEmpty = Color(hex: 0xDC2626)
    static let crimson = Color(hex: 0xE0245E)

    // Borders
    static let borderSubtle = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.14)

    /// The ambient glow a stash surface takes on under the pointer. Low opacity
    /// and thrown downward — warmth coming off the panel, not a halo around it.
    static let ambient = Color(hex: 0xFF5E00)

    // Text
    static let textPrimary = Color(hex: 0xF0F2F5)
    static let textSecondary = Color(hex: 0x8A929E)
    /// Raised from the spec's #525866, which measures 2.42:1 on `surface` —
    /// well under WCAG AA, and it carries the smallest type in the UI (11px
    /// mono counts and footer). #7E8695 reads the same visual weight at 4.71:1.
    static let textMuted = Color(hex: 0x7E8695)

    // Accents
    static let orange = Color(hex: 0xFF4F00)
    static let green = Color(hex: 0x20C997)
    static let red = Color(hex: 0xFF5F56)
    /// Near-black on orange measures 5.95:1; the spec's white was 3.30:1.
    static let onAccent = Color(hex: 0x0A0B0D)

    /// A module's domain colour, from `WidgetKind.domainIndex`. Thermal (4)
    /// has no fixed colour — it is gated on temperature — so it falls back to
    /// the neutral trace and callers override it.
    static func domain(_ index: Int) -> Color {
        switch index {
        case 0: return cyan
        case 1: return purple
        case 2: return trace
        case 3: return blue
        default: return trace
        }
    }

    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 8

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Default lamp colour for a new Gruppe.
    static let defaultGroupHex = "#FF6B00"

    /// Quick-select swatches. Any hex is allowed via the colour picker; these
    /// are just the ones worth one click.
    struct PresetColor: Identifiable, Hashable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let presetColors: [PresetColor] = [
        .init(name: "Guards Red", hex: "#E10600"),
        .init(name: "Acid Green", hex: "#88E600"),
        .init(name: "Industrial Orange", hex: "#FF6B00"),
        .init(name: "Signal Yellow", hex: "#FAD02C"),
        .init(name: "Cobalt", hex: "#0051A8"),
    ]
}

// MARK: - Buttons

struct IndustrialButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary, danger, ghost }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, kind: kind)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.sans(12, .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .ghost ? 8 : 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                        .fill(background(pressed: configuration.isPressed))
                        .overlay(
                            // Lit cap: brighter along the top, like the
                            // illuminated rocker on the panel.
                            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                                .fill(
                                    LinearGradient(colors: [.white.opacity(kind == .primary ? 0.22 : 0.06), .clear],
                                                   startPoint: .top, endPoint: .center)
                                )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.975 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
                .onHover { hovering = isEnabled && $0 }
                .contentShape(Rectangle())
        }

        private var foreground: Color {
            switch kind {
            case .primary: return Theme.onAccent
            case .danger: return hovering ? Theme.textPrimary : Theme.red
            case .secondary: return Theme.textPrimary
            case .ghost: return hovering ? Theme.textPrimary : Theme.textSecondary
            }
        }

        private func background(pressed: Bool) -> Color {
            switch kind {
            case .primary:
                return pressed ? Color(hex: 0xC93E00) : (hovering ? Color(hex: 0xE04500) : Theme.orange)
            case .danger:
                return hovering ? Theme.red.opacity(0.16) : Theme.surfaceHover
            case .secondary:
                return pressed ? Theme.surfacePressed : (hovering ? Theme.surfacePressed : Theme.surfaceHover)
            case .ghost:
                return hovering ? Theme.surfaceHover : .clear
            }
        }

        private var border: Color {
            switch kind {
            case .primary: return hovering ? Color(hex: 0xE04500) : Theme.orange
            case .danger: return hovering ? Theme.red.opacity(0.55) : Theme.borderSubtle
            case .secondary: return hovering ? Theme.borderStrong : Theme.borderSubtle
            case .ghost: return hovering ? Theme.borderSubtle : .clear
            }
        }
    }
}

extension View {
    func industrialButton(_ kind: IndustrialButtonStyle.Kind = .secondary) -> some View {
        buttonStyle(IndustrialButtonStyle(kind: kind))
    }

    /// The keys on a stash: zip, clear, minimise, close.
    func hardwareKey(size: CGFloat = 22, tint: Color = Theme.textSecondary) -> some View {
        buttonStyle(HardwareKeyStyle(size: size, tint: tint))
    }
}

/// A lit rocker switch.
///
/// The stock macOS switch was drawing grey while on, ignoring `.tint` — which it
/// will do whenever the system accent is set to Graphite, since that overrides
/// app accent colours globally. Rather than fight AppKit for a control that
/// never matched the panel anyway, this draws it: a recessed track that
/// *ignites* orange when the setting is on, and a machined cap that slides.
/// The colour is now ours, so no system setting can grey it out.
struct IndustrialSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: ToggleStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private let width: CGFloat = 38
        private let height: CGFloat = 21
        private var knob: CGFloat { height - 5 }
        private var on: Bool { configuration.isOn }

        var body: some View {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? Theme.orange : Theme.input)
                        .overlay(
                            // Lit switches glow through the lens; unlit ones are
                            // a dark well with a shadow across the top lip.
                            Capsule()
                                .fill(LinearGradient(
                                    colors: on
                                        ? [.white.opacity(0.28), .clear]
                                        : [.black.opacity(0.75), .clear],
                                    startPoint: .top, endPoint: .center))
                        )
                        .overlay(
                            Capsule().strokeBorder(on ? Theme.orange.mixed(with: .black, amount: 0.35)
                                                      : Theme.machinedBorder,
                                                   lineWidth: 1)
                        )
                        .shadow(color: on ? Theme.orange.opacity(0.5) : .clear, radius: 6)

                    Circle()
                        .fill(LinearGradient(colors: [Color(white: 0.94), Color(white: 0.74)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
                        .padding(2.5)
                }
                .frame(width: width, height: height)
                .opacity(isEnabled ? 1 : 0.4)
                .brightness(hovering && isEnabled ? 0.06 : 0)
                .animation(.spring(response: 0.26, dampingFraction: 0.72), value: on)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

extension ToggleStyle where Self == IndustrialSwitchStyle {
    static var industrial: IndustrialSwitchStyle { IndustrialSwitchStyle() }
}

/// A lit slider, for the same reason the switch is drawn by hand: AppKit
/// renders the stock control's fill in grey whenever the system accent is set to
/// Graphite, `.tint` or no `.tint`.
///
/// A recessed groove, an orange fill up to the value, and a machined cap you can
/// drag or click along. Nothing about it resizes, so the row it sits in cannot
/// twitch while you drag.
struct IndustrialSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.1

    private let track: CGFloat = 6
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - knob, 1)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (value - range.lowerBound) / span : 0
            let x = usable * CGFloat(min(max(fraction, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.input)
                    .overlay(Capsule().strokeBorder(Theme.machinedBorder, lineWidth: 1))
                    .frame(height: track)

                Capsule()
                    .fill(Theme.orange)
                    .frame(width: x + knob / 2, height: track)
                    .shadow(color: Theme.orange.opacity(0.45), radius: 4)

                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.94), Color(white: 0.72)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
                    .offset(x: x)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let raw = Double((drag.location.x - knob / 2) / usable) * span + range.lowerBound
                    let stepped = step > 0 ? (raw / step).rounded() * step : raw
                    value = min(max(stepped, range.lowerBound), range.upperBound)
                }
            )
        }
        .frame(height: knob)
    }
}

/// A physical key in a machined socket.
///
/// At rest it is a dark cap sitting slightly proud of the panel: a highlight
/// along its top edge, a shadow beneath it. Hovering lights the cap and warms
/// the glyph. Pressing inverts the whole thing — the highlight moves to the
/// bottom, the shadow goes inside, and the cap sinks — which is what a key
/// actually does and what makes a click feel like it landed.
///
/// The cap never changes size, so a row of keys cannot shift under the pointer.
struct HardwareKeyStyle: ButtonStyle {
    var size: CGFloat = 22
    var tint: Color = Theme.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, size: size, tint: tint)
    }

    private struct KeyBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private var pressed: Bool { configuration.isPressed }
        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
        }

        var body: some View {
            configuration.label
                .foregroundStyle(pressed ? Theme.ambient : (hovering ? Theme.textPrimary : tint))
                .frame(width: size, height: size)
                .background(shape.fill(cap))
                .overlay(
                    // Lit edge: top when the key is up, bottom when it is down.
                    shape.stroke(
                        LinearGradient(colors: pressed
                                       ? [.black.opacity(0.6), .white.opacity(0.10)]
                                       : [.white.opacity(hovering ? 0.16 : 0.09), .black.opacity(0.45)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                )
                .overlay(
                    // Pressed keys take their shadow on the inside.
                    shape
                        .stroke(Color.black.opacity(pressed ? 0.75 : 0), lineWidth: 4)
                        .blur(radius: 3)
                        .offset(y: 1.5)
                        .mask(shape)
                )
                .shadow(color: .black.opacity(pressed ? 0 : 0.5), radius: pressed ? 0 : 2, y: pressed ? 0 : 1)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
                .animation(.easeOut(duration: 0.11), value: hovering)
                .animation(.easeOut(duration: 0.06), value: pressed)
                .onHover { hovering = isEnabled && $0 }
        }

        private var cap: Color {
            if pressed { return Color(hex: 0x0B0B0D) }
            return hovering ? Color(hex: 0x232329) : Color(hex: 0x181A1E)
        }
    }
}

// MARK: - Small components

/// Monochrome noise tile used to give flat surfaces a moulded, slightly gritty
/// finish. Generated once at 128×128 and tiled — it never changes, so it costs
/// nothing after the first draw.
enum PanelTexture {
    static let grain: NSImage = makeGrain(side: 128)

    private static func makeGrain(side: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: side * 4, bitsPerPixel: 32)!
        if let data = rep.bitmapData {
            var generator = SystemRandomNumberGenerator()
            for pixel in 0..<(side * side) {
                // Wide spread on purpose: `.overlay` blending leaves the base
                // untouched at mid-grey, so noise clustered around 128 is
                // invisible no matter what opacity it is given.
                let value = UInt8.random(in: 56...200, using: &generator)
                let offset = pixel * 4
                data[offset] = value
                data[offset + 1] = value
                data[offset + 2] = value
                data[offset + 3] = 255
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }
}

struct Grain: ViewModifier {
    var opacity: Double = 0.28
    /// Clips the tile to a rounded shape so it can be laid onto a card's
    /// background without squaring off the corners.
    var cornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay(
            Image(nsImage: PanelTexture.grain)
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.overlay)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
        )
    }
}

/// The inverse of `.bezel()` — dark along the top lip, catching light at the
/// bottom, so the surface reads as milled *into* the panel. Used for anything
/// that should feel like a well: inputs, key caps, icon sockets.
struct Recessed: ViewModifier {
    var cornerRadius: CGFloat = Theme.radiusSm
    var fill: Color = Theme.input

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.15), .white.opacity(0.07)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
    }
}

/// The machined groove: dark titanium, a crisp dark border, and a heavy shadow
/// cast *inwards* from the top lip, so whatever sits in it reads as stamped into
/// the body rather than laid on it.
///
/// SwiftUI has no inner shadow, so this is the standard construction: a thick
/// stroke of black, blurred, pushed down, and masked to the shape with a
/// top-to-bottom falloff. All of it is decoration — `allowsHitTesting(false)`
/// throughout, and none of it changes on hover, so a row cannot shift under the
/// pointer.
struct MachinedRecess: ViewModifier {
    var cornerRadius: CGFloat = Theme.radiusSm
    var fill: Color = Theme.machined
    var border: Color = Theme.machinedBorder

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fill))
            .background(
                shape
                    .stroke(Color.black.opacity(0.8), lineWidth: 5)
                    .blur(radius: 4)
                    .offset(y: 2)
                    .mask(
                        shape.fill(
                            LinearGradient(colors: [.black, .black.opacity(0.12)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false))
            .clipShape(shape)
    }
}

extension View {
    /// Apply to a *background*, never over content — grain laid on top of text
    /// makes it gritty long before the surface looks textured.
    func grain(_ opacity: Double = 0.28, cornerRadius: CGFloat = 0) -> some View {
        modifier(Grain(opacity: opacity, cornerRadius: cornerRadius))
    }

    func recessed(cornerRadius: CGFloat = Theme.radiusSm, fill: Color = Theme.input) -> some View {
        modifier(Recessed(cornerRadius: cornerRadius, fill: fill))
    }

    /// Every file container, list row and instruction card in the app.
    func machined(cornerRadius: CGFloat = Theme.radiusSm,
                  fill: Color = Theme.machined,
                  border: Color = Theme.machinedBorder) -> some View {
        modifier(MachinedRecess(cornerRadius: cornerRadius, fill: fill, border: border))
    }

    /// Warmth off the panel while the pointer is on it. Shadow only — nothing
    /// about the layout moves.
    func ambientGlow(_ active: Bool) -> some View {
        shadow(color: active ? Theme.ambient.opacity(0.15) : .black.opacity(0.45),
               radius: active ? 25 : 8,
               y: active ? 20 : 4)
    }
}

/// An indicator lamp, borrowed from the switch panel in the app icon: a lens
/// with a specular highlight, and a bloom when it is lit.
///
/// Only lit lamps cast a shadow — an unlit one is just a dark lens, which is
/// both truer to the hardware and cheaper to draw.
struct LED: View {
    let color: Color
    var lit: Bool = true
    var size: CGFloat = 10

    /// Ignition. A filament does not fade up linearly — it overshoots and
    /// settles, which is the difference between a lamp switching on and an
    /// opacity animation. Drives the bloom only; the lens and the layout are
    /// fixed, so nothing around it can move.
    @State private var ignition: CGFloat = 0

    var body: some View {
        ZStack {
            if lit {
                Circle()
                    .fill(color.bloom(radius: size * 1.6))
                    .frame(width: size * 3.2, height: size * 3.2)
                    .scaleEffect(ignition)
                    .opacity(Double(min(ignition, 1)))
                    // Volumetric: the glow reads as light in the air around the
                    // lens rather than a ring drawn on the panel.
                    .shadow(color: color.opacity(0.7 * Double(min(ignition, 1))), radius: 12)
            }

            Circle()
                .fill(lit ? AnyShapeStyle(color.lensGradient) : AnyShapeStyle(color.lensTint))
                .overlay(
                    // Specular glint across the top of the lens.
                    Circle()
                        .fill(
                            LinearGradient(colors: [.white.opacity(lit ? 0.55 : 0.16), .clear],
                                           startPoint: .top, endPoint: .center)
                        )
                        .padding(size * 0.16)
                )
                .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: 0.5))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { ignite(lit, animated: false) }
        .onChange(of: lit) { ignite($0, animated: true) }
    }

    private func ignite(_ on: Bool, animated: Bool) {
        guard animated else { ignition = on ? 1 : 0; return }
        guard on else {
            withAnimation(.easeOut(duration: 0.18)) { ignition = 0 }
            return
        }
        // Surge, then settle.
        withAnimation(.easeOut(duration: 0.09)) { ignition = 1.35 }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55).delay(0.09)) { ignition = 1 }
    }
}

/// Hairline highlight along the top edge, the way light catches moulded
/// plastic. Applied to panels and cards to give them a sense of depth.
struct BezelHighlight: ViewModifier {
    var cornerRadius: CGFloat = Theme.radiusMd

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.02), .clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
    }
}

extension View {
    func bezel(cornerRadius: CGFloat = Theme.radiusMd) -> some View {
        modifier(BezelHighlight(cornerRadius: cornerRadius))
    }
}

/// Mono uppercase chip — AKTIV, SYSTEM OVERVIEW, and friends.
struct Chip: View {
    let text: String
    var tint: Color = Theme.green
    var size: CGFloat = 10

    var body: some View {
        Text(text)
            .font(Theme.mono(size, .semibold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(tint.opacity(0.3), lineWidth: 1)
            )
    }
}

/// Keyboard shortcut badge. Dims when the shortcut could not be claimed from
/// the system, so the badge never promises a binding that does not work.
struct KeyBadge: View {
    let text: String
    var enabled: Bool = true

    var body: some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(enabled ? Theme.textSecondary : Theme.textMuted.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .recessed(cornerRadius: 3)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(enabled ? Theme.borderStrong.opacity(0.6) : .clear, lineWidth: 1)
            )
            .strikethrough(!enabled, color: Theme.textMuted)
    }
}
