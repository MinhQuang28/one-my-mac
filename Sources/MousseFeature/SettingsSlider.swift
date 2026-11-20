import OneMacUI
import SwiftUI

/// One slider setting: title, explanation and live value on top, the slider with its end labels
/// beneath.
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
                CapsuleSlider(value: $value, in: range, step: step, label: title, height: 18)
                if !maxLabel.isEmpty { endLabel(maxLabel) }
            }
        }
    }

    private func endLabel(_ text: String) -> some View {
        Text(text).font(.system(size: FS.label)).foregroundStyle(.secondary)
    }
}
