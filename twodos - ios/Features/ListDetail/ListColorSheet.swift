import SwiftUI

/// Picking a list's colour.
///
/// A drill-down rather than the horizontal scroller this replaced. That
/// scroller lived inline in the settings sheet, which meant the eight colours
/// competed with every other setting for attention and only three or four were
/// visible at a time — so the one you wanted was usually off-screen, in a sheet
/// you were not scrolling horizontally in.
///
/// Laid out as a grid, every colour is visible at once and the choice takes one
/// tap. Selection applies immediately: recolouring is instantly reversible and
/// there is nothing to confirm.
struct ListColorSheet: View {
    let selected: ListTint
    let onSelect: (ListTint) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(ListTint.all) { tint in
                            swatch(tint)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func swatch(_ tint: ListTint) -> some View {
        let isSelected = tint.hex.uppercased() == selected.hex.uppercased()

        return Button {
            Haptics.selection()
            onSelect(tint)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(tint.color)
                        .frame(width: 46, height: 46)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay {
                    Circle().strokeBorder(
                        isSelected ? Color.primary.opacity(0.45) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2.5 : 1
                    )
                }
                .scaleEffect(isSelected ? 1.06 : 1)

                Text(tint.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .motion(Motion.tap, value: isSelected)
        .accessibilityLabel(tint.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
