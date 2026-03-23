import AppKit
import SwiftUI

@main
struct AIUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private lazy var providerStore = ProviderStore(settingsStore: settingsStore)
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(store: providerStore)
        providerStore.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        providerStore.stop()
        Task {
            await CodexAppServerClient.shared.stopIfOwned()
        }
    }
}
