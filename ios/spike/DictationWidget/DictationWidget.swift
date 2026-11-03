import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DictationWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.stage.symbol)
                    .foregroundStyle(stageColor(context.state.stage))
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Handy · \(context.state.stage.title)").font(.headline)
                    Text(context.state.stage.instruction)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            .padding()
            .activityBackgroundTint(Color(.secondarySystemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.stage.symbol)
                        .foregroundStyle(stageColor(context.state.stage))
                }
                DynamicIslandExpandedRegion(.trailing) { Text("Handy") }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.stage.title).font(.headline)
                        Text(context.state.stage.instruction).font(.caption).lineLimit(2)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.stage.symbol)
                    .foregroundStyle(stageColor(context.state.stage))
            } compactTrailing: {
                Text(context.state.stage.compactTitle)
                    .font(.caption2.bold())
                    .foregroundStyle(context.state.stage == .recording ? stageColor(.recording) : Color.primary)
            } minimal: {
                Image(systemName: context.state.stage.symbol)
                    .foregroundStyle(stageColor(context.state.stage))
            }
            .keylineTint(stageColor(context.state.stage))
        }
    }
}

/// Цвет стадии. Нейтральные стадии — `.primary`: белый на чёрном Dynamic Island
/// и тёмный/светлый по теме на экране блокировки.
private func stageColor(_ stage: DictationActivityAttributes.Stage) -> Color {
    switch stage {
    case .recording: return .red
    case .finished: return .green
    case .noSpeech, .failed: return .orange
    case .ready, .transcribing: return .primary
    }
}
