import AppKit

/// Нативные составные SF Symbols сохраняют оптическую центровку символа внутри круга.
final class HUDStatusIconView: NSView {
    private let imageView = NSImageView()
    private var symbolName = ""
    var tint: NSColor = .white { didSet { imageView.contentTintColor = tint } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.frame = bounds
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ name: String) {
        let native: String
        if name.hasPrefix("exclamationmark") { native = "exclamationmark.triangle.fill" }
        else if name.hasPrefix("mic") { native = "mic.circle.fill" }
        else if name.hasPrefix("checkmark") { native = "checkmark.circle.fill" }
        else if name.hasPrefix("info") { native = "info.circle.fill" }
        else { native = name }
        guard native != symbolName else { return }
        symbolName = native
        imageView.image = NSImage(systemSymbolName: native, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }
}

enum HUDIconDrawing {
    static func filledCircle(in rect: NSRect, color: NSColor, cutout: () -> Void) {
        guard rect.width > 0, rect.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Просвет удаляет только часть иконки; фон бабла под ней остаётся целым.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
        context.saveGState()
        context.setBlendMode(.destinationOut)
        cutout()
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
