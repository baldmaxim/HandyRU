import Foundation
import UIKit
import os

/// Снимок состояния процесса на момент вызова.
struct MetricsSnapshot {
    /// phys_footprint — то, что считает системный лимитер памяти (jetsam).
    let footprintBytes: UInt64
    /// Сколько ещё памяти можно занять до лимита (os_proc_available_memory).
    let availableBytes: Int
    let appState: String
    let thermal: String
}

/// Замеры процесса. Читать только с главного потока (нужен UIApplication).
@MainActor
enum Metrics {
    static func snapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            footprintBytes: footprintBytes(),
            availableBytes: availableBytes(),
            appState: appStateName(),
            thermal: thermalName()
        )
    }

    /// phys_footprint через task_info(TASK_VM_INFO).
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static func availableBytes() -> Int {
        Int(os_proc_available_memory())
    }

    static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    static func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Мегабайты целым числом, для журнала.
    static func mb(_ bytes: UInt64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }

    static func mb(_ bytes: Int) -> String {
        mb(UInt64(max(bytes, 0)))
    }
}

/// Таймер, который во время работы запоминает пиковый footprint и минимум доступной памяти.
@MainActor
final class PeakSampler {
    private var timer: Timer?
    private(set) var peakFootprint: UInt64 = 0
    private(set) var minAvailable = Int.max

    func start() {
        stopTimer()
        peakFootprint = 0
        minAvailable = Int.max
        sample()
        let newTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            // Таймер добавлен в главный цикл, блок вызывается на главном потоке.
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Останавливает таймер, делает последний замер и возвращает пик и минимум доступной памяти.
    func stop() -> (peakFootprint: UInt64, minAvailable: Int) {
        sample()
        stopTimer()
        return (peakFootprint, minAvailable == Int.max ? 0 : minAvailable)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        peakFootprint = max(peakFootprint, Metrics.footprintBytes())
        minAvailable = min(minAvailable, Metrics.availableBytes())
    }
}
