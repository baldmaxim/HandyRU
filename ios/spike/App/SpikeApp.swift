import SwiftUI
import UIKit

@main
struct SpikeApp: App {
    @StateObject private var controller: SpikeController
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasPendingDictationCommand = false

    init() {
        _controller = StateObject(wrappedValue: SpikeController(log: SpikeLog(), store: ModelStore()))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, store: controller.store, log: controller.log)
                .onAppear {
                    // На запуске onChange не срабатывает: сцена уже может быть активной.
                    if scenePhase == .active { activate() }
                }
                .onOpenURL { url in
                    guard url.scheme == "handyspike", url.host == "dictation", url.path == "/toggle" else { return }
                    hasPendingDictationCommand = true
                    runPendingDictationCommand()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        runPendingDictationCommand()
                        activate()
                    }
                }
        }
    }

    /// Автозагрузка модели, автовключение фоновой диктовки, Live Activity. Автоблокировкой управляет контроллер.
    private func activate() {
        Task { await controller.sceneBecameActive() }
    }

    /// Активация микрофона начинается только после выхода приложения на передний план.
    private func runPendingDictationCommand() {
        guard hasPendingDictationCommand, scenePhase == .active else { return }
        hasPendingDictationCommand = false
        Task { await controller.toggleDictationFromShortcut() }
    }
}
