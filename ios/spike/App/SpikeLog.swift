import Foundation

/// Журнал замеров в файле Documents/spike-log.txt.
///
/// Каждая строка пишется и сбрасывается на диск сразу (fsync): Metal в фоне может
/// аварийно завершить процесс, и последняя запись «старт» без «конец» покажет, где это случилось.
/// Формат строки: `время | метка | сообщение`, метки: «старт», «конец», «инфо».
final class SpikeLog: ObservableObject, @unchecked Sendable {
    @Published private(set) var text = ""

    let fileURL: URL

    private let lock = NSLock()
    private var handle: FileHandle?
    private let formatter: DateFormatter

    private static let tagStart = "старт"
    private static let tagEnd = "конец"
    private static let tagInfo = "инфо"
    private static let interruptedMarker = "предыдущий запуск оборвался"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("spike-log.txt")

        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()

        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        text = existing
        if SpikeLog.endsWithOpenStart(existing) {
            info("\(SpikeLog.interruptedMarker): последняя запись — «старт» без «конец» (вероятно, процесс убила система)")
        }
    }

    /// Начало опасной операции (загрузка модели, распознавание). Пишется ДО её запуска.
    func start(_ message: String) {
        write(tag: SpikeLog.tagStart, message)
    }

    /// Нормальное или ошибочное завершение операции, начатой через `start`.
    func end(_ message: String) {
        write(tag: SpikeLog.tagEnd, message)
    }

    func info(_ message: String) {
        write(tag: SpikeLog.tagInfo, message)
    }

    /// Очищает файл и экран.
    func clear() {
        lock.lock()
        _ = try? handle?.truncate(atOffset: 0)
        _ = try? handle?.seek(toOffset: 0)
        _ = try? handle?.synchronize()
        lock.unlock()
        DispatchQueue.main.async { self.text = "" }
    }

    private func write(tag: String, _ message: String) {
        // Одна запись — одна строка файла.
        let flat = message.replacingOccurrences(of: "\n", with: " ⏎ ")
        lock.lock()
        let line = "\(formatter.string(from: Date())) | \(tag) | \(flat)\n"
        if let data = line.data(using: .utf8), let handle {
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                // Журнал не должен ронять приложение; на экране строка всё равно появится.
            }
        }
        lock.unlock()
        DispatchQueue.main.async { self.text += line }
    }

    /// Последняя «старт»-запись без закрывающей «конец» (и без пометки об обрыве).
    private static func endsWithOpenStart(_ content: String) -> Bool {
        var open = false
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let tag = parts[1].trimmingCharacters(in: .whitespaces)
            if tag == tagStart {
                open = true
            } else if tag == tagEnd {
                open = false
            } else if line.contains(interruptedMarker) {
                open = false
            }
        }
        return open
    }
}
