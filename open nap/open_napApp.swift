import AppKit
import SwiftUI

@main
struct ModelNapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("ModelNap", systemImage: "moon.zzz") {
            ContentView(coordinator: delegate.coordinator)
        }.menuBarExtraStyle(.window)
        Settings { SettingsView(coordinator: delegate.coordinator) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests must not bind a port, create event taps or launch inference.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        coordinator.start()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            let safe = await coordinator.prepareToQuit()
            quitting = false
            sender.reply(toApplicationShouldTerminate: safe)
        }
        return .terminateLater
    }
}
