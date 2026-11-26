import Testing
import Foundation
@testable import CodeStatusCore
@testable import HookCore

/// Fork addition. The Claude desktop app runs Claude Code sessions itself. The
/// hook fires for them as for a terminal, but the app starts and stops their
/// processes on its own, warms a spare process for the next new session, and
/// exports no TERM_PROGRAM. See ``ClaudeDesktop``.
@Suite("Claude Code sessions in the Claude desktop app")
struct ClaudeDesktopTests {

    private let host = "local_1bab3871-f5c2-44d4-a11a-5ecc68ae251b"
    private var rowID: SessionID { SessionID.provider(.claudeCode, host) }

    private func desktop(
        _ id: String, _ event: String,
        session: String = "3ed159c1-103e-47d3-93ab-e05e9ff5ee95",
        pid: Int = 16403,
        cwd: String = "/Users/x/proj",
        extra: String = ""
    ) throws -> AgentEvent {
        let json = #"{"v":1,"id":"\#(id)","provider":"claudeCode","hook_event_name":"\#(event)","#
            + #""ppid":\#(pid),"entrypoint":"claude-desktop","host_session_id":"\#(host)","#
            + #""session_id":"\#(session)","cwd":"\#(cwd)"\#(extra)}"#
        return try EventWireDecoder.decode(line: Data(json.utf8))
    }

    // MARK: - Hook

    @Test("The hook sends what launched the agent and the desktop app's id for the session")
    func hookWritesTheFields() {
        let out = buildEventLine(
            envelope: EventEnvelope(
                provider: "claudeCode",
                eventID: Array("1-2-0".utf8),
                timestampSeconds: 1_770_000_000,
                timestampMicroseconds: 0,
                parentPID: 4242,
                entrypoint: Array("claude-desktop".utf8),
                hostSessionID: Array(host.utf8)
            ),
            fields: []
        )
        let line = String(decoding: out, as: UTF8.self)
        #expect(line.contains(#""entrypoint":"claude-desktop""#))
        #expect(line.contains(#""host_session_id":"\#(host)""#))
    }

    @Test("A terminal session's line carries neither")
    func terminalLineIsUnchanged() {
        let out = buildEventLine(
            envelope: EventEnvelope(
                provider: "claudeCode", eventID: Array("1".utf8),
                timestampSeconds: 0, timestampMicroseconds: 0, parentPID: 1
            ),
            fields: []
        )
        let line = String(decoding: out, as: UTF8.self)
        #expect(!line.contains("entrypoint"))
        #expect(!line.contains("host_session_id"))
    }

    // MARK: - Wire

    @Test("A desktop session is hosted by Claude")
    func decodesDesktop() throws {
        let event = try desktop("a", "Stop")
        #expect(event.entrypoint == "claude-desktop")
        #expect(event.hostSessionID == host)
        #expect(event.hostApplication == .claudeDesktop)
        #expect(event.isFromClaudeDesktop)
    }

    @Test("A host session id in any other shape is dropped, since it ends up in a path and a link", arguments: [
        "local_../../etc/passwd",
        "session_01JRWGj9Q8xCNND2nBozpE67",
        "local_",
        "local_abc?x=1",
        "local_" + String(repeating: "a", count: 65),
    ])
    func rejectsOtherHostIDs(_ candidate: String) throws {
        let json = #"{"v":1,"id":"a","provider":"claudeCode","hook_event_name":"Stop","#
            + #""entrypoint":"claude-desktop","host_session_id":"\#(candidate)","session_id":"s"}"#
        let event = try EventWireDecoder.decode(line: Data(json.utf8))
        #expect(event.hostSessionID == nil)
        #expect(event.hostApplication == .unknown)
    }

    @Test("Only Claude Code can claim the desktop app")
    func otherProvidersIgnoreTheFields() throws {
        let json = #"{"v":1,"id":"a","provider":"codex","hook_event_name":"Stop","#
            + #""entrypoint":"claude-desktop","host_session_id":"\#(host)","session_id":"s"}"#
        let event = try EventWireDecoder.decode(line: Data(json.utf8))
        #expect(event.entrypoint == nil)
        #expect(event.hostSessionID == nil)
    }

    @Test("A terminal still wins over nothing: the CLI entrypoint leaves TERM_PROGRAM in charge")
    func cliIsNotDesktop() throws {
        let json = #"{"v":1,"id":"a","provider":"claudeCode","hook_event_name":"Stop","#
            + #""entrypoint":"cli","term_program":"Apple_Terminal","session_id":"s"}"#
        let event = try EventWireDecoder.decode(line: Data(json.utf8))
        #expect(event.hostApplication == .terminal)
    }

    // MARK: - Lifecycle

    @Test("When the app stops the process, the row stays, idle, without its process")
    func pauseKeepsTheRow() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "UserPromptSubmit"))
        _ = registry.ingest(try desktop("2", "Stop"))
        #expect(registry[rowID]?.state == .free)

        _ = registry.ingest(try desktop("3", "SessionEnd", extra: #","end_reason":"other""#))
        _ = registry.ingest(ProcessWatcher.exitEvent(pid: 16403, startTime: 7, provider: .claudeCode))

        let session = try #require(registry[rowID])
        #expect(session.state == .free)
        #expect(session.pid == nil)
        #expect(session.isPausedDesktopSession)
        #expect(registry.visible.map(\.id) == [rowID])
    }

    @Test("Stopped mid-turn, it goes idle, and that is not announced as finished")
    func pauseMidTurn() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "UserPromptSubmit"))
        let results = registry.ingest(ProcessWatcher.exitEvent(pid: 16403, startTime: 7, provider: .claudeCode))

        #expect(registry[rowID]?.state == .free)
        let transition = try #require(results.compactMap { result -> Transition? in
            if case .sessionChanged(let t) = result { return t } else { return nil }
        }.first)
        #expect(transition.from == .busy)
        #expect(transition.source == .process)
    }

    @Test("Opening it again resumes the same row with the new process")
    func resume() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "Stop"))
        _ = registry.ingest(try desktop("2", "SessionEnd"))
        _ = registry.ingest(try desktop("3", "SessionStart", pid: 20001, extra: #","source":"resume""#))
        _ = registry.ingest(try desktop("4", "UserPromptSubmit", pid: 20001, extra: #","prompt_id":"p2""#))

        let session = try #require(registry[rowID])
        #expect(session.state == .busy)
        #expect(session.pid == 20001)
        #expect(registry.all.count == 1)
    }

    @Test("The warm spare is hidden, and claiming it keeps one row under its new agent id")
    func spare() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop(
            "1", "SessionStart", session: "spare-agent-id", cwd: "/Users/x/.claude/spares/spare-sEphHn"
        ))
        #expect(registry[rowID] != nil)
        #expect(registry.visible.isEmpty)
        #expect(registry.counts().isEmpty)

        _ = registry.ingest(try desktop("2", "UserPromptSubmit", extra: #","prompt_id":"p1""#))
        let session = try #require(registry[rowID])
        #expect(session.providerSessionID == "3ed159c1-103e-47d3-93ab-e05e9ff5ee95")
        #expect(session.cwd == "/Users/x/proj")
        #expect(registry.visible.map(\.id) == [rowID])
        #expect(registry.all.count == 1)
    }

    @Test("A row saved under the agent's session id before this fork version gives way to the new one")
    func retiresLegacyRow() throws {
        let agentID = "3ed159c1-103e-47d3-93ab-e05e9ff5ee95"
        var old = AgentSession(
            id: SessionID.provider(.claudeCode, agentID), provider: .claudeCode,
            state: .reconnecting, now: Date(), sourceAdapter: "claudeCodeHook"
        )
        old.providerSessionID = agentID
        old.hasHookEvidence = true
        var registry = SessionRegistry()
        registry.restore([old])

        _ = registry.ingest(try desktop("1", "PreToolUse", extra: #","tool_name":"Bash""#))

        #expect(registry.all.map(\.id) == [rowID])
    }

    @Test("A process exit reaches every row on that process, not only the last one indexed")
    func exitReachesEveryRow() throws {
        var registry = SessionRegistry()
        // Process discovery found the agent first; then its hook arrived.
        _ = registry.adopt(provider: .claudeCode, pid: 4242, startTime: 9, now: Date())
        let terminal = #"{"v":1,"id":"h","provider":"claudeCode","hook_event_name":"Stop","#
            + #""ppid":4242,"session_id":"term-1"}"#
        _ = registry.ingest(try EventWireDecoder.decode(line: Data(terminal.utf8)))
        #expect(registry.all.count == 2)

        _ = registry.ingest(ProcessWatcher.exitEvent(pid: 4242, startTime: 9, provider: .claudeCode))

        #expect(registry.all.allSatisfy { $0.state == .ended })
    }

    @Test("A wake leaves a paused row alone: there is no process to re-verify")
    func wakeSkipsPaused() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "Stop"))
        _ = registry.ingest(try desktop("2", "SessionEnd"))
        registry.markAllReconnecting(now: Date())
        #expect(registry[rowID]?.state == .free)
    }

    @Test("A restart puts saved rows back, and keeps a desktop row whose process went meanwhile")
    func restore() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "Stop"))
        let saved = try #require(registry[rowID])

        let live = StatePersistence.filterToLiveSessions([saved], isAlive: { _, _ in false })
        #expect(live.count == 1)

        var restarted = SessionRegistry()
        restarted.restore(live)
        #expect(restarted[rowID]?.hostSessionID == host)
        #expect(restarted.visible.count == 1)
    }

    @Test("The desktop app's id survives a restart")
    func persistence() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "Stop"))
        let data = try JSONEncoder().encode(try #require(registry[rowID]))
        let restored = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(restored.hostSessionID == host)
        #expect(restored.hostApplication == .claudeDesktop)
    }

    // MARK: - Opening

    @Test("A click opens the session through the app's own deep link")
    func continueURL() {
        #expect(ClaudeDesktop.continueURL(hostSessionID: host)?.absoluteString
            == "claude://code/continue?session=\(host)")
        #expect(ClaudeDesktop.continueURL(hostSessionID: "local_a&b") == nil)
    }

    // MARK: - Holding back notifications for the session on screen

    @Test("The last focus change in the app's log says which session is on screen")
    func focusFromLog() {
        let log = """
        2026-11-27 01:07:51 [info] [CCD] LocalSessions.setFocusedSession: sessionId=local_3cd58d1d-9061-41ba-bc7e-bffa1c0a9c25
        2026-11-27 01:08:08 [info] [CCD] LocalSessions.setFocusedSession: sessionId=session_01JRWGj6bZCxie3VMxVXXBin
        2026-11-27 01:08:09 [info] handoff: publishing session_01JRWGj6bZCxie3VMxVXXBin

        """
        #expect(ClaudeDesktop.focus(inLog: log) == .session("session_01JRWGj6bZCxie3VMxVXXBin"))
        #expect(ClaudeDesktop.focus(inLog: log + "x [CCD] LocalSessions.setFocusedSession: sessionId=null\n") == .nothing)
        #expect(ClaudeDesktop.focus(inLog: "x LocalSessions.setFocusedSession: sessionId=../etc\n") == nil)
        #expect(ClaudeDesktop.focus(inLog: "nothing here") == nil)
    }

    private var claudeApp: String? { HostApplication.claudeDesktop.bundleIdentifier }

    @Test("With the app in front, only the session it shows is held back")
    func onlyTheShownSession() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "Stop"))
        let session = try #require(registry[rowID])

        #expect(ClaudeDesktop.isUserLooking(at: session, frontmostBundleIdentifier: claudeApp, focus: .session(host)) == true)
        #expect(ClaudeDesktop.isUserLooking(
            at: session, frontmostBundleIdentifier: claudeApp,
            focus: .session("local_0bfa7851-9e71-4c3a-a921-82f4544940bd")
        ) == false)
        #expect(ClaudeDesktop.isUserLooking(at: session, frontmostBundleIdentifier: claudeApp, focus: .nothing) == false)
        #expect(ClaudeDesktop.isUserLooking(at: session, frontmostBundleIdentifier: "com.apple.Terminal", focus: .session(host)) == false)
        // The log could not tell: the app being in front decides, as before.
        #expect(ClaudeDesktop.isUserLooking(at: session, frontmostBundleIdentifier: claudeApp, focus: nil) == true)
    }

    @Test("A session in its own window is on screen whatever the main window shows")
    func popouts() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "Stop"))
        let session = try #require(registry[rowID])
        let file = Data(#"{"version":2,"windows":[{"kind":"session","key":"\#(host)","view":"{}"},{"kind":"session","key":"../x"},{"kind":"other","key":"session_01Abc"}]}"#.utf8)
        let popouts = ClaudeDesktop.popoutSessions(in: file)
        #expect(popouts == [host])
        #expect(ClaudeDesktop.isUserLooking(
            at: session, frontmostBundleIdentifier: claudeApp,
            focus: .session("session_01JRWGj6bZCxie3VMxVXXBin"), popouts: popouts
        ) == true)
        #expect(ClaudeDesktop.isUserLooking(
            at: session, frontmostBundleIdentifier: "com.google.Chrome", focus: .nothing, popouts: popouts
        ) == false)
        #expect(ClaudeDesktop.popoutSessions(in: Data("nope".utf8)).isEmpty)
    }

    @Test("A cloud session on screen in the app is held back too; a terminal session is not judged here")
    func cloudAndOthers() throws {
        var registry = SessionRegistry()
        let cloud = CloudSessionReader.Session(
            id: "session_01Abc", title: nil, repository: nil, state: .busy, isUnread: true, updatedAt: nil
        )
        _ = registry.syncCloudSessions([cloud], now: Date())
        let row = try #require(registry[SessionID.provider(.claudeCode, "session_01Abc")])
        #expect(ClaudeDesktop.isUserLooking(at: row, frontmostBundleIdentifier: claudeApp, focus: .session("session_01Abc")) == true)
        #expect(ClaudeDesktop.isUserLooking(at: row, frontmostBundleIdentifier: claudeApp, focus: nil) == false)

        let terminal = AgentSession(id: SessionID("t"), provider: .claudeCode, now: Date(), sourceAdapter: "x")
        #expect(ClaudeDesktop.isUserLooking(at: terminal, frontmostBundleIdentifier: claudeApp, focus: .nothing) == nil)
    }

    // MARK: - The desktop app's record

    private func writeRecord(_ json: String, id: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("account/org", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent((id ?? host) + ".json"))
        return root
    }

    @Test("Still unseen while not switched to since the turn ended unseen")
    func stillUnseen() throws {
        let root = try writeRecord(#"{"isArchived":false,"lastFocusedAt":1000,"lastTurnEdgeAt":2000,"title":"x"}"#)
        let lookup = DesktopSessionReader(root: root).lookup(hostSessionID: host)
        guard case .found(let record) = lookup else { Issue.record("not found: \(lookup)"); return }
        #expect(record.isStillUnseen(since: Date(timeIntervalSince1970: 2)))
        #expect(record.lastTurnEndedAt == Date(timeIntervalSince1970: 2))
    }

    @Test("Switched to since, archived, or never marked: seen", arguments: [
        (#"{"isArchived":false,"lastFocusedAt":3000,"lastTurnEdgeAt":2000}"#, 2.0 as Double?),
        (#"{"isArchived":true,"lastFocusedAt":1000,"lastTurnEdgeAt":2000}"#, 2.0),
        // The app's own record says unread, but CodeStatus saw the user
        // watching when it ended, so nothing was marked.
        (#"{"isArchived":false,"lastFocusedAt":1000,"lastTurnEdgeAt":2000}"#, nil),
    ])
    func seen(_ json: String, _ since: Double?) throws {
        let root = try writeRecord(json)
        guard case .found(let record) = DesktopSessionReader(root: root).lookup(hostSessionID: host) else {
            Issue.record("not found"); return
        }
        #expect(!record.isStillUnseen(since: since.map { Date(timeIntervalSince1970: $0) }))
    }

    // MARK: - Remembering whether a turn ended unseen

    private func transition(_ from: AgentState, _ to: AgentState, source: EventSource = .hook, at: TimeInterval = 50) -> Transition {
        Transition(
            sessionID: rowID, from: from, to: to, eventID: EventID("t"), source: source,
            confidence: .high, occurredAt: Date(timeIntervalSince1970: at), reason: "test"
        )
    }

    @Test("A turn that ends while the user looks elsewhere is marked; one they watch is not")
    func marksUnseenEnds() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "Stop"))
        let session = try #require(registry[rowID])

        let unseen = try #require(ClaudeDesktop.noteTurnChange(session, transition: transition(.busy, .free), userWasLooking: false))
        #expect(unseen.unseenSince == Date(timeIntervalSince1970: 50))
        #expect(ClaudeDesktop.noteTurnChange(session, transition: transition(.busy, .free), userWasLooking: true) == nil)

        let waiting = try #require(ClaudeDesktop.noteTurnChange(session, transition: transition(.busy, .waitingForApproval), userWasLooking: false))
        #expect(waiting.unseenSince != nil)

        // The next prompt is the user back at it.
        let cleared = try #require(ClaudeDesktop.noteTurnChange(unseen, transition: transition(.free, .busy), userWasLooking: false))
        #expect(cleared.unseenSince == nil)

        // The app pausing it is not a turn ending.
        #expect(ClaudeDesktop.noteTurnChange(session, transition: transition(.busy, .free, source: .process), userWasLooking: false) == nil)
    }

    @Test("The mark survives the pause and a restart")
    func markSurvives() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try desktop("1", "UserPromptSubmit"))
        var session = try #require(registry[rowID])
        session.unseenSince = Date(timeIntervalSince1970: 50)
        registry.update(session)
        _ = registry.ingest(ProcessWatcher.exitEvent(pid: 16403, startTime: 7, provider: .claudeCode))
        let paused = try #require(registry[rowID])
        #expect(paused.isPausedDesktopSession)
        #expect(paused.unseenSince == Date(timeIntervalSince1970: 50))

        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(paused))
        #expect(restored.unseenSince == Date(timeIntervalSince1970: 50))
    }

    @Test("No file is missing; a broken one is unreadable, never read")
    func missingAndUnreadable() throws {
        let root = try writeRecord("{not json")
        let reader = DesktopSessionReader(root: root)
        #expect(reader.lookup(hostSessionID: host) == .unreadable)
        #expect(reader.lookup(hostSessionID: "local_0bfa7851-9e71-4c3a-a921-82f4544940bd") == .missing)
        #expect(reader.lookup(hostSessionID: "local_../../x") == .missing)
    }
}
