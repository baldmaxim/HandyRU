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
            case .finished: return "Текст готов"
            case .noSpeech: return "Речи не слышно"
            case .failed: return "Не удалось распознать"
            }
        }

        var instruction: String {
            switch self {
            case .ready: return "Нажмите AssistiveTouch и говорите"
            case .recording: return "Нажмите ещё раз, чтобы остановить"
            case .transcribing: return "Запись остановлена, подождите"
            case .finished: return "Нажмите «Вставить» в нужном приложении"
            case .noSpeech: return "Нажмите AssistiveTouch и повторите фразу"
            case .failed: return "Откройте Handy, там указана причина"
            }
        }

        var compactTitle: String {
            switch self {
            case .ready: return "Готов"
            case .recording: return "Стоп"
            case .transcribing: return "Ждём"
            case .finished: return "Текст"
            case .noSpeech, .failed: return "!"
            }
        }

        var symbol: String {
            switch self {
            case .ready: return "mic"
            case .recording: return "record.circle.fill"
            case .transcribing: return "waveform"
            case .finished: return "doc.on.clipboard"
            case .noSpeech, .failed: return "exclamationmark.bubble"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        var stage: Stage
    }
}
