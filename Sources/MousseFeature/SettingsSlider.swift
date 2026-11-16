import OneMacUI
import SwiftUI

/// One slider setting: title, explanation and live value on top, the slider with its end labels
/// beneath. `Slider`'s own `step:` draws a tick per step — 30–60 ticks read as a grey bar — so
/// snapping happens in the binding instead and the stored value still lands on the step grid.
struct SettingsSlider: View {
    let title: String
    var detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var minLabel = ""
    var maxLabel = ""

    var body: some View {
        SettingsStack(title, detail: detail, value: format(value)) {
            HStack(spacing: Gap.sm) {
                if !minLabel.isEmpty { endLabel(minLabel) }
                Slider(value: snapped, in: range).labelsHidden().controlSize(.small)
                if !maxLabel.isEmpty { endLabel(maxLabel) }
            }
        }
    }

    private func endLabel(_ text: String) -> some View {
        Text(text).font(.system(size: FS.label)).foregroundStyle(.secondary)
    }

    private var snapped: Binding<Double> {
        Binding(
            get: { value },
            set: { raw in
                let stepped = (raw / step).rounded() * step
                value = min(max(stepped, range.lowerBound), range.upperBound)
            })
    }
}
