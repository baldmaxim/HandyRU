import AppIntents

enum DictationCommandError: LocalizedError {
    case notReady
    case busy
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "Откройте Handy и включите фоновую диктовку. После этого можно вернуться в мессенджер."
        case .busy: return "Дождитесь завершения распознавания."
        case .failed(let message): return message
        }
    }
}

@available(iOS 18.0, *)
struct ToggleBackgroundDictationIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Диктовка в фоне"
    static let description = IntentDescription("Первое нажатие — запись, второе — остановить и распознать. Затем дождитесь копирования командой «Handy» и нажмите «Вставить». Сначала включите фоновую диктовку в Handy.")
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let controller = SpikeController.current else { throw DictationCommandError.notReady }
        return .result(value: try await controller.toggleBackgroundDictation())
    }
}

@available(iOS 18.0, *)
struct HandyDictationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleBackgroundDictationIntent(),
                    phrases: ["Диктовка в \(.applicationName)"],
                    shortTitle: "Диктовка в фоне",
                    systemImageName: "mic.fill")
    }
}
