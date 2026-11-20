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
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds:
            // The centre third takes the rounding remainder, so the three tile without gaps.
            let third = floor(visible.width / 3)
            let (x, w): (CGFloat, CGFloat)
            switch action {
            case .leftThird: (x, w) = (visible.minX, third)
            case .centerThird: (x, w) = (visible.minX + third, visible.width - 2 * third)
            case .rightThird: (x, w) = (visible.maxX - third, third)
            case .leftTwoThirds: (x, w) = (visible.minX, visible.width - third)
            default: (x, w) = (visible.minX + third, visible.width - third)
            }
            return CGRect(x: x, y: visible.minY, width: w, height: visible.height)
        case .almostMaximize:
            let w = floor(visible.width * almostMaximizeShare), h = floor(visible.height * almostMaximizeShare)
            return CGRect(x: visible.minX + floor((visible.width - w) / 2), y: visible.minY + floor((visible.height - h) / 2),
                          width: w, height: h)
        case .restore, .nextDisplay, .previousDisplay: return current
        }
    }

    /// Share of the usable area an almost-maximised window takes on each axis.
    static let almostMaximizeShare: CGFloat = 0.9

    /// The sizes a repeated half walks through: 1/2 → 2/3 → 1/3 → 1/2.
    private static func cycle(for action: WindowAction) -> [WindowAction]? {
        switch action {
        case .leftHalf: return [.leftHalf, .leftTwoThirds, .leftThird]
        case .rightHalf: return [.rightHalf, .rightTwoThirds, .rightThird]
        default: return nil
        }
    }

    /// Like `frame(for:in:current:)`, but a left or right half pressed again while the window already
    /// sits at one of the cycle's frames moves on to the next size.
    static func cycledFrame(for action: WindowAction, in visible: CGRect, current: CGRect) -> CGRect {
        guard let steps = cycle(for: action) else { return frame(for: action, in: visible, current: current) }
        let frames = steps.map { frame(for: $0, in: visible, current: current) }
        guard let at = frames.firstIndex(where: { matches($0, current, slack: cycleSlack) }) else { return frames[0] }
        return frames[(at + 1) % frames.count]
    }

    /// How far a window may be from a cycle frame and still count as sitting at it.
    static let cycleSlack: CGFloat = 6

    static func matches(_ a: CGRect, _ b: CGRect, slack: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= slack && abs(a.minY - b.minY) <= slack
            && abs(a.width - b.width) <= slack && abs(a.height - b.height) <= slack
    }

    /// Where to slide a window that came out larger than asked (an app enforcing a minimum size, or
    /// refusing to resize) so it does not hang off the display. Nil when it already fits. A window
    /// larger than the area keeps its top-left corner on screen, where the title bar is.
    static func originKeepingOnDisplay(_ frame: CGRect, in area: CGRect) -> CGPoint? {
        guard isValid(frame), isValid(area) else { return nil }
        let x = max(area.minX, min(frame.minX, area.maxX - frame.width))
        let y = max(area.minY, min(frame.minY, area.maxY - frame.height))
        guard abs(x - frame.minX) > 1 || abs(y - frame.minY) > 1 else { return nil }
        return CGPoint(x: x, y: y)
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
