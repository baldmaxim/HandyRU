import Foundation

/// Бэкенд распознавания: ядро на Rust (CPU, Metal) или Core ML (WhisperKit).
enum SpikeBackend: String, CaseIterable, Identifiable {
    case cpu
    case metal
    case coreMLNeuralEngine
    case coreMLCPU

    var id: String { rawValue }

    /// Техническое имя: идёт в журнал, менять нельзя.
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .metal: return "Metal"
        case .coreMLNeuralEngine: return "Core ML: Neural Engine"
        case .coreMLCPU: return "Core ML: CPU"
        }
    }

    /// Название для пользователя.
    var displayTitle: String {
        switch self {
        case .cpu: return "Процессор, файл GGML"
        case .metal: return "Видеокарта, только в открытом приложении"
        case .coreMLNeuralEngine: return "Neural Engine (рекомендуется)"
        case .coreMLCPU: return "Процессор (запасной)"
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
