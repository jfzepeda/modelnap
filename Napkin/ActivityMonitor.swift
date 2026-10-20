import AppKit
import CoreGraphics

@MainActor
protocol ActivityMonitoring: AnyObject {
    var onActivity: (() -> Bool)? { get set }
    var onFailure: (() -> Void)? { get set }
    var isAvailable: Bool { get }
    var permissionMessage: String { get }
    func start() -> Bool
    func requestPermission()
}

@MainActor
final class ActivityMonitor: ActivityMonitoring {
    var onActivity: (() -> Bool)?
    var onFailure: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeys: Set<Int64> = []
    private var swallowedButtons: Set<Int64> = []
    var isAvailable: Bool { AXIsProcessTrusted() && (tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false) }
    var permissionMessage: String {
        if isAvailable { return "Input monitor is ready." }
        if !AXIsProcessTrusted() { return "Enable Accessibility for Napkin in System Settings, then return here." }
        return "Accessibility is granted, but the input monitor could not start. Quit and reopen this copy of Napkin if macOS requested a restart."
    }

    func start() -> Bool {
        if isAvailable { return true }
        guard AXIsProcessTrusted() else { return false }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let monitor = Unmanaged<ActivityMonitor>.fromOpaque(context).takeUnretainedValue()
                return monitor.handle(type, event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return isAvailable
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onFailure?()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Ignore identifiable application-posted events. Never read or store text.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return Unmanaged.passUnretained(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if type == .keyUp, swallowedKeys.remove(key) != nil { return nil }
        if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type), swallowedButtons.remove(button) != nil { return nil }
        if type == .keyDown, swallowedKeys.contains(key) { return nil }
        // Releasing the control that started AI is not a new interaction.
        if [.keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) {
            return Unmanaged.passUnretained(event)
        }
        if onActivity?() ?? false {
            if type == .keyDown { swallowedKeys.insert(key) }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { swallowedButtons.insert(button) }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
