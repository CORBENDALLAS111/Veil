import CryptoKit
import Foundation

struct NeuralManifest: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let path: String
        let url: URL?
        let bundledPath: String?
        let bytes: Int64
        let sha256: String
    }
    let id: String
    let totalBytes: Int64
    let files: [File]

    static func bundled() throws -> Self {
        let bundle = resourceBundle
        guard let url = bundle.url(forResource: "NeuralManifest", withExtension: "json") else {
            throw NeuralError.modelUnavailable
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !manifest.files.isEmpty, manifest.files.allSatisfy({ file in
            !file.path.hasPrefix("/") && !file.path.split(separator: "/").contains("..") &&
            ((file.url?.scheme == "https" && file.url?.host == "huggingface.co") ||
             (file.bundledPath?.hasPrefix("BundledVAE/") == true && !file.bundledPath!.split(separator: "/").contains(".."))) && file.sha256.count == 64
        }) else { throw NeuralError.modelUnavailable }
        return manifest
    }
    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
    static var downloadLabel: String {
        let size = Double((try? bundled().totalBytes) ?? 974_547_868) / 1_000_000_000
        return String(format: "%.2f ГБ", locale: Locale(identifier: "ru_RU"), size)
    }
}

enum NeuralError: LocalizedError {
    case modelUnavailable, corruptDownload, downloadFailed, busy, insufficientMemory, invalidOutput
    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "Не найдена модель нейросети. Загрузите её заново."
        case .corruptDownload: "Проверка загрузки не прошла. Попробуйте ещё раз."
        case .downloadFailed: "Не удалось загрузить модель. Проверьте соединение и свободное место."
        case .busy: "Загрузка ещё завершается. Попробуйте через несколько секунд."
        case .insufficientMemory: "Для этой нейросети нужно устройство с 8 ГБ оперативной памяти или больше. Очистка метаданных доступна без неё."
        case .invalidOutput: "Нейросеть не вернула корректное изображение. Попробуйте более мягкую обработку."
        }
    }
}

/// Immutable callback; URLSession owns delegate invocation and the receiver handles isolation.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Int64) -> Void
    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) { report(totalBytesWritten) }
}

actor NeuralModelStore {
    private let parent: URL
    private var installing = false

    init(parent: URL? = nil) {
        self.parent = parent ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veil-Models", isDirectory: true)
    }

    func installedURL() throws -> URL? {
        let manifest = try NeuralManifest.bundled()
        let url = parent.appendingPathComponent(manifest.id, isDirectory: true)
        guard (try? String(contentsOf: url.appendingPathComponent("complete"), encoding: .utf8)) == manifest.id,
              manifest.files.allSatisfy({ file in
                  let values = try? url.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey])
                  return values?.fileSize == Int(file.bytes)
              }) else { return nil }
        return url
    }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let url = try installedURL() { return url }
        guard !installing else { throw NeuralError.busy }
        installing = true
        defer { installing = false }
        let manifest = try NeuralManifest.bundled()
        let fm = FileManager.default
        let staging = parent.appendingPathComponent(manifest.id + ".partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = parent
        try excluded.setResourceValues(values)
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            let downloadBytes = file.url == nil ? 0 : file.bytes
            if fm.fileExists(atPath: destination.path), try hash(destination) == file.sha256 {
                completed += downloadBytes
                progress(Double(completed) / Double(manifest.totalBytes))
                continue
            }
            let base = completed
            if let path = file.bundledPath {
                guard let resources = NeuralManifest.resourceBundle.resourceURL else { throw NeuralError.modelUnavailable }
                let original = resources.appendingPathComponent(path)
                guard try hash(original) == file.sha256 else { throw NeuralError.corruptDownload }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: original, to: destination)
                continue
            }
            guard let url = file.url else { throw NeuralError.modelUnavailable }
            let delegate = DownloadProgress { bytes in
                progress(min(1, Double(base + min(bytes, file.bytes)) / Double(manifest.totalBytes)))
            }
            let (temporary, response) = try await session.download(from: url, delegate: delegate)
            defer { try? fm.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NeuralError.downloadFailed }
            let count = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard count == Int(file.bytes), try hash(temporary) == file.sha256 else { throw NeuralError.corruptDownload }
            try Task.checkCancellation()
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
            completed += downloadBytes
            progress(Double(completed) / Double(manifest.totalBytes))
        }
        try Task.checkCancellation()
        try manifest.id.write(to: staging.appendingPathComponent("complete"), atomically: true, encoding: .utf8)
        let ready = parent.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: ready.path) { try fm.removeItem(at: ready) }
        try fm.moveItem(at: staging, to: ready)
        return ready
    }

    private func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
