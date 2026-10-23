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

actor NeuralModelStore {
    private let parent: URL
    private var installing = false
    private let downloads: ModelDownloads

    init(parent: URL? = nil) {
        self.parent = parent ?? ModelDownloads.parent
        self.downloads = parent.map { ModelDownloads(parent: $0) } ?? .shared
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

    func hasActiveDownloads() async -> Bool { await downloads.hasActiveTasks() }

    func install(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> URL {
        if let url = try installedURL() { return url }
        guard !installing else { throw NeuralError.busy }
        installing = true
        defer { installing = false }
        let manifest = try NeuralManifest.bundled()
        let fm = FileManager.default
        let staging = parent.appendingPathComponent(manifest.id + ".partial", isDirectory: true)
        progress(ModelDownloadProgress(received: 0, total: manifest.totalBytes, phase: .preparing))
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = parent
        try excluded.setResourceValues(values)
        for file in manifest.files where file.bundledPath != nil {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            if ModelFileStorage.valid(destination, file: file) { continue }
            guard let resources = NeuralManifest.resourceBundle.resourceURL,
                  let path = file.bundledPath else { throw NeuralError.modelUnavailable }
            let original = resources.appendingPathComponent(path)
            guard ModelFileStorage.valid(original, file: file) else { throw NeuralError.corruptDownload }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: original, to: destination)
        }
        try await downloads.download(manifest, progress: progress)
        try Task.checkCancellation()
        guard let ready = try installedURL() else { throw NeuralError.modelUnavailable }
        return ready
    }
}
