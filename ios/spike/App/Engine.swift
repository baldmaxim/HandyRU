import Foundation

/// Результат одного прогона распознавания.
struct TranscribeOutcome {
    let text: String?
    let error: String?
    /// Чистое время вызова ядра, секунды.
    let seconds: Double
    /// Дополнительные числа для журнала (например, тайминги Core ML); у остальных движков пусто.
    var detail: String? = nil
}

enum EngineError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Обёртка над C ABI ядра. Всё тяжёлое выполняется на отдельной serial-очереди,
/// главный поток не блокируется. Модель и сессия живут в процессе приложения.
final class Engine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "handyspike.engine", qos: .userInitiated)
    /// Доступ только с `queue`.
    private var ctx: OpaquePointer?

    /// Загружает модель (предыдущая выгружается). Возвращает имя реального бэкенда.
    func load(path: String, useGPU: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                self.freeContext()
                var errorPointer: UnsafeMutablePointer<CChar>?
                guard let newContext = spike_load(path, useGPU, &errorPointer) else {
                    let message = Engine.takeString(errorPointer) ?? "неизвестная ошибка загрузки"
                    continuation.resume(throwing: EngineError.message(message))
                    return
                }
                self.ctx = newContext
                let backend = Engine.takeString(spike_backend_name(newContext)) ?? "неизвестно"
                continuation.resume(returning: backend)
            }
        }
    }

    /// Распознаёт 16 кГц mono Float32.
    func transcribe(samples: [Float], language: String) async -> TranscribeOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<TranscribeOutcome, Never>) in
            queue.async {
                guard let context = self.ctx else {
                    continuation.resume(returning: TranscribeOutcome(text: nil, error: "модель не загружена", seconds: 0))
                    return
                }
                var errorPointer: UnsafeMutablePointer<CChar>?
                let started = DispatchTime.now().uptimeNanoseconds
                let textPointer = samples.withUnsafeBufferPointer { buffer in
                    spike_transcribe(context, buffer.baseAddress, buffer.count, language, &errorPointer)
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                let text = Engine.takeString(textPointer)
                let error = Engine.takeString(errorPointer)
                continuation.resume(
                    returning: TranscribeOutcome(
                        text: text,
                        error: text == nil ? (error ?? "неизвестная ошибка распознавания") : nil,
                        seconds: elapsed
                    )
                )
            }
        }
    }

    /// Выгружает модель и сессию (освобождает память).
    func unload() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.freeContext()
                continuation.resume()
            }
        }
    }

    private func freeContext() {
        if let context = ctx {
            spike_free(context)
            ctx = nil
        }
    }

    /// Копирует C-строку ядра в String и освобождает её.
    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { spike_free_string(pointer) }
        return String(cString: pointer)
    }
}
