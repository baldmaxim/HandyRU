import Combine
import Foundation
import UIKit
import ActivityKit
import AVFoundation

/// Ключи UserDefaults, которые читают несколько файлов контроллера.
enum SpikeDefaults {
    /// Идёт автозагрузка модели при запуске (защита от петли падений).
    static let autoLoadInProgress = "autoLoadInProgress"
    /// Пользователь хочет, чтобы фоновая диктовка была включена.
    static let backgroundDictationWanted = "backgroundDictationWanted"
    static let lastResultText = "spike.lastResultText"
    static let logIncludesText = "spike.logIncludesText"
}

/// Сценарии замеров: загрузка модели, запись, распознавание, фоновый тест.
/// Экран (`ContentView`) только показывает состояние и вызывает методы.
/// Фоновая диктовка — в `SpikeController+Background.swift`, распознавание — в `SpikeController+Transcription.swift`.
@MainActor
final class SpikeController: ObservableObject {
    /// App Intents выполняются в процессе приложения и используют ту же аудиосессию.
    static weak var current: SpikeController?

    enum Phase: Equatable {
        case idle
        /// Запрос разрешения и запуск микрофона: занимает фазу до первого `await`, чтобы закрыть двойной запуск.
        case starting
        case loading
        case unloading
        case recording
        case transcribing
        case backgroundRecording
    }

    struct LoadedModel {
        let modelID: String
        let requestedBackend: SpikeBackend
        let backend: String
        let title: String
    }

    /// Итог последнего успешного распознавания для блока результата.
    struct RunResult {
        let seconds: Double
        let rtf: Double
        let audioSeconds: Double
        let modelTitle: String
        let backendTitle: String
        let modeTitle: String
    }

    /// Длительность записи в фоновом тесте, секунды.
    static let backgroundSeconds = 20
    /// Сколько секунд без команд диктовки фоновый режим остаётся включённым.
    static let BACKGROUND_IDLE_LIMIT: TimeInterval = 2 * 60 * 60
    /// Через сколько секунд записи нулевой сигнал считается поломкой захвата.
    static let zeroSignalWait: TimeInterval = 1.5
    static let language = "ru"
    /// Короче этого (0,5 с) распознавать бессмысленно.
    static let minSamples = 8_000

    let log: SpikeLog
    let store: ModelStore

    @Published var selectedModelID = "turbo" {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "spike.selectedModelID") }
    }
    @Published var selectedBackend: SpikeBackend = .coreMLNeuralEngine {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: "spike.selectedBackend") }
    }
    @Published var phase: Phase = .idle {
        didSet {
            updateDictationActivity()
            updateIdleTimer()
        }
    }
    @Published var backgroundDictationEnabled = false
    @Published var backgroundModeChanging = false
    @Published private(set) var loaded: LoadedModel?
    @Published var parallelCoreMLLoading = false
    private var loadStayedActive = false

    func noteInactiveSceneDuringLoad() {
        if phase == .loading { loadStayedActive = false }
    }
    @Published private(set) var modelError: String?
    @Published private(set) var modelLoadStage = ""
    @Published private(set) var modelLoadStarted: Date?
    /// Последний текст; при запуске восстанавливается из UserDefaults (метрики не сохраняются).
    @Published var resultText = ""
    @Published var status = "" {
        didSet { statusIsError = false }
    }
    /// Статус — ошибка (экран красит его красным). Сбрасывается любой новой записью в `status`.
    @Published var statusIsError = false
    @Published var lastResult: RunResult?
    @Published var noMicrophoneSignal = false
    @Published var capturedSeconds = 0.0
    @Published var countdown = 0
    @Published var lastAudioSeconds = 0.0
    /// Уровень входного сигнала 0…1 (последний пик за интервал счётчика); вне записи 0.
    @Published var inputLevel: Float = 0
    /// Пользователь отказал в доступе к микрофону.
    @Published var microphoneAccessDenied = false
    /// Писать текст распознавания в журнал (по умолчанию нет).
    @Published var logIncludesText = false {
        didSet { UserDefaults.standard.set(logIncludesText, forKey: SpikeDefaults.logIncludesText) }
    }

    let engine = Engine()
    let coreMLEngine = CoreMLEngine()
    let recorder = Recorder()
    let sampler = PeakSampler()
    var lastSamples: [Float] = []
    var meterTask: Task<Void, Never>?
    var isHandlingShortcut = false
    var shortcutDictationActive = false
    var dictationActivity: Activity<DictationActivityAttributes>?
    var activityCleanupTask: Task<Void, Never>?
    var activityUpdateTask: Task<Void, Never>?
    var dictationIdleStage: DictationActivityAttributes.Stage = .ready
    var idleWatchTask: Task<Void, Never>?
    var lastCommandAt = Date()
    private var didAttemptAutoLoad = false
    private var isDownloading = false
    private var downloadObserver: AnyCancellable?
    private var mediaResetObserver: NSObjectProtocol?

    init(log: SpikeLog, store: ModelStore) {
        self.log = log
        self.store = store
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "spike.selectedBackend"),
           let backend = SpikeBackend(rawValue: saved) {
            selectedBackend = backend
        }
        if let saved = defaults.string(forKey: "spike.selectedModelID"),
           ModelCatalog.all.contains(where: { $0.id == saved }) {
            selectedModelID = saved
        }
        resultText = defaults.string(forKey: SpikeDefaults.lastResultText) ?? ""
        logIncludesText = defaults.bool(forKey: SpikeDefaults.logIncludesText)
        recorder.onEvent = { message in
            log.info(message)
        }
        recorder.onInterruption = { [weak self] in
            Task { @MainActor in self?.handleMicrophoneInterruption() }
        }
        store.onLog = { message in
            log.info(message)
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
        // Старый индикатор не означает работающий микрофон в новом процессе.
        // Снимок берём ДО создания новой Activity; включение режима дождётся очистки.
        let staleActivities = Activity<DictationActivityAttributes>.activities
        activityCleanupTask = Task {
            for activity in staleActivities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            log.info("Live Activity: завершено после запуска: \(staleActivities.count); фоновый режим выключен")
        }
        // Значение приходит до записи в свойство, поэтому флаг скачивания хранится отдельно.
        downloadObserver = store.$downloadingID.sink { [weak self] id in
            self?.isDownloading = id != nil
            self?.updateIdleTimer()
        }
        updateIdleTimer()
        Self.current = self
    }

    var selectedModel: ModelInfo? {
        ModelCatalog.all.first { $0.id == selectedModelID }
    }

    var isBusy: Bool {
        phase != .idle || backgroundModeChanging
    }

    var selectedModelIsLoaded: Bool {
        guard let loaded else { return false }
        return loaded.requestedBackend == selectedBackend
            && (selectedBackend.isCoreML || loaded.modelID == selectedModelID)
    }

    /// Текст прошлого запуска для экрана, когда нового результата (`lastResult`) ещё нет.
    var restoredText: String {
        lastResult == nil ? resultText : ""
    }

    /// Единственное место расчёта автоблокировки: экран не гаснет только во время работы с моделью,
    /// записи на переднем плане, распознавания и фонового теста.
    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isDownloading || phase != .idle
    }

    /// Команда для AssistiveTouch / «Команд»: первое нажатие — запись, второе — текст в буфер.
    func toggleDictationFromShortcut() async {
        guard !isHandlingShortcut else { return }
        isHandlingShortcut = true
        defer { isHandlingShortcut = false }

        if phase == .recording {
            shortcutDictationActive = true
            await stopAndTranscribe()
            return
        }
        guard phase == .idle else {
            log.info("команда диктовки пропущена: приложение занято")
            return
        }
        if !selectedModelIsLoaded { await loadModel() }
        guard phase == .idle, selectedModelIsLoaded else { return }
        if await startRecording() {
            shortcutDictationActive = true
            // Старый результат не должен попасть в буфер после слишком короткой записи.
            lastResult = nil
            resultText = ""
            status = "Идёт диктовка. Нажмите AssistiveTouch ещё раз или «Стоп и распознать»."
            log.info("диктовка запущена внешней командой")
        }
    }

    // MARK: - Модель

    func deleteModel(_ model: ModelInfo) async {
        guard phase == .idle, !backgroundDictationEnabled, store.downloadingID == nil else { return }
        modelError = nil
        if loaded?.modelID == model.id {
            await unloadAll()
            log.info("модель \(model.id) выгружена перед удалением файла")
        }
        store.delete(model)
    }

    func deleteCoreMLModel() async {
        guard phase == .idle, !backgroundDictationEnabled, store.downloadingID == nil else { return }
        modelError = nil
        if loaded?.modelID == ModelStore.coreMLID {
            await unloadAll()
            log.info("модель \(ModelStore.coreMLID) выгружена перед удалением файла")
        }
        store.deleteCoreML()
    }

    /// Выгружает оба движка.
    private func unloadAll() async {
        await engine.unload()
        await coreMLEngine.unload()
        loaded = nil
    }

    /// Освобождает память движков, сохраняя скачанные файлы и последнюю запись.
    func unloadModel() async {
        guard phase == .idle, !backgroundDictationEnabled, let model = loaded else { return }
        phase = .unloading
        await unloadAll()
        modelError = nil
        status = ""
        log.info("модель \(model.modelID) выгружена пользователем; файл сохранён")
        phase = .idle
    }

    func loadModel() async {
        guard phase == .idle, !backgroundDictationEnabled, store.downloadingID == nil else { return }
        modelError = nil
        let backend = selectedBackend
        let modelID: String
        let title: String
        let path: String
        if backend.isCoreML {
            guard let folder = store.coreMLFolderURL else {
                modelError = "Сначала скачайте модель"
                return
            }
            modelID = ModelStore.coreMLID
            title = ModelStore.coreMLTitle
            path = folder.path
        } else {
            guard let model = selectedModel, store.isDownloaded(model), let url = store.fileURL(for: model) else {
                modelError = "Сначала скачайте выбранную модель"
                return
            }
            modelID = model.id
            title = model.title
            path = url.path
        }
        loadStayedActive = UIApplication.shared.applicationState == .active
        phase = .loading
        status = ""
        store.clearMessage()
        modelLoadStage = "Подготовка модели…"
        modelLoadStarted = Date()
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                self.log.info("загрузка: \(self.modelLoadStage); состояние=\(Metrics.appStateName()); thermal=\(Metrics.snapshot().thermal)")
            }
        }
        defer { heartbeat.cancel(); modelLoadStarted = nil }
        if loaded != nil {
            await unloadAll()
        }

        let requested = backend.coreMLCompute?.logName ?? (backend == .metal ? "Metal" : "CPU")
        let before = Metrics.snapshot()
        sampler.start()
        // Строка «старт» пишется и сбрасывается на диск до вызова ядра: Metal может убить процесс.
        log.start("загрузка модели \(modelID), запрошен \(requested); footprint=\(Metrics.mb(before.footprintBytes)) МБ, доступно=\(Metrics.mb(before.availableBytes)) МБ, состояние=\(before.appState), thermal=\(before.thermal)")
        let started = Date()
        do {
            let actual: String
            let loadDetail: String
            if let compute = backend.coreMLCompute {
                loadDetail = try await coreMLEngine.load(folder: URL(fileURLWithPath: path, isDirectory: true), compute: compute, parallel: parallelCoreMLLoading, log: log) { [weak self] stage in
                    self?.modelLoadStage = stage
                }
                actual = compute.logName
            } else {
                loadDetail = ""
                actual = try await engine.load(path: path, useGPU: backend == .metal)
            }
            let seconds = Date().timeIntervalSince(started)
            let peak = sampler.stop()
            let after = Metrics.snapshot()
            loaded = LoadedModel(modelID: modelID, requestedBackend: backend, backend: actual, title: title)
            status = ""
            let foregroundRun = loadStayedActive && UIApplication.shared.applicationState == .active
            log.end("загрузка модели ok: foregroundRun=\(foregroundRun); \(modelID), запрошен \(requested), бэкенд=\(actual), время=\(Self.fmt(seconds)) с; footprint до=\(Metrics.mb(before.footprintBytes)) после=\(Metrics.mb(after.footprintBytes)) пик=\(Metrics.mb(peak.peakFootprint)) МБ; доступно до=\(Metrics.mb(before.availableBytes)) после=\(Metrics.mb(after.availableBytes)) мин=\(Metrics.mb(peak.minAvailable)) МБ; thermal=\(after.thermal)")
            if !loadDetail.isEmpty { log.info(loadDetail) }
        } catch {
            _ = sampler.stop()
            if let issue = error as? ModelFilesError {
                modelError = issue.localizedDescription
                log.end("загрузка модели ОШИБКА: \(modelID), запрошен \(requested): \(issue.detail)")
            } else {
                modelError = "Ошибка загрузки: \(error.localizedDescription)"
                log.end("загрузка модели ОШИБКА: \(modelID), запрошен \(requested): \(error.localizedDescription)")
            }
        }
        phase = .idle
    }

    /// Файлы выбранной модели уже на устройстве.
    private var selectedModelFilesPresent: Bool {
        if selectedBackend.isCoreML { return store.coreMLDownloaded }
        guard let model = selectedModel else { return false }
        return store.isDownloaded(model)
    }

    /// Автозагрузка при запуске, один раз за процесс. Флаг в UserDefaults защищает от петли падений:
    /// если прошлая автозагрузка не завершилась (систему убила во время подготовки Core ML), пользователь нажимает кнопку сам.
    func autoLoadModelIfNeeded() async {
        guard !didAttemptAutoLoad else { return }
        didAttemptAutoLoad = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: SpikeDefaults.autoLoadInProgress) {
            defaults.set(false, forKey: SpikeDefaults.autoLoadInProgress)
            log.info("автозагрузка модели пропущена: прошлая автозагрузка не завершилась (вероятно, процесс убила система); пользователь загрузит модель кнопкой")
            return
        }
        guard phase == .idle, !selectedModelIsLoaded, store.downloadingID == nil, selectedModelFilesPresent else { return }
        defaults.set(true, forKey: SpikeDefaults.autoLoadInProgress)
        // Флаг должен попасть на диск до тяжёлой подготовки: процесс могут убить в любой момент.
        defaults.synchronize()
        log.info("автозагрузка модели при запуске")
        await loadModel()
        defaults.set(false, forKey: SpikeDefaults.autoLoadInProgress)
    }

    // MARK: - Запись на переднем плане

    /// Возвращает true, только если запись действительно началась.
    @discardableResult
    func startRecording() async -> Bool {
        guard phase == .idle, !backgroundModeChanging, selectedModelIsLoaded, store.downloadingID == nil else { return false }
        // Фаза занимается до первого await: второй вызов уже не пройдёт проверку.
        phase = .starting
        guard await beginCapture() else {
            phase = .idle
            return false
        }
        lastResult = nil
        resultText = ""
        dictationIdleStage = .ready
        phase = .recording
        status = ""
        startMeter()
        return true
    }

    func stopAndTranscribe() async {
        guard phase == .recording else { return }
        let copyResult = shortcutDictationActive
        shortcutDictationActive = false
        stopMeter()
        let samples = recorder.takeSamples()
        if backgroundDictationEnabled { recorder.enterKeepAlive() } else { recorder.stop() }
        guard acceptRecording(samples) else {
            dictationIdleStage = .noSpeech
            phase = .idle
            return
        }
        await runTranscription(samples: samples,
                               mode: backgroundDictationEnabled ? "фоновая диктовка" : "передний план",
                               modeTitle: backgroundDictationEnabled ? "Диктовка" : "Запись",
                               checkSpeech: true)
        if copyResult, lastResult != nil {
            if resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = "Речь не распознана. Повторите диктовку."
            } else {
                UIPasteboard.general.string = resultText
                status = "Текст скопирован. Вернитесь в приложение и нажмите «Вставить»."
                log.info("результат диктовки скопирован в буфер")
            }
        }
    }

    /// Открывает настройки Handy в «Настройках» iPhone (например, чтобы выдать доступ к микрофону).
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
