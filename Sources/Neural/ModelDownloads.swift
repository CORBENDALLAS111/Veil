import CryptoKit
import Foundation

struct ModelDownloadProgress: Sendable {
    enum Phase: Sendable { case preparing, connecting, waiting, transferring, verifying }
    var received: Int64
    let total: Int64
    var phase: Phase
    var fraction: Double { min(1, max(0, Double(received) / Double(max(1, total)))) }
    var label: String {
        switch phase {
        case .preparing: return "Подготовка файлов…"
        case .connecting: return "Соединение с сервером…"
        case .waiting: return "Ожидаем подключение к сети…"
        case .verifying: return "Проверка модели…"
        case .transferring:
            let mb = String(format: "%.1f", locale: Locale(identifier: "ru_RU"), Double(received) / 1_000_000)
            return "Загрузка · \(mb) / \(Int(ceil(Double(total) / 1_000_000))) МБ"
        }
    }
}

enum ModelFileStorage {
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func valid(_ url: URL, file: NeuralManifest.File) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == Int(file.bytes) else { return false }
        return (try? hash(url)) == file.sha256
    }
}

/// Mutable state and delegate callbacks are confined to the same serial queue.
/// A stable background session owns transfers independently of the Swift task/UI.
final class ModelDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "io.github.corbendallas111.veil.models.v1"
    static let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Veil-Models", isDirectory: true)
    static let shared = ModelDownloads(parent: parent)

    private let parent: URL
    private let queue = DispatchQueue(label: "Veil.ModelDownloads")
    private var session: URLSession!
    private var manifest: NeuralManifest?
    private var continuation: CheckedContinuation<Void, Error>?
    private var observer: (@Sendable (ModelDownloadProgress) -> Void)?
    private var counts: [String: Int64] = [:]
    private var currentTasks: [URLSessionTask] = []
    private var lastReport = Date.distantPast

    init(parent: URL, configuration: URLSessionConfiguration? = nil) {
        self.parent = parent
        super.init()
        manifest = try? NeuralManifest.bundled()
        let configuration = configuration ?? Self.configuration()
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        delegates.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
        queue.async { self.completeIfReady() }
    }

    static func configuration() -> URLSessionConfiguration {
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        #else
        let config = URLSessionConfiguration.default
        #endif
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3_600
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    func hasActiveTasks() async -> Bool {
        await withCheckedContinuation { reply in
            session.getAllTasks { tasks in reply.resume(returning: tasks.contains { $0.state == .running || $0.state == .suspended }) }
        }
    }

    func download(_ manifest: NeuralManifest, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        try Task.checkCancellation()
        let cancellation = DownloadCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard !cancellation.isCancelled else { reply.resume(throwing: CancellationError()); return }
                    guard self.continuation == nil else { reply.resume(throwing: NeuralError.busy); return }
                    self.manifest = manifest
                    self.observer = progress
                    self.continuation = reply
                    self.counts = [:]
                    self.session.getAllTasks { tasks in
                        self.queue.async { self.enqueue(manifest, tasks: tasks, cancellation: cancellation) }
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async {
                self.currentTasks.forEach { $0.cancel() }
                self.finish(CancellationError())
            }
        }
    }

    private func enqueue(_ manifest: NeuralManifest, tasks: [URLSessionTask], cancellation: DownloadCancellation) {
        guard !cancellation.isCancelled, continuation != nil else { return }
        currentTasks = []
        for file in manifest.files where file.url != nil {
            let description = manifest.id + "|" + file.path
            let destination = staging(manifest).appendingPathComponent(file.path)
            if ModelFileStorage.valid(destination, file: file) {
                counts[file.path] = file.bytes
                tasks.filter { $0.taskDescription == description }.forEach { $0.cancel() }
                continue
            }
            let matching = tasks.filter { $0.taskDescription == description && $0.state != .canceling && $0.state != .completed }
            let task: URLSessionTask
            if let existing = matching.first {
                task = existing
                counts[file.path] = max(0, existing.countOfBytesReceived)
                matching.dropFirst().forEach { $0.cancel() }
            } else {
                var components = URLComponents(url: file.url!, resolvingAgainstBaseURL: false)!
                // Avoid persisting an expired cached signed-CDN redirect.
                components.queryItems = [URLQueryItem(name: "download", value: "true"),
                                         URLQueryItem(name: "veil", value: String(Int(Date().timeIntervalSince1970)))]
                var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let created = session.downloadTask(with: request)
                created.taskDescription = description
                task = created
            }
            currentTasks.append(task)
        }
        report(counts.values.contains(where: { $0 > 0 }) ? .transferring : .connecting)
        // Queue every file before suspension, rather than depending on foreground
        // continuations to start the next file after a transfer completes.
        currentTasks.forEach { $0.resume() }
        if currentTasks.isEmpty { completeIfReady() }
    }

    private func staging(_ manifest: NeuralManifest) -> URL {
        parent.appendingPathComponent(manifest.id + ".partial", isDirectory: true)
    }

    private func identify(_ task: URLSessionTask) -> (NeuralManifest, NeuralManifest.File)? {
        guard let current = manifest ?? (try? NeuralManifest.bundled()),
              let file = current.files.first(where: { task.taskDescription == current.id + "|" + $0.path && $0.url != nil }) else { return nil }
        manifest = current
        return (current, file)
    }

    private func report(_ phase: ModelDownloadProgress.Phase) {
        guard let manifest else { return }
        observer?(ModelDownloadProgress(received: counts.values.reduce(0, +), total: manifest.totalBytes, phase: phase))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (_, file) = identify(downloadTask) else { return }
        counts[file.path] = min(file.bytes, max(0, totalBytesWritten))
        if Date().timeIntervalSince(lastReport) >= 0.15 || totalBytesWritten >= file.bytes {
            lastReport = Date()
            report(.transferring)
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) { report(.waiting) }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (manifest, file) = identify(downloadTask) else { return }
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw NeuralError.downloadFailed }
            guard ModelFileStorage.valid(location, file: file) else { throw NeuralError.corruptDownload }
            let destination = staging(manifest).appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            counts[file.path] = file.bytes
            report(.transferring)
            completeIfReady()
        } catch {
            currentTasks.filter { $0.taskIdentifier != downloadTask.taskIdentifier }.forEach { $0.cancel() }
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard identify(task) != nil, let error,
              currentTasks.contains(where: { $0.taskIdentifier == task.taskIdentifier }) else { return }
        currentTasks.filter { $0.taskIdentifier != task.taskIdentifier }.forEach { $0.cancel() }
        finish(error)
    }

    private func completeIfReady() {
        guard let manifest else { return }
        do {
            if counts.values.reduce(0, +) >= manifest.totalBytes { report(.verifying) }
            if try Self.promote(manifest, parent: parent) { finish(nil) }
        } catch { finish(error) }
    }

    /// Revalidates all files before marking a recovered/background install ready.
    static func promote(_ manifest: NeuralManifest, parent: URL) throws -> Bool {
        let ready = parent.appendingPathComponent(manifest.id, isDirectory: true)
        if (try? String(contentsOf: ready.appendingPathComponent("complete"), encoding: .utf8)) == manifest.id { return true }
        let partial = parent.appendingPathComponent(manifest.id + ".partial", isDirectory: true)
        guard manifest.files.allSatisfy({ file in
            (try? partial.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes)
        }) else { return false }
        guard manifest.files.allSatisfy({ ModelFileStorage.valid(partial.appendingPathComponent($0.path), file: $0) }) else { throw NeuralError.corruptDownload }
        try manifest.id.write(to: partial.appendingPathComponent("complete"), atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: ready.path) { try FileManager.default.removeItem(at: ready) }
        try FileManager.default.moveItem(at: partial, to: ready)
        return true
    }

    private func finish(_ error: Error?) {
        let reply = continuation
        continuation = nil
        observer = nil
        if let error { reply?.resume(throwing: error) } else { reply?.resume() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completeIfReady()
        #if os(iOS)
        Task { @MainActor in BackgroundDownloadEvents.finish() }
        #endif
    }
}

private final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
