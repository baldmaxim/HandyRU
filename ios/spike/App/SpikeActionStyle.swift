import SwiftUI

/// Одинаковые состояния действий: цвет и рамка обозначают доступную кнопку,
/// нейтральный фон — недоступную. Причину недоступности показывает сам экран.
struct SpikeActionStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case stop
    }

    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    private var accent: Color {
        kind == .stop ? .red : Color("HandyAccent")
    }

    private var filled: Bool {
        kind != .secondary
    }

    /// Белая надпись сохраняет контраст 4,5:1 в обеих темах; светлый акцент нужен
    /// только надписям и рамкам второстепенных кнопок в тёмной теме.
    private var fillColor: Color {
        kind == .stop ? Color("HandyStopFill") : Color("HandyAccentFill")
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isEnabled ? (filled ? Color.white : accent) : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isEnabled ? (filled ? fillColor : accent.opacity(0.1)) : Color(.tertiarySystemFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isEnabled ? accent.opacity(filled ? 0 : 0.45) : Color(.separator), lineWidth: 1)
            }
            .opacity(configuration.isPressed && isEnabled ? 0.75 : 1)
    }
}
