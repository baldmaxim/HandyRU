import AVFoundation

/// Запись с микрофона в 16 кГц mono Float32.
///
/// Режим `keepAlive`: движок продолжает работать, а сэмплы отбрасываются.
/// Это нужно, чтобы во время распознавания в фоне приложение не усыпили:
/// iOS держит процесс живым, пока работает аудиосессия с фоновым режимом audio.
final class Recorder {
    enum RecorderError: LocalizedError {
        case noInput
        case converter

        var errorDescription: String? {
            switch self {
            case .noInput: return "у микрофона нет входного формата (занят другим приложением или нет доступа)"
            case .converter: return "не удалось создать конвертер в 16 кГц mono"
            }
        }
    }

    static let sampleRate = 16_000.0

    /// Сообщения об прерываниях сессии и смене конфигурации (для журнала). Вызывается на главном потоке.
    var onEvent: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var keepAlive = false
    private var running = false
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []

    /// Разрешение на микрофон; при первом вызове показывает системный запрос.
    static func ensurePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    /// Сколько секунд накоплено с начала записи.
    var capturedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Recorder.sampleRate
    }

    /// Начинает запись (буфер обнуляется). Вызывать только на переднем плане:
    /// из фона активировать аудиосессию нельзя.
    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        keepAlive = false
        lock.unlock()
        if running { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Recorder.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let newConverter = AVAudioConverter(from: inputFormat, to: target)
        else {
            throw RecorderError.converter
        }
        targetFormat = target
        converter = newConverter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
        observe()
    }

    /// Забирает накопленные сэмплы и очищает буфер.
    func takeSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let taken = samples
        samples.removeAll(keepingCapacity: true)
        return taken
    }

    /// Движок продолжает работать, сэмплы отбрасываются.
    func enterKeepAlive() {
        lock.lock()
        keepAlive = true
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Внутреннее

    /// Вызывается на аудиопотоке.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let discard = keepAlive
        lock.unlock()
        if discard { return }
        guard let converter, let targetFormat else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }

        let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                self?.onEvent?("прерывание аудиосессии: \(type == .began ? "началось" : "закончилось")")
            }
        )
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.onEvent?("изменилась конфигурация аудиодвижка (запись могла остановиться)")
            }
        )
    }
}
