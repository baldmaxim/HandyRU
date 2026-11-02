import CoreML
import Foundation
import WhisperKit

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

    /// Загружает модель из локальной папки (предыдущая выгружается). Первая компиляция под Neural Engine может идти минуты.
    func load(folder: URL, compute: CoreMLCompute) async throws {
        await unload()
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            computeOptions: compute.options,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
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

    /// Тайминги первого результата: по ним видно, не откатился ли Neural Engine на CPU.
    private static func detail(of results: [TranscriptionResult]) -> String? {
        guard let timings = results.first?.timings else { return nil }
        let encoder = String(format: "%.2f", timings.encoding)
        let decoder = String(format: "%.2f", timings.decodingLoop)
        let fallbacks = String(format: "%.0f", timings.totalDecodingFallbacks)
        return "энкодер=\(encoder) с декодер=\(decoder) с откаты=\(fallbacks)"
    }
}
