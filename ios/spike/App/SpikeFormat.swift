import Foundation

/// Форматирование чисел для экрана: запятая как разделитель, без пробелов между разрядами.
/// Журнал использует свой `fmt` в `SpikeController` и этим не затрагивается.
enum SpikeFormat {
    /// Число с запятой: 7,06.
    static func number(_ value: Double, digits: Int = 2) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(digits))
                .locale(Locale(identifier: "ru_RU"))
                .grouping(.never)
        )
    }

    /// Секунды с неразрывным пробелом перед «с»: «7,06 с».
    static func seconds(_ value: Double, digits: Int = 2) -> String {
        number(value, digits: digits) + "\u{00A0}с"
    }
}
