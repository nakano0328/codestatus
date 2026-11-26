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
