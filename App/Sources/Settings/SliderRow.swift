import SwiftUI

/// A percentage slider in a Settings row (1.26.1): the name and value on one
/// line, the slider under them across the row (it was squeezed to 170 pt
/// beside the name, and pushed off the row at large text sizes).
struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
    }

    private var percent: String { value.formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text(percent).monospacedDigit()
            }
            .accessibilityHidden(true)
            Slider(value: $value, in: range, step: step) { Text(title) }
                .accessibilityValue(percent)
        }
    }
}
