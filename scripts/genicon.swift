// genicon.swift — рисует иконку приложения 1024×1024 и сохраняет PNG.
// Использование: genicon <output.png>

import AppKit

guard CommandLine.arguments.count > 1 else { exit(2) }
let out = CommandLine.arguments[1]
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// фон: скруглённый квадрат с градиентом
let inset = size * 0.055
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.57, green: 0.25, blue: 0.87, alpha: 1),
])!
gradient.draw(in: shape, angle: -90)

// лёгкий блик сверху (внутри контура, с плавным затуханием)
NSGraphicsContext.saveGraphicsState()
shape.addClip()
let gloss = NSGradient(colors: [
    NSColor(white: 1, alpha: 0.16),
    NSColor(white: 1, alpha: 0.0),
])!
gloss.draw(in: NSRect(x: inset, y: size * 0.42, width: size - inset * 2, height: size * 0.53),
           angle: -90)
NSGraphicsContext.restoreGraphicsState()

// белый символ «waveform»
if let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = base.withSymbolConfiguration(cfg) {
        let s = symbol.size
        let target = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2,
                            width: s.width, height: s.height)
        symbol.draw(in: target)
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }

try png.write(to: URL(fileURLWithPath: out))
