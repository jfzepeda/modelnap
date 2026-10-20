import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var windows: [NSWindow] = []
    func show() {
        hide()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OverlayView())
            window.orderFrontRegardless()
            windows.append(window)
        }
    }
    func hide() { windows.forEach { $0.orderOut(nil) }; windows.removeAll() }
}

private struct OverlayView: View {
    var body: some View {
        ZStack {
            WallpaperBackground()
//            VStack(spacing: 18) {
//                GlassLetters(text: "LLM RUNNING")
//                Text("Click or press any key to take control")
//                    .font(.system(size: 13, weight: .regular))
//                    .tracking(1.5)
//                    .foregroundStyle(.white.opacity(0.28))
//            }
        }.ignoresSafeArea().preferredColorScheme(.dark)
    }
}

/// macOS system wallpaper (Sonoma); falls back to a gradient with blurred colour blobs if the file is missing.
private struct WallpaperBackground: View {
    /// Real system wallpaper, loaded once and shared by every screen's overlay.
    private static let systemWallpaper = NSImage(contentsOfFile: "/System/Library/Wallpapers/.default/DefaultAerial.heic")

    var body: some View {
        if let image = Self.systemWallpaper {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        } else {
            fallback
        }
    }

    private var fallback: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.22),
                                        Color(red: 0.16, green: 0.07, blue: 0.30),
                                        Color(red: 0.03, green: 0.14, blue: 0.24)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse().fill(Color(red: 0.25, green: 0.45, blue: 1.0).opacity(0.55))
                    .frame(width: w * 0.7, height: h * 0.6).offset(x: -w * 0.22, y: -h * 0.18)
                Ellipse().fill(Color(red: 0.75, green: 0.30, blue: 0.95).opacity(0.50))
                    .frame(width: w * 0.6, height: h * 0.55).offset(x: w * 0.25, y: h * 0.05)
                Ellipse().fill(Color(red: 0.10, green: 0.80, blue: 0.75).opacity(0.38))
                    .frame(width: w * 0.55, height: h * 0.45).offset(x: -w * 0.05, y: h * 0.30)
            }
            .blur(radius: 110)
            .frame(width: w, height: h)
            .clipped()
        }
    }
}

/// Subtle "liquid glass" lettering: translucent fill, lit top edge, soft depth shadow.
private struct GlassLetters: View {
    let text: String
    private var label: some View {
        Text(text)
            .font(.system(size: 96, weight: .bold, design: .rounded))
            .tracking(14)
    }
    var body: some View {
        label
            .foregroundStyle(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.10)],
                                            startPoint: .top, endPoint: .bottom))
            .overlay {
                label.foregroundStyle(.white.opacity(0.0))
                    .overlay(LinearGradient(colors: [.white.opacity(0.55), .clear],
                                            startPoint: .top, endPoint: .center))
                    .mask(label)
                    .blendMode(.overlay)
            }
            .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
            .shadow(color: .white.opacity(0.12), radius: 1, y: -1)
    }
}
