import AppKit
import SwiftUI

/// A small glass pill near the pointer that confirms something happened,
/// like text copied from a capture, then fades away on its own.
@MainActor
enum Toast {
    private static var window: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String) {
        hideWork?.cancel()
        window?.orderOut(nil)

        let host = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let panel = NSPanel(contentRect: NSRect(x: mouse.x - size.width / 2, y: mouse.y + 24,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        window = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassFrame(capsule: true)
            .padding(8)
    }
}
