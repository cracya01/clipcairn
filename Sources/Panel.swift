import AppKit
import SwiftUI

/// Borderless floating panel that takes keyboard input without activating Clipcairn,
/// so the app the user was in stays frontmost and receives the paste.
final class HistoryPanel: NSPanel {
    var onResignKey: (() -> Void)?
    /// True while a sheet or menu from this panel is open; the panel then stays visible.
    var holdOpen = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .none
        minSize = NSSize(width: 640, height: 400)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if !holdOpen && attachedSheet == nil { onResignKey?() }
    }

    /// Wraps SwiftUI content in a rounded Liquid Glass background.
    func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let glass = NSGlassEffectView()
        glass.cornerRadius = 26
        glass.contentView = host
        glass.frame = NSRect(origin: .zero, size: frame.size)
        glass.autoresizingMask = [.width, .height]
        let container = NSView(frame: glass.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 26
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(glass)
        contentView = container
    }

    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = frame.size
            setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08))
        }
        orderFrontRegardless()
        makeKey()
    }
}
