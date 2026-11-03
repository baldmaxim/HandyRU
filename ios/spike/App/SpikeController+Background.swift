import Foundation
import UIKit
import ActivityKit
import AVFoundation

/// Фоновая диктовка: микрофон держится включённым, Live Activity, автоотключение, прерывания, фоновый тест.
extension SpikeController {
    private var isBackgroundDictationWanted: Bool {
        UserDefaults.standard.bool(forKey: SpikeDefaults.backgroundDictationWanted)
    }

    private func setBackgroundDictationWanted(_ wanted: Bool) {
        UserDefaults.standard.set(wanted, forKey: SpikeDefaults.backgroundDictationWanted)
    }

    // MARK: - Включение и выключение

    /// Микрофон включается явно на переднем плане; между фразами сэмплы отбрасываются.
    /// Явное включение и выключение пользователем запоминается в `backgroundDictationWanted`.
    func setBackgroundDictationEnabled(_ enabled: Bool) async {
        if enabled {
            await enableBackgroundDictation(automatic: false)
            if backgroundDictationEnabled { setBackgroundDictationWanted(true) }
            return
        }
        setBackgroundDictationWanted(false)
        guard phase == .idle, !backgroundModeChanging else { return }
        backgroundModeChanging = true
        defer { backgroundModeChanging = false }
        await activityCleanupTask?.value
        guard phase == .idle else { return }
        stopIdleWatch()
        backgroundDictationEnabled = false
        recorder.stop()
        await endDictationActivity()
        status = ""
        log.info("фоновая диктовка выключена")
    }

    /// `automatic`: включение при открытии приложения по сохранённому желанию; `wanted` не меняется.
    private func enableBackgroundDictation(automatic: Bool) async {
        guard phase == .idle, !backgroundModeChanging, !backgroundDictationEnabled else { return }
        backgroundModeChanging = true
        defer { backgroundModeChanging = false }
        await activityCleanupTask?.value
        guard phase == .idle else { return }
        // Автоматический путь вызывается из активной сцены; состояние UIApplication может отставать на запуске.
        if !automatic {
            guard UIApplication.shared.applicationState == .active else {
                fail("Включите фоновую диктовку при открытом Handy.")
                return
            }
        }
        guard selectedBackend != .metal else {
            fail("Для фоновой диктовки выберите Neural Engine в настройках.")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            fail("Включите Live Activity для Handy в настройках iPhone.")
            return
        }
        if !selectedModelIsLoaded { await loadModel() }
        guard selectedModelIsLoaded, phase == .idle, await beginCapture() else { return }
        recorder.enterKeepAlive()
        do {
            dictationIdleStage = .ready
            dictationActivity = try Activity.request(
                attributes: DictationActivityAttributes(),
                content: ActivityContent(state: .init(stage: .ready), staleDate: nil),
                pushType: nil
            )
            backgroundDictationEnabled = true
            lastCommandAt = Date()
            startIdleWatch()
            status = ""
            log.info("фоновая диктовка включена: микрофон активен, ожидание команды\(automatic ? " (автоматически, по сохранённому желанию)" : "")")
        } catch {
            recorder.stop()
            fail("Не удалось включить индикатор диктовки: \(error.localizedDescription)")
        }
    }

    /// Возвращает только новый результат: «Команды» сами копируют его без открытия Handy.
    func toggleBackgroundDictation() async throws -> String {
        guard backgroundDictationEnabled, recorder.isRunning, dictationActivity != nil else {
            throw DictationCommandError.notReady
        }
        guard !isHandlingShortcut, !backgroundModeChanging, phase == .idle || phase == .recording else {
            throw DictationCommandError.busy
        }
        isHandlingShortcut = true
        defer { isHandlingShortcut = false }
        lastCommandAt = Date()
        log.info("фоновая команда диктовки: состояние=\(Metrics.appStateName())")
        if phase == .recording {
            await stopAndTranscribe()
            lastCommandAt = Date()
            if statusIsError { throw DictationCommandError.failed(status) }
            let text = lastResult == nil ? "" : resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // Статус не нужен: текст уже виден на экране, подсказка — в Live Activity.
                status = ""
                dictationIdleStage = .finished
                updateDictationActivity()
                log.info("результат фоновой диктовки передан в «Команды»")
            }
            if text.isEmpty {
                dictationIdleStage = .noSpeech
                updateDictationActivity()
            }
            return text
        }
        lastResult = nil
        resultText = ""
        shortcutDictationActive = false
        guard await startRecording() else {
            // Запись не началась: «Команды» должны получить ошибку, а не пустой результат.
            throw DictationCommandError.failed(statusIsError && !status.isEmpty ? status : "Запись не началась. Повторите команду.")
        }
        return ""
    }

    // MARK: - Автоотключение по простою

    func startIdleWatch() {
        idleWatchTask?.cancel()
        idleWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.backgroundDictationEnabled else { return }
                if self.isBackgroundIdleExpired {
                    await self.disableBackgroundForIdle()
                    return
                }
            }
        }
    }

    func stopIdleWatch() {
        idleWatchTask?.cancel()
        idleWatchTask = nil
    }

    /// Во время записи и распознавания таймер не срабатывает.
    private var isBackgroundIdleExpired: Bool {
        phase == .idle && !isHandlingShortcut && !backgroundModeChanging
            && Date().timeIntervalSince(lastCommandAt) >= Self.BACKGROUND_IDLE_LIMIT
    }

    /// Освобождает микрофон и Live Activity; `backgroundDictationWanted` не сбрасывается.
    private func disableBackgroundForIdle() async {
        backgroundModeChanging = true
        defer { backgroundModeChanging = false }
        // Эта задача сама вызывает метод: отменять её нельзя, она завершится возвратом из цикла.
        idleWatchTask = nil
        backgroundDictationEnabled = false
        recorder.stop()
        await endDictationActivity()
        log.info("фоновая диктовка выключена по простою: \(Int(Self.BACKGROUND_IDLE_LIMIT / 60)) мин без команд")
    }

    // MARK: - Live Activity

    var currentActivityStage: DictationActivityAttributes.Stage {
        phase == .recording ? .recording : (phase == .transcribing ? .transcribing : dictationIdleStage)
    }

    func updateDictationActivity() {
        guard let activity = dictationActivity else { return }
        let stage = currentActivityStage
        let previous = activityUpdateTask
        activityUpdateTask = Task {
            await previous?.value
            await activity.update(ActivityContent(state: .init(stage: stage), staleDate: nil))
        }
    }

    func endDictationActivity() async {
        guard let activity = dictationActivity else { return }
        dictationActivity = nil
        await activityUpdateTask?.value
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    /// Система завершает активности (в том числе по пределу 8 часов): при возврате в приложение запрашиваем новую.
    func restoreDictationActivityIfNeeded() {
        guard backgroundDictationEnabled, !backgroundModeChanging else { return }
        if let current = dictationActivity, current.activityState == .active { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let previous = dictationActivity
        do {
            dictationActivity = try Activity.request(
                attributes: DictationActivityAttributes(),
                content: ActivityContent(state: .init(stage: currentActivityStage), staleDate: nil),
                pushType: nil
            )
            log.info("Live Activity: прежняя не активна, запрошена новая")
            if let previous {
                Task { await previous.end(nil, dismissalPolicy: .immediate) }
            }
        } catch {
            log.info("Live Activity: не удалось запросить новую: \(error.localizedDescription)")
        }
    }

    // MARK: - Прерывания

    /// Прерывание микрофона или остановка движка. Фоновый режим выключается (желание `wanted` остаётся);
    /// на переднем плане запись останавливается и распознаётся, если набралось достаточно звука.
    func handleMicrophoneInterruption() {
        if backgroundDictationEnabled {
            backgroundDictationEnabled = false
            shortcutDictationActive = false
            stopIdleWatch()
            stopMeter()
            recorder.stop()
            if phase == .recording { phase = .idle }
            fail("Микрофон прерван. Откройте Handy, режим включится снова.")
            log.info("фоновая диктовка выключена после прерывания микрофона")
            Task { await endDictationActivity() }
            return
        }
        guard phase == .recording else { return }
        if recorder.capturedSeconds >= Double(Self.minSamples) / Recorder.sampleRate {
            log.info("запись на переднем плане прервана: распознаём записанное (\(Self.fmt(recorder.capturedSeconds)) с)")
            Task { await stopAndTranscribe() }
        } else {
            stopMeter()
            shortcutDictationActive = false
            _ = recorder.takeSamples()
            recorder.stop()
            phase = .idle
            fail("Запись прервана. Повторите фразу.")
            log.info("запись на переднем плане прервана: записано меньше 0,5 с, сброс")
        }
    }

    /// Система перезапустила медиасервисы: старые аудиообъекты непригодны.
    func handleMediaServicesReset() {
        log.info("медиасервисы iOS перезапущены системой")
        let wasBackground = backgroundDictationEnabled
        let wasRecording = phase == .recording || phase == .starting
        stopMeter()
        shortcutDictationActive = false
        recorder.resetAfterMediaServicesReset()
        if wasBackground {
            backgroundDictationEnabled = false
            stopIdleWatch()
            Task { await endDictationActivity() }
            log.info("фоновая диктовка выключена после сброса медиасервисов")
        }
        if phase == .recording { phase = .idle }
        if wasBackground || wasRecording {
            fail("Микрофон перезапущен системой. Повторите запись.")
        }
    }

    // MARK: - Сцена стала активной

    /// Вызывается при каждом переходе сцены в active (и на запуске): Live Activity, автозагрузка модели,
    /// автоматическое включение фонового режима.
    func sceneBecameActive() async {
        if microphoneAccessDenied, AVAudioApplication.shared.recordPermission == .granted {
            microphoneAccessDenied = false
        }
        restoreDictationActivityIfNeeded()
        await autoLoadModelIfNeeded()
        await enableBackgroundDictationIfWanted()
    }

    private func enableBackgroundDictationIfWanted() async {
        guard isBackgroundDictationWanted, !backgroundDictationEnabled, selectedModelIsLoaded,
              selectedBackend != .metal, phase == .idle, !backgroundModeChanging,
              store.downloadingID == nil else { return }
        log.info("фоновая диктовка: автоматическое включение при открытии приложения")
        await enableBackgroundDictation(automatic: true)
    }

    // MARK: - Фоновый тест

    /// Запись `backgroundSeconds` секунд; пользователь уходит на домашний экран и говорит.
    /// По таймеру аудио забирается, запись переходит в keepAlive, запускается распознавание.
    func startBackgroundTest() async {
        guard phase == .idle, !backgroundModeChanging, !backgroundDictationEnabled else { return }
        guard loaded != nil else {
            status = "Сначала загрузите модель"
            return
        }
        // Фаза занимается до первого await: второй вызов уже не пройдёт проверку.
        phase = .starting
        guard await beginCapture() else {
            phase = .idle
            return
        }
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
            await runTranscription(samples: samples, mode: "фоновый тест", modeTitle: "Фоновый тест", checkSpeech: true)
        } else {
            phase = .idle
        }
        recorder.stop()
        log.info("фоновый тест: запись остановлена")
    }
}
