import Testing
import Foundation
@testable import CodeStatusCore

/// Fork addition. ChatGPT conversations reach the daemon from the ChatGPT
/// Unread browser extension through its native messaging host, which writes
/// the same one-line wire format as the hook. They have no process, so every
/// check that judges a session by its process has to leave them alone.
@Suite("ChatGPT sessions from the browser extension")
struct ChatGPTTests {

    private let url = "https://chatgpt.com/c/6b026225-1cc0-83ec-827d-9c159d1194d4#codestatus"

    private func line(_ id: String, _ event: String, _ extra: String = "") -> Data {
        Data((#"{"v":1,"id":"\#(id)","provider":"chatgpt","hook_event_name":"\#(event)","#
            + #""session_id":"chatgpt-c:abc-1","turn_id":"chatgpt-c:abc-1"\#(extra)}"#).utf8)
    }

    private func decode(_ id: String, _ event: String, _ extra: String = "") throws -> AgentEvent {
        try EventWireDecoder.decode(line: line(id, event, extra))
    }

    private func chatGPTSession(state: AgentState, hasHookEvidence: Bool = true) -> AgentSession {
        var session = AgentSession(
            id: SessionID.provider(.chatGPT, "chatgpt-c:abc-1"), provider: .chatGPT,
            now: Date(timeIntervalSince1970: 0), sourceAdapter: "test"
        )
        session.state = state
        session.hasHookEvidence = hasHookEvidence
        return session
    }

    // MARK: - Wire

    @Test("The native host's line decodes as ChatGPT, hosted in Chrome")
    func decodesChatGPT() throws {
        let event = try decode("a", "Stop", #","conversation_url":"\#(url)","title":"  日本の\n歴史要約  ""#)
        #expect(event.provider == .chatGPT)
        #expect(event.kind == .stop)
        #expect(event.providerSessionID == "chatgpt-c:abc-1")
        #expect(event.hostApplication == .chrome)
        #expect(event.conversationURL == url)
        #expect(event.title == "日本の 歴史要約")
        #expect(event.pid == nil)
    }

    @Test("Only https ChatGPT addresses are kept, because a click opens them", arguments: [
        "http://chatgpt.com/c/abc",
        "https://evil.example/c/abc",
        "https://chatgpt.com.evil.example/c/abc",
        "javascript:alert(1)",
        "file:///Applications/Calculator.app",
        "",
    ])
    func rejectsOtherURLs(_ candidate: String) throws {
        let event = try decode("a", "Stop", #","conversation_url":"\#(candidate)""#)
        #expect(event.conversationURL == nil)
    }

    @Test("The old ChatGPT host is accepted too")
    func acceptsOpenAIHost() throws {
        let event = try decode("a", "Stop", #","conversation_url":"https://chat.openai.com/c/abc""#)
        #expect(event.conversationURL == "https://chat.openai.com/c/abc")
    }

    @Test("Another provider cannot carry a URL or a title in")
    func otherProvidersIgnoreTheFields() throws {
        let json = #"{"v":1,"id":"a","provider":"claudeCode","hook_event_name":"Stop","#
            + #""session_id":"s","conversation_url":"https://chatgpt.com/c/x","title":"hi"}"#
        let event = try EventWireDecoder.decode(line: Data(json.utf8))
        #expect(event.conversationURL == nil)
        #expect(event.title == nil)
    }

    @Test("A title is capped, so a sender cannot balloon the HUD")
    func titleIsCapped() throws {
        let long = String(repeating: "あ", count: 1_000)
        let event = try decode("a", "Stop", #","title":"\#(long)""#)
        #expect(event.title?.count == EventWireDecoder.chatGPTTitleLimit)
    }

    // MARK: - Lifecycle

    @Test("Busy, then free with its name leading the row, renamed, then gone")
    func lifecycle() throws {
        var registry = SessionRegistry()
        let id = SessionID.provider(.chatGPT, "chatgpt-c:abc-1")

        _ = registry.ingest(try decode("1", "UserPromptSubmit", #","title":"新しいチャット""#))
        #expect(registry[id]?.state == .busy)

        _ = registry.ingest(try decode("2", "Stop", #","title":"新しいチャット","conversation_url":"\#(url)""#))
        var session = try #require(registry[id])
        #expect(session.state == .free)
        #expect(session.hostApplication == .chrome)
        #expect(session.conversationURL == url)
        #expect(session.primaryLabel == "新しいチャット")
        #expect(session.secondaryLabel == nil)

        // ChatGPT names a new chat a moment after answering; the extension
        // resends Stop with the name, which must land on the same row.
        _ = registry.ingest(try decode("3", "Stop", #","title":"日本の歴史要約""#))
        session = try #require(registry[id])
        #expect(session.state == .free)
        #expect(session.primaryLabel == "日本の歴史要約")
        #expect(session.conversationURL == url)

        _ = registry.ingest(try decode("4", "SessionEnd"))
        #expect(registry[id]?.state == .ended)
    }

    @Test("Before it has a name, the row says ChatGPT")
    func unnamedRow() {
        let session = chatGPTSession(state: .busy)
        #expect(session.primaryLabel == "ChatGPT")
    }

    // MARK: - Process checks leave it alone

    @Test("A wake does not leave ChatGPT stuck in reconnecting")
    func wakeSkipsChatGPT() throws {
        var registry = SessionRegistry()
        _ = registry.ingest(try decode("1", "Stop"))
        _ = registry.ingest(try EventWireDecoder.decode(line: Data(
            #"{"v":1,"id":"c","provider":"claudeCode","hook_event_name":"Stop","session_id":"claude-1"}"#.utf8
        )))

        registry.markAllReconnecting(now: Date())

        #expect(registry[SessionID.provider(.chatGPT, "chatgpt-c:abc-1")]?.state == .free)
        #expect(registry[SessionID.provider(.claudeCode, "claude-1")]?.state == .reconnecting)
    }

    @Test("A restart keeps an unread conversation, which has no process to check")
    func restoreKeepsChatGPT() {
        let live = StatePersistence.filterToLiveSessions(
            [chatGPTSession(state: .free)],
            isAlive: { _, _ in false }
        )
        #expect(live.count == 1)
    }

    @Test("A restart still drops a ChatGPT row that never had an event")
    func restoreDropsUnreported() {
        let live = StatePersistence.filterToLiveSessions(
            [chatGPTSession(state: .free, hasHookEvidence: false)],
            isAlive: { _, _ in true }
        )
        #expect(live.isEmpty)
    }

    @Test("ChatGPT generating does not keep the Mac awake")
    func noWakeLock() {
        #expect(WakeLockPolicy.workingSessions(in: [chatGPTSession(state: .busy)]).isEmpty)
    }

    @Test("The conversation address survives a restart; its name does not")
    func persistence() throws {
        var session = chatGPTSession(state: .free)
        session.conversationURL = url
        session.sessionTitle = "日本の歴史要約"

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(restored.provider == .chatGPT)
        #expect(restored.conversationURL == url)
        #expect(restored.sessionTitle == nil)
    }
}
