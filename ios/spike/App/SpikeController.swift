import Foundation

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
    enum Phase: Equatable {
        case idle
        case loading
        case recording
        case transcribing
        case backgroundRecording
    }

    struct LoadedModel {
        let modelID: String
        let requestedBackend: SpikeBackend
        let backend: String
    }

    /// Длительность записи в фоновом тесте, секунды.
    static let backgroundSeconds = 20
    private static let language = "ru"
    /// Короче этого (0,5 с) распознавать бессмысленно.
    private static let minSamples = 8_000

    let log: SpikeLog
    let store: ModelStore

    @Published var selectedModelID = "turbo"
    @Published var selectedBackend: SpikeBackend = .coreMLNeuralEngine
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var loaded: LoadedModel?
    @Published private(set) var resultText = ""
    @Published private(set) var status = ""
    @Published private(set) var capturedSeconds = 0.0
    @Published private(set) var countdown = 0
    @Published private(set) var lastAudioSeconds = 0.0

    private let engine = Engine()
    private let coreMLEngine = CoreMLEngine()
    private let recorder = Recorder()
    private let sampler = PeakSampler()
    private var lastSamples: [Float] = []
    private var meterTask: Task<Void, Never>?

    init(log: SpikeLog, store: ModelStore) {
        self.log = log
        self.store = store
        recorder.onEvent = { message in
            log.info(message)
        }
    }

    var selectedModel: ModelInfo? {
        ModelCatalog.all.first { $0.id == selectedModelID }
    }

    var isBusy: Bool {
        phase != .idle
    }

    // MARK: - Модель

    func deleteModel(_ model: ModelInfo) async {
        if loaded?.modelID == model.id {
            await unloadAll()
            log.info("модель \(model.id) выгружена перед удалением файла")
        }
        store.delete(model)
    }

    func deleteCoreMLModel() async {
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

    func loadModel() async {
        guard phase == .idle else { return }
        let backend = selectedBackend
        let modelID: String
        let title: String
        let path: String
        if backend.isCoreML {
            guard let folder = store.coreMLFolderURL else {
                status = "Сначала скачайте модель Turbo Core ML."
                return
            }
            modelID = ModelStore.coreMLID
            title = ModelStore.coreMLTitle
            path = folder.path
        } else {
            guard let model = selectedModel, store.isDownloaded(model), let url = store.fileURL(for: model) else {
                status = "Сначала скачайте выбранную модель."
                return
            }
            modelID = model.id
            title = model.title
            path = url.path
        }
        phase = .loading
        status = backend.isCoreML
            ? "Загрузка модели… Первый раз на Neural Engine это может занять несколько минут."
            : "Загрузка модели \(title)…"
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
            if let compute = backend.coreMLCompute {
                try await coreMLEngine.load(folder: URL(fileURLWithPath: path, isDirectory: true), compute: compute)
                actual = compute.logName
            } else {
                actual = try await engine.load(path: path, useGPU: backend == .metal)
            }
            let seconds = Date().timeIntervalSince(started)
            let peak = sampler.stop()
            let after = Metrics.snapshot()
            loaded = LoadedModel(modelID: modelID, requestedBackend: backend, backend: actual)
            status = "Модель загружена за \(Self.fmt(seconds)) с."
            log.end("загрузка модели ok: \(modelID), запрошен \(requested), бэкенд=\(actual), время=\(Self.fmt(seconds)) с; footprint до=\(Metrics.mb(before.footprintBytes)) после=\(Metrics.mb(after.footprintBytes)) пик=\(Metrics.mb(peak.peakFootprint)) МБ; доступно до=\(Metrics.mb(before.availableBytes)) после=\(Metrics.mb(after.availableBytes)) мин=\(Metrics.mb(peak.minAvailable)) МБ; thermal=\(after.thermal)")
        } catch {
            _ = sampler.stop()
            status = "Ошибка загрузки: \(error.localizedDescription)"
            log.end("загрузка модели ОШИБКА: \(modelID), запрошен \(requested): \(error.localizedDescription)")
        }
        phase = .idle
    }

    // MARK: - Запись на переднем плане

    func startRecording() async {
        guard phase == .idle else { return }
        guard await beginCapture() else { return }
        phase = .recording
        status = "Идёт запись. Скажите фразу 15–20 секунд."
        startMeter()
    }

    func stopAndTranscribe() async {
        guard phase == .recording else { return }
        stopMeter()
        let samples = recorder.takeSamples()
        recorder.stop()
        guard acceptRecording(samples) else {
            phase = .idle
            return
        }
        await runTranscription(samples: samples, mode: "передний план")
    }

    /// Повторное распознавание того же аудио (например, после смены бэкенда).
    func repeatOnLastRecording() async {
        guard phase == .idle, !lastSamples.isEmpty else { return }
        await runTranscription(samples: lastSamples, mode: "повтор той же записи")
    }

    // MARK: - Фоновый тест

    /// Запись `backgroundSeconds` секунд; пользователь уходит на домашний экран и говорит.
    /// По таймеру аудио забирается, запись переходит в keepAlive, запускается распознавание.
    func startBackgroundTest() async {
        guard phase == .idle else { return }
        guard loaded != nil else {
            status = "Сначала загрузите модель."
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
            await runTranscription(samples: samples, mode: "фоновый тест")
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
            status = "Нет доступа к микрофону. Разрешите его в Настройки → Handy Spike."
            return false
        }
        do {
            try recorder.start()
            return true
        } catch {
            status = "Не удалось начать запись: \(error.localizedDescription)"
            log.info("не удалось начать запись: \(error.localizedDescription)")
            return false
        }
    }

    private func acceptRecording(_ samples: [Float]) -> Bool {
        guard samples.count >= Self.minSamples else {
            status = "Запись слишком короткая (\(Self.fmt(Double(samples.count) / Recorder.sampleRate)) с)."
            log.info(status)
            recorder.stop()
            return false
        }
        lastSamples = samples
        lastAudioSeconds = Double(samples.count) / Recorder.sampleRate
        return true
    }

    private func runTranscription(samples: [Float], mode: String) async {
        guard let model = loaded else {
            status = "Сначала загрузите модель."
            phase = .idle
            return
        }
        phase = .transcribing
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
            status = "Готово: \(Self.fmt(outcome.seconds)) с, RTF \(Self.fmt(rtf, digits: 3))."
            log.end("\(label) \(numbers)\(detail) текст=«\(text)»")
        } else {
            let message = outcome.error ?? "неизвестная ошибка"
            resultText = ""
            status = "Ошибка распознавания: \(message)"
            log.end("\(label) \(numbers)\(detail) ОШИБКА: \(message)")
        }
        phase = .idle
    }

    private func startMeter() {
        meterTask?.cancel()
        capturedSeconds = 0
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.capturedSeconds = self.recorder.capturedSeconds
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
