import SwiftUI

/// Уровень входного сигнала: тонкая полоса, заполнение растягивается от левого края.
/// Анимируется масштаб, а не ширина, чтобы не пересчитывать раскладку.
struct InputLevelBar: View {
    /// Уровень 0…1.
    let level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: CGFloat {
        CGFloat(min(max(level, 0), 1))
    }

    var body: some View {
        Rectangle()
            .fill(Color(.tertiarySystemFill))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color("HandyAccent"))
                    .scaleEffect(x: fraction, y: 1, anchor: .leading)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
            }
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }
}
