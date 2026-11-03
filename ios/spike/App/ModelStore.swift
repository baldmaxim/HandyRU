import CryptoKit
import Foundation
import WhisperKit

/// Модель из каталога десктопа (src-tauri/src/managers/model.rs): URL, имя файла и sha256 оттуда же.
struct ModelInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let filename: String
    let url: URL
    let sha256: String
    let sizeMB: Int
}

enum ModelCatalog {
    static let all: [ModelInfo] = [
        ModelInfo(
            id: "turbo",
            title: "Turbo",
            filename: "ggml-large-v3-turbo.bin",
            url: URL(string: "https://blob.handy.computer/ggml-large-v3-turbo.bin")!,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            sizeMB: 1549
        ),
        ModelInfo(
            id: "small",
            title: "Small",
            filename: "ggml-small.bin",
            url: URL(string: "https://blob.handy.computer/ggml-small.bin")!,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            sizeMB: 465
        ),
        ModelInfo(
            id: "medium-q4_1",
            title: "Medium q4_1",
            filename: "whisper-medium-q4_1.bin",
            url: URL(string: "https://blob.handy.computer/whisper-medium-q4_1.bin")!,
            sha256: "79283fc1f9fe12ca3248543fbd54b73292164d8df5a16e095e2bceeaaabddf57",
            sizeMB: 469
        ),
    ]
}

/// Скачивание, проверка и хранение моделей в Application Support (вне резервной копии).
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var downloadedIDs: Set<String> = []
    @Published private(set) var downloadingID: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var message = ""
    @Published private(set) var messageIsError = false

    func clearMessage() {
        message = ""
        messageIsError = false
    }

    /// Идентификатор модели Core ML: в `downloadingID` и в журнале.
    static let coreMLID = "turbo-coreml-632"
    static let coreMLTitle = "Turbo Core ML"
    static let coreMLSizeMB = 632
    /// Путь к папке модели Core ML относительно Application Support (абсолютный путь контейнера может меняться).
    private static let coreMLPathKey = "coreml.modelRelativePath"
    /// Обязательный файл в папке модели: по нему определяется, что модель скачана.
    private static let coreMLMarkerFile = "AudioEncoder.mlmodelc"

    @Published private(set) var coreMLDownloaded = false

    private var downloader: Downloader?
    private var coreMLTask: Task<URL, Error>?

    init() {
        refresh()
    }

    func isDownloaded(_ model: ModelInfo) -> Bool {
        downloadedIDs.contains(model.id)
    }

    func fileURL(for model: ModelInfo) -> URL? {
        guard let dir = try? Self.modelsDirectory() else { return nil }
        return dir.appendingPathComponent(model.filename)
    }

    /// Файл появляется под своим именем только после успешной проверки sha256.
    func refresh() {
        var found: Set<String> = []
        for model in ModelCatalog.all {
            if let url = fileURL(for: model), FileManager.default.fileExists(atPath: url.path) {
                found.insert(model.id)
            }
        }
        downloadedIDs = found
        coreMLDownloaded = coreMLFolderURL != nil
    }

    func download(_ model: ModelInfo) async {
        guard downloadingID == nil else { return }
        clearMessage()
        downloadingID = model.id
        progress = 0
        message = "Скачивание \(model.title) (\(model.sizeMB) МБ). Не сворачивайте приложение."
        defer {
            downloadingID = nil
            downloader = nil
        }

        var partURL: URL?
        do {
            let dir = try Self.modelsDirectory()
            let part = dir.appendingPathComponent(model.filename + ".part")
            var finalURL = dir.appendingPathComponent(model.filename)
            partURL = part
            try? FileManager.default.removeItem(at: part)

            let newDownloader = Downloader(destination: part) { [weak self] fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            downloader = newDownloader
            try await newDownloader.run(url: model.url)

            progress = 1
            message = "Проверка sha256…"
            let actual = try await Task.detached(priority: .utility) {
                try Self.sha256Hex(of: part)
            }.value
            guard actual == model.sha256 else {
                try? FileManager.default.removeItem(at: part)
                messageIsError = true
                message = "sha256 не совпал: ожидалось \(model.sha256.prefix(12))…, получено \(actual.prefix(12))…. Файл удалён."
                return
            }

            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: part, to: finalURL)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? finalURL.setResourceValues(values)

            message = "\(model.title): скачана, sha256 совпал"
            refresh()
        } catch {
            if let partURL { try? FileManager.default.removeItem(at: partURL) }
            messageIsError = (error as NSError).code != NSURLErrorCancelled
            message = "Ошибка скачивания: \(error.localizedDescription)"
        }
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    func delete(_ model: ModelInfo) {
        clearMessage()
        guard let url = fileURL(for: model) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            message = "\(model.title): удалена"
        } catch {
            messageIsError = true
            message = "Не удалось удалить: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Core ML

    /// Папка модели Core ML, если она скачана целиком (путь сохраняется только после успешного скачивания).
    var coreMLFolderURL: URL? {
        guard let relative = UserDefaults.standard.string(forKey: Self.coreMLPathKey),
            let support = try? Self.applicationSupportDirectory()
        else { return nil }
        let folder = support.appendingPathComponent(relative, isDirectory: true)
        let marker = folder.appendingPathComponent(Self.coreMLMarkerFile)
        return FileManager.default.fileExists(atPath: marker.path) ? folder : nil
    }

    func downloadCoreML() async {
        guard downloadingID == nil else { return }
        clearMessage()
        downloadingID = Self.coreMLID
        progress = 0
        message = "Скачивание \(Self.coreMLTitle) (\(Self.coreMLSizeMB) МБ). Не сворачивайте приложение."
        defer {
            downloadingID = nil
            coreMLTask = nil
        }

        let task = Task { [weak self] () -> URL in
            let base = try Self.coreMLBaseDirectory()
            return try await WhisperKit.download(
                variant: CoreMLEngine.modelVariant,
                downloadBase: base,
                progressCallback: { info in
                    let value = info.fractionCompleted
                    Task { @MainActor in self?.progress = value }
                }
            )
        }
        coreMLTask = task
        do {
            let folder = try await task.value
            let support = try Self.applicationSupportDirectory()
            let prefix = support.standardizedFileURL.path + "/"
            let full = folder.standardizedFileURL.path
            guard full.hasPrefix(prefix) else {
                throw EngineError.message("папка модели вне Application Support: \(full)")
            }
            UserDefaults.standard.set(String(full.dropFirst(prefix.count)), forKey: Self.coreMLPathKey)
            guard coreMLFolderURL != nil else {
                UserDefaults.standard.removeObject(forKey: Self.coreMLPathKey)
                throw EngineError.message("после скачивания нет \(Self.coreMLMarkerFile)")
            }
            progress = 1
            message = "\(Self.coreMLTitle): скачана"
        } catch {
            messageIsError = !task.isCancelled
            message = task.isCancelled ? "Скачивание отменено" : "Ошибка скачивания: \(error.localizedDescription)"
        }
        refresh()
    }

    func cancelCoreMLDownload() {
        coreMLTask?.cancel()
    }

    func deleteCoreML() {
        clearMessage()
        UserDefaults.standard.removeObject(forKey: Self.coreMLPathKey)
        do {
            let base = try Self.coreMLBaseDirectory()
            try FileManager.default.removeItem(at: base)
            message = "\(Self.coreMLTitle): удалена"
        } catch {
            messageIsError = true
            message = "Не удалось удалить: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Файлы

    nonisolated static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Application Support/coreml, исключён из резервной копии: сюда WhisperKit кладёт модель (`downloadBase`).
    nonisolated static func coreMLBaseDirectory() throws -> URL {
        var dir = try applicationSupportDirectory().appendingPathComponent("coreml", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// Application Support/Models, исключён из резервной копии.
    nonisolated static func modelsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var dir = base.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// sha256 потоково, кусками по 4 МБ: файл целиком в память не читается.
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 4 * 1024 * 1024) }),
                !chunk.isEmpty
            else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Загрузка одного файла через URLSession с прогрессом.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReported = -1.0
    private var session: URLSession?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(url: URL) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let newSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock { session = newSession }
        defer { newSession.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            newSession.downloadTask(with: url).resume()
        }
    }

    func cancel() {
        lock.lock()
        let current = session
        lock.unlock()
        current?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Не чаще, чем на каждые 0,5 %, чтобы не заваливать главный поток.
        if fraction - lastReported >= 0.005 {
            lastReported = fraction
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Файл во временной папке удаляется сразу после возврата из этого метода, переносим здесь.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            setFailure(EngineError.message("сервер ответил HTTP \(status)"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            setFailure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let savedFailure = failure
        lock.unlock()
        guard let cont else { return }
        if let error {
            cont.resume(throwing: error)
        } else if let savedFailure {
            cont.resume(throwing: savedFailure)
        } else {
            cont.resume()
        }
    }

    private func setFailure(_ error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }
}
