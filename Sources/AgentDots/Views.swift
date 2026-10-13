import ServiceManagement
import SwiftUI

extension Notification.Name {
    /// A click landed somewhere that is not the strip: whatever is open closes.
    static let clickedAway = Notification.Name("AgentDots.clickedAway")
}

/// What the strip has open. The pointer is followed by the app itself (`AppDelegate.follow`), not by the views:
/// the window never changes size or place, so nothing jumps when the pointer arrives.
@MainActor
final class Open: ObservableObject {
    @Published var pointed: String?  // the dot under the pointer: it grows at once
    @Published var hovered: String?  // the dot the pointer has rested on: its card shows
    @Published var pinned: String?  // the dot that was clicked: its card stays, in full, until a click away
    @Published var typingIn: String?  // the card being written in stays open
    @Published var dismissed: Set<String> = []  // "needs you" cards closed by a click away, until they change
    @Published var tick = false  // flipped twice a second: see `Strip.glass`
    var cards: [CGRect] = []  // where the cards are in the window, for telling whether the pointer is on one

    func closeAll(waiting: [String]) {
        pointed = nil
        hovered = nil
        pinned = nil
        typingIn = nil
        dismissed.formUnion(waiting)
    }
}

struct CardRects: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// A dot for one session: blue and breathing while it works, amber and ringing when it needs a person,
/// green when it has finished and nobody has looked yet, faint when it is idle. A little larger under the
/// pointer, and ringed when its card is pinned.
struct Dot: View {
    let state: AgentState
    var big = false
    var pinned = false
    @State private var breathe = false
    private let size: CGFloat = 11

    var body: some View {
        ZStack {
            if state == .waiting {
                Circle().stroke(state.color.opacity(breathe ? 0 : 0.8), lineWidth: 1.5)
                    .frame(width: size, height: size).scaleEffect(breathe ? 2.0 : 1)
            }
            Circle().fill(state.color)
                .frame(width: size, height: size)
                .opacity(state == .running ? (breathe ? 1 : 0.55) : 1)
            if pinned { Circle().stroke(.primary.opacity(0.7), lineWidth: 1.5).frame(width: size + 6, height: size + 6) }
        }
        .scaleEffect(big ? 1.25 : 1)
        .animation(.easeOut(duration: 0.12), value: big)
        .frame(width: Strip.row, height: Strip.row)
        .contentShape(Rectangle())
        .onAppear { animate() }
        .onChange(of: state) { animate() }
    }

    private func animate() {
        breathe = false
        guard state == .running || state == .waiting else { return }
        withAnimation(.easeInOut(duration: state == .waiting ? 1.3 : 1.8).repeatForever(autoreverses: state == .running)) {
            breathe = true
        }
    }
}

/// What is shown beside a dot: who it is, what it is doing, the last thing it said (its question, when it
/// stopped on one), and a line to answer it with. Pinned (by a click on it or on its dot), it shows all of what was said.
struct Card: View {
    let session: AgentSession
    let full: Bool
    @ObservedObject var store: Store
    @ObservedObject var open: Open
    @State private var text = ""
    @FocusState private var focused: Bool

    /// The agent writes Markdown: bold and code are shown as such, line breaks kept.
    static func rich(_ text: String) -> AttributedString {
        let keep = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: keep)) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(session.state.color).frame(width: 8, height: 8)
                Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
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
                if full {
                    ScrollView {
                        Text(Card.rich(said)).font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Strip.fullText)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Card.rich(said)).font(.system(size: 12)).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            TextField(session.state == .waiting ? "Answer…" : "Message…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .focused($focused)
                .onChange(of: focused) { open.typingIn = focused ? session.id : (open.typingIn == session.id ? nil : open.typingIn) }
                .onSubmit {
                    store.send(text, to: session)
                    text = ""
                    focused = false
                }
            if let note = store.sendNote[session.id] {
                Label(note, systemImage: note == "Delivered" ? "checkmark.circle.fill" : note == "Sending…" ? "paperplane" : "clock")
                    .font(.system(size: 11)).foregroundStyle(note == "Delivered" ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
        }
        .padding(12)
        .frame(width: Strip.cardWidth, alignment: .leading)
        .glassEffect(Strip.glass(open.tick), in: .rect(cornerRadius: 20))
        .background(GeometryReader { g in Color.clear.preference(key: CardRects.self, value: [g.frame(in: .named("strip"))]) })
        .contentShape(.rect(cornerRadius: 20))
        .onTapGesture { if !full { open.pinned = session.id } }  // a click on a card pins it, as a click on its dot does
        .onReceive(NotificationCenter.default.publisher(for: .clickedAway)) { _ in focused = false }
    }
}

/// The strip on the edge of the screen: a glass capsule of dots. A dot the pointer rests on shows its card; a
/// clicked dot keeps its card open, in full, until a click anywhere else; a session that needs a person shows
/// its card by itself, with what it asked. A single card pours out of its dot: a neck of the same glass joins
/// the strip to the card at the dot's level, and the card grows out of that point.
struct Strip: View {
    static let row: CGFloat = 23
    static let inset: CGFloat = 6  // between the strip and the edge of the screen
    static let capsulePad: CGFloat = 8
    static let cardWidth: CGFloat = 300
    static let fullText: CGFloat = 300  // the most of the screen a pinned card's text takes before it scrolls
    static let gap: CGFloat = 16  // between the strip and a card; the neck crosses it
    static let neck: CGFloat = 18  // how thick the neck is
    static let blend: CGFloat = 12  // how near two pieces of glass are before the system runs them together
    static let pour = Animation.spring(response: 0.34, dampingFraction: 0.8)
    static let width: CGFloat = inset + row + 6 + gap + cardWidth + 8
    static func height(count: Int) -> CGFloat { max(CGFloat(max(count, 1)) * row + 2 * capsulePad + 300, 560) }

    @ObservedObject var store: Store
    @ObservedObject var open: Open
    @AppStorage("edge") var edge = "right"
    @State private var cardHeight: CGFloat = 120

    /// The system's glass, told apart by a tint nobody can see. Glass picks light or dark from what is behind it
    /// only when it is drawn again, and a strip nobody touches is never drawn again: it stayed light over a
    /// window that had turned dark until the pointer came. Flipping this makes it look again by itself.
    static func glass(_ tick: Bool) -> Glass { .regular.tint(Color.gray.opacity(tick ? 0.004 : 0.008)) }

    static func key(_ s: AgentSession) -> String { "\(s.id)@\(s.since.timeIntervalSince1970)" }

    /// The cards to show: the pinned one; else the one being written in, just written to or rested on; else every session that
    /// needs a person.
    private var shown: [AgentSession] {
        if let id = open.pinned ?? open.typingIn ?? store.sent ?? open.hovered, let s = store.sessions.first(where: { $0.id == id }) {
            return [s]
        }
        return store.sessions.filter { $0.state == .waiting && !open.dismissed.contains(Strip.key($0)) }
    }

    var body: some View {
        let onRight = edge == "right"
        let cards = shown
        GlassEffectContainer(spacing: Strip.blend) {
            HStack(alignment: .center, spacing: 0) {
                if !onRight { capsule; neck(cards, onRight: onRight) }
                if !cards.isEmpty { column(cards, onRight: onRight) }
                if onRight { neck(cards, onRight: onRight); capsule }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onRight ? .trailing : .leading)
        .padding(.horizontal, Strip.inset)
        .background {
            if Store.demo != nil {  // a plain backdrop for the README's pictures, in place of the real screen
                LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.36), Color(red: 0.52, green: 0.30, blue: 0.42), Color(red: 0.93, green: 0.62, blue: 0.40)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .coordinateSpace(name: "strip")
        .onPreferenceChange(CardRects.self) { rects in
            open.cards = rects
            if let h = rects.first?.height, rects.count == 1, abs(h - cardHeight) > 1 { cardHeight = h }
        }
        .animation(Strip.pour, value: cards.map(\.id))  // the card pours out of its dot, and slides from dot to dot
        .onReceive(NotificationCenter.default.publisher(for: .clickedAway)) { _ in
            open.closeAll(waiting: store.sessions.filter { $0.state == .waiting }.map(Strip.key))
        }
        .onExitCommand { open.closeAll(waiting: []) }
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
                    Dot(state: s.state, big: open.pointed == s.id || open.pinned == s.id, pinned: open.pinned == s.id)
                        .onTapGesture { open.pinned = open.pinned == s.id ? nil : s.id }
                }
            }
        }
        .padding(.vertical, Strip.capsulePad).padding(.horizontal, 3)
        .glassEffect(Strip.glass(open.tick), in: .capsule)
    }

    /// One card sits with its middle level with its dot (kept inside the window); several stack beside the strip.
    private func column(_ cards: [AgentSession], onRight: Bool) -> some View {
        let one = cards.count == 1 ? cards[0] : nil
        let shift = one.map(level) ?? 0
        // where on the card's near edge its dot is: the middle, unless the card was kept inside the window
        let from = UnitPoint(x: onRight ? 1 : 0, y: 0.5 + ((one.map(dotLevel) ?? 0) - shift) / max(cardHeight, 1))
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { s in
                Card(session: s, full: open.pinned == s.id, store: store, open: open)
            }
        }
        .offset(y: shift)
        .transition(.scale(scale: 0.02, anchor: from).combined(with: .opacity))
    }

    /// The glass between a dot and its card: it reaches a little into both, so the three run together as one.
    private func neck(_ cards: [AgentSession], onRight: Bool) -> some View {
        ZStack {
            if cards.count == 1 {
                Color.clear
                    .frame(width: Strip.gap + 16, height: Strip.neck)
                    .glassEffect(Strip.glass(open.tick), in: .capsule)
                    .offset(y: dotLevel(of: cards[0]))
                    .transition(.scale(scale: 0.02, anchor: onRight ? .trailing : .leading).combined(with: .opacity))
            }
        }
        .frame(width: Strip.gap)
    }

    /// How far a session's dot is above or below the middle of the strip.
    private func dotLevel(of s: AgentSession) -> CGFloat {
        guard let at = store.sessions.firstIndex(of: s) else { return 0 }
        return (CGFloat(at) - CGFloat(store.sessions.count - 1) / 2) * Strip.row
    }

    private func level(of s: AgentSession) -> CGFloat {
        let room = max(0, Strip.height(count: store.sessions.count) / 2 - cardHeight / 2 - 6)
        return min(max(dotLevel(of: s), -room), room)
    }
}
