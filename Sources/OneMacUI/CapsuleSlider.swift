import SwiftUI

/// The app's slider, in the Control Center style: a thick capsule track, a white fill up to a round
/// knob, and an optional glyph inside the leading end. `Slider` can't be styled this way on macOS.
///
/// `step` snaps the stored value without drawing ticks — `Slider(step:)` draws one per step, and
/// 30–60 of them read as a grey bar.
public struct CapsuleSlider: View {

    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let icon: String?
    let label: String
    let height: CGFloat
    let onEditingChanged: (Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var editing = false

    public init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, step: Double? = nil,
                icon: String? = nil, label: String, height: CGFloat = 22,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.icon = icon
        self.label = label
        self.height = height
        self.onEditingChanged = onEditingChanged
    }

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, height)
            let travel = width - height
            let fillWidth = height + travel * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.white).frame(width: fillWidth)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: height, height: height)
                    .offset(x: fillWidth - height)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: height * 0.5, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.6))
                        .frame(width: height, height: height)
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !editing { editing = true; onEditingChanged(true) }
                        guard travel > 0 else { return }
                        set(fraction: (drag.location.x - height / 2) / travel)
                    }
                    .onEnded { _ in
                        editing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: height)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let delta = step.map { $0 / span } ?? 0.05
            // Bracketed like a drag, so callers that commit on release see the change too.
            onEditingChanged(true)
            switch direction {
            case .increment: set(fraction: fraction + delta)
            case .decrement: set(fraction: fraction - delta)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }

    private func set(fraction raw: Double) {
        var next = range.lowerBound + min(max(raw, 0), 1) * span
        if let step, step > 0 {
            next = range.lowerBound + ((next - range.lowerBound) / step).rounded() * step
        }
        next = min(max(next, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }
}
