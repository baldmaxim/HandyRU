import SwiftUI

/// Шкала задержки: заполнение до `seconds` (не дальше `maxSeconds`) и отметка предела.
struct DelayScale: View {
    /// Предел задержки, секунды: отметка на шкале.
    static let limitSeconds = 5.0
    /// Правый край шкалы, секунды.
    static let maxSeconds = 15.0

    let seconds: Double

    private static let trackHeight: CGFloat = 4
    private static let markWidth: CGFloat = 2
    private static let markHeight: CGFloat = 12

    private var fillFraction: Double {
        min(max(seconds, 0), Self.maxSeconds) / Self.maxSeconds
    }

    private var limitFraction: Double {
        Self.limitSeconds / Self.maxSeconds
    }

    var body: some View {
        VStack(spacing: 4) {
            track
            labels
        }
        .accessibilityHidden(true)
    }

    /// Дорожка, заполнение и отметка предела. Высота фиксирована по высоте отметки.
    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.systemFill))
                    .frame(height: Self.trackHeight)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color("HandyAccent"))
                    .frame(width: geo.size.width * fillFraction, height: Self.trackHeight)
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: Self.markWidth, height: Self.markHeight)
                    .offset(x: geo.size.width * limitFraction - Self.markWidth / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.markHeight)
    }

    /// Подписи: «0» слева, «5 с» под отметкой, «15 с» справа. Высоту задаёт строка «0».
    private var labels: some View {
        Text("0")
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                GeometryReader { geo in
                    Text("\(Int(Self.limitSeconds)) с")
                        .position(x: geo.size.width * limitFraction, y: geo.size.height / 2)
                }
            }
            .overlay(alignment: .trailing) {
                Text("\(Int(Self.maxSeconds)) с")
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
