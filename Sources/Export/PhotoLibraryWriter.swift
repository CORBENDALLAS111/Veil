import Foundation
import Photos

enum ExportEnvironment {
    /// LiveContainer preserves LC_HOME_PATH for the host container while HOME
    /// and Bundle.main are redirected to the guest. Do not ask guest PhotoKit
    /// to authorize against an identity it does not own.
    static func usesSystemExport(environment: [String: String], arguments: [String]) -> Bool {
        if environment["LC_HOME_PATH"]?.isEmpty == false { return true }
        #if DEBUG
        if arguments.contains("-ui-container") { return true }
        #endif
        return false
    }
    static var usesSystemExport: Bool {
        usesSystemExport(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments)
    }
}

enum PhotoLibraryWriter {
    enum Media: Sendable, Equatable { case photo, video }
    enum SaveError: LocalizedError {
        case permission
        var errorDescription: String? {
            "Разрешите добавление в Фото в настройках приложения или сохраните файл через «Поделиться»."
        }
    }

    /// Explicitly nonisolated: PhotoKit executes its change block on its own
    /// queue. Constructing it inside StudioModel's MainActor can inherit an
    /// executor assertion and crash in Swift 6 before the request even runs.
    nonisolated static func changeBlock(url: URL, media: Media) -> @Sendable () -> Void {
        {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            options.originalFilename = url.lastPathComponent
            PHAssetCreationRequest.forAsset().addResource(with: media == .photo ? .photo : .video,
                                                         fileURL: url, options: options)
        }
    }

    nonisolated static func save(url: URL, media: Media) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.permission }
        try await PHPhotoLibrary.shared().performChanges(changeBlock(url: url, media: media))
    }
}
