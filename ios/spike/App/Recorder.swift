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
    var onInterruption: (() -> Void)?

    /// Пересоздаётся после сброса медиасервисов iOS.
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var keepAlive = false
    private var rawPeak: Float = 0
    private var rawSamples = 0
    private var conversionErrors = 0
    /// Пик с прошлого опроса `takeIntervalPeak()` (для индикатора уровня).
    private var intervalPeak: Float = 0
    /// Время начала фразы (systemUptime) и признак, что перезапуск захвата на ней уже был.
    private var phraseStarted: TimeInterval = 0
    private var zeroRecoveryDone = false

    var receivingSilentBuffers: Bool {
        lock.withLock { rawSamples > 0 && rawPeak == 0 }
    }

    var signalDescription: String {
        lock.withLock { "peak=\(rawPeak) samples=\(rawSamples) conversionErrors=\(conversionErrors)" }
    }
    private var running = false
    private var captureGeneration = 0
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

    var isRunning: Bool { running && engine.isRunning }

    /// Входной маршрут аудиосессии для журнала.
    var routeDescription: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
    }

    /// Начинает запись (буфер обнуляется). Вызывать только на переднем плане:
    /// из фона активировать аудиосессию нельзя.
    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        keepAlive = false
        rawPeak = 0
        rawSamples = 0
        conversionErrors = 0
        intervalPeak = 0
        phraseStarted = ProcessInfo.processInfo.systemUptime
        zeroRecoveryDone = false
        captureGeneration += 1
        lock.unlock()
        if running {
            if engine.isRunning { return }
            // Движок остановился сам (например, после смены конфигурации): запускаем заново.
            teardownEngine()
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        do {
            try startCapture(session: session)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        running = true
        observe()
    }

    /// Нулевой сигнал: на фразе ещё не было перезапуска, запись идёт (не keepAlive),
    /// с начала прошло `seconds`, а сырой пик по-прежнему 0.
    func needsZeroSignalRestart(after seconds: TimeInterval) -> Bool {
        lock.withLock {
            running && !keepAlive && !zeroRecoveryDone && rawPeak == 0
                && ProcessInfo.processInfo.systemUptime - phraseStarted >= seconds
        }
    }

    /// Перезапускает захват: tap снимается, движок останавливается, tap ставится заново.
    /// На переднем плане (`resetSession`) перед этим сессия деактивируется и активируется.
    /// Накопленный буфер очищается. Один раз на фразу.
    func restartCapture(resetSession: Bool) throws {
        lock.withLock { zeroRecoveryDone = true }
        guard running else { throw RecorderError.noInput }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let session = AVAudioSession.sharedInstance()
        do {
            if resetSession {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                try session.setActive(true)
            }
            lock.lock()
            samples.removeAll(keepingCapacity: true)
            rawPeak = 0
            rawSamples = 0
            conversionErrors = 0
            intervalPeak = 0
            captureGeneration += 1
            lock.unlock()
            try startCapture(session: session)
        } catch {
            teardownEngine()
            throw error
        }
    }

    /// Последний пик с прошлого вызова (0…1, линейная шкала сырого сигнала).
    func takeIntervalPeak() -> Float {
        lock.withLock {
            let peak = intervalPeak
            intervalPeak = 0
            return peak
        }
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
        captureGeneration += 1
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func stop() {
        guard running else { return }
        teardownEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// После `mediaServicesWereReset` старые аудиообъекты непригодны: движок создаётся заново.
    func resetAfterMediaServicesReset() {
        teardownEngine()
        engine = AVAudioEngine()
        converter = nil
        targetFormat = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Внутреннее

    /// Снимает tap и останавливает движок; сессию не трогает.
    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Конвертер в 16 кГц mono, tap и запуск движка. Сессия уже активна.
    private func startCapture(session: AVAudioSession) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        onEvent?("микрофон: route=\(routeDescription); input=\(inputFormat); sessionRate=\(session.sampleRate); inputMuted=\(AVAudioApplication.shared.isInputMuted); inputAvailable=\(session.isInputAvailable); inputGain=\(session.inputGain)")
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
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Вызывается на аудиопотоке.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let discard = keepAlive
        let generation = captureGeneration
        lock.unlock()
        if discard { return }
        if let channel = buffer.floatChannelData?[0] {
            let peak = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs($1)) }
            lock.withLock {
                if !keepAlive && generation == captureGeneration {
                    rawPeak = max(rawPeak, peak)
                    intervalPeak = max(intervalPeak, peak)
                    rawSamples += Int(buffer.frameLength)
                }
            }
        }
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
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            lock.withLock { conversionErrors += 1 }
            return
        }

        let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        lock.lock()
        if !keepAlive && generation == captureGeneration {
            samples.append(contentsOf: chunk)
        }
        lock.unlock()
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                self?.onEvent?("прерывание аудиосессии: \(type == .began ? "началось" : "закончилось")")
                if type == .began { self?.onInterruption?() }
            }
        )
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.onEvent?("изменилась конфигурация аудиодвижка (запись могла остановиться)")
                if self?.engine.isRunning == false { self?.onInterruption?() }
            }
        )
    }
}
