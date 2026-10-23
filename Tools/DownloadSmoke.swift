import Foundation
import CryptoKit

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelDownloadProgress] = []
    func append(_ value: ModelDownloadProgress) { lock.withLock { values.append(value) } }
    var snapshots: [ModelDownloadProgress] { lock.withLock { values } }
}

@main struct DownloadSmoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var data = Data()
        let pattern = (0...255).map { UInt8($0) }
        for _ in 0..<8192 { data.append(contentsOf: pattern) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func file(_ path: String, route: String, digest: String? = nil) -> NeuralManifest.File {
            NeuralManifest.File(path: path, url: URL(string: "http://127.0.0.1:18765/" + route)!,
                                bundledPath: nil, bytes: Int64(data.count), sha256: digest ?? hash)
        }
        func downloader(_ name: String) -> ModelDownloads {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            return ModelDownloads(parent: root.appendingPathComponent(name), configuration: config)
        }
        let directory = root.appendingPathComponent("resume")
        let plan = NeuralManifest(id: "fixture", totalBytes: Int64(data.count * 2),
                                  files: [file("fast.bin", route: "fast"), file("slow.bin", route: "slow")])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("fixture.partial"), withIntermediateDirectories: true)
        let downloads = downloader("resume")
        let first = ProgressCapture()
        let task = Task { try await downloads.download(plan) { first.append($0) } }
        let deadline = Date().addingTimeInterval(15)
        while !(ModelFileStorage.valid(directory.appendingPathComponent("fixture.partial/fast.bin"), file: plan.files[0]) &&
                first.snapshots.contains(where: { $0.received > Int64(data.count) && $0.received < plan.totalBytes })) {
            guard Date() < deadline else { fatalError("Fixture did not reach the cancellation precondition") }
            try await Task.sleep(for: .milliseconds(25))
        }
        task.cancel()
        do { try await task.value; fatalError("Cancellation was ignored") }
        catch is CancellationError { }
        guard ModelFileStorage.valid(directory.appendingPathComponent("fixture.partial/fast.bin"), file: plan.files[0]) else {
            fatalError("Completed transfer was lost on cancellation")
        }
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18765/release")!)
        let resumed = ProgressCapture()
        try await downloads.download(plan) { resumed.append($0) }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture/complete").path),
              resumed.snapshots.contains(where: { $0.received >= Int64(data.count) && $0.received < plan.totalBytes }),
              resumed.snapshots.contains(where: { $0.received > Int64(data.count) && $0.received < plan.totalBytes }) else {
            fatalError("Resume or incremental progress failed")
        }
        for (name, entry) in [("http-error", file("bad.bin", route: "missing")),
                              ("hash-error", file("bad.bin", route: "fast", digest: String(repeating: "0", count: 64)))] {
            let plan = NeuralManifest(id: "fixture", totalBytes: Int64(data.count), files: [entry])
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name + "/fixture.partial"), withIntermediateDirectories: true)
            do {
                try await downloader(name).download(plan) { _ in }
                fatalError("Invalid HTTP/hash result was accepted")
            } catch is NeuralError { }
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(name + "/fixture/complete").path) else {
                fatalError("Incomplete model was installed")
            }
        }
        let source = try JSONDecoder().decode(NeuralManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let entry = source.files.first { $0.path == "TextEncoder.mlmodelc/model.mil" }!
        let live = NeuralManifest(id: "live-pinned-source", totalBytes: entry.bytes, files: [entry])
        let liveRoot = root.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: liveRoot.appendingPathComponent(live.id + ".partial"), withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        try await ModelDownloads(parent: liveRoot, configuration: config).download(live) { _ in }
        guard ModelFileStorage.valid(liveRoot.appendingPathComponent(live.id + "/" + entry.path), file: entry) else {
            fatalError("Pinned production source failed validation")
        }
        print("DOWNLOAD CHECK PASSED: incremental bytes, cancellation, retained complete files, restart, HTTP error, SHA-256 rejection")
        print("LIVE SOURCE CHECK PASSED: pinned Hugging Face file downloaded by native URLSession and verified by SHA-256")
    }
}
