import SwiftUI

/// Choosing how the lists screen is ordered.
struct SortSheet: View {
    @Binding var selection: SortOrder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        GlassSection(
                            footer: "Overdue lists always appear at the top, whichever order you pick. Favourites come next."
                        ) {
                            ForEach(Array(SortOrder.allCases.enumerated()), id: \.element) { index, order in
                                GlassRow(
                                    icon: order.icon,
                                    title: order.title,
                                    subtitle: order.subtitle,
                                    action: {
                                        selection = order
                                        Haptics.selection()
                                        dismiss()
                                    }
                                ) {
                                    if selection == order {
                                        Image(systemName: "checkmark")
                                            .font(.footnote.weight(.bold))
                                            .foregroundStyle(Color.accentColor)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .accessibilityAddTraits(selection == order ? [.isSelected, .isButton] : .isButton)

                                if index < SortOrder.allCases.count - 1 { GlassDivider() }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 8)
                    .motion(Motion.tap, value: selection)
                }
            }
            .navigationTitle("Sort by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
