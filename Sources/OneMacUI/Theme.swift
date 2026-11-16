import SwiftUI

/// Font sizes used across OneMac. Nothing smaller than `caption`; bold only from `value` up.
public enum FS {
    public static let caption: CGFloat = 10
    public static let label: CGFloat = 11
    public static let body: CGFloat = 12
    public static let title: CGFloat = 13
    public static let subhead: CGFloat = 14
    public static let value: CGFloat = 16
    public static let display: CGFloat = 28
}

/// Corner radii.
public enum Rad {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 10
    public static let lg: CGFloat = 14
}

/// Spacing.
public enum Gap {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
}

/// Popover size shared by the menu-bar panel and the preview renderer.
public enum PanelSize {
    public static let width: CGFloat = 380
    public static let height: CGFloat = 600
}

public extension Color {
    /// Card fill: a lifted surface in dark mode, a soft grey in light mode.
    static let cardFill = Color.primary.opacity(0.06)
    static let tileFill = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.08)
}
