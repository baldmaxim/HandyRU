import SwiftUI
import UIKit

/// Основной сценарий — записать фразу и получить текст. Замеры раскрываются отдельно.
struct ContentView: View {
    @ObservedObject var controller: SpikeController
    @ObservedObject var store: ModelStore
    @ObservedObject var log: SpikeLog
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var isConfirmingLogClear = false

    private var selectedModelDownloaded: Bool {
        if controller.selectedBackend.isCoreML { return store.coreMLDownloaded }
        guard let model = controller.selectedModel else { return false }
        return store.isDownloaded(model)
    }

    private var selectionMatchesLoaded: Bool { controller.selectedModelIsLoaded }
    private var modelActionsDisabled: Bool {
        controller.isBusy || controller.backgroundDictationEnabled || store.downloadingID != nil
    }
    private var canRecord: Bool {
        selectionMatchesLoaded && !controller.isBusy && store.downloadingID == nil
    }
    private var modelTitle: String {
        controller.selectedBackend.isCoreML ? ModelStore.coreMLTitle : (controller.selectedModel?.title ?? "Модель")
    }
    private var modelSize: Int {
        controller.selectedBackend.isCoreML ? ModelStore.coreMLSizeMB : (controller.selectedModel?.sizeMB ?? 0)
    }
    private var modelRowBackground: Color {
        guard selectionMatchesLoaded else { return Color(.secondarySystemGroupedBackground) }
        return colorScheme == .dark
            ? Color(red: 0.07, green: 0.24, blue: 0.15)
            : Color(red: 0.84, green: 0.95, blue: 0.87)
    }

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                recordingSection
                resultSection
                backgroundSection
                diagnosticsSection
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

    private var modelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(modelTitle)
                        .font(.headline)
                    Spacer(minLength: 0)
                    if selectionMatchesLoaded {
                        Button { Task { await controller.loadModel() } } label: {
                            Label("Перезагрузить модель", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                        }
                        .buttonStyle(SpikeIconButtonStyle())
                        .disabled(modelActionsDisabled)
                        Button { Task { await controller.unloadModel() } } label: {
                            Label("Выгрузить модель", systemImage: "eject").labelStyle(.iconOnly)
                        }
                        .buttonStyle(SpikeIconButtonStyle())
                        .disabled(modelActionsDisabled)
                    } else if !selectedModelDownloaded {
                        Text("\(modelSize) МБ").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if store.downloadingID != nil {
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
                } else if controller.phase == .loading || controller.phase == .unloading {
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
                    Text("Оставьте Handy открытым. Подготовка модели иногда занимает несколько минут.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !selectionMatchesLoaded {
                    Text(selectedModelDownloaded ? "Файлы на iPhone · можно загрузить" : "Скачайте один раз для работы без сети")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task {
                            if selectedModelDownloaded { await controller.loadModel() }
                            else if controller.selectedBackend.isCoreML { await store.downloadCoreML() }
                            else if let model = controller.selectedModel { await store.download(model) }
                        }
                    } label: {
                        Label(selectedModelDownloaded ? "Загрузить модель" : "Скачать модель",
                              systemImage: selectedModelDownloaded ? "play.circle.fill" : "arrow.down.circle.fill")
                    }
                    .buttonStyle(SpikeActionStyle(kind: .primary))
                    .disabled(modelActionsDisabled)
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
            .padding(.vertical, selectionMatchesLoaded ? 0 : 6)
            .listRowBackground(modelRowBackground)
            .accessibilityValue(selectionMatchesLoaded ? "Модель загружена" : "")
            .modifier(DeleteModelOnSwipe(disabled: modelActionsDisabled || !selectedModelDownloaded) {
                Task {
                    if controller.selectedBackend.isCoreML { await controller.deleteCoreMLModel() }
                    else if let model = controller.selectedModel { await controller.deleteModel(model) }
                }
            })
        }
    }

    private var recordingSection: some View {
        Section("Диктовка") {
            VStack(alignment: .leading, spacing: 12) {
                if controller.phase == .recording {
                    HStack {
                        Label("Идёт запись", systemImage: "record.circle.fill").foregroundStyle(.red)
                        Spacer()
                        Text(SpikeFormat.seconds(controller.capturedSeconds, digits: 1)).monospacedDigit()
                    }
                    Button { Task { await controller.stopAndTranscribe() } } label: {
                        Label("Остановить и распознать", systemImage: "stop.fill")
                    }
                    .buttonStyle(SpikeActionStyle(kind: .stop))
                    Text(controller.noMicrophoneSignal
                         ? "От микрофона пока не поступает звук. Скажите несколько слов и проверьте микрофон."
                         : "Закончили фразу? Нажмите кнопку ещё раз — только после остановки появится текст.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if controller.phase == .transcribing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Распознаём речь…").font(.headline)
                    }
                    Text("Дождитесь текста. Запись уже остановлена.").font(.subheadline).foregroundStyle(.secondary)
                } else if controller.phase == .backgroundRecording {
                    Label("Тест: осталось \(controller.countdown) с", systemImage: "record.circle")
                        .foregroundStyle(.red).monospacedDigit()
                } else {
                    Button { Task { await controller.startRecording() } } label: {
                        Label("Начать запись", systemImage: "mic.fill")
                    }
                    .buttonStyle(SpikeActionStyle(kind: .primary))
                    .disabled(!canRecord)
                    Text(selectionMatchesLoaded
                         ? "Нажмите, скажите фразу, затем нажмите «Остановить и распознать»."
                         : "Сначала подготовьте модель в карточке выше.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !controller.status.isEmpty && controller.phase == .idle {
                    Text(controller.status)
                        .font(.subheadline)
                        .foregroundStyle(controller.statusIsError ? Color.red : Color.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var resultSection: some View {
        Section("Текст") {
            if let result = controller.lastResult {
                ResultBlock(result: result, text: controller.resultText)
            } else {
                Text(controller.phase == .recording ? "Текст появится после второго нажатия." : "Здесь появится распознанная фраза.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var backgroundSection: some View {
        Section("Из других приложений") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Фоновая диктовка", systemImage: "waveform")
                        .font(.headline)
                    Spacer()
                    if controller.backgroundDictationEnabled {
                        Button { Task { await controller.setBackgroundDictationEnabled(false) } } label: {
                            Label("Выключить фоновую диктовку", systemImage: "power").labelStyle(.iconOnly)
                        }
                        .buttonStyle(SpikeIconButtonStyle())
                        .disabled(controller.isBusy)
                    }
                }
                if controller.backgroundModeChanging {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Настраиваем микрофон…").font(.subheadline)
                    }
                } else if !controller.backgroundDictationEnabled {
                    Button { Task { await controller.setBackgroundDictationEnabled(true) } } label: {
                        Label("Включить", systemImage: "mic.badge.plus")
                    }
                    .buttonStyle(SpikeActionStyle())
                    .disabled(!canRecord || controller.selectedBackend == .metal)
                }
                VStack(alignment: .leading, spacing: 7) {
                    instruction("1", "Нажмите AssistiveTouch — начнётся запись.")
                    instruction("2", "Нажмите ещё раз — запись остановится, появится текст.")
                    instruction("3", "Дождитесь команды «Handy» и выберите «Вставить» в нужном приложении.")
                }
                Text(controller.backgroundDictationEnabled
                     ? "Режим включён. Микрофон активен; между фразами звук отбрасывается."
                     : (controller.selectedBackend == .metal
                        ? "Для фоновой диктовки выберите Neural Engine или CPU в настройках ниже."
                        : "Включите один раз перед переходом в другое приложение. Микрофон останется активным; между фразами звук отбрасывается. После перезапуска включите режим снова."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).frame(width: 22, height: 22)
                .background(Color("HandyAccent").opacity(0.15), in: Circle())
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("Настройки и диагностика") {
                Picker("Распознавание", selection: $controller.selectedBackend) {
                    ForEach(SpikeBackend.allCases) { backend in Text(backend.title).tag(backend) }
                }
                .disabled(modelActionsDisabled)
                if !controller.selectedBackend.isCoreML {
                    Picker("Модель", selection: $controller.selectedModelID) {
                        ForEach(ModelCatalog.all) { model in Text(model.title).tag(model.id) }
                    }
                    .disabled(modelActionsDisabled)
                }
                if controller.selectedBackend.isCoreML {
                    Toggle("Параллельная загрузка Core ML", isOn: $controller.parallelCoreMLLoading)
                        .disabled(modelActionsDisabled)
                }
                if controller.backgroundDictationEnabled {
                    Text("Чтобы изменить или выгрузить модель, выключите фоновую диктовку.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await controller.transcribeDiagnosticAudio() } } label: {
                    Label("Проверить распознавание без микрофона", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(SpikeActionStyle())
                .disabled(!canRecord)
                Text("Тестовая фраза: «Проверка распознавания речи. Завтра в десять утра мы обсудим новый проект и подготовим список задач».")
                    .font(.caption).foregroundStyle(.secondary)
                Button { Task { await controller.repeatOnLastRecording() } } label: {
                    Label("Распознать последнюю запись ещё раз", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SpikeActionStyle())
                .disabled(!canRecord || controller.lastAudioSeconds == 0)
                Button { Task { await controller.startBackgroundTest() } } label: {
                    Label("Фоновый тест · 20 с", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(SpikeActionStyle())
                .disabled(!canRecord || controller.backgroundDictationEnabled)
                Text("Только тест останавливает запись по таймеру. Запустите его и сверните Handy на 20 секунд.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Журнал") {
                    Button { UIPasteboard.general.string = log.text } label: {
                        Label("Скопировать журнал", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: log.fileURL) {
                        Label("Поделиться журналом", systemImage: "square.and.arrow.up")
                    }
                    Button("Очистить журнал", role: .destructive) { isConfirmingLogClear = true }
                        .confirmationDialog("Очистить журнал замеров?", isPresented: $isConfirmingLogClear, titleVisibility: .visible) {
                            Button("Очистить журнал", role: .destructive) { log.clear() }
                        }
                    Text(log.text.split(separator: "\n").suffix(100).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
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
