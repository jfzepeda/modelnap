import Foundation
import Darwin
import CoreGraphics
import Testing
@testable import ModelNap

@Suite(.serialized)
struct ModelNapTests {
    @Test @MainActor func releasingStartControlDoesNotInterrupt() throws {
        let monitor = ActivityMonitor()
        var activities = 0
        monitor.onActivity = { activities += 1; return true }
        let event = try #require(CGEvent(source: nil))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        #expect(monitor.handle(.leftMouseUp, event) != nil)
        #expect(monitor.handle(.keyUp, event) != nil)
        #expect(activities == 0)
        #expect(monitor.handle(.leftMouseDown, event) == nil)
        #expect(monitor.handle(.leftMouseUp, event) == nil)
        #expect(activities == 1)
    }

    @Test @MainActor func permissionRecoveryAllowsStartingAgain() async throws {
        let monitor = TestActivityMonitor()
        let coordinator = AppCoordinator(monitor: monitor)
        coordinator.tick()
        #expect(coordinator.canEnable)
        coordinator.enable()
        monitor.isAvailable = false
        coordinator.tick()
        for _ in 0..<100 where coordinator.isStopping { try await Task.sleep(for: .milliseconds(10)) }
        #expect(coordinator.state == .error)
        monitor.isAvailable = true
        coordinator.tick()
        #expect(coordinator.canEnable)
        #expect(coordinator.errorMessage == nil)
    }

    @Test @MainActor func repeatedStopCancelsPendingStartAndCanRestart() async throws {
        let coordinator = AppCoordinator(monitor: TestActivityMonitor())
        coordinator.tick()
        coordinator.enable()
        #expect(coordinator.isStarting)
        coordinator.retryStop()
        coordinator.retryStop()
        #expect(!coordinator.canEnable)
        for _ in 0..<100 where coordinator.isStopping { try await Task.sleep(for: .milliseconds(10)) }
        #expect(coordinator.state == .userActive)
        #expect(coordinator.canEnable)
        #expect(coordinator.serverCount == 0)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ollama")))
    @MainActor func coordinatorCanStartStopAndStartAgain() async throws {
        let suite = "ModelNapTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppCoordinator(monitor: TestActivityMonitor())
        coordinator.settings = SettingsManager(defaults: defaults)
        coordinator.settings.showOverlay = false
        coordinator.tick()
        for _ in 0..<2 {
            coordinator.enable()
            for _ in 0..<300 where coordinator.isStarting { try await Task.sleep(for: .milliseconds(20)) }
            let reachedActive = coordinator.state == .aiActive
            coordinator.retryStop()
            for _ in 0..<300 where coordinator.isStopping { try await Task.sleep(for: .milliseconds(20)) }
            #expect(reachedActive)
            #expect(coordinator.state == .userActive)
            #expect(coordinator.canEnable)
            #expect(coordinator.serverCount == 0)
        }
    }

    @Test func activityResetsOneDeadline() {
        var idle = IdleScheduler(now: 0)
        #expect(idle.remaining(timeout: 1800, now: 1200) == 600)
        idle.recordActivity(now: 1200)
        #expect(idle.remaining(timeout: 1800, now: 2700) == 300)
        #expect(idle.remaining(timeout: 1800, now: 3000) == 0)
        idle.recordActivity(now: 3001)
        #expect(idle.remaining(timeout: 1800, now: 3001) == 1800)
    }

    @Test func incompleteRequestWaitsForBody() throws {
        let header = "POST /api/generate HTTP/1.1\r\nContent-Length: 2\r\n\r\n"
        #expect(try GatewayRequest.parse(Data((header + "{").utf8)) == nil)
        let parsed = try GatewayRequest.parse(Data((header + "{}").utf8))
        let request = try #require(parsed)
        #expect(request.isAllowed)
        #expect(request.body == Data("{}".utf8))
    }

    @Test(arguments: [
        "POST /api/chat HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST /api/chat HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST /api/chat HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 2\r\n\r\n",
        "GET /api/ps HTTP/1.1\r\n\r\nextra"
    ]) func ambiguousRequestsRejected(_ raw: String) {
        #expect(throws: GatewayError.self) { try GatewayRequest.parse(Data(raw.utf8)) }
    }

    @Test func arbitraryUpstreamPathsNotExposed() {
        #expect(!GatewayRequest(method: "POST", path: "/api/pull", body: Data()).isAllowed)
        #expect(!GatewayRequest(method: "GET", path: "http://example.com", body: Data()).isAllowed)
        #expect(GatewayRequest(method: "POST", path: "/v1/chat/completions", body: Data()).isAllowed)
    }

    @Test func killOnlyOwnedProcessGroupIncludingChildren() async throws {
        let manager = ProcessManager()
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { unrelated.terminate() }
        let pid = try await manager.start(executable: "/bin/sh", arguments: ["-c", "sleep 30 & wait"])
        #expect(await manager.isRunning(pid))
        try await Task.sleep(for: .milliseconds(100))
        try await manager.stopAll()
        #expect(!isGroupPresent(pid))
        #expect(unrelated.isRunning)
        try await manager.stopAll()
    }

    @Test func cancelledLaunchCannotCreateWork() async throws {
        let manager = ProcessManager()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await manager.start(executable: "/bin/sleep", arguments: ["30"])
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled launch must not spawn a process")
        } catch is CancellationError { } catch { throw error }
        try await manager.stopAll()
    }

    @Test func exitedServerCanStillBeSafelyCleanedUp() async throws {
        let manager = ProcessManager()
        let pid = try await manager.start(executable: "/usr/bin/true", arguments: [])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(await manager.isRunning(pid)))
        try await manager.stopAll()
        #expect(!isGroupPresent(pid))
    }

    @Test @MainActor func permissionMissingPreventsActivation() {
        let coordinator = AppCoordinator()
        #expect(!coordinator.canEnable)
        coordinator.enable()
        #expect(coordinator.state == .userActive)
        #expect(!coordinator.humanActivity())
    }

    @Test @MainActor func gatewayRejectsWorkWhileBlocked() async throws {
        let gatewayPort = try InferenceManager.availablePort()
        let gateway = InferenceGateway(port: gatewayPort)
        gateway.status = { "USER ACTIVE" }
        try gateway.start()
        defer { gateway.shutdown() }
        try await Task.sleep(for: .milliseconds(200))
        let session = URLSession(configuration: .ephemeral)
        let base = URL(string: "http://127.0.0.1:\(gatewayPort)")!
        let (data, response) = try await session.data(from: base.appendingPathComponent("api/ps"))
        #expect((response as? HTTPURLResponse)?.statusCode == 503)
        #expect(String(decoding: data, as: UTF8.self).contains("temporarily disabled"))
        let (_, status) = try await session.data(from: base.appendingPathComponent("status"))
        #expect((status as? HTTPURLResponse)?.statusCode == 200)
        var heartbeat = URLRequest(url: base)
        heartbeat.httpMethod = "HEAD"
        let (empty, alive) = try await session.data(for: heartbeat)
        #expect((alive as? HTTPURLResponse)?.statusCode == 200)
        #expect(empty.isEmpty)
        gateway.block()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ollama")))
    @MainActor func privateOllamaStartupGatewayAndShutdown() async throws {
        let manager = ProcessManager()
        let inference = InferenceManager()
        let port = try InferenceManager.availablePort()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let pid = try await manager.start(executable: "/opt/homebrew/bin/ollama", arguments: ["serve"],
                                          environment: ["OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_NO_CLOUD": "1"])
        do {
            var ready = false
            for _ in 0..<30 {
                if (try? await inference.models(at: base)) != nil { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(ready)
            try await inference.unload([], at: base)
            #expect(await manager.isRunning(pid))
            let gatewayPort = try InferenceManager.availablePort()
            let gateway = InferenceGateway(port: gatewayPort)
            try gateway.start()
            defer { gateway.shutdown() }
            gateway.enable(upstream: base)
            try await Task.sleep(for: .milliseconds(200))
            let endpoint = URL(string: "http://127.0.0.1:\(gatewayPort)/api/version")!
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("version"))
            let cli = try await Self.runCLI(port: gatewayPort, arguments: ["list"])
            #expect(cli.0 == 0)
            var show = URLRequest(url: URL(string: "http://127.0.0.1:\(gatewayPort)/api/show")!)
            show.httpMethod = "POST"
            show.setValue("application/json", forHTTPHeaderField: "Content-Type")
            show.httpBody = Data("{\"model\":\"modelnap-nonexistent-test-model\"}".utf8)
            let (showData, showResponse) = try await URLSession.shared.data(for: show)
            #expect((showResponse as? HTTPURLResponse)?.statusCode == 404)
            #expect(!String(decoding: showData, as: UTF8.self).contains("Endpoint not exposed"))
            gateway.block()
            let blockedCLI = try await Self.runCLI(port: gatewayPort, arguments: ["list"])
            #expect(blockedCLI.0 != 0)
            #expect(blockedCLI.1.contains("temporarily disabled"))
            let (_, blocked) = try await URLSession.shared.data(from: endpoint)
            #expect((blocked as? HTTPURLResponse)?.statusCode == 503)
            try await manager.stopAll()
            #expect(!isGroupPresent(pid))
        } catch {
            try await manager.stopAll()
            throw error
        }
    }

    private static func runCLI(port: UInt16, arguments: [String]) async throws -> (Int32, String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["OLLAMA_HOST": "http://127.0.0.1:\(port)"]) { _, value in value }
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    private func isGroupPresent(_ pid: pid_t) -> Bool { kill(-pid, 0) == 0 || errno != ESRCH }
}

@MainActor
private final class TestActivityMonitor: ActivityMonitoring {
    var onActivity: (() -> Bool)?
    var onFailure: (() -> Void)?
    var isAvailable = true
    var permissionMessage: String { "Test monitor" }
    func start() -> Bool { isAvailable }
    func requestPermission() {}
}
