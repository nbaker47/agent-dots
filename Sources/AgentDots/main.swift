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
    let open = Open()
    var panel: FloatingPanel!
    private var restedOn: (id: String, since: Date)?
    private var leftAt: Date?
    private var beat = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Strip.width, height: Strip.height(count: 1)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        // no fixed look: the glass and the text follow the system
        panel.contentView = NSHostingView(rootView: Strip(store: store, open: open))
        place()
        panel.orderFrontRegardless()
        store.start()
        // AGENTDOTS_PIN=<n> pins the nth dot's card a few seconds after launch, for looking at it without clicking
        if let n = Int(ProcessInfo.processInfo.environment["AGENTDOTS_PIN"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.store.sessions.indices.contains(n) else { return }
                self.open.pinned = self.store.sessions[n].id
            }
        }
        // a click in any other app, or on the desktop, closes whatever the strip has open
        if let scene = Store.demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if scene == "pinned" { self?.open.pinned = "demo-0" }
                if scene == "hover" { self?.open.pointed = "demo-1"; self?.open.hovered = "demo-1" }
            }
        }
        if ProcessInfo.processInfo.environment["AGENTDOTS_PIN"] == nil, Store.demo == nil {  // (a pinned look stays for its picture)
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                NotificationCenter.default.post(name: .clickedAway, object: nil)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.follow() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.place() } }
    }

    private var onRight: Bool { (UserDefaults.standard.string(forKey: "edge") ?? "right") == "right" }

    /// The window is one size and stays put, hugging its edge halfway down the screen. It only changes when the
    /// number of sessions does, or the edge. Where nothing is drawn it lets every click through (`follow`).
    func place() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let height = min(Strip.height(count: store.sessions.count), area.height - 20)
        let frame = NSRect(
            x: onRight ? area.maxX - Strip.width : area.minX, y: area.midY - height / 2, width: Strip.width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Thirty times a second: where the pointer is. Over a dot, the dot grows at once and its card shows after
    /// a short rest; over a card, the card stays; anywhere else the window lets clicks through to what is
    /// under it, and a card that was only being looked at goes after a moment.
    private func follow() {
        place()
        beat += 1
        if beat % 15 == 0 { open.tick.toggle() }  // twice a second the glass looks at what is behind it (`Strip.glass`)
        if Store.demo != nil { return }  // the pictures are posed, not pointed at
        store.holding = Set([open.pinned, open.typingIn, open.hovered].compactMap { $0 })
        let frame = panel.frame
        let at = NSEvent.mouseLocation
        let point = CGPoint(x: at.x - frame.minX, y: frame.maxY - at.y)  // in the window, from its top left
        let count = store.sessions.count
        let capsule = CGRect(
            x: onRight ? frame.width - Strip.inset - Strip.row - 6 : Strip.inset,
            y: (frame.height - (CGFloat(max(count, 1)) * Strip.row + 2 * Strip.capsulePad)) / 2,
            width: Strip.row + 6, height: CGFloat(max(count, 1)) * Strip.row + 2 * Strip.capsulePad)
        let onCapsule = capsule.insetBy(dx: -3, dy: 0).contains(point)
        let onCard = open.cards.contains { $0.insetBy(dx: -Strip.gap, dy: -6).contains(point) }  // and the neck beside it
        let through = !(onCapsule || onCard)
        if panel.ignoresMouseEvents != through { panel.ignoresMouseEvents = through }

        if onCapsule, count > 0 {
            let index = min(max(Int((point.y - capsule.minY - Strip.capsulePad) / Strip.row), 0), count - 1)
            let id = store.sessions[index].id
            leftAt = nil
            if open.pointed != id { open.pointed = id }
            if restedOn?.id != id { restedOn = (id, Date()) }
            if let rested = restedOn, Date().timeIntervalSince(rested.since) > 0.18, open.hovered != id { open.hovered = id }
        } else if onCard {
            leftAt = nil
            if open.pointed != nil { open.pointed = nil }
        } else {
            restedOn = nil
            if open.pointed != nil { open.pointed = nil }
            if open.hovered != nil {
                if leftAt == nil { leftAt = Date() }
                if let left = leftAt, Date().timeIntervalSince(left) > 0.3 {
                    open.hovered = nil
                    leftAt = nil
                }
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
