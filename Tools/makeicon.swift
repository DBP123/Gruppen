// Renders Resources/AppIcon.icns. Run with: swift Tools/makeicon.swift
import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current!.saveGraphicsState()
    let s = size / 1024.0
    NSGraphicsContext.current!.cgContext.setShouldAntialias(true)

    // Industrial Dark panel.
    let inset = 80 * s
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: 200 * s, yRadius: 200 * s)
    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.094, green: 0.106, blue: 0.125, alpha: 1),  // #181B20
        NSColor(calibratedRed: 0.039, green: 0.043, blue: 0.051, alpha: 1),  // #0A0B0D
    ])!
    gradient.draw(in: rect, angle: -90)

    // Hairline edge, the same idea as --border-strong.
    NSColor.white.withAlphaComponent(0.14).setStroke()
    let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 1 * s, dy: 1 * s),
                            xRadius: 200 * s, yRadius: 200 * s)
    edge.lineWidth = 6 * s
    edge.stroke()

    // Three stacked Gruppen rows; the top one is active and carries the
    // orange rail from .gruppe-card.active-state.
    let cardWidth = 470 * s
    let cardHeight = 140 * s
    let gap = 50 * s
    let radius = 34 * s
    let centerX = size / 2
    let totalHeight = cardHeight * 3 + gap * 2
    var y = (size - totalHeight) / 2

    for index in 0..<3 {
        let isActive = index == 2
        let cardRect = NSRect(x: centerX - cardWidth / 2, y: y, width: cardWidth, height: cardHeight)
        NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius).addClip()

        NSColor.white.withAlphaComponent(isActive ? 0.10 : 0.05).setFill()
        NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius).fill()

        NSColor.white.withAlphaComponent(isActive ? 0.20 : 0.09).setStroke()
        let border = NSBezierPath(roundedRect: cardRect.insetBy(dx: 2 * s, dy: 2 * s),
                                  xRadius: radius, yRadius: radius)
        border.lineWidth = 4 * s
        border.stroke()

        if isActive {
            // Left rail.
            NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.0, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: cardRect.minX, y: cardRect.minY,
                                      width: 22 * s, height: cardRect.height)).fill()
            // Status dot.
            let dotSize = 46 * s
            NSColor(calibratedRed: 0.125, green: 0.788, blue: 0.592, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: cardRect.minX + 70 * s,
                                        y: cardRect.midY - dotSize / 2,
                                        width: dotSize, height: dotSize)).fill()
        }

        NSGraphicsContext.current!.restoreGraphicsState()
        NSGraphicsContext.current!.saveGraphicsState()
        path.addClip()

        y += cardHeight + gap
    }

    NSGraphicsContext.current!.restoreGraphicsState()
    image.unlockFocus()
    return image
}

/// Loads Resources/icon-source.png if present. A supplied artwork always wins
/// over the drawn fallback — drop a square PNG (1024x1024 ideally) there and
/// rerun this script.
func sourceArtwork() -> NSImage? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/icon-source.png")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return NSImage(contentsOf: url)
}

/// Redraws artwork at an exact pixel size, preserving aspect ratio.
func scaled(_ image: NSImage, to size: CGFloat) -> NSImage {
    let out = NSImage(size: NSSize(width: size, height: size))
    out.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = min(image.size.width, image.size.height)
    let crop = NSRect(x: (image.size.width - side) / 2,
                      y: (image.size.height - side) / 2,
                      width: side, height: side)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: crop, operation: .copy, fraction: 1)
    out.unlockFocus()
    return out
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let artwork = sourceArtwork()
if artwork != nil { print("Using Resources/icon-source.png") }

for (name, size) in variants {
    let image = artwork.map { scaled($0, to: size) } ?? drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

try? fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
