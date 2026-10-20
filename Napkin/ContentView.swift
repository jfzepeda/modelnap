import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    private var active: Bool { coordinator.state == .aiActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 26)).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Napkin").font(.title3.weight(.semibold))
                    Text("Your Mac. Your priority.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(active ? Color.mint : .secondary).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(coordinator.state.rawValue).font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(active ? .mint : .primary)
                Text(coordinator.state == .error ? "Setup needs attention." : (active ? "Room to think." : "Make yourself at home.")).font(.title2.weight(.medium))
                Text(coordinator.gatewayFailed ? "Napkin could not open its gateway. Requests to that port are not controlled by Napkin." : (active ? "Managed inference is available. Any interaction stops it." : "Requests through Napkin are blocked. Other AI services are not controlled."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if coordinator.settings.automaticActivation && !active && coordinator.state != .error {
                    HStack {
                        Label("Available after inactivity", systemImage: "timer")
                        Spacer()
                        Text(coordinator.countdown).monospacedDigit()
                    }.font(.caption)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))

            HStack {
                metric("MANAGED SERVERS", value: "\(coordinator.serverCount)")
                Spacer()
                metric("MANAGED MODELS", value: "\(coordinator.models.count)")
                Spacer()
                metric("MODEL SIZE", value: ByteCountFormatter.string(fromByteCount: coordinator.models.reduce(0) { $0 + $1.size }, countStyle: .memory))
            }
            Text("\(coordinator.agentCount) managed agents · gateway :11435").font(.caption).foregroundStyle(.secondary)
            if !coordinator.models.isEmpty {
                Text(coordinator.models.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let external = coordinator.externalModels {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Ollama outside Napkin", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    Text("Port 11434 · \(external.count) loaded models · \(ByteCountFormatter.string(fromByteCount: external.reduce(0) { $0 + $1.size }, countStyle: .memory))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(external.isEmpty ? "Server available; no models loaded. This is not a running generation." : "Models resident in memory, not necessarily generating. Napkin does not stop this external server.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !coordinator.permissionGranted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Input monitoring required", systemImage: "hand.raised").font(.callout.weight(.medium))
                    Text(coordinator.permissionMessage)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open permission settings…") { coordinator.requestPermissions() }
                }
            }
            if let error = coordinator.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(coordinator.gatewayFailed ? "Retry connection" : (coordinator.isStopping ? "Stopping…" : (coordinator.state == .error ? "Retry" : "Stop AI Now")), systemImage: coordinator.state == .error ? "arrow.clockwise" : "stop.fill") { coordinator.retryStop() }
                    .disabled(coordinator.isStopping || (!coordinator.canStop && coordinator.state != .error))
                Spacer()
                Button(coordinator.isStarting ? "Starting…" : "Start AI Now", systemImage: "play.fill") { dismiss(); coordinator.enable() }
                    .disabled(!coordinator.canEnable).buttonStyle(.borderedProminent).tint(.mint)
            }.controlSize(.large)
            Toggle("Automatic activation", isOn: Binding(get: { coordinator.settings.automaticActivation }, set: { coordinator.setAutomaticActivation($0) })).toggleStyle(.switch).font(.callout)
            Divider()
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                Spacer()
                Button("Quit Napkin") { NSApp.terminate(nil) }
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 370)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.medium)).monospacedDigit()
        }
    }
}
