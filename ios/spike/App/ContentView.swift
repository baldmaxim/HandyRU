import SwiftUI
import UIKit

/// Единственный экран прототипа: модель, бэкенд, запись, фоновый тест, журнал.
struct ContentView: View {
    @ObservedObject var controller: SpikeController
    @ObservedObject var store: ModelStore
    @ObservedObject var log: SpikeLog
    @Environment(\.scenePhase) private var scenePhase

    /// Сколько последних строк журнала показывать (копируется и отправляется весь файл).
    private static let visibleLogLines = 100

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                backendSection
                actionsSection
                resultSection
                logSection
            }
            .navigationTitle("Handy Spike")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: scenePhase) { _, newPhase in
            log.info("приложение: \(Self.scenePhaseName(newPhase))")
        }
    }

    // MARK: - Модель

    private var modelSection: some View {
        Section("Модель") {
            if controller.selectedBackend.isCoreML {
                coreMLModelRows
            } else {
                ggmlModelRows
            }

            if !store.message.isEmpty {
                Text(store.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Модель Core ML: одна, скачивается отдельно.
    @ViewBuilder
    private var coreMLModelRows: some View {
        let downloaded = store.coreMLDownloaded
        Text(downloaded
            ? "\(ModelStore.coreMLTitle) (\(ModelStore.coreMLSizeMB) МБ): скачана"
            : "\(ModelStore.coreMLTitle) (\(ModelStore.coreMLSizeMB) МБ): не скачана")
            .font(.subheadline)

        if store.downloadingID == ModelStore.coreMLID {
            ProgressView(value: store.progress)
            Text("\(Int(store.progress * 100)) %")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Отменить скачивание", role: .destructive) {
                store.cancelCoreMLDownload()
            }
        } else if downloaded {
            Button("Удалить файл модели", role: .destructive) {
                Task { await controller.deleteCoreMLModel() }
            }
            .disabled(controller.isBusy)
        } else {
            Button("Скачать") {
                Task { await store.downloadCoreML() }
            }
            .disabled(controller.isBusy || store.downloadingID != nil)
        }
    }

    /// Модели ggml (CPU, Metal): выбор из каталога.
    @ViewBuilder
    private var ggmlModelRows: some View {
        Group {
            Picker("Модель", selection: $controller.selectedModelID) {
                ForEach(ModelCatalog.all) { model in
                    Text(model.title).tag(model.id)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isBusy || store.downloadingID != nil)

            if let model = controller.selectedModel {
                let downloaded = store.isDownloaded(model)
                Text(downloaded ? "\(model.title) (\(model.sizeMB) МБ): скачана" : "\(model.title) (\(model.sizeMB) МБ): не скачана")
                    .font(.subheadline)

                if store.downloadingID == model.id {
                    ProgressView(value: store.progress)
                    Text("\(Int(store.progress * 100)) %")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Отменить скачивание", role: .destructive) {
                        store.cancelDownload()
                    }
                } else if downloaded {
                    Button("Удалить файл модели", role: .destructive) {
                        Task { await controller.deleteModel(model) }
                    }
                    .disabled(controller.isBusy)
                } else {
                    Button("Скачать") {
                        Task { await store.download(model) }
                    }
                    .disabled(controller.isBusy || store.downloadingID != nil)
                }
            }
        }
    }

    // MARK: - Бэкенд

    private var backendSection: some View {
        Section("Бэкенд") {
            Picker("Бэкенд", selection: $controller.selectedBackend) {
                ForEach(SpikeBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .pickerStyle(.menu)
            .disabled(controller.isBusy)

            Button("Загрузить модель") {
                Task { await controller.loadModel() }
            }
            .disabled(controller.isBusy || store.downloadingID != nil)

            if let loaded = controller.loaded {
                Text("Загружена: \(loaded.modelID), бэкенд: \(loaded.backend)")
                    .font(.caption)
                if loaded.requestedBackend != controller.selectedBackend {
                    Text("Выбранный бэкенд (\(controller.selectedBackend.title)) не совпадает с загруженной моделью: нажмите «Загрузить модель» ещё раз.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Модель не загружена")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Действия

    private var actionsSection: some View {
        Section("Замер") {
            let ready = controller.loaded != nil

            if controller.phase == .recording {
                Button("Стоп и распознать") {
                    Task { await controller.stopAndTranscribe() }
                }
                .buttonStyle(.borderedProminent)
                Text("Записано: \(String(format: "%.1f", controller.capturedSeconds)) с")
                    .font(.caption)
            } else {
                Button("Запись") {
                    Task { await controller.startRecording() }
                }
                .disabled(controller.isBusy || !ready)
            }

            Button("Повторить на последней записи") {
                Task { await controller.repeatOnLastRecording() }
            }
            .disabled(controller.isBusy || !ready || controller.lastAudioSeconds == 0)
            if controller.lastAudioSeconds > 0 {
                Text("Последняя запись: \(String(format: "%.1f", controller.lastAudioSeconds)) с")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Фоновый тест (\(SpikeController.backgroundSeconds) с)") {
                Task { await controller.startBackgroundTest() }
            }
            .disabled(controller.isBusy || !ready)
            if controller.phase == .backgroundRecording {
                Text("Осталось: \(controller.countdown) с. Идёт запись \(String(format: "%.1f", controller.capturedSeconds)) с. Сверните приложение и говорите.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if controller.phase == .loading || controller.phase == .transcribing {
                HStack {
                    ProgressView()
                    Text(controller.phase == .loading ? "Загрузка модели…" : "Распознавание…")
                }
            }
            if !controller.status.isEmpty {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Результат

    private var resultSection: some View {
        Section("Результат") {
            Text(controller.resultText.isEmpty ? "—" : controller.resultText)
                .textSelection(.enabled)
        }
    }

    // MARK: - Журнал

    private var logSection: some View {
        Section("Журнал (последние \(Self.visibleLogLines) строк)") {
            HStack {
                Button("Скопировать журнал") {
                    UIPasteboard.general.string = log.text
                }
                .buttonStyle(.bordered)
                Button("Очистить журнал", role: .destructive) {
                    log.clear()
                }
                .buttonStyle(.bordered)
            }
            ShareLink(item: log.fileURL) {
                Label("Поделиться файлом журнала", systemImage: "square.and.arrow.up")
            }
            Text(visibleLog)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var visibleLog: String {
        let lines = log.text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(Self.visibleLogLines).joined(separator: "\n")
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
