import SwiftUI
import UIKit

@main
struct SpikeApp: App {
    @StateObject private var controller: SpikeController

    init() {
        _controller = StateObject(wrappedValue: SpikeController(log: SpikeLog(), store: ModelStore()))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, store: controller.store, log: controller.log)
                .onAppear {
                    // Экран не гаснет во время замеров: автоблокировка исказила бы состояние приложения.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
