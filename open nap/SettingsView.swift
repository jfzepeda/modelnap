import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    var body: some View {
        Form {
            Section("Human First") {
                Toggle("Enable AI automatically after inactivity", isOn: $coordinator.settings.automaticActivation)
                Stepper("Idle timeout: \(Int(coordinator.settings.idleMinutes)) minutes", value: $coordinator.settings.idleMinutes, in: 1...240, step: 1)
                Toggle("Show fullscreen overlay on all displays", isOn: $coordinator.settings.showOverlay)
                Text("Keyboard, pointer movement, clicks and scrolling always interrupt AI. Managed processes are forcibly terminated; interrupted sessions never resume.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Managed Ollama server") {
                TextField("Executable", text: $coordinator.settings.ollamaPath)
                Button("Choose executable…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { coordinator.settings.ollamaPath = url.path }
                }
                LabeledContent("Client endpoint", value: "http://127.0.0.1:11435")
                Text("ModelNap starts a separate Ollama process on a private loopback port. Configure clients to use the endpoint above. Existing Ollama services are never stopped. Changes apply at the next activation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connect your clients") {
                Text("The Ollama CLI normally connects to port 11434 and bypasses ModelNap. Set its host in the client terminal before starting a new session:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("export OLLAMA_HOST=http://127.0.0.1:11435")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy client setup") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("export OLLAMA_HOST=http://127.0.0.1:11435", forType: .string)
                }
                Text("The gateway returns HTTP 503 while you are using this Mac. Test inference from a remote client while the Mac is idle; typing locally intentionally stops managed AI. Existing terminal sessions are not migrated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Managed agent · optional") {
                TextField("Executable path", text: $coordinator.settings.agentPath)
                TextField("Arguments (one per line)", text: $coordinator.settings.agentArguments, axis: .vertical)
                    .lineLimit(2...4)
                Text("POST /agents/start starts a new session only while AI is active. The agent inherits the gateway endpoint. No shell expansion; do not put secrets in arguments. Agents never restart automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(get: { coordinator.settings.launchAtLogin }, set: { coordinator.settings.setLogin($0) }))
                if let error = coordinator.settings.loginError { Text(error).foregroundStyle(.orange).font(.caption) }
                LabeledContent("Input monitor", value: coordinator.permissionGranted ? "Ready" : "Permission needed")
                Text(coordinator.permissionMessage).font(.caption).foregroundStyle(.secondary)
                Button("Open permission settings…") { coordinator.requestPermissions() }
                if let milliseconds = coordinator.releaseMilliseconds {
                    LabeledContent("Last verified process shutdown", value: "\(milliseconds) ms")
                }
            }
        }.formStyle(.grouped).frame(width: 570, height: 720)
    }
}
