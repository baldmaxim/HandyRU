import Foundation

/// Отсечка тишины и известных «галлюцинаций» Whisper на тишине. Чистые функции без состояния.
enum SpeechGate {
    /// Длина кадра для оценки громкости, секунды.
    static let frameSeconds = 0.03
    /// Кадр озвучен, если его RMS больше этого значения.
    static let rmsThreshold = 0.005
    /// Запись без речи, если озвученных секунд меньше.
    static let minVoicedSeconds = 0.2
    /// Фразы вежливости считаются галлюцинацией только на длинной записи.
    static let politeMinAudioSeconds = 5.0

    /// Сколько секунд записи озвучено: кадры по 30 мс с RMS выше порога.
    static func voicedSeconds(samples: [Float], sampleRate: Double) -> Double {
        let frameSize = max(1, Int(sampleRate * frameSeconds))
        var voicedSamples = 0
        var start = 0
        while start < samples.count {
            let end = min(start + frameSize, samples.count)
            var squares = 0.0
            for index in start..<end {
                let value = samples[index]
                if value.isFinite { squares += Double(value) * Double(value) }
            }
            let rms = (squares / Double(end - start)).squareRoot()
            if rms > rmsThreshold { voicedSamples += end - start }
            start = end
        }
        return Double(voicedSamples) / sampleRate
    }

    private static let alwaysHallucination: Set<String> = Set([
        "продолжение следует",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
    ].map { SpeechGate.normalize($0) })

    private static let politeHallucination: Set<String> = Set([
        "спасибо",
        "спасибо за просмотр",
    ].map { SpeechGate.normalize($0) })

    /// Типичные фразы, которые Whisper «слышит» в тишине.
    static func isSilenceHallucination(text: String, audioSeconds: Double) -> Bool {
        let normalized = normalize(text)
        if alwaysHallucination.contains(normalized) { return true }
        return audioSeconds > politeMinAudioSeconds && politeHallucination.contains(normalized)
    }

    /// Нижний регистр, без пробелов и знаков препинания.
    private static func normalize(_ text: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var result = ""
        for scalar in text.lowercased().unicodeScalars where !dropped.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
