import SwiftUI
import UIKit

/// Настройки движка, контрольные проверки, последний замер и журнал. Свёрнуты по умолчанию.
struct DiagnosticsSection: View {
    @ObservedObject var controller: SpikeController
    @ObservedObject var store: ModelStore
    @ObservedObject var log: SpikeLog
    @State private var isConfirmingLogClear = false

    private var state: ModelState { ModelState(controller: controller, store: store) }

    var body: some View {
        Section {
            DisclosureGroup("Настройки и диагностика") {
                engineSettings
                modelActions
                checks
                lastMeasurement
                logGroup
            }
        }
    }

    private var engineSettings: some View {
        Group {
            Picker("Распознавание", selection: $controller.selectedBackend) {
                ForEach(SpikeBackend.allCases) { backend in Text(backend.displayTitle).tag(backend) }
            }
            .disabled(state.actionsDisabled)
            if !controller.selectedBackend.isCoreML {
                Picker("Модель", selection: $controller.selectedModelID) {
                    ForEach(ModelCatalog.all) { model in Text(model.title).tag(model.id) }
                }
                .disabled(state.actionsDisabled)
            }
            if controller.selectedBackend.isCoreML {
                Toggle("Параллельная загрузка Core ML", isOn: $controller.parallelCoreMLLoading)
                    .disabled(state.actionsDisabled)
            }
            if controller.backgroundDictationEnabled {
                Text("Чтобы изменить модель, выключите фоновую диктовку.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelActions: some View {
        if state.isLoaded {
            Button { Task { await controller.loadModel() } } label: {
                Label("Перезагрузить модель", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SpikeActionStyle())
            .disabled(state.actionsDisabled)
            Button { Task { await controller.unloadModel() } } label: {
                Label("Выгрузить модель", systemImage: "eject")
            }
            .buttonStyle(SpikeActionStyle())
            .disabled(state.actionsDisabled)
        }
    }

    private var checks: some View {
        Group {
            Button { Task { await controller.transcribeDiagnosticAudio() } } label: {
                Label("Проверить распознавание без микрофона", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(SpikeActionStyle())
            .disabled(!state.canRecord)
            Text("Тестовая фраза: «Проверка распознавания речи. Завтра в десять утра мы обсудим новый проект и подготовим список задач».")
                .font(.caption).foregroundStyle(.secondary)
            Button { Task { await controller.repeatOnLastRecording() } } label: {
                Label("Распознать последнюю запись ещё раз", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SpikeActionStyle())
            .disabled(!state.canRecord || controller.lastAudioSeconds == 0)
            Button { Task { await controller.startBackgroundTest() } } label: {
                Label("Фоновый тест · 20 с", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(SpikeActionStyle())
            .disabled(!state.canRecord || controller.backgroundDictationEnabled)
            Text("Только тест останавливает запись по таймеру. Запустите его и сверните Handy на 20 секунд.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var lastMeasurement: some View {
        if let result = controller.lastResult, result.seconds > 0 {
            DisclosureGroup("Последний замер") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Время \(SpikeFormat.seconds(result.seconds))")
                    Text("RTF \(SpikeFormat.number(result.rtf)) · аудио \(SpikeFormat.seconds(result.audioSeconds))")
                    Text("\(result.modelTitle) · \(result.backendTitle) · \(result.modeTitle)")
                    DelayScale(seconds: result.seconds)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var logGroup: some View {
        DisclosureGroup("Журнал") {
            Toggle("Сохранять текст в журнале", isOn: $controller.logIncludesText)
            if !controller.logIncludesText {
                Text("Выключено: журнал не содержит диктовок.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { UIPasteboard.general.string = log.recentText(lines: 200) } label: {
                Label("Скопировать последние 200 строк", systemImage: "doc.on.doc")
            }
            ShareLink(item: log.fileURL) {
                Label("Поделиться журналом", systemImage: "square.and.arrow.up")
            }
            Button("Очистить журнал", role: .destructive) { isConfirmingLogClear = true }
                .confirmationDialog("Очистить журнал?", isPresented: $isConfirmingLogClear, titleVisibility: .visible) {
                    Button("Очистить журнал", role: .destructive) { log.clear() }
                }
            Text(log.recentText(lines: 100))
                .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
        }
    }
}
