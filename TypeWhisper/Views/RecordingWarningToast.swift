import AppKit
import SwiftUI

/// A standalone floating warning toast shown when recording approaches the time limit.
/// Appears in the top-right corner, independent of the recording overlay.
@MainActor
final class RecordingWarningToast {
    static let shared = RecordingWarningToast()

    private var panel: NSPanel?

    private init() {}

    @MainActor
    func show(message: String) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let view = NSHostingView(rootView: WarningToastView(message: message))
        view.sizingOptions = []
        panel.contentView = view

        // Position: top-right corner of active screen
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame
        let x = sf.maxX - 280 - 16
        let y = sf.maxY - 52 - 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel

        // Play beep 3 times for emphasis
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSSound.beep() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSSound.beep() }

        // Auto-dismiss after 5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.dismiss()
        }
    }

    @MainActor
    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct WarningToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 18, weight: .semibold))
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 280, height: 52)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.yellow.opacity(0.6), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        .preferredColorScheme(.dark)
    }
}
