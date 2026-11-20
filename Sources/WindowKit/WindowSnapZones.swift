import CoreGraphics

/// Where a window dragged to a screen edge would snap: which display, and to what.
struct WindowSnapZone: Equatable {
    let display: Int
    let action: WindowAction
}

/// Pure hit-testing for drag-to-edge snapping. Coordinates are Accessibility ones (top-left origin).
enum WindowSnapZones {
    /// How close (in points) the pointer must be to a display edge to count as pushed against it.
    static let edge: CGFloat = 5
    /// How far along an edge, from a corner, still counts as that corner.
    static let corner: CGFloat = 120

    /// The zone under `pointer`, given every display's full frame:
    /// top edge = maximize, left/right edge = that half, the ends of an edge = that quarter.
    /// The middle of the bottom edge is left alone — that is where the Dock lives.
    static func zone(at pointer: CGPoint, displays: [CGRect]) -> WindowSnapZone? {
        // The pointer stops a fraction of a point short of the far edges, hence the 1 pt of grace.
        guard let index = displays.firstIndex(where: { $0.insetBy(dx: -1, dy: -1).contains(pointer) }) else { return nil }
        let display = displays[index]
        let fromLeft = pointer.x - display.minX, fromRight = display.maxX - pointer.x
        let fromTop = pointer.y - display.minY, fromBottom = display.maxY - pointer.y

        let action: WindowAction?
        if fromLeft <= edge || fromRight <= edge {
            let left = fromLeft <= edge
            if fromTop <= corner { action = left ? .topLeft : .topRight }
            else if fromBottom <= corner { action = left ? .bottomLeft : .bottomRight }
            else { action = left ? .leftHalf : .rightHalf }
        } else if fromTop <= edge {
            action = fromLeft <= corner ? .topLeft : fromRight <= corner ? .topRight : .maximize
        } else if fromBottom <= edge {
            action = fromLeft <= corner ? .bottomLeft : fromRight <= corner ? .bottomRight : nil
        } else {
            action = nil
        }
        return action.map { WindowSnapZone(display: index, action: $0) }
    }
}
