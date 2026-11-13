import AppKit

/// Чистая геометрия: центр карточки под мышью; у нижнего края — над ней.
struct HUDPlacement {
    let origin: NSPoint
    let growsUpward: Bool

    static func calculate(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> HUDPlacement {
        let frame = visibleFrame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 10
        let x = max(frame.minX, min(anchor.midX - size.width / 2, frame.maxX - size.width))
        let below = anchor.minY - gap - size.height
        let above = anchor.maxY + gap
        let upward = below < frame.minY && (above + size.height <= frame.maxY
                                           || anchor.minY - frame.minY < frame.maxY - anchor.maxY)
        let y = max(frame.minY, min(upward ? above : below, frame.maxY - size.height))
        return HUDPlacement(origin: NSPoint(x: x, y: y), growsUpward: upward)
    }
}

/// Позиция фиксируется один раз. Ширина меняется вокруг общей центральной оси;
/// высота растёт от мыши: вниз под указателем, вверх — над ним.
struct HUDSessionPosition {
    let visibleFrame: NSRect
    let attachment: NSPoint
    let growsUpward: Bool

    var availableHeight: CGFloat {
        growsUpward ? visibleFrame.maxY - 8 - attachment.y : attachment.y - visibleFrame.minY - 8
    }

    init(anchor: NSRect, visibleFrame: NSRect, reservedSize: NSSize) {
        self.visibleFrame = visibleFrame
        let placement = HUDPlacement.calculate(size: reservedSize, anchor: anchor, visibleFrame: visibleFrame)
        growsUpward = placement.growsUpward
        attachment = NSPoint(x: placement.origin.x + reservedSize.width / 2,
                             y: placement.origin.y + (growsUpward ? 0 : reservedSize.height))
    }

    func frame(for size: NSSize) -> NSRect {
        NSRect(x: attachment.x - size.width / 2,
               y: attachment.y - (growsUpward ? 0 : size.height),
               width: size.width, height: size.height)
    }
}
