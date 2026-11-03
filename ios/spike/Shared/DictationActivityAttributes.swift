import ActivityKit

struct DictationActivityAttributes: ActivityAttributes {
    enum Stage: String, Codable, Hashable {
        case ready
        case recording
        case transcribing
        case finished
        case noSpeech
        case failed

        var title: String {
            switch self {
            case .ready: return "Диктовка готова"
            case .recording: return "Идёт запись"
            case .transcribing: return "Распознаём речь"
            case .finished: return "Текст готов → «Вставить»"
            case .noSpeech: return "Нет текста — повторите"
            case .failed: return "Не удалось распознать"
            }
        }

        var instruction: String {
            switch self {
            case .ready: return "1. Нажмите AssistiveTouch и говорите. Микрофон активен."
            case .recording: return "2. Нажмите AssistiveTouch ещё раз, чтобы остановить запись и получить текст."
            case .transcribing: return "Запись остановлена. Дождитесь текста."
            case .finished: return "3. Дождитесь команды «Handy», затем нажмите «Вставить» в нужном приложении."
            case .noSpeech: return "Нажмите AssistiveTouch, скажите фразу и нажмите ещё раз."
            case .failed: return "Откройте Handy для подробностей."
            }
        }

        var compactTitle: String {
            switch self {
            case .ready: return "1"
            case .recording: return "СТОП"
            case .transcribing: return "…"
            case .finished: return "3"
            case .noSpeech, .failed: return "!"
            }
        }

        var symbol: String {
            switch self {
            case .ready: return "mic"
            case .recording: return "record.circle.fill"
            case .transcribing: return "text.bubble"
            case .finished: return "doc.on.clipboard"
            case .noSpeech, .failed: return "exclamationmark.bubble"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        var stage: Stage
    }
}
