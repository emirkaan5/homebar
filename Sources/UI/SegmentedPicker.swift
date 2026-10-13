import SwiftUI

/// A black-and-white segmented control. The selected option is a solid pill
/// that slides between options; only its icon keeps the option's colour.
struct SegmentedPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        let symbol: String
        let tint: Color
    }

    let options: [Option]
    let selection: Value?
    var isEnabled = true
    let onSelect: (Value) -> Void

    @Namespace private var namespace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button { onSelect(option.value) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? option.tint : Color.secondary)
                        Text(option.title)
                            .foregroundStyle(isSelected ? Palette.paper(scheme) : Color.secondary)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.primary)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.surface, in: Capsule())
        .animation(Motion.snappy, value: selection)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}
