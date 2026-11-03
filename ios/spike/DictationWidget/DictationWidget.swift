import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DictationWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.stage.symbol)
                    .foregroundStyle(context.state.stage == .recording ? Color.red : Color.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Handy · \(context.state.stage.title)").font(.headline)
                    Text(context.state.stage.instruction)
                        .font(.caption)
                }
            }
            .padding()
            .activityBackgroundTint(Color(.secondarySystemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.stage.symbol)
                        .foregroundStyle(context.state.stage == .recording ? Color.red : Color.green)
                }
                DynamicIslandExpandedRegion(.trailing) { Text("Handy") }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.stage.title).font(.headline)
                        Text(context.state.stage.instruction).font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.stage.symbol)
                    .foregroundStyle(context.state.stage == .recording ? Color.red : Color.green)
            } compactTrailing: {
                Text(context.state.stage.compactTitle).font(.caption2.bold())
            } minimal: {
                Image(systemName: context.state.stage.symbol)
            }
        }
    }
}
