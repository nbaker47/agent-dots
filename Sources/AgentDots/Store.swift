import Foundation
import SwiftUI

/// What one agent session is doing, as the cmux status hook records it
/// (`~/.config/cmux/conductor-sidebar/cmux-status.sh` writes one file a pane under `~/.cache/cmux-status/`).
enum AgentState: String {
    case running, waiting, done, ready

    var label: String {
        switch self {
        case .running: "Working"
        case .waiting: "Needs you"
        case .done: "Finished"
        case .ready: "Idle"
        }
    }

    /// The system's own colours, so they follow light and dark and the contrast settings.
    var color: Color {
        switch self {
        case .running: Color(nsColor: .systemBlue)
        case .waiting: Color(nsColor: .systemOrange)
        case .done: Color(nsColor: .systemGreen)
        case .ready: Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// The order of the strip: what needs a person first, then what is working, then the rest.
    var rank: Int {
        switch self {
        case .waiting: 0
        case .done: 1
        case .running: 2
        case .ready: 3
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    let id: String  // the pane's (surface's) uuid in cmux
    let workspaceID: String
    var name: String
    var workspace: String
    var state: AgentState
    var since: Date
}

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var sent: String?  // the pane a message was just sent to: its card stays open to say how it went
    @Published var sendNote: [String: String] = [:]  // pane -> what became of the last message sent to it
    @Published var said: [String: String] = [:]  // pane -> the last thing its agent said (or asked)

    private var transcripts: [String: URL] = [:]  // pane -> its Claude Code transcript
    private var readAt: [String: Date] = [:]  // pane -> the transcript's date when it was last read

    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/cmux-status")
    private var names: [String: String] = [:]  // uuid of a pane or a workspace -> its title
    private var live: Set<String>?  // the panes cmux has now; nil until cmux has answered once
    private var ticks = 0

    /// How long after it last said or did anything a session keeps its dot.
    static let recent: TimeInterval = 600
    var holding: Set<String> = []  // the panes whose cards are open: they keep their dots while they are looked at

    nonisolated static let cmux: String = {
        let bundled = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/usr/bin/env"
    }()

    /// AGENTDOTS_DEMO=<hover|pinned|ask>: made-up sessions on a plain backdrop, for the pictures in the README.
    /// Nothing of the real screen or the real sessions is in them.
    static let demo = ProcessInfo.processInfo.environment["AGENTDOTS_DEMO"]

    private func startDemo(_ scene: String) {
        func s(_ n: Int, _ name: String, _ ws: String, _ state: AgentState, _ ago: TimeInterval) -> AgentSession {
            AgentSession(id: "demo-\(n)", workspaceID: "w", name: name, workspace: ws, state: state, since: Date().addingTimeInterval(-ago))
        }
        sessions = [
            s(0, "api: retry on 429", "backend", scene == "ask" ? .waiting : .done, 95),
            s(1, "fix flaky upload test", "backend", .running, 12),
            s(2, "landing page copy", "website", .running, 48),
            s(3, "release notes", "website", .ready, 1500),
            s(4, "database migration", "infra", .ready, 5400),
        ]
        said = [
            "demo-0": scene == "ask"
                ? "The retry is in, but two callers pass their own timeout. Should the retry respect it, or always wait the full back-off?"
                : "The retry on 429 is in and **all 212 tests pass**.\n\n- **What changed:** `fetch` now waits for the `Retry-After` header, up to three tries.\n- **Not covered:** the streaming path still fails on the first 429; say if you want that too.\n- **Next:** I can open the pull request, or keep going on the streaming path first.",
            "demo-1": "The test fails one run in six. The upload finishes before the mock server is listening; I'm moving the wait into the fixture.",
        ]
    }

    func start() {
        if let scene = Self.demo { return startDemo(scene) }
        refreshNames()
        refreshTranscripts()
        read()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ticks += 1
                if self.ticks % 6 == 0 { self.refreshNames() }
                if self.ticks % 6 == 1 { self.refreshTranscripts() }
                self.read()
                self.readSaid()
            }
        }
    }

    /// The state files, one a pane. A pane cmux no longer has is left out, and so is one that has been quiet
    /// for ten minutes (neither its state nor its transcript has changed), unless it is working or needs a person.
    private func read() {
        let fm = FileManager.default
        var found: [AgentSession] = []
        for ws in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !ws.hasPrefix(".") {
            let dir = root.appendingPathComponent(ws)
            for pane in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !pane.hasPrefix(".") {
                let file = dir.appendingPathComponent(pane)
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                    let state = AgentState(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
                else { continue }
                if let live, !live.contains(pane) { continue }
                let changed = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
                let spoke = transcripts[pane].flatMap { try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
                let quiet = Date().timeIntervalSince(max(changed, spoke ?? changed)) > Self.recent
                if quiet, state == .done || state == .ready, !holding.contains(pane), sent != pane { continue }
                found.append(
                    AgentSession(
                        id: pane, workspaceID: ws, name: names[pane] ?? "agent", workspace: names[ws] ?? "",
                        state: state, since: changed))
            }
        }
        found.sort { ($0.state.rank, $0.workspace, $0.name) < ($1.state.rank, $1.workspace, $1.name) }
        if found != sessions { sessions = found }
    }

    /// Titles of the panes and workspaces, from `cmux tree` (asked every nine seconds, off the main thread).
    private func refreshNames() {
        Task.detached {
            guard let out = Self.run(["--id-format", "both", "tree", "--all"]), !out.isEmpty else { return }
            var names: [String: String] = [:]
            var live = Set<String>()
            let pattern = try! NSRegularExpression(
                pattern: #"(workspace|surface) \S+ ([0-9A-Fa-f-]{36}) (?:\[[^\]]*\] )*"([^"]*)""#)
            for line in out.split(separator: "\n") {
                let s = String(line)
                guard let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
                let kind = String(s[Range(m.range(at: 1), in: s)!])
                let id = String(s[Range(m.range(at: 2), in: s)!]).uppercased()
                names[id] = String(s[Range(m.range(at: 3), in: s)!])
                if kind == "surface" { live.insert(id) }
            }
            guard !live.isEmpty else { return }
            let (foundNames, foundLive) = (names, live)
            await MainActor.run {
                self.names = foundNames
                self.live = foundLive
            }
        }
    }

    /// Which transcript belongs to which pane. Claude Code lists its sessions (`claude agents --json`: pid and
    /// session id); a session's process carries its pane's id in `CMUX_PANEL_ID`; the transcript is the file
    /// named after the session id under `~/.claude/projects/`.
    private func refreshTranscripts() {
        Task.detached {
            guard let out = Self.shell("/bin/zsh", ["-lc", "claude agents --json"]),
                let list = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]
            else { return }
            let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            let paneID = try! NSRegularExpression(pattern: "CMUX_PANEL_ID=([0-9A-Fa-f-]{36})")
            var found: [String: URL] = [:]
            for item in list {
                guard let pid = item["pid"] as? Int, let session = item["sessionId"] as? String,
                    let env = Self.shell("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)]),
                    let m = paneID.firstMatch(in: env, range: NSRange(env.startIndex..., in: env))
                else { continue }
                let pane = String(env[Range(m.range(at: 1), in: env)!]).uppercased()
                if let file = folders.map({ $0.appendingPathComponent("\(session).jsonl") })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) })
                {
                    found[pane] = file
                }
            }
            let result = found
            await MainActor.run { self.transcripts = result }
        }
    }

    /// The last thing each agent said, read from the end of its transcript when the file has changed: its last
    /// words, or the question it is asking when it stopped on one.
    private func readSaid() {
        for (pane, file) in transcripts {
            guard let changed = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
                readAt[pane] != changed
            else { continue }
            readAt[pane] = changed
            Task.detached {
                guard let text = Self.lastSaid(in: file) else { return }
                await MainActor.run { if self.said[pane] != text { self.said[pane] = text } }
            }
        }
    }

    nonisolated static func lastSaid(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        guard let data = try? handle.readToEnd(), let tail = String(data: data, encoding: .utf8) else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                row["type"] as? String == "assistant", row["isSidechain"] as? Bool != true,
                let message = row["message"] as? [String: Any], let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content.reversed() {
                if block["type"] as? String == "tool_use", block["name"] as? String == "AskUserQuestion",
                    let input = block["input"] as? [String: Any], let questions = input["questions"] as? [[String: Any]],
                    let question = questions.first?["question"] as? String
                {
                    return question
                }
                if block["type"] as? String == "text", let text = block["text"] as? String,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8000))
                }
            }
        }
        return nil
    }

    /// Bring cmux forward on this session's pane. A finished session counts as seen from then on.
    func jump(to s: AgentSession) {
        Task.detached {
            _ = Self.run(["select-workspace", "--workspace", s.workspaceID])
            _ = Self.run(["focus-panel", "--panel", s.id, "--workspace", s.workspaceID])
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-b", "com.cmuxterm.app"]
            try? open.run()
            if s.state == .done {
                let hook = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/cmux/conductor-sidebar/cmux-status.sh").path
                let seen = Process()
                seen.executableURL = URL(fileURLWithPath: "/bin/bash")
                seen.arguments = [hook, "seen", s.id]
                try? seen.run()
            }
        }
    }

    /// Say something to the agent in that pane. cmux hands it over through the agent's hooks, never by typing
    /// the message into its terminal, and the card says what became of it.
    func send(_ text: String, to s: AgentSession) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sent = s.id
        sendNote[s.id] = "Sending…"
        Task.detached {
            let note = Self.deliver(text, to: s)
            await MainActor.run {
                self.sendNote[s.id] = note
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    guard self.sendNote[s.id] == note else { return }
                    self.sendNote[s.id] = nil
                    if self.sent == s.id { self.sent = nil }
                }
            }
        }
    }

    /// Hand the message to cmux and follow it until the agent has it. cmux only queues a message: an idle
    /// session is woken by a helper its last stop left waiting, and that helper is gone a day after the stop
    /// (and for a session started before cmux had it), so a message to a long-idle session stayed queued until
    /// somebody typed in its pane (2026-10-11). When the message is still queued after four seconds and the
    /// session is not working, its pane is given a one-line prompt: submitting it is what makes cmux hand the
    /// queued message over. cmux refuses that when the pane holds a half-typed prompt or an open question.
    nonisolated static func deliver(_ text: String, to s: AgentSession) -> String {
        guard let out = run(["agent", "message", s.id, "--from", NSFullUserName(), "--json", "--", text]),
            let made = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            let id = made["id"] as? String
        else { return "Not sent: cmux did not take it" }
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.5)
            if !queued(id, in: s.id) { return "Delivered" }
        }
        if s.state == .running { return "Queued: read when this turn ends" }
        let pane = ["--workspace", s.workspaceID, "--surface", s.id]
        guard run(["send"] + pane + ["--paste", "--", "A message for you is waiting in cmux: read it and answer it."]) != nil
        else { return "Queued: its pane is busy with a prompt, open it" }
        _ = run(["send"] + pane + ["--force", "--", "\\n"])
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.5)
            if !queued(id, in: s.id) { return "Delivered" }
        }
        return "Queued: open its pane"
    }

    /// Whether cmux still holds that message for the pane, unread by its agent.
    nonisolated static func queued(_ id: String, in pane: String) -> Bool {
        guard let out = run(["agent", "inbox", "--surface", pane, "--state", "queued", "--limit", "50", "--json"]),
            let all = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            let rows = all["messages"] as? [[String: Any]]
        else { return true }
        return rows.contains { $0["id"] as? String == id }
    }

    /// Run the cmux command; its output, or nil when it failed or took more than twelve seconds.
    nonisolated static func run(_ args: [String]) -> String? {
        shell(cmux, cmux.hasSuffix("env") ? ["cmux"] + args : args)
    }

    nonisolated static func shell(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = DispatchTime.now() + 12
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
