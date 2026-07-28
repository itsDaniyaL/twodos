import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// What the user sees while they are at a place with things to do there.
///
/// Three presentations of one idea, at very different sizes:
///
/// - **Lock Screen / banner** — the list, tickable.
/// - **Dynamic Island, expanded** — the same, shorter.
/// - **Dynamic Island, compact** — a count, because that is all that fits beside
///   the camera.
///
/// Every one of them leads with *where*, not *what*. The user already knows what
/// they came for; what they want confirming is that they are in the right place
/// and how much is left before they can leave.
struct PlaceVisitLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaceVisitAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(Brand.meadow)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title3)
                        .foregroundStyle(Brand.meadow)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.doneCount)/\(context.state.totalCount)")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.placeName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    itemList(context, limit: 3)
                }
            } compactLeading: {
                Image(systemName: "checklist")
                    .foregroundStyle(Brand.meadow)
            } compactTrailing: {
                Text("\(remainingCount(context))")
                    .monospacedDigit()
                    .foregroundStyle(Brand.meadow)
            } minimal: {
                Text("\(remainingCount(context))")
                    .monospacedDigit()
                    .foregroundStyle(Brand.meadow)
            }
            .widgetURL(DeepLink.list(id: context.attributes.listId).url)
            .keylineTint(Brand.meadow)
        }
    }

    private func remainingCount(_ context: ActivityViewContext<PlaceVisitAttributes>) -> Int {
        max(0, context.state.totalCount - context.state.doneCount)
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<PlaceVisitAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.meadow)
                Text(context.attributes.placeName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(context.state.doneCount)/\(context.state.totalCount)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if context.state.isComplete {
                // The reason to look at this is gone. Saying so plainly is
                // better than showing an empty list and leaving the user to
                // work out whether it failed.
                Label("All done here", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.success)
            } else {
                itemList(context, limit: PlaceVisitAttributes.maxTitles)

                ProgressView(value: context.state.progress)
                    .tint(Brand.meadow)
            }
        }
        .padding(16)
    }

    // MARK: - Shared

    @ViewBuilder
    private func itemList(
        _ context: ActivityViewContext<PlaceVisitAttributes>,
        limit: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(context.state.remaining.prefix(limit), id: \.self) { title in
                HStack(spacing: 7) {
                    Image(systemName: "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }

            // Never silently truncates. A list that stops at four without
            // saying so reads as "that's everything".
            let hidden = context.state.overflow + max(0, context.state.remaining.count - limit)
            if hidden > 0 {
                Text("+ \(hidden) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
