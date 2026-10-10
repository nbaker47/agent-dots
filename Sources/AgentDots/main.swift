import AppKit
import SwiftUI

/// A panel that floats over every window and Space without taking the app in front away from it, and can still
/// be typed in (for a message to an agent).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panel: FloatingPanel!

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 52, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        let view = Strip(store: store) { [weak self] open, count in self?.place(open: open, count: count) }
        panel.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark))
        place(open: false, count: 0)
        panel.orderFrontRegardless()
        store.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.place(open: false, count: self?.store.sessions.count ?? 0) } }
    }

    /// The panel hugs its edge, halfway down the screen: as narrow as the dots when closed, wide enough for the
    /// list when open, so the rest of the screen is never covered by an unseen window.
    func place(open: Bool, count: Int) {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let rows = CGFloat(max(count, 1))
        let closed = rows * 23 + 26
        let opened = rows * 50 + 96
        let height = min(max(open ? max(opened, closed) : closed, 60), area.height - 40)
        let width: CGFloat = open ? 360 : 44
        let onRight = (UserDefaults.standard.string(forKey: "edge") ?? "right") == "right"
        let x = onRight ? area.maxX - width : area.minX
        let y = area.midY - height / 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
