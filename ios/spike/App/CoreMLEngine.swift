import CryptoKit
import CoreML
import Foundation
import WhisperKit

/// Файлы модели неполные или повреждены. Пользователю — короткий текст, подробности — в `detail` (для журнала).
struct ModelFilesError: LocalizedError {
    let detail: String

    var errorDescription: String? { "Файл модели повреждён. Скачайте её заново." }
}

/// Единицы расчёта Core ML.
enum CoreMLCompute {
    case neuralEngine
    case cpu

    /// Название бэкенда для журнала.
    var logName: String {
        switch self {
        case .neuralEngine: return "CoreML Neural Engine"
        case .cpu: return "CoreML CPU"
        }
    }

    var options: ModelComputeOptions {
        switch self {
        case .neuralEngine:
            // melCompute обязательно .cpuOnly: значение по умолчанию (.cpuAndGPU) сломается в фоне,
            // потому что GPU там запрещён.
            return ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        case .cpu:
            return ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuOnly,
                textDecoderCompute: .cpuOnly
            )
        }
    }
}

/// Распознавание Turbo через Core ML (WhisperKit). Экземпляр WhisperKit живёт внутри актора.
actor CoreMLEngine {
    /// Вариант модели в репозитории argmaxinc/whisperkit-coreml.
    static let modelVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private var whisperKit: WhisperKit?

    /// Замеры MLModel.load не доказывают попадание в системный кэш: Core ML не сообщает его здесь.
    func load(folder: URL, compute: CoreMLCompute, parallel: Bool, log: SpikeLog,
              progress: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        let totalStart = ProcessInfo.processInfo.systemUptime
        await unload()
        let session = String(UUID().uuidString.prefix(8))
        let previousPath = UserDefaults.standard.string(forKey: "spike.lastCoreMLPath")
        log.info("Core ML [\(session)]: folder=\(folder.path); previousPathEqual=\(previousPath.map { $0 == folder.path }?.description ?? "unknown"); OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        UserDefaults.standard.set(folder.path, forKey: "spike.lastCoreMLPath")
        log.info("Core ML [\(session)]: WhisperKit 1.1.1; prewarm=false; download=false; mel=cpuOnly; encoder/decoder=\(compute.logName); optimizationHints=default; explicitCompile=false; parallelEncoder=\(parallel)")
        // Только метаданные: чтение 632 МБ весов перед замером исказило бы файловый кэш.
        let metadataStart = ProcessInfo.processInfo.systemUptime
        for name in ["MelSpectrogram", "TextDecoder", "AudioEncoder"] {
            let url = folder.appendingPathComponent(name + ".mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ModelFilesError(detail: "Отсутствует \(name).mlmodelc. Скачайте модель заново.")
            }
            log.info("Core ML [\(session)]: \(name) \(Self.manifest(at: url))")
        }
        log.info(String(format: "Core ML [%@]: metadata=%.3f с", session, ProcessInfo.processInfo.systemUptime - metadataStart))
        let encoder = MeasuredAudioEncoder(log: log, session: session, progress: progress)
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            computeOptions: compute.options,
            audioEncoder: encoder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: false,
            download: false
        )
        let initStart = ProcessInfo.processInfo.systemUptime
        let kit = try await WhisperKit(config)
        log.info(String(format: "Core ML [%@]: WhisperKit.init(load:false)=%.3f с", session, ProcessInfo.processInfo.systemUptime - initStart))
        if parallel {
            await progress("Подготовка энкодера и декодера…")
            encoder.startPreloading(at: folder.appendingPathComponent("AudioEncoder.mlmodelc"),
                                    computeUnits: compute.options.audioEncoderCompute)
        } else {
            await progress("Подготовка декодера…")
        }
        log.info("Core ML [\(session)]: loadModels begin (MelSpectrogram → TextDecoder → AudioEncoder → tokenizer)")
        do {
            try await kit.loadModels()
        } catch {
            await encoder.cancelPreloading()
            await kit.unloadModels()
            log.info("Core ML [\(session)]: loadModels failed: \(error.localizedDescription)")
            throw error
        }
        whisperKit = kit
        let timings = kit.currentTimings
        let other = max(0, timings.modelLoading - timings.encoderLoadTime - timings.decoderLoadTime - timings.tokenizerLoadTime)
        return String(
            format: "Core ML [%@]: total=%.3f с; ожидание энкодера в loadModels=%.3f с; декодер=%.3f с; токенизатор=%.3f с; прочее loadModels=%.3f с; cacheHit=unknown",
            session, ProcessInfo.processInfo.systemUptime - totalStart,
            timings.encoderLoadTime, timings.decoderLoadTime, timings.tokenizerLoadTime, other
        )
    }

    /// Отпечаток имён, размеров и mtime, а не контрольная сумма содержимого модели.
    private static func manifest(at folder: URL) -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return "metadata unavailable"
        }
        var rows: [String] = []
        var bytes = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            bytes += size
            rows.append("\(url.path.replacingOccurrences(of: folder.path, with: ""))|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        let digest = SHA256.hash(data: Data(rows.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "files=\(rows.count); bytes=\(bytes); metadataSHA256=\(digest)"
    }

    /// Распознаёт 16 кГц mono Float32. Ошибки возвращает в результате, не бросает.
    func transcribe(samples: [Float], language: String) async -> TranscribeOutcome {
        guard let kit = whisperKit else {
            return TranscribeOutcome(text: nil, error: "модель не загружена", seconds: 0)
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscribeOutcome(text: text, error: nil, seconds: elapsed, detail: Self.detail(of: results))
        } catch {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            return TranscribeOutcome(text: nil, error: error.localizedDescription, seconds: elapsed)
        }
    }

    /// Освобождает модели и экземпляр WhisperKit.
    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    /// Тайминги для сравнения с CPU; сами по себе не доказывают выбор вычислительного устройства.
    private static func detail(of results: [TranscriptionResult]) -> String? {
        guard let timings = results.first?.timings else { return nil }
        let encoder = String(format: "%.2f", timings.encoding)
        let decoder = String(format: "%.2f", timings.decodingLoop)
        let fallbacks = String(format: "%.0f", timings.totalDecodingFallbacks)
        return "энкодер=\(encoder) с декодер=\(decoder) с откаты=\(fallbacks)"
    }
}

/// Обёртка использует штатный AudioEncoder для инференса и ту же конфигурацию загрузки.
/// Единственный MLModel.load измеряется напрямую; повторной загрузки или prewarm здесь нет.
private final class MeasuredAudioEncoder: AudioEncoding, WhisperMLModel {
    private let encoder = AudioEncoder()
    private let log: SpikeLog
    private let session: String
    private let progress: @MainActor @Sendable (String) -> Void
    private var preloadTask: Task<MLModel, Error>?

    init(log: SpikeLog, session: String, progress: @escaping @MainActor @Sendable (String) -> Void) {
        self.log = log
        self.session = session
        self.progress = progress
    }

    var model: MLModel? {
        get { encoder.model }
        set { encoder.model = newValue }
    }
    var embedSize: Int? { encoder.embedSize }

    func encodeFeatures(_ features: any FeatureExtractorOutputType) async throws -> (any AudioEncoderOutputType)? {
        try await encoder.encodeFeatures(features)
    }

    /// Перекрываем независимые загрузки энкодера и декодера. Каждая модель создаётся один раз.
    func startPreloading(at url: URL, computeUnits: MLComputeUnits) {
        preloadTask = Task { try await Self.load(at: url, computeUnits: computeUnits, log: log, session: session) }
    }

    func cancelPreloading() async {
        preloadTask?.cancel()
        // Core ML может завершать системную операцию несмотря на отмену. Не оставляем её бесхозной.
        _ = await preloadTask?.result
        preloadTask = nil
    }

    func loadModel(at modelPath: URL, computeUnits: MLComputeUnits, prewarmMode: Bool) async throws {
        await progress("Подготовка энкодера…")
        let loaded: MLModel
        if let task = preloadTask {
            defer { preloadTask = nil }
            loaded = try await task.value
        } else {
            loaded = try await Self.load(at: modelPath, computeUnits: computeUnits, log: log, session: session)
        }
        model = prewarmMode ? nil : loaded
        await progress("Подготовка словаря…")
    }

    private static func load(at url: URL, computeUnits: MLComputeUnits, log: SpikeLog, session: String) async throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        log.info("Core ML [\(session)]: AudioEncoder MLModel.load begin; units=\(computeUnits.rawValue)")
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let loaded = try await MLModel.load(contentsOf: url, configuration: config)
            log.info(String(format: "Core ML [%@]: AudioEncoder MLModel.load end=%.3f с", session, ProcessInfo.processInfo.systemUptime - start))
            return loaded
        } catch {
            log.info(String(format: "Core ML [%@]: AudioEncoder MLModel.load failed after %.3f с: %@", session, ProcessInfo.processInfo.systemUptime - start, error.localizedDescription))
            throw error
        }
    }
}
