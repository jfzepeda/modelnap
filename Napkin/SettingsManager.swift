import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class SettingsManager {
    var idleMinutes: Double { didSet { defaults.set(idleMinutes, forKey: "idleMinutes") } }
    var automaticActivation: Bool { didSet { defaults.set(automaticActivation, forKey: "automaticActivation") } }
    var showOverlay: Bool { didSet { defaults.set(showOverlay, forKey: "showOverlay") } }
    var ollamaPath: String { didSet { defaults.set(ollamaPath, forKey: "ollamaPath") } }
    var agentPath: String { didSet { defaults.set(agentPath, forKey: "agentPath") } }
    var agentArguments: String { didSet { defaults.set(agentArguments, forKey: "agentArguments") } }
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var loginError: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["idleMinutes": 30.0, "automaticActivation": true,
                                     "showOverlay": true, "ollamaPath": "/opt/homebrew/bin/ollama"])
        idleMinutes = defaults.double(forKey: "idleMinutes")
        automaticActivation = defaults.bool(forKey: "automaticActivation")
        showOverlay = defaults.bool(forKey: "showOverlay")
        ollamaPath = defaults.string(forKey: "ollamaPath") ?? ""
        agentPath = defaults.string(forKey: "agentPath") ?? ""
        agentArguments = defaults.string(forKey: "agentArguments") ?? ""
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = SMAppService.mainApp.status == .requiresApproval ? "Approve Napkin in System Settings → Login Items." : nil
        } catch { loginError = error.localizedDescription }
    }
}

struct IdleScheduler {
    private(set) var lastActivity: TimeInterval
    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastActivity = now }
    mutating func recordActivity(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastActivity = now }
    func remaining(timeout: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, timeout - max(0, now - lastActivity))
    }
}
