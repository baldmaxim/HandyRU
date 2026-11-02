import SwiftUI

/// Итог замера: время, RTF, шкала задержки, пояснение и текст распознавания.
struct ResultBlock: View {
    let result: SpikeController.RunResult
    let text: String

    @ScaledMetric(relativeTo: .largeTitle) private var timeSize: CGFloat = 48

    private var limitText: String {
        let limit = Int(DelayScale.limitSeconds)
        if result.seconds <= DelayScale.limitSeconds {
            return "В пределах \(limit) с"
        }
        return "На \(SpikeFormat.seconds(result.seconds - DelayScale.limitSeconds)) дольше предела \(limit) с"
    }

    private var detailsText: String {
        "\(result.modelTitle) · \(result.backendTitle) · \(result.modeTitle) · аудио \(SpikeFormat.seconds(result.audioSeconds))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(SpikeFormat.seconds(result.seconds))
                    .font(.system(size: timeSize, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Text("RTF \(SpikeFormat.number(result.rtf))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            DelayScale(seconds: result.seconds)

            Text(limitText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(detailsText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(text.isEmpty ? "—" : text)
                .textSelection(.enabled)
        }
    }
}
