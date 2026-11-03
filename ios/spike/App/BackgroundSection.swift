import SwiftUI

/// Фоновая диктовка: переключатель, подпись и две свёрнутые инструкции.
struct BackgroundSection: View {
    @ObservedObject var controller: SpikeController
    @ObservedObject var store: ModelStore

    private var state: ModelState { ModelState(controller: controller, store: store) }

    private var isMetal: Bool { controller.selectedBackend == .metal }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { controller.backgroundDictationEnabled },
            set: { value in Task { await controller.setBackgroundDictationEnabled(value) } }
        )
    }

    /// Включить можно только при загруженной модели; выключить — когда ничего не занято.
    private var toggleDisabled: Bool {
        if controller.isBusy || controller.backgroundModeChanging || isMetal { return true }
        return !controller.backgroundDictationEnabled && !state.canRecord
    }

    private var caption: String {
        if isMetal { return "Для фоновой диктовки выберите Neural Engine в настройках." }
        if controller.backgroundDictationEnabled {
            return "Микрофон активен. Выключится после 2 часов без диктовки."
        }
        if !state.isLoaded { return "Сначала подготовьте модель." }
        return "Включите, чтобы диктовать из других приложений."
    }

    var body: some View {
        Section("Из других приложений") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: toggleBinding) {
                    Label("Фоновая диктовка", systemImage: "waveform").font(.headline)
                }
                .disabled(toggleDisabled)
                if controller.backgroundModeChanging {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Настраиваем микрофон…").font(.subheadline)
                    }
                } else {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            DisclosureGroup("Как пользоваться") {
                VStack(alignment: .leading, spacing: 8) {
                    InstructionStep(number: "1", text: "Нажмите AssistiveTouch и говорите.")
                    InstructionStep(number: "2", text: "Нажмите ещё раз — запись остановится.")
                    InstructionStep(number: "3", text: "Когда в Dynamic Island появится «Текст готов», нажмите «Вставить» в нужном приложении.")
                }
                .padding(.vertical, 4)
            }
            DisclosureGroup("Как настроить один раз") {
                VStack(alignment: .leading, spacing: 8) {
                    InstructionStep(number: "1", text: "В «Командах» создайте команду: действие Handy «Диктовка в фоне», затем «Если» результат «Диктовки в фоне» «есть любое значение», а внутри — «Скопировать в буфер обмена».")
                    InstructionStep(number: "2", text: "Настройки → Универсальный доступ → Касание → AssistiveTouch → Одно касание → Быстрые команды: выберите эту команду.")
                }
                .padding(.vertical, 4)
            }
        }
    }
}
