import SwiftUI

/// Главный сценарий: подготовить модель, записать фразу, скопировать текст.
/// Всё техническое свёрнуто в «Настройки и диагностика».
struct ContentView: View {
    @ObservedObject var controller: SpikeController
    @ObservedObject var store: ModelStore
    @ObservedObject var log: SpikeLog
    @Environment(\.scenePhase) private var scenePhase

    /// Блок «Текст» виден, если есть результат или текст прошлого запуска; во время записи его нет.
    private var showsResult: Bool {
        if controller.lastResult != nil || !controller.restoredText.isEmpty { return true }
        return controller.phase != .recording
    }

    var body: some View {
        NavigationStack {
            Form {
                ModelSection(controller: controller, store: store)
                RecordingSection(controller: controller, store: store)
                resultSection
                BackgroundSection(controller: controller, store: store)
                DiagnosticsSection(controller: controller, store: store, log: log)
            }
            .textCase(nil)
            .navigationTitle("Handy")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Color("HandyAccent"))
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { controller.noteInactiveSceneDuringLoad() }
            log.info("приложение: \(Self.scenePhaseName(newPhase))")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if showsResult {
            Section("Текст") {
                if controller.lastResult != nil || !controller.restoredText.isEmpty {
                    ResultBlock(text: controller.resultText)
                } else {
                    Text("Здесь появится распознанная фраза.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func scenePhaseName(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "на переднем плане (active)"
        case .inactive: return "inactive"
        case .background: return "ушло в фон (background)"
        @unknown default: return "unknown"
        }
    }
}
