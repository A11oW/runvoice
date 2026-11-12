import AppKit
import ApplicationServices

/// Координаты каретки читаются без выделения текста, ⌘C и смены фокуса.
enum HUDAnchor {
    static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &selected) == .success,
              let selected, CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
        let value = selected as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange,
              AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }

        // При выделении привязываемся к его концу, а не ко всему полю ввода.
        var caret = CFRange(location: range.location + range.length, length: 0)
        let parameter = AXValueCreate(.cfRange, &caret)!
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let bounds = result as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(bounds) == .cgRect,
              AXValueGetValue(bounds, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width >= 0, rect.height > 0 else { return nil }
        // AX: начало сверху слева основного экрана. AppKit: снизу слева.
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = NSRect(x: rect.minX, y: desktopTop - rect.maxY,
                           width: max(1, rect.width), height: rect.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(cocoa) }) else { return nil }
        return cocoa
    }
}

/// Чистая геометрия: бабл ниже каретки; у нижнего края — выше неё.
struct HUDPlacement {
    let origin: NSPoint

    static func calculate(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> HUDPlacement {
        let margin: CGFloat = 8
        let gap: CGFloat = 10
        let frame = visibleFrame.insetBy(dx: margin, dy: margin)
        let x = max(frame.minX, min(anchor.midX - 32, frame.maxX - size.width))
        let below = anchor.minY - gap - size.height
        let above = anchor.maxY + gap
        let atTop = below >= frame.minY || above + size.height > frame.maxY
        let y = max(frame.minY, min(atTop ? below : above, frame.maxY - size.height))
        return HUDPlacement(origin: NSPoint(x: x, y: y))
    }
}

/// Снимок позиции на всю операцию. Рост текста меняет только размер карточки:
/// верхний левый угол остаётся на месте, указатель и каретка больше не опрашиваются.
struct HUDSessionPosition {
    let visibleFrame: NSRect
    let topLeft: NSPoint

    init(anchor: NSRect, visibleFrame: NSRect, reservedSize: NSSize) {
        self.visibleFrame = visibleFrame
        let placement = HUDPlacement.calculate(size: reservedSize, anchor: anchor,
                                                visibleFrame: visibleFrame)
        topLeft = NSPoint(x: placement.origin.x, y: placement.origin.y + reservedSize.height)
    }

    func frame(for size: NSSize) -> NSRect {
        NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }
}
