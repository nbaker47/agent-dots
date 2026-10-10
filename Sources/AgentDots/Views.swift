import ServiceManagement
import SwiftUI

extension Notification.Name {
    /// A click landed somewhere that is not the strip: whatever is open closes.
    static let clickedAway = Notification.Name("AgentDots.clickedAway")
}

/// A dot for one session: blue and breathing while it works, amber and ringing when it needs a person,
/// green when it has finished and nobody has looked yet, faint when it is idle. It grows under the pointer.
struct Dot: View {
    let state: AgentState
    var big = false
    @State private var breathe = false
    private let size: CGFloat = 11

    var body: some View {
        ZStack {
            if state == .waiting {
                Circle().stroke(state.color.opacity(breathe ? 0 : 0.8), lineWidth: 1.5)
                    .frame(width: size, height: size).scaleEffect(breathe ? 2.2 : 1)
            }
            Circle().fill(state.color)
                .frame(width: size, height: size)
                .opacity(state == .running ? (breathe ? 1 : 0.5) : 1)
                .shadow(color: state == .ready ? .clear : state.color.opacity(0.8), radius: state == .waiting ? 6 : 4)
        }
        .scaleEffect(big ? 1.7 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.45), value: big)
        .frame(width: Strip.row, height: Strip.row)
        .contentShape(Rectangle())
        .onAppear { animate() }
        .onChange(of: state) { animate() }
    }

    private func animate() {
        breathe = false
        guard state == .running || state == .waiting else { return }
        withAnimation(.easeInOut(duration: state == .waiting ? 1.1 : 1.6).repeatForever(autoreverses: state == .running)) {
            breathe = true
        }
    }
}

/// What is shown beside a dot: who it is, what it is doing, the last thing it said (its question, when it
/// stopped on one), and a line to answer it with.
struct Card: View {
    let session: AgentSession
    @ObservedObject var store: Store
    let typing: (Bool) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(session.state.color).frame(width: 8, height: 8)
                Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if store.sent == session.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Button { store.jump(to: session) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open \(session.name) in cmux")
            }
            HStack(spacing: 4) {
                Text(session.state.label).foregroundStyle(session.state == .ready ? AnyShapeStyle(.secondary) : AnyShapeStyle(session.state.color))
                Text("·")
                Text(session.since, style: .relative)
                if !session.workspace.isEmpty { Text("· \(session.workspace)").lineLimit(1) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if let said = store.said[session.id] {
                Text(said).font(.system(size: 12)).lineLimit(7).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField(session.state == .waiting ? "Answer…" : "Message…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .focused($focused)
                .onChange(of: focused) { typing(focused) }
                .onSubmit {
                    store.send(text, to: session)
                    text = ""
                    focused = false
                }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onReceive(NotificationCenter.default.publisher(for: .clickedAway)) { _ in focused = false }
    }
}

/// The strip on the edge of the screen: a glass capsule of dots. A dot under the pointer grows and shows its
/// card; a session that needs a person shows its card by itself, with what it asked. A click anywhere else
/// closes whatever is open.
struct Strip: View {
    static let row: CGFloat = 23
    static let cardHeight: CGFloat = 230

    @ObservedObject var store: Store
    @AppStorage("edge") var edge = "right"
    @State private var hovered: String?  // the dot, or its card, under the pointer
    @State private var typingIn: String?  // the card being written in stays open
    @State private var dismissed: Set<String> = []  // "needs you" cards closed by a click away, until they change
    let resize: (_ open: Bool, _ count: Int) -> Void

    private func key(_ s: AgentSession) -> String { "\(s.id)@\(s.since.timeIntervalSince1970)" }

    /// The cards to show: the one being written in or pointed at; otherwise every session that needs a person.
    private var shown: [AgentSession] {
        if let id = typingIn ?? hovered, let s = store.sessions.first(where: { $0.id == id }) { return [s] }
        return store.sessions.filter { $0.state == .waiting && !dismissed.contains(key($0)) }
    }

    var body: some View {
        let onRight = edge == "right"
        let cards = shown
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if !onRight { capsule }
                if !cards.isEmpty { column(cards, onRight: onRight) }
                if onRight { capsule }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onRight ? .trailing : .leading)
        .padding(.horizontal, 6)
        .animation(.spring(duration: 0.25), value: cards.map(\.id))
        .onChange(of: cards.isEmpty) { resize(!cards.isEmpty, store.sessions.count) }
        .onChange(of: store.sessions.count) { resize(!cards.isEmpty, store.sessions.count) }
        .onChange(of: edge) { resize(!cards.isEmpty, store.sessions.count) }
        .onAppear {
            resize(!cards.isEmpty, store.sessions.count)
            // AGENTDOTS_SHOW=<n> opens the nth dot's card after a few seconds, for looking at it without a pointer
            if let n = Int(ProcessInfo.processInfo.environment["AGENTDOTS_SHOW"] ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if store.sessions.indices.contains(n) { hovered = store.sessions[n].id }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clickedAway)) { _ in
            hovered = nil
            typingIn = nil
            dismissed.formUnion(store.sessions.filter { $0.state == .waiting }.map(key))
        }
        .contextMenu {
            Button(onRight ? "Move to the left edge" : "Move to the right edge") { edge = onRight ? "left" : "right" }
            Toggle("Open at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }))
            Divider()
            Button("Quit Agent Dots") { NSApp.terminate(nil) }
        }
    }

    private var capsule: some View {
        VStack(spacing: 0) {
            if store.sessions.isEmpty {
                Dot(state: .ready)
            } else {
                ForEach(store.sessions) { s in
                    Dot(state: s.state, big: hovered == s.id)
                        .onHover { inside in point(inside, at: s.id) }
                        .onTapGesture { store.jump(to: s) }
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 3)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// One card sits level with its dot; several (more than one session asking) stack beside the strip.
    @ViewBuilder
    private func column(_ cards: [AgentSession], onRight: Bool) -> some View {
        let n = CGFloat(store.sessions.count)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { s in
                Card(session: s, store: store) { on in typingIn = on ? s.id : (typingIn == s.id ? nil : typingIn) }
                    .onHover { inside in point(inside, at: s.id) }
            }
        }
        .offset(y: cards.count == 1 ? level(of: cards[0], among: n) : 0)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: onRight ? .trailing : .leading)))
    }

    private func level(of s: AgentSession, among n: CGFloat) -> CGFloat {
        guard let at = store.sessions.firstIndex(of: s) else { return 0 }
        let wanted = (CGFloat(at) - (n - 1) / 2) * Strip.row
        let room = Strip.cardHeight / 2 - 40  // the window is this much taller than the strip, above and below
        return min(max(wanted, -(n * Strip.row / 2 + room - 100)), n * Strip.row / 2 + room - 100)
    }

    /// The pointer came over a dot or its card, or left it. Leaving waits a moment, so the pointer can cross
    /// from the dot to the card without the card going.
    private func point(_ inside: Bool, at id: String) {
        if inside {
            hovered = id
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if hovered == id { hovered = nil } }
        }
    }
}
