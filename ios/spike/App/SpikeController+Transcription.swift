import Foundation
import UIKit
import AVFoundation

/// Захват звука, распознавание и общие помощники контроллера.
extension SpikeController {
    // MARK: - Повторное и контрольное распознавание

    /// Повторное распознавание того же аудио (например, после смены бэкенда).
    func repeatOnLastRecording() async {
        guard phase == .idle, !backgroundModeChanging, !lastSamples.isEmpty else { return }
        await runTranscription(samples: lastSamples, mode: "повтор той же записи", modeTitle: "Повтор")
    }

    /// Контрольная синтезированная фраза обходит микрофон и ресемплер Recorder.
    func transcribeDiagnosticAudio() async {
        guard phase == .idle, !backgroundModeChanging, selectedModelIsLoaded else { return }
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

    static func signalDescription(_ samples: [Float]) -> String {
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

    // MARK: - Захват

    /// Разрешение на микрофон и запуск записи. При отказе пишет причину в статус.
    func beginCapture() async -> Bool {
        guard await Recorder.ensurePermission() else {
            microphoneAccessDenied = true
            fail("Нет доступа к микрофону. Разрешите его в настройках.")
            return false
        }
        microphoneAccessDenied = false
        do {
            try recorder.start()
            return true
        } catch {
            fail("Не удалось начать запись: \(error.localizedDescription)")
            log.info("не удалось начать запись: \(error.localizedDescription)")
            return false
        }
    }

    /// Нулевой сигнал после `zeroSignalWait`: один раз на фразу перезапускаем захват.
    /// На переднем плане дополнительно переактивируем сессию, в фоне её не трогаем.
    func restartCaptureAfterZeroSignal() {
        let foreground = UIApplication.shared.applicationState == .active
        let muted = AVAudioApplication.shared.isInputMuted
        let route = recorder.routeDescription
        let prefix = "нулевой сигнал микрофона через \(Self.fmt(Self.zeroSignalWait, digits: 1)) с: inputMuted=\(muted); route=\(route); сессия \(foreground ? "переактивирована" : "не тронута")"
        do {
            try recorder.restartCapture(resetSession: foreground)
            log.info("\(prefix); перезапуск захвата: выполнен")
        } catch {
            log.info("\(prefix); перезапуск захвата: ОШИБКА \(error.localizedDescription)")
            handleMicrophoneInterruption()
        }
    }

    func startMeter() {
        meterTask?.cancel()
        capturedSeconds = 0
        inputLevel = 0
        noMicrophoneSignal = false
        _ = recorder.takeIntervalPeak()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.capturedSeconds = self.recorder.capturedSeconds
                self.inputLevel = Self.level(forPeak: self.recorder.takeIntervalPeak())
                self.noMicrophoneSignal = self.capturedSeconds >= 1 && self.recorder.receivingSilentBuffers
                if self.recorder.needsZeroSignalRestart(after: Self.zeroSignalWait) {
                    self.restartCaptureAfterZeroSignal()
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
        inputLevel = 0
    }

    /// Пик сигнала (0…1) в шкалу индикатора: −50…0 дБ линейно в 0…1.
    static func level(forPeak peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return min(1, max(0, (decibels + 50) / 50))
    }

    // MARK: - Проверка записи и распознавание

    func acceptRecording(_ samples: [Float]) -> Bool {
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
            let muted = AVAudioApplication.shared.isInputMuted
            // Это сбой, а не пустая фраза: команда AssistiveTouch тоже должна получить ошибку.
            fail(muted
                ? "Микрофон отключён в системе. Включите его и повторите запись."
                : "От микрофона не поступил звук. Проверьте микрофон и повторите запись.")
            log.info("\(status) inputMuted=\(muted); распознавание пропущено")
            lastResult = nil
            resultText = ""
            return false
        }
        lastSamples = samples
        lastAudioSeconds = Double(samples.count) / Recorder.sampleRate
        return true
    }

    /// `checkSpeech`: пропустить распознавание, если в записи нет речи. Для контрольного WAV и повтора выключено.
    func runTranscription(samples: [Float], mode: String, modeTitle: String, checkSpeech: Bool = false) async {
        guard let model = loaded else {
            status = "Сначала загрузите модель"
            phase = .idle
            return
        }
        let audioSeconds = Double(samples.count) / Recorder.sampleRate
        if checkSpeech {
            let voiced = SpeechGate.voicedSeconds(samples: samples, sampleRate: Recorder.sampleRate)
            let noSpeech = voiced < SpeechGate.minVoicedSeconds
            log.info("отсечка тишины: озвучено=\(Self.fmt(voiced, digits: 3)) с из \(Self.fmt(audioSeconds)) с (кадр \(Int(SpeechGate.frameSeconds * 1000)) мс, RMS>\(SpeechGate.rmsThreshold)); минимум=\(SpeechGate.minVoicedSeconds) с; \(noSpeech ? "речи нет, распознавание пропущено" : "речь есть")")
            if noSpeech {
                // Как при пустом тексте: экран покажет «Речь не распознана», в фоне стадия noSpeech.
                resultText = ""
                lastResult = RunResult(seconds: 0, rtf: 0, audioSeconds: audioSeconds, modelTitle: model.title,
                                       backendTitle: model.requestedBackend.title, modeTitle: modeTitle)
                dictationIdleStage = .noSpeech
                status = ""
                phase = .idle
                return
            }
        }
        phase = .transcribing
        lastResult = nil
        status = "Распознавание…"
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

        if let recognized = outcome.text {
            var text = recognized
            if SpeechGate.isSilenceHallucination(text: text, audioSeconds: audioSeconds) {
                log.info("отброшено как галлюцинация на тишине: «\(text)»")
                text = ""
            }
            text = TermDictionary.apply(to: text)
            resultText = text
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(text, forKey: SpikeDefaults.lastResultText)
            }
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
            let textPart = logIncludesText ? "текст=«\(text)»" : "текст=скрыт символов=\(text.count)"
            log.end("\(label) \(numbers)\(detail) \(textPart)")
        } else {
            let message = outcome.error ?? "неизвестная ошибка"
            resultText = ""
            fail("Ошибка распознавания: \(message)")
            log.end("\(label) \(numbers)\(detail) ОШИБКА: \(message)")
        }
        phase = .idle
    }

    // MARK: - Общее

    /// Ошибка в статусе: экран красит её красным.
    func fail(_ text: String) {
        status = text
        statusIsError = true
        dictationIdleStage = .failed
        updateDictationActivity()
    }

    static func fmt(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }
}
