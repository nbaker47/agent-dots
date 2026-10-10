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

    var color: Color {
        switch self {
        case .running: Color(red: 0.30, green: 0.62, blue: 1.0)
        case .waiting: Color(red: 1.0, green: 0.66, blue: 0.20)
        case .done: Color(red: 0.25, green: 0.86, blue: 0.50)
        case .ready: Color(white: 0.62).opacity(0.75)
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
    @Published var sent: String?  // the pane a message was just sent to, for a tick in its row

    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/cmux-status")
    private var names: [String: String] = [:]  // uuid of a pane or a workspace -> its title
    private var live: Set<String>?  // the panes cmux has now; nil until cmux has answered once
    private var ticks = 0

    nonisolated static let cmux: String = {
        let bundled = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/usr/bin/env"
    }()

    func start() {
        refreshNames()
        read()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ticks += 1
                if self.ticks % 6 == 0 { self.refreshNames() }
                self.read()
            }
        }
    }

    /// The state files, one a pane. A pane cmux no longer has is left out.
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
    /// into its terminal: an idle session wakes to read it, a busy one reads it at its next step.
    func send(_ text: String, to s: AgentSession) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task.detached {
            let ok = Self.run(["agent", "message", s.id, "--from", "Nathan", "--", text]) != nil
            await MainActor.run {
                self.sent = ok ? s.id : nil
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if self.sent == s.id { self.sent = nil }
                }
            }
        }
    }

    /// Run the cmux command; its output, or nil when it failed or took more than five seconds.
    nonisolated static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmux)
        p.arguments = cmux.hasSuffix("env") ? ["cmux"] + args : args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = DispatchTime.now() + 5
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
