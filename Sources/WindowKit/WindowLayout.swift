import CoreGraphics

/// Pure window geometry. Every rectangle is in Accessibility coordinates: origin at the top-left
/// corner of the primary display, y growing downwards.
enum WindowLayout {
    /// How close (in points) a window edge must be to a display edge to count as touching it.
    static let edgeSlack: CGFloat = 4

    /// The frame an action gives a window inside the usable area of its display. `restore` and the
    /// display moves need more context and are resolved by `WindowMover`; here they keep the frame.
    static func frame(for action: WindowAction, in visible: CGRect, current: CGRect) -> CGRect {
        let halfW = floor(visible.width / 2), halfH = floor(visible.height / 2)
        let right = visible.maxX - halfW, bottom = visible.maxY - halfH
        switch action {
        case .leftHalf: return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: visible.height)
        case .rightHalf: return CGRect(x: right, y: visible.minY, width: halfW, height: visible.height)
        case .topHalf: return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfH)
        case .bottomHalf: return CGRect(x: visible.minX, y: bottom, width: visible.width, height: halfH)
        case .topLeft: return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: halfH)
        case .topRight: return CGRect(x: right, y: visible.minY, width: halfW, height: halfH)
        case .bottomLeft: return CGRect(x: visible.minX, y: bottom, width: halfW, height: halfH)
        case .bottomRight: return CGRect(x: right, y: bottom, width: halfW, height: halfH)
        case .maximize: return visible
        case .center:
            // Keep the window's size, only shrink it when the display is smaller.
            let w = min(current.width, visible.width), h = min(current.height, visible.height)
            return CGRect(x: visible.minX + (visible.width - w) / 2, y: visible.minY + (visible.height - h) / 2,
                          width: w, height: h)
        case .restore, .nextDisplay, .previousDisplay: return current
        }
    }

    static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    /// Moves a window from one display's usable area to another's, one axis at a time:
    /// - on an axis where the window touches an edge (a half, a quarter, a maximised window) it is
    ///   *tiled*, so it keeps its share of the display: a left half stays a left half;
    /// - on an axis where it floats free it keeps its size in points (shrunk to fit) and its centre
    ///   lands at the same relative spot.
    static func transfer(window: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard isValid(window), isValid(source), isValid(destination) else { return window }
        let x = mapAxis(window.minX, window.maxX, from: source.minX, source.maxX, to: destination.minX, destination.maxX)
        let y = mapAxis(window.minY, window.maxY, from: source.minY, source.maxY, to: destination.minY, destination.maxY)
        return CGRect(x: x.lower, y: y.lower, width: x.upper - x.lower, height: y.upper - y.lower)
    }

    /// One axis of `transfer`, as a segment `lower...upper` mapped between two ranges.
    private static func mapAxis(_ lower: CGFloat, _ upper: CGFloat, from a0: CGFloat, _ a1: CGFloat,
                                to b0: CGFloat, _ b1: CGFloat) -> (lower: CGFloat, upper: CGFloat) {
        let sourceLength = a1 - a0, targetLength = b1 - b0
        let tiled = abs(lower - a0) <= edgeSlack || abs(a1 - upper) <= edgeSlack
            || lower < a0 || upper > a1
        if tiled {
            // Share of the source range, clamped to it, laid onto the target range.
            func share(_ v: CGFloat) -> CGFloat { min(max((v - a0) / sourceLength, 0), 1) }
            let start = (b0 + share(lower) * targetLength).rounded()
            let end = (b0 + share(upper) * targetLength).rounded()
            if end - start >= 1 { return (start, end) }
        }
        let length = min(upper - lower, targetLength)
        let centre = b0 + (((lower + upper) / 2 - a0) / sourceLength) * targetLength
        let start = min(max(centre - length / 2, b0), b1 - length).rounded()
        return (start, start + length)
    }

    /// The display a window belongs to: the one holding most of it, else the nearest by centre.
    static func displayIndex(containing window: CGRect, displays: [CGRect]) -> Int? {
        guard !displays.isEmpty else { return nil }
        func overlap(_ display: CGRect) -> CGFloat {
            let part = display.intersection(window)
            return part.isNull ? 0 : part.width * part.height
        }
        if let best = displays.indices.max(by: { overlap(displays[$0]) < overlap(displays[$1]) }),
           overlap(displays[best]) > 0 { return best }
        func distance(_ display: CGRect) -> CGFloat { hypot(window.midX - display.midX, window.midY - display.midY) }
        return displays.indices.min(by: { distance(displays[$0]) < distance(displays[$1]) })
    }

    /// `frame` shrunk to fit inside `area` and slid in from whichever side it overhangs.
    static func fit(_ frame: CGRect, into area: CGRect) -> CGRect {
        let w = min(frame.width, area.width), h = min(frame.height, area.height)
        let x = min(max(frame.minX, area.minX), area.maxX - w)
        let y = min(max(frame.minY, area.minY), area.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
