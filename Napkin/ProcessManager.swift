import Foundation
import Darwin

struct ManagedProcessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Only process groups created here are ever signalled. No name-based process lookup.
actor ProcessManager {
    private var groups: Set<pid_t> = []

    func start(executable: String, arguments: [String], environment: [String: String] = [:]) throws -> pid_t {
        try Task.checkCancellation()
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw ManagedProcessError(message: "Choose an executable Ollama binary in Settings.")
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Inference output can contain prompts. Do not persist it.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let merged = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw ManagedProcessError(message: "Launch failed: \(String(cString: strerror(result)))") }
        groups.insert(pid)
        return pid
    }

    func isRunning(_ pid: pid_t) -> Bool {
        guard groups.contains(pid) else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        // Keep the child unreaped until cleanup, so its PID/group ID cannot be recycled.
        return info.pbi_status != SZOMB
    }

    private func hasLiveMembers(_ group: pid_t) -> Bool {
        let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard needed >= 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 128)
        let capacity = pids.count * MemoryLayout<pid_t>.size
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32(capacity))
        }
        guard bytes >= 0, bytes < capacity else { return true }
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
            if read != size {
                if errno != ESRCH { return true }
            } else if info.pbi_pgid == UInt32(group), info.pbi_status != SZOMB {
                return true
            }
        }
        return false
    }

    func stopAll() async throws {
        let owned = Array(groups)
        // No checkpoint or grace period: TERM then KILL, including descendants in the group.
        for pid in owned { kill(-pid, SIGTERM); kill(-pid, SIGKILL) }
        for _ in 0..<100 {
            for pid in owned where groups.contains(pid) {
                if !hasLiveMembers(pid) {
                    var status: Int32 = 0
                    if waitpid(pid, &status, WNOHANG) == pid { groups.remove(pid) }
                }
            }
            if groups.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw ManagedProcessError(message: "Managed processes are still present. AI remains blocked. Retry Stop AI Now.")
    }
}
