import UIKit

@MainActor final class ModelDownloadPreparation {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Prepare model transfers") { [weak self] in
            self?.end()
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

@MainActor enum BackgroundDownloadEvents {
    static var completion: (() -> Void)?
    static func finish() {
        let callback = completion
        completion = nil
        callback?()
    }
}

@MainActor final class VeilAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Recreate the same session at launch to recover transfers and progress.
        _ = ModelDownloads.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ModelDownloads.identifier else { completionHandler(); return }
        BackgroundDownloadEvents.completion = completionHandler
        _ = ModelDownloads.shared
    }
}
