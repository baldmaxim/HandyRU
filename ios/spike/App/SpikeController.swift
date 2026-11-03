import Foundation
import UIKit
import ActivityKit
import AVFoundation

/// Бэкенд распознавания: ядро на Rust (CPU, Metal) или Core ML (WhisperKit).
enum SpikeBackend: String, CaseIterable, Identifiable {
    case cpu
    case metal
    case coreMLNeuralEngine
    case coreMLCPU

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .metal: return "Metal"
        case .coreMLNeuralEngine: return "Core ML: Neural Engine"
        case .coreMLCPU: return "Core ML: CPU"
        }
    }

    var isCoreML: Bool {
        switch self {
        case .cpu, .metal: return false
        case .coreMLNeuralEngine, .coreMLCPU: return true
        }
    }

    /// Единицы расчёта для Core ML; для остальных бэкендов nil.
    var coreMLCompute: CoreMLCompute? {
        switch self {
        case .cpu, .metal: return nil
        case .coreMLNeuralEngine: return .neuralEngine
        case .coreMLCPU: return .cpu
        }
    }
}

/// Сценарии замеров: загрузка модели, запись, распознавание, фоновый тест.
/// Экран (`ContentView`) только показывает состояние и вызывает методы.
@MainActor
final class SpikeController: ObservableObject {
    /// App Intents выполняются в процессе приложения и используют ту же аудиосессию.
    static weak var current: SpikeController?

    enum Phase: Equatable {
        case idle
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
    private static let language = "ru"
    /// Короче этого (0,5 с) распознавать бессмысленно.
    private static let minSamples = 8_000

    let log: SpikeLog
    let store: ModelStore

    @Published var selectedModelID = "turbo" {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "spike.selectedModelID") }
    }
    @Published var selectedBackend: SpikeBackend = .coreMLNeuralEngine {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: "spike.selectedBackend") }
    }
    @Published private(set) var phase: Phase = .idle {
        didSet { updateDictationActivity() }
    }
    @Published private(set) var backgroundDictationEnabled = false
    @Published private(set) var backgroundModeChanging = false
    @Published private(set) var loaded: LoadedModel?
    @Published var parallelCoreMLLoading = false
    private var loadStayedActive = false

    func noteInactiveSceneDuringLoad() {
        if phase == .loading { loadStayedActive = false }
    }
    @Published private(set) var modelError: String?
    @Published private(set) var modelLoadStage = ""
    @Published private(set) var modelLoadStarted: Date?
    @Published private(set) var resultText = ""
    @Published private(set) var status = "" {
        didSet { statusIsError = false }
    }
    /// Статус — ошибка (экран красит его красным). Сбрасывается любой новой записью в `status`.
    @Published private(set) var statusIsError = false
    @Published private(set) var lastResult: RunResult?
    @Published private(set) var noMicrophoneSignal = false
    @Published private(set) var capturedSeconds = 0.0
    @Published private(set) var countdown = 0
    @Published private(set) var lastAudioSeconds = 0.0

    private let engine = Engine()
    private let coreMLEngine = CoreMLEngine()
    private let recorder = Recorder()
    private let sampler = PeakSampler()
    private var lastSamples: [Float] = []
    private var meterTask: Task<Void, Never>?
    private var isHandlingShortcut = false
    private var shortcutDictationActive = false
    private var dictationActivity: Activity<DictationActivityAttributes>?
    private var activityCleanupTask: Task<Void, Never>?
    private var activityUpdateTask: Task<Void, Never>?
    private var dictationIdleStage: DictationActivityAttributes.Stage = .ready

    init(log: SpikeLog, store: ModelStore) {
        self.log = log
        self.store = store
        if let saved = UserDefaults.standard.string(forKey: "spike.selectedBackend"),
           let backend = SpikeBackend(rawValue: saved) {
            selectedBackend = backend
        }
        if let saved = UserDefaults.standard.string(forKey: "spike.selectedModelID"),
           ModelCatalog.all.contains(where: { $0.id == saved }) {
            selectedModelID = saved
        }
        recorder.onEvent = { message in
            log.info(message)
        }
        recorder.onInterruption = { [weak self] in
            Task { @MainActor in self?.interruptBackgroundDictation() }
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
        await startRecording()
        if phase == .recording {
            shortcutDictationActive = true
            // Старый результат не должен попасть в буфер после слишком короткой записи.
            lastResult = nil
            resultText = ""
            status = "Идёт диктовка. Нажмите AssistiveTouch ещё раз или «Стоп и распознать»."
            log.info("диктовка запущена внешней командой")
        }
    }

    /// Микрофон включается явно на переднем плане; между фразами сэмплы отбрасываются.
    func setBackgroundDictationEnabled(_ enabled: Bool) async {
        guard phase == .idle, !backgroundModeChanging else { return }
        backgroundModeChanging = true
        defer { backgroundModeChanging = false }
        await activityCleanupTask?.value
        guard phase == .idle else { return }
        if !enabled {
            backgroundDictationEnabled = false
            recorder.stop()
            await endDictationActivity()
            status = ""
            log.info("фоновая диктовка выключена")
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            fail("Включите фоновую диктовку при открытом Handy.")
            return
        }
        guard selectedBackend != .metal else {
            fail("Для фоновой диктовки выберите Neural Engine или CPU: Metal в фоне недоступен.")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            fail("Разрешите Live Activities для Handy в настройках iPhone.")
            return
        }
        if !selectedModelIsLoaded { await loadModel() }
        guard selectedModelIsLoaded, phase == .idle, await beginCapture() else { return }
        recorder.enterKeepAlive()
        do {
            dictationIdleStage = .ready
            dictationActivity = try Activity.request(
                attributes: DictationActivityAttributes(),
                content: ActivityContent(state: .init(stage: .ready), staleDate: nil),
                pushType: nil
            )
            backgroundDictationEnabled = true
            status = ""
            log.info("фоновая диктовка включена: микрофон активен, ожидание команды")
        } catch {
            recorder.stop()
            fail("Не удалось включить индикатор диктовки: \(error.localizedDescription)")
        }
    }

    /// Возвращает только новый результат: «Команды» сами копируют его без открытия Handy.
    func toggleBackgroundDictation() async throws -> String {
        guard backgroundDictationEnabled, recorder.isRunning, dictationActivity != nil else {
            throw DictationCommandError.notReady
        }
        guard !isHandlingShortcut, phase == .idle || phase == .recording else {
            throw DictationCommandError.busy
        }
        isHandlingShortcut = true
        defer { isHandlingShortcut = false }
        log.info("фоновая команда диктовки: состояние=\(Metrics.appStateName())")
        if phase == .recording {
            await stopAndTranscribe()
            if statusIsError { throw DictationCommandError.failed(status) }
            let text = lastResult == nil ? "" : resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                status = "Текст передан в «Команды» для копирования. Нажмите «Вставить»."
                dictationIdleStage = .finished
                updateDictationActivity()
                log.info("результат фоновой диктовки передан в «Команды»")
            }
            if text.isEmpty {
                dictationIdleStage = .noSpeech
                updateDictationActivity()
            }
            return text
        }
        lastResult = nil
        resultText = ""
        shortcutDictationActive = false
        await startRecording()
        if statusIsError { throw DictationCommandError.failed(status) }
        return ""
    }

    private func updateDictationActivity() {
        guard let activity = dictationActivity else { return }
        let stage: DictationActivityAttributes.Stage = phase == .recording ? .recording
            : (phase == .transcribing ? .transcribing : dictationIdleStage)
        let previous = activityUpdateTask
        activityUpdateTask = Task {
            await previous?.value
            await activity.update(ActivityContent(state: .init(stage: stage), staleDate: nil))
        }
    }

    private func endDictationActivity() async {
        guard let activity = dictationActivity else { return }
        dictationActivity = nil
        await activityUpdateTask?.value
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func interruptBackgroundDictation() {
        guard backgroundDictationEnabled else { return }
        backgroundDictationEnabled = false
        shortcutDictationActive = false
        stopMeter()
        recorder.stop()
        if phase == .recording { phase = .idle }
        fail("Микрофон прерван другим приложением. Включите фоновую диктовку снова в Handy.")
        log.info("фоновая диктовка выключена после прерывания микрофона")
        Task { await endDictationActivity() }
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
                modelError = "Сначала скачайте модель Turbo Core ML"
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
            modelError = "Ошибка загрузки: \(error.localizedDescription)"
            log.end("загрузка модели ОШИБКА: \(modelID), запрошен \(requested): \(error.localizedDescription)")
        }
        phase = .idle
    }

    // MARK: - Запись на переднем плане

    func startRecording() async {
        guard phase == .idle, selectedModelIsLoaded, store.downloadingID == nil else { return }
        guard await beginCapture() else { return }
        lastResult = nil
        resultText = ""
        dictationIdleStage = .ready
        phase = .recording
        status = ""
        startMeter()
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
                               modeTitle: backgroundDictationEnabled ? "Диктовка" : "Запись")
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

    /// Повторное распознавание того же аудио (например, после смены бэкенда).
    func repeatOnLastRecording() async {
        guard phase == .idle, !lastSamples.isEmpty else { return }
        await runTranscription(samples: lastSamples, mode: "повтор той же записи", modeTitle: "Повтор")
    }

    /// Контрольная синтезированная фраза обходит микрофон и ресемплер Recorder.
    func transcribeDiagnosticAudio() async {
        guard phase == .idle, selectedModelIsLoaded else { return }
        do {
            guard let url = Bundle.main.url(forResource: "diagnostic-ru", withExtension: "wav") else {
                throw EngineError.message("Нет тестовой аудиозаписи в приложении")
            }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == Recorder.sampleRate,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw EngineError.message("Неверный формат тестовой записи")
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw EngineError.message("Нет аудиоданных") }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            log.info("контрольный WAV (без микрофона): \(Self.signalDescription(samples))")
            await runTranscription(samples: samples, mode: "контрольный WAV", modeTitle: "Тестовая фраза")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func signalDescription(_ samples: [Float]) -> String {
        var squares = 0.0
        var peak: Float = 0
        var nonfinite = 0
        var nonzero = 0
        for value in samples {
            guard value.isFinite else { nonfinite += 1; continue }
            squares += Double(value) * Double(value)
            peak = max(peak, abs(value))
            if value != 0 { nonzero += 1 }
        }
        let rms = sqrt(squares / Double(max(1, samples.count)))
        return String(format: "samples=%d peak=%.6f rms=%.6f dBFS=%.1f nonzero=%d nonfinite=%d",
                      samples.count, peak, rms, 20 * log10(max(rms, 1e-12)), nonzero, nonfinite)
    }

    // MARK: - Фоновый тест

    /// Запись `backgroundSeconds` секунд; пользователь уходит на домашний экран и говорит.
    /// По таймеру аудио забирается, запись переходит в keepAlive, запускается распознавание.
    func startBackgroundTest() async {
        guard phase == .idle, !backgroundDictationEnabled else { return }
        guard loaded != nil else {
            status = "Сначала загрузите модель"
            return
        }
        guard await beginCapture() else { return }
        phase = .backgroundRecording
        status = "Идёт запись. Сверните приложение (домашний экран) и говорите."
        log.info("фоновый тест: запись \(Self.backgroundSeconds) с, состояние=\(Metrics.appStateName())")
        startMeter()

        let deadline = Date().addingTimeInterval(Double(Self.backgroundSeconds))
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            countdown = Int(left.rounded(.up))
            try? await Task.sleep(for: .milliseconds(250))
        }
        countdown = 0
        stopMeter()

        let samples = recorder.takeSamples()
        // Движок записи остаётся включённым на время распознавания, чтобы приложение не усыпили.
        recorder.enterKeepAlive()
        log.info("фоновый тест: собрано \(Self.fmt(Double(samples.count) / Recorder.sampleRate)) с аудио из \(Self.backgroundSeconds), состояние=\(Metrics.appStateName())")
        if acceptRecording(samples) {
            await runTranscription(samples: samples, mode: "фоновый тест", modeTitle: "Фоновый тест")
        } else {
            phase = .idle
        }
        recorder.stop()
        log.info("фоновый тест: запись остановлена")
    }

    // MARK: - Общее

    /// Разрешение на микрофон и запуск записи. При отказе пишет причину в статус.
    private func beginCapture() async -> Bool {
        guard await Recorder.ensurePermission() else {
            fail("Нет доступа к микрофону. Разрешите его в Настройки → Handy Spike.")
            return false
        }
        do {
            try recorder.start()
            return true
        } catch {
            fail("Не удалось начать запись: \(error.localizedDescription)")
            log.info("не удалось начать запись: \(error.localizedDescription)")
            return false
        }
    }

    private func acceptRecording(_ samples: [Float]) -> Bool {
        log.info("запись: \(Self.signalDescription(samples)); raw \(recorder.signalDescription)")
        guard samples.count >= Self.minSamples else {
            status = "Запись слишком короткая (\(SpikeFormat.seconds(Double(samples.count) / Recorder.sampleRate)))"
            log.info(status)
            if !backgroundDictationEnabled { recorder.stop() }
            return false
        }
        // Whisper может придумать фразу даже для цифрового нуля.
        // Тихую речь пропускаем без порога громкости.
        guard samples.contains(where: { $0 != 0 && $0.isFinite }) else {
            status = "От микрофона не поступил звук. Проверьте микрофон и повторите запись."
            log.info("\(status) inputMuted=\(AVAudioApplication.shared.isInputMuted); распознавание пропущено")
            lastResult = nil
            resultText = ""
            return false
        }
        lastSamples = samples
        lastAudioSeconds = Double(samples.count) / Recorder.sampleRate
        return true
    }

    private func runTranscription(samples: [Float], mode: String, modeTitle: String) async {
        guard let model = loaded else {
            status = "Сначала загрузите модель"
            phase = .idle
            return
        }
        phase = .transcribing
        lastResult = nil
        status = "Распознавание…"
        let audioSeconds = Double(samples.count) / Recorder.sampleRate
        let before = Metrics.snapshot()
        let label = "модель=\(model.modelID) бэкенд=\(model.backend) режим=\(mode)"
        sampler.start()
        // «Старт» пишется до вызова ядра: в фоне процесс может быть убит прямо внутри.
        log.start("распознавание \(label) аудио=\(Self.fmt(audioSeconds)) с; состояние=\(before.appState) footprint=\(Metrics.mb(before.footprintBytes)) МБ доступно=\(Metrics.mb(before.availableBytes)) МБ thermal=\(before.thermal)")

        let outcome: TranscribeOutcome
        if model.requestedBackend.isCoreML {
            outcome = await coreMLEngine.transcribe(samples: samples, language: Self.language)
        } else {
            outcome = await engine.transcribe(samples: samples, language: Self.language)
        }

        let peak = sampler.stop()
        let after = Metrics.snapshot()
        let rtf = audioSeconds > 0 ? outcome.seconds / audioSeconds : 0
        let numbers = "аудио=\(Self.fmt(audioSeconds)) с время=\(Self.fmt(outcome.seconds)) с RTF=\(Self.fmt(rtf, digits: 3)) footprint пик=\(Metrics.mb(peak.peakFootprint)) сейчас=\(Metrics.mb(after.footprintBytes)) МБ доступно сейчас=\(Metrics.mb(after.availableBytes)) мин=\(Metrics.mb(peak.minAvailable)) МБ состояние начало=\(before.appState) конец=\(after.appState) thermal=\(after.thermal)"

        let detail = outcome.detail.map { " \($0)" } ?? ""

        if let text = outcome.text {
            resultText = text
            lastResult = RunResult(
                seconds: outcome.seconds,
                rtf: rtf,
                audioSeconds: audioSeconds,
                modelTitle: model.title,
                backendTitle: model.requestedBackend.title,
                modeTitle: modeTitle
            )
            dictationIdleStage = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noSpeech : .finished
            // Время показывает блок результата.
            status = ""
            log.end("\(label) \(numbers)\(detail) текст=«\(text)»")
        } else {
            let message = outcome.error ?? "неизвестная ошибка"
            resultText = ""
            fail("Ошибка распознавания: \(message)")
            log.end("\(label) \(numbers)\(detail) ОШИБКА: \(message)")
        }
        phase = .idle
    }

    /// Ошибка в статусе: экран красит её красным.
    private func fail(_ text: String) {
        status = text
        statusIsError = true
        dictationIdleStage = .failed
        updateDictationActivity()
    }

    private func startMeter() {
        meterTask?.cancel()
        capturedSeconds = 0
        noMicrophoneSignal = false
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.capturedSeconds = self.recorder.capturedSeconds
                self.noMicrophoneSignal = self.capturedSeconds >= 1 && self.recorder.receivingSilentBuffers
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    private static func fmt(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }
}
