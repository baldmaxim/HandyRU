import SwiftUI

/// Запись фразы на открытом приложении: начать, остановить, распознать.
struct RecordingSection: View {
    @ObservedObject var controller: SpikeController
    @ObservedObject var store: ModelStore

    private var state: ModelState { ModelState(controller: controller, store: store) }

    var body: some View {
        Section("Диктовка") {
            VStack(alignment: .leading, spacing: 12) {
                switch controller.phase {
                case .recording:
                    recordingBlock
                case .transcribing:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Распознаём речь…").font(.headline)
                    }
                case .backgroundRecording:
                    Label("Тест: осталось \(controller.countdown) с", systemImage: "record.circle")
                        .foregroundStyle(.red).monospacedDigit()
                default:
                    idleBlock
                }
            }
            .padding(.vertical, 4)
            .sensoryFeedback(.impact(weight: .medium), trigger: controller.phase) { oldPhase, newPhase in
                oldPhase == .recording || newPhase == .recording
            }
        }
    }

    private var recordingBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Идёт запись", systemImage: "record.circle.fill").foregroundStyle(.red)
                Spacer()
                Text(SpikeFormat.seconds(controller.capturedSeconds, digits: 1)).monospacedDigit()
            }
            InputLevelBar(level: controller.inputLevel)
            Button { Task { await controller.stopAndTranscribe() } } label: {
                Label("Остановить и распознать", systemImage: "stop.fill")
            }
            .buttonStyle(SpikeActionStyle(kind: .stop))
            if controller.noMicrophoneSignal {
                Text("Микрофон молчит. Скажите несколько слов.")
                    .font(.subheadline).foregroundStyle(.red)
            }
        }
    }

    /// Кнопка видна и в фазе `.starting`, но заблокирована: `canRecord` требует `!isBusy`.
    private var idleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { Task { await controller.startRecording() } } label: {
                Label("Начать запись", systemImage: "mic.fill")
            }
            .buttonStyle(SpikeActionStyle(kind: .primary))
            .disabled(!state.canRecord)
            if !state.isLoaded {
                Text("Сначала подготовьте модель.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !controller.status.isEmpty && controller.phase == .idle {
                Text(controller.status)
                    .font(.subheadline)
                    .foregroundStyle(controller.statusIsError ? Color.red : Color.secondary)
            }
            if controller.microphoneAccessDenied && controller.phase == .idle {
                Button { controller.openSystemSettings() } label: {
                    Label("Открыть настройки", systemImage: "gear")
                }
                .buttonStyle(SpikeActionStyle())
            }
        }
    }
}
