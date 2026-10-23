import Foundation
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit

@Observable @MainActor
final class StudioModel {
    var source: ImportedPhoto?
    var result: ProcessedPhoto?
    var originalPreview: UIImage?
    var resultPreview: UIImage?
    var strength: ProcessingStrength = .balanced
    var mode: ProcessingMode = .pattern
    var progress: Double = 0
    var workLabel = "Обработка…"
    var format: ExportFormat = .png
    var clarity = false
    var resolution: OutputResolution = .original
    var isWorking = false
    var isSaving = false
    var isImporting = false
    var errorMessage: String?
    var saveMessage: String?
    var comparison: Double = 0.5
    var shareURL: URL?

    @ObservationIgnored private let processor = PhotoProcessor()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var exportedURLs: [URL] = []

    func configure() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-metadata") { mode = .metadata }
        #endif
    }

    func select(_ item: PhotosPickerItem) {
        beginImport {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ProcessingError.invalidImage }
            return data
        }
    }

    func selectFile(_ url: URL) {
        beginImport { try await self.processor.readFile(url) }
    }

    private func beginImport(_ read: @escaping @MainActor () async throws -> Data) {
        cancel()
        let id = operationID
        isWorking = true
        isImporting = true
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await read()
                try Task.checkCancellation()
                let photo = try await processor.load(data)
                try Task.checkCancellation()
                guard id == operationID else { return }
                source = photo
                originalPreview = UIImage(data: photo.preview)
                clearResult()
                isWorking = false
                isImporting = false
            } catch {
                finish(error, id: id)
            }
        }
    }

    func process() {
        guard let source, !isWorking else { return }
        let id = operationID
        let selectedStrength = strength
        let selectedFormat = format
        let selectedMode = mode
        let selectedClarity = clarity
        let selectedResolution = resolution
        isWorking = true
        progress = 0
        workLabel = selectedMode == .pattern ? "Защита текста…" : "Очистка метаданных…"
        saveMessage = nil
        clearResult()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let output: ProcessedPhoto
                if selectedMode == .pattern {
                    output = try await processor.process(source, strength: selectedStrength, format: selectedFormat,
                                                         clarity: selectedClarity, resolution: selectedResolution) { [weak self] value, label in
                        Task { @MainActor in
                            guard let self, id == self.operationID else { return }
                            self.progress = value
                            self.workLabel = label
                        }
                    }
                } else {
                    output = try await processor.stripMetadata(source, format: selectedFormat)
                }
                try Task.checkCancellation()
                guard id == operationID else { return }
                result = output
                resultPreview = UIImage(data: output.preview)
                comparison = 0.5
                isWorking = false
            } catch {
                finish(error, id: id)
            }
        }
    }

    func cancel() {
        operation?.cancel()
        operation = nil
        operationID = UUID()
        isWorking = false
        isImporting = false
    }

    func reset() {
        cancel()
        source = nil
        originalPreview = nil
        clearResult()
        cleanupExports()
        saveMessage = nil
    }

    func clearResult() {
        result = nil
        resultPreview = nil
        shareURL = nil
        saveMessage = nil
    }

    func save() async {
        guard let result, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            errorMessage = "Разрешите добавление фото в Настройках → Veil → Фото. Или экспортируйте файл через «Поделиться»."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: result.data, options: nil)
            }
            saveMessage = "Новое фото сохранено"
        } catch {
            errorMessage = "Не удалось сохранить фото: \(error.localizedDescription)"
        }
    }

    func prepareShare() async {
        guard let result else { return }
        do {
            let url = try await processor.writeExport(result)
            exportedURLs.append(url)
            shareURL = url
        } catch { errorMessage = error.localizedDescription }
    }

    func cleanupExports() {
        for url in exportedURLs { try? FileManager.default.removeItem(at: url) }
        exportedURLs = []
        shareURL = nil
    }

    private func finish(_ error: Error, id: UUID) {
        guard id == operationID else { return }
        isWorking = false
        isImporting = false
        if !(error is CancellationError) { errorMessage = error.localizedDescription }
    }

    #if DEBUG
    func loadFixture() {
        beginImport { FixturePhoto.make() }
    }
    #endif
}

extension PhotoProcessor {
    func readFile(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50 * 1_024 * 1_024 else { throw ProcessingError.oversized }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func writeExport(_ result: ProcessedPhoto) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Veil-Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Veil-\(UUID().uuidString).\(result.format.fileExtension)")
        try result.data.write(to: url, options: .atomic)
        return url
    }
}

#if DEBUG
/// Synthetic artwork only; no user photographs are bundled or uploaded for CI.
@MainActor enum FixturePhoto {
    static func make() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 960), format: format)
        return renderer.pngData { context in
            let ctx = context.cgContext
            let colors = [UIColor(red: 0.72, green: 0.81, blue: 0.78, alpha: 1).cgColor,
                          UIColor(red: 0.93, green: 0.87, blue: 0.72, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 720, y: 960), options: [])
            ctx.setFillColor(UIColor(red: 0.97, green: 0.91, blue: 0.76, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 440, y: 140, width: 120, height: 120))
            for i in 0..<5 {
                let path = UIBezierPath()
                let y = CGFloat(400 + i * 95)
                path.move(to: CGPoint(x: -100, y: y + 120))
                path.addCurve(to: CGPoint(x: 820, y: y), controlPoint1: CGPoint(x: 230, y: y - 260), controlPoint2: CGPoint(x: 390, y: y + 220))
                path.addLine(to: CGPoint(x: 820, y: 1_000))
                path.addLine(to: CGPoint(x: -100, y: 1_000))
                path.close()
                UIColor(red: 0.23 - Double(i) * 0.035, green: 0.47 - Double(i) * 0.05,
                        blue: 0.39 - Double(i) * 0.04, alpha: 1).setFill()
                path.fill()
            }
        }
    }
}
#endif
