import Foundation
import Testing
@testable import Napkin

@Suite(.serialized)
struct CLIControlTests {
    @Test @MainActor func menuBarVisibilityPersistsWithoutChangingActivation() throws {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        #expect(coordinator.settings.showInMenuBar)
        for value in ["hide", "show", "hide"] {
            let reply = try coordinator.handleControl(command("{\"action\":\"menubar\",\"value\":\"\(value)\"}"))
            let visible = value == "show"
            #expect(reply.code == 200)
            #expect(try json(reply)["show_in_menu_bar"] as? Bool == visible)
            #expect(SettingsManager(defaults: fixture.defaults).showInMenuBar == visible)
            #expect(coordinator.settings.automaticActivation)
            #expect(coordinator.state == .userActive)
            #expect(!coordinator.isStarting)
        }
        for raw in [#"{"action":"menubar"}"#, #"{"action":"menubar","value":"other"}"#] {
            #expect(throws: ControlError.self) { try coordinator.handleControl(command(raw)) }
            #expect(!coordinator.settings.showInMenuBar)
        }
        coordinator.settings.showInMenuBar = true
        let status = try coordinator.handleControl(GatewayRequest(method: "GET", path: "/control/status", body: Data()))
        #expect(try json(status)["show_in_menu_bar"] as? Bool == true)
        #expect(SettingsManager(defaults: fixture.defaults).showInMenuBar)
    }

    @Test @MainActor func modesPersistAndManualSuppressesAutomaticStart() throws {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        _ = try coordinator.handleControl(command(#"{"action":"mode","value":"manual"}"#))
        coordinator.tick(now: ProcessInfo.processInfo.systemUptime + 20_000)
        #expect(!coordinator.isStarting)
        #expect(coordinator.state == .userActive)
        #expect(!SettingsManager(defaults: fixture.defaults).automaticActivation)

        let first = try coordinator.handleControl(command(#"{"action":"mode","value":"toggle"}"#))
        #expect(try json(first)["mode"] as? String == "auto")
        #expect(coordinator.remaining == 1800)
        coordinator.tick()
        #expect(!coordinator.isStarting)
        #expect(coordinator.remaining > 1798)
        let second = try coordinator.handleControl(command(#"{"action":"mode","value":"toggle"}"#))
        #expect(try json(second)["mode"] as? String == "manual")
        #expect(!SettingsManager(defaults: fixture.defaults).automaticActivation)
    }

    @Test @MainActor func idleTimeoutValidatesPersistsAndResetsCountdown() throws {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.setAutomaticActivation(false)
        coordinator.tick(now: ProcessInfo.processInfo.systemUptime + 20_000)
        #expect(coordinator.remaining == 0)
        let reply = try coordinator.handleControl(command(#"{"action":"idle","minutes":10}"#))
        #expect(coordinator.remaining == 600)
        #expect(try json(reply)["remaining_seconds"] as? Int == 600)
        #expect(SettingsManager(defaults: fixture.defaults).idleMinutes == 10)
        for raw in [
            #"{"action":"idle","minutes":0}"#, #"{"action":"idle","minutes":-1}"#,
            #"{"action":"idle","minutes":241}"#, #"{"action":"idle","minutes":1.5}"#,
            #"{"action":"idle","minutes":"10"}"#, #"{"action":"idle"}"#,
            #"{"action":"mode","value":"unknown"}"#, #"{"action":"unknown"}"#, "{}", "not JSON"
        ] {
            #expect(throws: ControlError.self) { try coordinator.handleControl(command(raw)) }
            #expect(coordinator.settings.idleMinutes == 10)
            #expect(!coordinator.settings.automaticActivation)
        }
        for minutes in [1, 240] {
            _ = try coordinator.handleControl(command("{\"action\":\"idle\",\"minutes\":\(minutes)}"))
            #expect(SettingsManager(defaults: fixture.defaults).idleMinutes == Double(minutes))
        }
    }

    @Test @MainActor func manualStartStillInterruptsAndDoesNotChangeMode() async throws {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.setAutomaticActivation(false)
        let reply = try coordinator.handleControl(command(#"{"action":"start"}"#))
        #expect(reply.code == 202)
        #expect(coordinator.isStarting)
        #expect(!coordinator.settings.automaticActivation)
        // Cancel synchronously before the startup task can spawn any process.
        #expect(coordinator.humanActivity())
        #expect(!coordinator.isStarting)
        #expect(throws: ControlError.self) {
            try coordinator.handleControl(command(#"{"action":"start"}"#))
        }
        #expect(await coordinator.prepareToQuit())
        #expect(coordinator.state == .userActive)
        #expect(!coordinator.settings.automaticActivation)
        #expect(coordinator.serverCount == 0)
    }

    @Test @MainActor func unavailableMonitorRejectsManualStart() throws {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        fixture.monitor.isAvailable = false
        #expect(throws: ControlError.self) {
            try fixture.coordinator.handleControl(command(#"{"action":"start"}"#))
        }
        #expect(!fixture.coordinator.isStarting)
    }

    @Test @MainActor func controlWorksWhileBlockedAndStopKeepsItsResponse() async throws {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        fixture.gateway.control = { try fixture.coordinator.handleControl($0) }
        try fixture.gateway.start()
        try await Task.sleep(for: .milliseconds(200))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let base = URL(string: "http://127.0.0.1:\(fixture.port)")!
        let (snapshot, response) = try await session.data(from: base.appendingPathComponent("control/status"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let status = try #require(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        #expect(status["accepting_requests"] as? Bool == false)
        #expect(status["mode"] as? String == "auto")
        #expect(status["can_start"] as? Bool == true)

        var request = URLRequest(url: base.appendingPathComponent("control"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action":"mode","value":"manual"}"#.utf8)
        let (_, modeResponse) = try await session.data(for: request)
        #expect((modeResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(!fixture.coordinator.settings.automaticActivation)

        request.httpBody = Data(#"{"action":"idle","minutes":0}"#.utf8)
        let (_, invalid) = try await session.data(for: request)
        #expect((invalid as? HTTPURLResponse)?.statusCode == 400)
        request.httpBody = Data(#"{"action":"start"}"#.utf8)
        fixture.monitor.isAvailable = false
        let (_, unavailable) = try await session.data(for: request)
        #expect((unavailable as? HTTPURLResponse)?.statusCode == 409)

        fixture.gateway.enable(upstream: URL(string: "http://127.0.0.1:1")!)
        request.httpBody = Data(#"{"action":"stop"}"#.utf8)
        let (stopped, stopResponse) = try await session.data(for: request)
        #expect((stopResponse as? HTTPURLResponse)?.statusCode == 202)
        let stopStatus = try #require(JSONSerialization.jsonObject(with: stopped) as? [String: Any])
        #expect(stopStatus["accepting_requests"] as? Bool == false)
        #expect(stopStatus["mode"] as? String == "manual")
        #expect(fixture.gateway.upstream == nil)
        let (_, blocked) = try await session.data(from: base.appendingPathComponent("api/ps"))
        #expect((blocked as? HTTPURLResponse)?.statusCode == 503)
        #expect(await fixture.coordinator.prepareToQuit())
    }

    @Test @MainActor func browserControlRequestsAreRejected() async throws {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        fixture.gateway.control = { try fixture.coordinator.handleControl($0) }
        try fixture.gateway.start()
        try await Task.sleep(for: .milliseconds(200))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(fixture.port)/control")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"action":"mode","value":"manual"}"#.utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let (_, plain) = try await session.data(for: request)
        #expect((plain as? HTTPURLResponse)?.statusCode == 400)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://example.com", forHTTPHeaderField: "Origin")
        let (_, origin) = try await session.data(for: request)
        #expect((origin as? HTTPURLResponse)?.statusCode == 400)
        #expect(fixture.coordinator.settings.automaticActivation)
    }

    @Test @MainActor func cliRoundTripUsesRealGatewayAndAppPreferences() async throws {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        fixture.gateway.control = { try fixture.coordinator.handleControl($0) }
        try fixture.gateway.start()
        try await Task.sleep(for: .milliseconds(200))
        let bundledCLI = try #require(Bundle.main.url(forResource: "napkin", withExtension: nil))
        #expect(FileManager.default.isExecutableFile(atPath: bundledCLI.path))
        let sourceCLI = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("cli/napkin")
        #expect(try Data(contentsOf: bundledCLI) == Data(contentsOf: sourceCLI))
        let script = bundledCLI.path
        for arguments in [["mode", "manual"], ["idle", "set", "10m"], ["mode", "toggle"], ["mode", "toggle"], ["menubar", "hide"], ["status"], ["menubar", "show"], ["stop"], ["status"]] {
            let result = try await Self.runCLI(script, port: fixture.port, arguments: arguments)
            #expect(result.0 == 0, "\(arguments): \(result.1)")
            let snapshot = try #require(JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [String: Any])
            #expect(snapshot["mode"] as? String == (fixture.coordinator.settings.automaticActivation ? "auto" : "manual"))
            #expect(snapshot["show_in_menu_bar"] as? Bool == fixture.coordinator.settings.showInMenuBar)
            #expect(snapshot["idle_minutes"] as? Double == fixture.coordinator.settings.idleMinutes)
        }
        #expect(!SettingsManager(defaults: fixture.defaults).automaticActivation)
        #expect(SettingsManager(defaults: fixture.defaults).idleMinutes == 10)
        #expect(await fixture.coordinator.prepareToQuit())
    }

    private static func runCLI(_ script: String, port: UInt16, arguments: [String]) async throws -> (Int32, String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["NAPKIN_URL": "http://127.0.0.1:\(port)"]) { _, value in value }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    private func command(_ body: String) -> GatewayRequest {
        GatewayRequest(method: "POST", path: "/control", body: Data(body.utf8))
    }

    private func json(_ reply: ControlReply) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any])
    }
}

@MainActor
private final class ControlFixture {
    let suite = "NapkinCLIControlTests." + UUID().uuidString
    let defaults: UserDefaults
    let monitor = ControlMonitor()
    let gateway: InferenceGateway
    let coordinator: AppCoordinator
    let port: UInt16

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        port = try InferenceManager.availablePort()
        gateway = InferenceGateway(port: port)
        coordinator = AppCoordinator(monitor: monitor, gateway: gateway)
        coordinator.settings = SettingsManager(defaults: defaults)
        coordinator.settings.showOverlay = false
        coordinator.tick()
    }

    func cleanup() {
        gateway.shutdown()
        gateway.control = nil
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class ControlMonitor: ActivityMonitoring {
    var onActivity: (() -> Bool)?
    var onFailure: (() -> Void)?
    var isAvailable = true
    var permissionMessage: String { "Test monitor" }
    func start() -> Bool { isAvailable }
    func requestPermission() {}
}
