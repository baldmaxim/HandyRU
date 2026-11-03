import SwiftUI

/// Состояние модели: скачать, загрузить или «готова». Зелёная строка — модель загружена.
struct ModelSection: View {
    @ObservedObject var controller: SpikeController
    @ObservedObject var store: ModelStore

    private var state: ModelState { ModelState(controller: controller, store: store) }

    private var rowBackground: Color {
        state.isReady ? Color("HandyReady") : Color(.secondarySystemGroupedBackground)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if state.isReady {
                    Label {
                        Text("Модель готова")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.headline)
                } else {
                    header
                    if state.isDownloading {
                        downloadingBlock
                    } else if state.isPreparing {
                        loadingBlock
                    } else {
                        actionBlock
                    }
                }
                if let error = controller.modelError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.red)
                }
                if store.messageIsError {
                    Label(store.message, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.red)
                }
            }
            .padding(.vertical, state.isReady ? 0 : 6)
            .listRowBackground(rowBackground)
            .modifier(DeleteModelOnSwipe(disabled: state.actionsDisabled || !state.isDownloaded) {
                Task {
                    if controller.selectedBackend.isCoreML { await controller.deleteCoreMLModel() }
                    else if let model = controller.selectedModel { await controller.deleteModel(model) }
                }
            })
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(state.isDownloaded && !state.isDownloading && !state.isPreparing
                 ? "Модель не загружена" : "Модель распознавания")
                .font(.headline)
            Spacer(minLength: 0)
            if !state.isDownloaded {
                Text("\(state.sizeMB) МБ").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var downloadingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.progress >= 1 ? "Проверка файлов…" : "Скачивание…")
                Spacer()
                Text("\(Int(store.progress * 100)) %").monospacedDigit()
            }
            ProgressView(value: store.progress)
            Button("Отменить скачивание", role: .destructive) {
                if controller.selectedBackend.isCoreML { store.cancelCoreMLDownload() }
                else { store.cancelDownload() }
            }
            .buttonStyle(SpikeActionStyle())
        }
        .font(.subheadline)
    }

    private var loadingBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.phase == .loading ? controller.modelLoadStage : "Освобождаем память…")
                    if let started = controller.modelLoadStarted {
                        Text(started, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            if controller.phase == .loading {
                Text("При первом запуске подготовка занимает около 3,5 минуты. Не сворачивайте Handy, иначе придётся начинать заново.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actionBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.isDownloaded {
                Text("Скачивается один раз, дальше работает без сети")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    if state.isDownloaded { await controller.loadModel() }
                    else if controller.selectedBackend.isCoreML { await store.downloadCoreML() }
                    else if let model = controller.selectedModel { await store.download(model) }
                }
            } label: {
                Label(state.isDownloaded ? "Загрузить модель" : "Скачать модель",
                      systemImage: state.isDownloaded ? "play.circle.fill" : "arrow.down.circle.fill")
            }
            .buttonStyle(SpikeActionStyle(kind: .primary))
            .disabled(state.actionsDisabled)
        }
    }
}
