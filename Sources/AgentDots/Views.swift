import ServiceManagement
import SwiftUI

/// A dot for one session: blue and breathing while it works, amber and ringing when it needs a person,
/// green when it has finished and nobody has looked yet, faint when it is idle.
struct Dot: View {
    let state: AgentState
    var size: CGFloat = 11
    @State private var breathe = false

    var body: some View {
        ZStack {
            if state == .waiting {
                Circle().stroke(state.color.opacity(breathe ? 0 : 0.8), lineWidth: 1.5)
                    .frame(width: size, height: size).scaleEffect(breathe ? 2.2 : 1)
            }
            Circle().fill(state.color)
                .frame(width: size, height: size)
                .opacity(state == .running ? (breathe ? 1 : 0.45) : 1)
                .shadow(color: state == .ready ? .clear : state.color.opacity(0.9), radius: state == .waiting ? 6 : 4)
        }
        .frame(width: size + 10, height: size + 10)
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

struct Row: View {
    let session: AgentSession
    @ObservedObject var store: Store
    @Binding var writingTo: String?
    @State private var text = ""
    @State private var over = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Dot(state: session.state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.state.label).foregroundStyle(session.state == .ready ? .secondary : session.state.color)
                        Text("·")
                        Text(session.since, style: .relative)
                        if !session.workspace.isEmpty { Text("· \(session.workspace)").lineLimit(1) }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if store.sent == session.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    writingTo = writingTo == session.id ? nil : session.id
                    typing = writingTo == session.id
                } label: {
                    Image(systemName: "bubble.left.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(writingTo == session.id ? .primary : .tertiary)
                .help("Send this agent a message")
            }
            if writingTo == session.id {
                TextField("Message \(session.name)…", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.10), in: Capsule())
                    .focused($typing)
                    .onSubmit {
                        store.send(text, to: session)
                        text = ""
                        writingTo = nil
                    }
                    .onAppear { typing = true }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(over ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { over = $0 }
        .onTapGesture { store.jump(to: session) }
        .help("Open \(session.name) in cmux")
    }
}

/// The strip on the edge of the screen: a glass capsule of dots, which opens into the list when the pointer
/// is over it and closes again when it leaves (unless a message is being written).
struct Strip: View {
    @ObservedObject var store: Store
    @AppStorage("edge") var edge = "right"
    @State private var open = false
    @State private var writingTo: String?
    let resize: (_ open: Bool, _ count: Int) -> Void

    var body: some View {
        let onRight = edge == "right"
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if !onRight { capsule }
                if open { list.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: onRight ? .trailing : .leading))) }
                if onRight { capsule }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onRight ? .trailing : .leading)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                resize(true, store.sessions.count)
                withAnimation(.spring(duration: 0.28)) { open = true }
            } else if writingTo == nil {
                withAnimation(.easeOut(duration: 0.18)) { open = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { if !open { resize(false, store.sessions.count) } }
            }
        }
        .onChange(of: store.sessions.count) { resize(open, store.sessions.count) }
        .onChange(of: edge) { resize(open, store.sessions.count) }
        .onAppear {
            // AGENTDOTS_OPEN=1 starts with the list open, for looking at it without a pointer over it
            let pinned = ProcessInfo.processInfo.environment["AGENTDOTS_OPEN"] == "1"
            open = pinned
            resize(pinned, store.sessions.count)
            if pinned { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { resize(true, store.sessions.count) } }
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
        VStack(spacing: 2) {
            if store.sessions.isEmpty {
                Dot(state: .ready)
            } else {
                ForEach(store.sessions) { s in
                    Dot(state: s.state).onTapGesture { store.jump(to: s) }.help("\(s.name): \(s.state.label)")
                }
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            let needs = store.sessions.filter { $0.state == .waiting || $0.state == .done }.count
            HStack {
                Text("Agents").font(.system(size: 12, weight: .bold))
                Spacer()
                Text(needs == 0 ? "\(store.sessions.count) open" : "\(needs) for you")
                    .font(.system(size: 11)).foregroundStyle(needs == 0 ? .secondary : AgentState.waiting.color)
            }
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            if store.sessions.isEmpty {
                Text("No agent sessions in cmux right now.").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
            }
            ForEach(store.sessions) { s in Row(session: s, store: store, writingTo: $writingTo) }
        }
        .padding(8)
        .frame(width: 290)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onChange(of: writingTo) { resize(open, store.sessions.count) }
    }
}
