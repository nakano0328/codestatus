import Testing
import Foundation
@testable import CodeStatusCore

/// Fork addition. After a restart or a wake every session is `reconnecting`
/// until re-verified; Claude Code's own per-process record is what re-verifies
/// an idle one, which may not send a hook for hours.
@Suite("Re-verifying Claude Code sessions from ~/.claude/sessions")
struct ClaudeSessionFileTests {

    private func file(_ json: String, pid: pid_t = 70650) -> ClaudeSessionFile? {
        ClaudeSessionFile.parse(Data(json.utf8), expectedPID: pid)
    }

    @Test("Each status Claude Code writes maps to a state", arguments: [
        (#""status":"busy""#, AgentState.busy),
        (#""status":"idle""#, .free),
        (#""status":"shell""#, .free),
        (#""status":"waiting","waitingFor":"permission prompt""#, .waitingForApproval),
        (#""status":"waiting","waitingFor":"input needed""#, .waitingForInput),
    ])
    func states(_ fields: String, _ expected: AgentState) throws {
        let parsed = try #require(file(#"{"pid":70650,"sessionId":"s",\#(fields),"statusUpdatedAt":1795708492435}"#))
        #expect(parsed.state == expected)
        #expect(parsed.statusUpdatedAt == Date(timeIntervalSince1970: 1_795_708_492.435))
    }

    @Test("An unknown status leaves the row alone, and a file for another pid is not this one")
    func refusesWhatItDoesNotKnow() {
        #expect(file(#"{"pid":70650,"sessionId":"s","status":"dreaming"}"#)?.state == nil)
        #expect(file(#"{"pid":1,"sessionId":"s","status":"idle"}"#) == nil)
        #expect(file("not json") == nil)
    }

    private func reconnectingSession() -> AgentSession {
        var session = AgentSession(
            id: SessionID.provider(.claudeCode, "s"), provider: .claudeCode,
            state: .reconnecting, now: Date(), sourceAdapter: "claudeCodeHook"
        )
        session.pid = 70650
        session.providerSessionID = "s"
        session.hasHookEvidence = true
        session.previousState = .busy
        return session
    }

    @Test("The file matches its row by agent session id or by desktop host id, on the same pid")
    func matching() throws {
        var session = reconnectingSession()
        let byAgent = try #require(file(#"{"pid":70650,"sessionId":"s","status":"idle"}"#))
        #expect(byAgent.describes(session))

        session.providerSessionID = "old"
        session.hostSessionID = "local_1bab3871-f5c2-44d4-a11a-5ecc68ae251b"
        let byHost = try #require(file(#"{"pid":70650,"sessionId":"new","hostSessionId":"local_1bab3871-f5c2-44d4-a11a-5ecc68ae251b","status":"idle"}"#))
        #expect(byHost.describes(session))

        let other = try #require(file(#"{"pid":70650,"sessionId":"someone-else","status":"idle"}"#))
        #expect(!other.describes(session))
    }

    private let desktopFile = #"{"pid":16344,"sessionId":"fabbed23","hostSessionId":"local_7c552b77-49be-430c-9509-6ec3285e9ffb","entrypoint":"claude-desktop","cwd":"/Users/x/proj","status":"idle","statusUpdatedAt":1795582293685}"#

    @Test("A desktop session found only as a process becomes its own row, named by its record")
    func promotesDesktopProcess() throws {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .claudeCode, pid: 16344, startTime: 9, now: Date())
        let processRow = SessionID.process(.claudeCode, pid: 16344, startTime: 9)
        #expect(registry.unreported.count == 1)

        let parsed = try #require(ClaudeSessionFile.parse(Data(desktopFile.utf8), expectedPID: 16344))
        let results = registry.promoteDesktopProcess(processRow, using: parsed, now: Date())

        let id = SessionID.provider(.claudeCode, "local_7c552b77-49be-430c-9509-6ec3285e9ffb")
        #expect(results == [.sessionRemoved(processRow), .sessionAdded(id)])
        let row = try #require(registry[id])
        #expect(row.state == .free)
        #expect(row.isDesktopSession)
        #expect(row.pid == 16344)
        #expect(row.processStartTime == 9)
        #expect(row.providerSessionID == "fabbed23")
        #expect(registry.unreported.isEmpty)
        #expect(registry.visible.map(\.id) == [id])
    }

    @Test("A terminal session's record is not enough for a row, and a hook row wins over the process copy")
    func promotionLimits() throws {
        var registry = SessionRegistry()
        _ = registry.adopt(provider: .claudeCode, pid: 16344, startTime: 9, now: Date())
        let processRow = SessionID.process(.claudeCode, pid: 16344, startTime: 9)
        let terminal = try #require(ClaudeSessionFile.parse(Data(
            #"{"pid":16344,"sessionId":"t","entrypoint":"cli","status":"idle"}"#.utf8), expectedPID: 16344))
        #expect(registry.promoteDesktopProcess(processRow, using: terminal, now: Date()).isEmpty)

        let hook = #"{"v":1,"id":"h","provider":"claudeCode","hook_event_name":"Stop","ppid":16344,"entrypoint":"claude-desktop","host_session_id":"local_7c552b77-49be-430c-9509-6ec3285e9ffb","session_id":"fabbed23"}"#
        _ = registry.ingest(try EventWireDecoder.decode(line: Data(hook.utf8)))
        let parsed = try #require(ClaudeSessionFile.parse(Data(desktopFile.utf8), expectedPID: 16344))
        #expect(registry.promoteDesktopProcess(processRow, using: parsed, now: Date()) == [.sessionRemoved(processRow)])
        #expect(registry.all.count == 1)
    }

    @Test("A reconnecting row settles quietly; anything else is left as it is")
    func reverify() throws {
        var registry = SessionRegistry()
        registry.restore([reconnectingSession()])
        let id = SessionID.provider(.claudeCode, "s")
        let since = Date(timeIntervalSince1970: 1_795_708_492)

        let results = registry.reverify(id, as: .free, since: since, now: Date())
        #expect(results == [.sessionRefreshed(id)])
        #expect(registry[id]?.state == .free)
        #expect(registry[id]?.stateChangedAt == since)
        #expect(registry.visible.map(\.id) == [id])

        // Already settled: a later file read changes nothing.
        #expect(registry.reverify(id, as: .busy, since: nil, now: Date()).isEmpty)
        #expect(registry[id]?.state == .free)
    }
}
