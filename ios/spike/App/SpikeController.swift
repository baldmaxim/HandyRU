import Foundation

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
        let requestedGPU: Bool
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
    @Published var useGPU = true
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var loaded: LoadedModel?
    @Published private(set) var resultText = ""
    @Published private(set) var status = ""
    @Published private(set) var capturedSeconds = 0.0
    @Published private(set) var countdown = 0
    @Published private(set) var lastAudioSeconds = 0.0

    private let engine = Engine()
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
            await engine.unload()
            loaded = nil
            log.info("модель \(model.id) выгружена перед удалением файла")
        }
        store.delete(model)
    }

    func loadModel() async {
        guard phase == .idle else { return }
        guard let model = selectedModel, store.isDownloaded(model), let url = store.fileURL(for: model) else {
            status = "Сначала скачайте выбранную модель."
            return
        }
        phase = .loading
        status = "Загрузка модели \(model.title)…"
        if loaded != nil {
            await engine.unload()
            loaded = nil
        }

        let requested = useGPU ? "Metal" : "CPU"
        let before = Metrics.snapshot()
        sampler.start()
        // Строка «старт» пишется и сбрасывается на диск до вызова ядра: Metal может убить процесс.
        log.start("загрузка модели \(model.id), запрошен \(requested); footprint=\(Metrics.mb(before.footprintBytes)) МБ, доступно=\(Metrics.mb(before.availableBytes)) МБ, состояние=\(before.appState), thermal=\(before.thermal)")
        let started = Date()
        do {
            let backend = try await engine.load(path: url.path, useGPU: useGPU)
            let seconds = Date().timeIntervalSince(started)
            let peak = sampler.stop()
            let after = Metrics.snapshot()
            loaded = LoadedModel(modelID: model.id, requestedGPU: useGPU, backend: backend)
            status = "Модель загружена за \(Self.fmt(seconds)) с."
            log.end("загрузка модели ok: \(model.id), запрошен \(requested), бэкенд=\(backend), время=\(Self.fmt(seconds)) с; footprint до=\(Metrics.mb(before.footprintBytes)) после=\(Metrics.mb(after.footprintBytes)) пик=\(Metrics.mb(peak.peakFootprint)) МБ; доступно до=\(Metrics.mb(before.availableBytes)) после=\(Metrics.mb(after.availableBytes)) мин=\(Metrics.mb(peak.minAvailable)) МБ; thermal=\(after.thermal)")
        } catch {
            _ = sampler.stop()
            status = "Ошибка загрузки: \(error.localizedDescription)"
            log.end("загрузка модели ОШИБКА: \(model.id), запрошен \(requested): \(error.localizedDescription)")
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

        let outcome = await engine.transcribe(samples: samples, language: Self.language)

        let peak = sampler.stop()
        let after = Metrics.snapshot()
        let rtf = audioSeconds > 0 ? outcome.seconds / audioSeconds : 0
        let numbers = "аудио=\(Self.fmt(audioSeconds)) с время=\(Self.fmt(outcome.seconds)) с RTF=\(Self.fmt(rtf, digits: 3)) footprint пик=\(Metrics.mb(peak.peakFootprint)) сейчас=\(Metrics.mb(after.footprintBytes)) МБ доступно сейчас=\(Metrics.mb(after.availableBytes)) мин=\(Metrics.mb(peak.minAvailable)) МБ состояние начало=\(before.appState) конец=\(after.appState) thermal=\(after.thermal)"

        if let text = outcome.text {
            resultText = text
            status = "Готово: \(Self.fmt(outcome.seconds)) с, RTF \(Self.fmt(rtf, digits: 3))."
            log.end("\(label) \(numbers) текст=«\(text)»")
        } else {
            let message = outcome.error ?? "неизвестная ошибка"
            resultText = ""
            status = "Ошибка распознавания: \(message)"
            log.end("\(label) \(numbers) ОШИБКА: \(message)")
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
