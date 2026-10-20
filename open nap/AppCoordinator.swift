import AppKit
import Observation
import OSLog

@MainActor @Observable
final class AppCoordinator {
    enum State: String { case userActive = "USER ACTIVE", transitioning = "TRANSITIONING", aiActive = "AI ACTIVE", error = "ERROR" }
    private(set) var state: State = .userActive
    private(set) var remaining: TimeInterval = 1800
    private(set) var permissionGranted = false
    private(set) var models: [LoadedModel] = []
    private(set) var serverCount = 0
    private(set) var externalModels: [LoadedModel]?
    private(set) var agentCount = 0
    private var agentPIDs: [pid_t] = []
    private var launchingAgent = false
    private(set) var errorMessage: String?
    private(set) var releaseMilliseconds: Int?
    var settings = SettingsManager()
    private let monitor: any ActivityMonitoring
    private let overlay = OverlayController()
    private let processes = ProcessManager()
    private let inference = InferenceManager()
    private let gateway = InferenceGateway()
    private var idle = IdleScheduler()
    private var generation = 0
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var externalServerMonitor: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private(set) var gatewayFailed = false
    private var started = false
    private var resourcesReleased = true
    private let logger = Logger(subsystem: "com.jfzepeda.ModelNap", category: "lifecycle")

    init(monitor: (any ActivityMonitoring)? = nil) {
        self.monitor = monitor ?? ActivityMonitor()
    }

    var permissionMessage: String { monitor.permissionMessage }
    private var permissionFailure = false
    var isStarting: Bool { startTask != nil }
    var isStopping: Bool { stopTask != nil }
    var canStop: Bool { isStarting || state == .aiActive }

    var canEnable: Bool { permissionGranted && !gatewayFailed && !sleeping && state == .userActive && stopTask == nil }
    var countdown: String {
        let seconds = Int(ceil(remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.onActivity = { [weak self] in self?.humanActivity() ?? false }
        monitor.onFailure = { [weak self] in self?.monitorFailed() }
        permissionGranted = monitor.start()
        gateway.startAgent = { [weak self] in
            guard let self else { throw GatewayError.upstream }
            try await self.startAgent()
        }
        gateway.status = { [weak self] in self?.state.rawValue ?? "USER ACTIVE" }
        gateway.onFailure = { [weak self] message in
            self?.gatewayFailed = true
            self?.stop(reason: message)
        }
        do { try gateway.start() } catch { gatewayFailed = true; errorMessage = error.localizedDescription; state = .error }
        // Read-only discovery: never unload or signal a server we did not launch.
        externalServerMonitor = Task { [weak self, inference] in
            let address = URL(string: "http://127.0.0.1:11434")!
            while !Task.isCancelled {
                let loaded = try? await inference.models(at: address)
                guard !Task.isCancelled else { return }
                self?.externalModels = loaded
                try? await Task.sleep(for: .seconds(5))
                guard self != nil else { return }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = false; _ = self?.humanActivity() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = true; _ = self?.humanActivity() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.humanActivity() }
        })
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func tick() {
        permissionGranted = monitor.isAvailable
        if !permissionGranted {
            idle.recordActivity()
            if state == .aiActive || startTask != nil { monitorFailed() }
            permissionGranted = monitor.start()
        }
        if permissionGranted && permissionFailure && stopTask == nil {
            permissionFailure = false
            errorMessage = nil
            state = .userActive
        }
        remaining = idle.remaining(timeout: max(1, settings.idleMinutes) * 60)
        if remaining == 0 && settings.automaticActivation && canEnable { enable() }
    }

    @discardableResult func humanActivity() -> Bool {
        idle.recordActivity()
        remaining = max(1, settings.idleMinutes) * 60
        let interrupt = state == .aiActive || startTask != nil
        if interrupt { stop() }
        return interrupt
    }

    private func monitorFailed() {
        permissionGranted = false
        stop(reason: "Input monitoring was interrupted. AI has been blocked.")
        permissionFailure = true
    }

    func requestPermissions() {
        idle.recordActivity()
        monitor.requestPermission()
        tick()
    }

    func enable() {
        guard canEnable else { return }
        guard monitor.isAvailable else { permissionGranted = false; return }
        generation += 1
        let current = generation
        state = .transitioning
        errorMessage = nil
        releaseMilliseconds = nil
        let path = settings.ollamaPath
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                resourcesReleased = false
                let port = try InferenceManager.availablePort()
                let base = URL(string: "http://127.0.0.1:\(port)")!
                let pid = try await processes.start(executable: path, arguments: ["serve"], environment: [
                    "OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_NO_CLOUD": "1", "OLLAMA_ORIGINS": "http://127.0.0.1:\(InferenceGateway.port)"
                ])
                for _ in 0..<60 {
                    try Task.checkCancellation()
                    guard current == generation else { return }
                    guard await processes.isRunning(pid) else { throw ManagedProcessError(message: "Ollama exited before becoming ready. Check the executable and its configuration.") }
                    if let loaded = try? await inference.models(at: base) {
                        try Task.checkCancellation()
                        let running = await processes.isRunning(pid)
                        try Task.checkCancellation()
                        guard current == generation, monitor.isAvailable, !sleeping, running else { throw CancellationError() }
                        models = loaded
                        serverCount = 1
                        gateway.enable(upstream: base)
                        state = .aiActive
                        startTask = nil
                        if settings.showOverlay { overlay.show() }
                        pollTask = Task { [weak self] in
                            while !Task.isCancelled {
                                try? await Task.sleep(for: .seconds(3))
                                guard let self, !Task.isCancelled, self.generation == current else { return }
                                let running = await self.processes.isRunning(pid)
                                guard !Task.isCancelled, self.generation == current else { return }
                                guard running else {
                                    self.stop(reason: "The managed inference server exited unexpectedly."); return
                                }
                                do {
                                    let loaded = try await self.inference.models(at: base)
                                    guard !Task.isCancelled, self.generation == current else { return }
                                    self.models = loaded
                                    var running: [pid_t] = []
                                    for pid in self.agentPIDs where await self.processes.isRunning(pid) { running.append(pid) }
                                    guard !Task.isCancelled, self.generation == current else { return }
                                    self.agentPIDs = running
                                    self.agentCount = running.count
                                } catch {
                                    guard !Task.isCancelled, self.generation == current else { return }
                                    self.stop(reason: "The managed inference server is not responding."); return
                                }
                            }
                        }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                throw ManagedProcessError(message: "Ollama did not become ready. AI remains blocked.")
            } catch {
                guard current == generation else { return }
                // Clear before stop so cleanup never awaits its own task.
                startTask = nil
                stop(reason: error.localizedDescription)
            }
        }
    }

    private func startAgent() async throws {
        guard state == .aiActive, gateway.upstream != nil, agentCount < 8, !launchingAgent else { throw GatewayError.upstream }
        let current = generation
        launchingAgent = true
        defer { launchingAgent = false }
        let arguments = settings.agentArguments.components(separatedBy: "\n").filter { !$0.isEmpty }
        let pid = try await processes.start(executable: settings.agentPath, arguments: arguments, environment: [
            "OLLAMA_HOST": "http://127.0.0.1:\(InferenceGateway.port)",
            "OPENAI_BASE_URL": "http://127.0.0.1:\(InferenceGateway.port)/v1"
        ])
        guard current == generation, state == .aiActive else { throw CancellationError() }
        agentPIDs.append(pid)
        agentCount = agentPIDs.count
    }

    func stop(reason: String? = nil) {
        let began = ContinuousClock.now
        overlay.hide()
        gateway.block()
        idle.recordActivity()
        remaining = max(1, settings.idleMinutes) * 60
        if let reason { errorMessage = reason; permissionFailure = false }
        guard stopTask == nil else { return }
        generation += 1
        let pendingStart = startTask
        pendingStart?.cancel()
        startTask = nil
        pollTask?.cancel(); pollTask = nil
        state = .transitioning
        releaseMilliseconds = nil
        logger.info("Human First: admission closed; process termination requested")
        stopTask = Task { [weak self] in
            guard let self else { return }
            // Signal immediately, even if a readiness request is still pending.
            do {
                try await processes.stopAll()
                await pendingStart?.value
                try await processes.stopAll()
                resourcesReleased = true
                models = []; serverCount = 0; agentPIDs = []; agentCount = 0
                releaseMilliseconds = Int(began.duration(to: .now).components.seconds * 1000 + began.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
                state = errorMessage == nil ? .userActive : .error
                logger.info("Managed process groups verified terminated")
            } catch {
                permissionFailure = false
                errorMessage = error.localizedDescription
                state = .error
                logger.error("Could not verify process termination")
            }
            stopTask = nil
        }
    }

    func retryStop() {
        guard stopTask == nil else { return }
        permissionFailure = false
        errorMessage = nil
        if gatewayFailed {
            gateway.shutdown()
            do { try gateway.start(); gatewayFailed = false }
            catch { errorMessage = error.localizedDescription }
        }
        stop()
    }

    func prepareToQuit() async -> Bool {
        sleeping = true
        stop()
        await stopTask?.value
        if !resourcesReleased { sleeping = false }
        return resourcesReleased
    }
}
