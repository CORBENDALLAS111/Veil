import SwiftUI

@main
struct VeilApp: App {
    @UIApplicationDelegateAdaptor(VeilAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            StudioView()
        }
    }
}
