import Testing
import Foundation
@testable import CodeStatusCore

/// Fork addition. Cloud sessions are read from the Claude desktop app's own
/// IndexedDB cache, because nothing of ours runs where they run. The fixtures
/// here are written in the same format by a small encoder, since the real
/// cache holds the user's conversation list.
@Suite("Claude Code cloud sessions from the desktop app's cache")
struct CloudSessionTests {

    // MARK: - A minimal writer for the format

    /// Values as V8 serialises them.
    private indirect enum JS {
        case string(String), utf16(String), number(Double), bool(Bool), null
        case array([JS]), object([(String, JS)])

        func encode(into out: inout [UInt8]) {
            switch self {
            case .string(let s):
                out.append(UInt8(ascii: "\""))
                let bytes = Array(s.utf8)
                varint(bytes.count, into: &out)
                out += bytes
            case .utf16(let s):
                out.append(UInt8(ascii: "c"))
                let units = Array(s.utf16)
                varint(units.count * 2, into: &out)
                for unit in units { out += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            case .number(let n):
                out.append(UInt8(ascii: "N"))
                let bits = n.bitPattern
                for shift in 0..<8 { out.append(UInt8((bits >> (8 * UInt64(shift))) & 0xFF)) }
            case .bool(let b):
                out.append(b ? UInt8(ascii: "T") : UInt8(ascii: "F"))
            case .null:
                out.append(UInt8(ascii: "0"))
            case .array(let items):
                out.append(UInt8(ascii: "A"))
                varint(items.count, into: &out)
                for item in items { item.encode(into: &out) }
                out.append(UInt8(ascii: "$"))
                varint(0, into: &out)
                varint(items.count, into: &out)
            case .object(let pairs):
                out.append(UInt8(ascii: "o"))
                for (key, value) in pairs {
                    JS.string(key).encode(into: &out)
                    value.encode(into: &out)
                }
                out.append(UInt8(ascii: "{"))
                varint(pairs.count, into: &out)
            }
        }
    }

    private static func varint(_ value: Int, into out: inout [UInt8]) {
        var v = UInt64(value)
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
    }
    private func varint(_ value: Int, into out: inout [UInt8]) { Self.varint(value, into: &out) }

    /// Snappy with literals only, which every decoder must accept.
    private func snappyLiterals(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        varint(input.count, into: &out)
        var index = 0
        while index < input.count {
            let chunk = min(65_536, input.count - index)
            out.append(61 << 2)
            out += [UInt8((chunk - 1) & 0xFF), UInt8((chunk - 1) >> 8)]
            out += input[index..<(index + chunk)]
            index += chunk
        }
        return out
    }

    /// A blob file as IndexedDB writes it.
    private func blob(_ value: JS, compressed: Bool = true) -> [UInt8] {
        var inner: [UInt8] = [0xFF, 0x15, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 0x0F]
        value.encode(into: &inner)
        return [0xFF, 0x11, compressed ? 0x02 : 0x00] + (compressed ? snappyLiterals(inner) : inner)
    }

    private func record(
        _ id: String, title: String = "提案資料作成", bucket: String = "completed",
        worker: String = "idle", session: String = "idle", connection: String = "disconnected",
        unread: Bool = false, lifecycle: String = "active", category: String = "completed",
        repo: String? = "https://github.com/nakano0328/zerotoone_survey",
        updated: String = "2026-11-25T00:51:09.753650Z"
    ) -> JS {
        var pairs: [(String, JS)] = [
            ("type", .string("session")), ("id", .string(id)), ("title", .utf16(title)),
            ("session_status", .string(session)), ("lifecycle_status", .string(lifecycle)),
            ("environment_kind", .string("anthropic_cloud")),
            ("updated_at", .string(updated)), ("worker_status", .string(worker)),
            ("connection_status", .string(connection)), ("status_bucket", .string(bucket)),
            ("unread", .bool(unread)),
            ("post_turn_summary", .object([("status_category", .string(category))])),
        ]
        let sources: [JS] = repo.map { [.object([("type", .string("git_repository")), ("url", .string($0))])] } ?? []
        pairs.append(("session_context", .object([("sources", .array(sources))])))
        return .object(pairs)
    }

    private func cache(_ records: [JS], fetchedAt: Double = 1_795_595_709_196) -> JS {
        .object([
            ("timestamp", .number(1_795_595_768_847)),
            ("clientState", .object([
                ("queries", .array([
                    .object([
                        ("queryKey", .array([.string("current_account"), .string("org")])),
                        ("state", .object([("data", .null)])),
                    ]),
                    .object([
                        ("queryKey", .array([
                            .string("sessions_api_list_sessions"),
                            .object([("orgUuid", .string("org"))]),
                        ])),
                        ("state", .object([
                            ("dataUpdatedAt", .number(fetchedAt)),
                            ("data", .object([("pages", .array([.object([("data", .array(records))])]))])),
                        ])),
                    ]),
                ])),
            ])),
        ])
    }

    // MARK: - Format

    @Test("Snappy back-references, overlapping ones included, expand as written")
    func snappyCopies() throws {
        // "ab", then copy 4 bytes from 2 back: "ababab".
        let out = try ChromiumValueDecoding.snappyDecompress([6, 0x04, 0x61, 0x62, 0x01, 0x02])
        #expect(out == Array("ababab".utf8))
    }

    @Test("Snappy that claims more than it holds is refused, not trusted", arguments: [
        [UInt8]([10, 0x04, 0x61, 0x62]),
        [6, 0x04, 0x61, 0x62, 0x01, 0x09],
        [0xFF, 0xFF, 0xFF, 0xFF, 0x0F],
    ])
    func snappyRefusesBadInput(_ input: [UInt8]) {
        #expect(throws: ChromiumValueDecoding.DecodeError.self) {
            _ = try ChromiumValueDecoding.snappyDecompress(input)
        }
    }

    @Test("A blob decodes, compressed or not, with two-byte strings intact")
    func decodesBlob() throws {
        let value = JS.object([("title", .utf16("提案資料作成")), ("n", .number(3)), ("ok", .bool(true))])
        for compressed in [true, false] {
            let decoded = try ChromiumValueDecoding.decodeIndexedDBBlob(blob(value, compressed: compressed))
            #expect(decoded["title"]?.string == "提案資料作成")
            #expect(decoded["n"]?.number == 3)
            #expect(decoded["ok"]?.bool == true)
        }
    }

    @Test("A truncated blob is an error, never a crash")
    func truncatedBlob() {
        let full = blob(cache([record("session_01A")]))
        for cut in stride(from: 3, to: full.count, by: max(1, full.count / 40)) {
            _ = try? ChromiumValueDecoding.decodeIndexedDBBlob(Array(full.prefix(cut)))
        }
    }

    // MARK: - Reading the sessions

    @Test("States follow the fields the app's sidebar uses")
    func states() throws {
        let snapshot = try #require(CloudSessionReader.snapshot(from: try ChromiumValueDecoding.decodeIndexedDBBlob(blob(cache([
            record("session_01Run", bucket: "working", worker: "running", session: "running"),
            record("session_01Start", bucket: "working", connection: "connected"),
            record("session_01Wait", bucket: "blocked", unread: true, category: "need_input"),
            record("session_01Done", bucket: "completed", unread: true),
            record("session_01Seen", bucket: "review_ready"),
        ])))))
        let states = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0.state) })
        #expect(states["session_01Run"] == .busy)
        #expect(states["session_01Start"] == .busy)
        #expect(states["session_01Wait"] == .waitingForInput)
        #expect(states["session_01Done"] == .free)
        #expect(states["session_01Seen"] == .free)
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 1_795_595_709.196))

        let listed = Set(snapshot.sessions.filter(\.isWorthListing).map(\.id))
        #expect(listed == ["session_01Run", "session_01Start", "session_01Wait", "session_01Done"])
    }

    @Test("Archived sessions and ids in any other shape are left out", arguments: [
        "session_01../x", "local_abc", "cse_01abc", "session_",
    ])
    func filtersRecords(_ badID: String) throws {
        let snapshot = try #require(CloudSessionReader.snapshot(from: try ChromiumValueDecoding.decodeIndexedDBBlob(blob(cache([
            record("session_01Gone", lifecycle: "archived"),
            record(badID),
            record("session_01Kept", repo: "https://github.com/HIBARI-inc/601_digital-twins-demo.git"),
        ])))))
        #expect(snapshot.sessions.map(\.id) == ["session_01Kept"])
        #expect(snapshot.sessions.first?.repository == "HIBARI-inc/601_digital-twins-demo")
        #expect(snapshot.sessions.first?.title == "提案資料作成")
    }

    @Test("The newest blob that is the cache wins; another large blob is passed over")
    func readsNewestCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        let bucket = root.appendingPathComponent("1/9c", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)

        let old = bucket.appendingPathComponent("9c2c")
        try Data(blob(cache([record("session_01Old", unread: true)]))).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path)
        let current = bucket.appendingPathComponent("9c2d")
        try Data(blob(cache([record("session_01New", unread: true)]))).write(to: current)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30)], ofItemAtPath: current.path)
        let other = bucket.appendingPathComponent("9c2e")
        try Data(blob(.object([("id", .string("apart"))]))).write(to: other)

        let reader = CloudSessionReader(blobRoot: root)
        #expect(reader.read()?.sessions.map(\.id) == ["session_01New"])
        // Unchanged files: the same answer, from memory.
        #expect(reader.read()?.sessions.map(\.id) == ["session_01New"])
    }

    @Test("No cache at all is no news, not an empty list")
    func missingCache() {
        let reader = CloudSessionReader(blobRoot: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(reader.read() == nil)
    }

    @Test("A click opens the app's own link, or claude.ai")
    func links() throws {
        let urls = try #require(CloudSessionReader.openURLs(for: "session_01JRWGj9Q8xCNND2nBozpE67"))
        #expect(urls.app.absoluteString == "claude://code/session_01JRWGj9Q8xCNND2nBozpE67")
        #expect(urls.web.absoluteString == "https://claude.ai/code/session_01JRWGj9Q8xCNND2nBozpE67")
        #expect(CloudSessionReader.openURLs(for: "session_01?x=1") == nil)
    }

    // MARK: - Rows

    private func cloud(_ state: AgentState, unread: Bool = true, updated: TimeInterval = 100) -> CloudSessionReader.Session {
        CloudSessionReader.Session(
            id: "session_01Abc", title: "提案資料作成", repository: "nakano0328/zerotoone_survey",
            state: state, isUnread: unread, updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private var rowID: SessionID { SessionID.provider(.claudeCode, "session_01Abc") }

    @Test("A row appears quietly, then finishing is a transition like any other")
    func lifecycle() throws {
        var registry = SessionRegistry()
        let added = registry.syncCloudSessions([cloud(.busy)], now: Date())
        #expect(added.contains(.sessionAdded(rowID)))
        #expect(!added.contains { if case .sessionChanged = $0 { return true } else { return false } })

        let row = try #require(registry[rowID])
        #expect(row.state == .busy)
        #expect(row.hostApplication == .claudeCloud)
        #expect(row.displayName == "zerotoone_survey")
        #expect(row.secondaryLabel == "提案資料作成")
        #expect(registry.visible.map(\.id) == [rowID])

        let finished = registry.syncCloudSessions([cloud(.free, updated: 200)], now: Date())
        let transition = try #require(finished.compactMap { result -> Transition? in
            if case .sessionChanged(let t) = result { return t } else { return nil }
        }.first)
        #expect(transition.from == .busy && transition.to == .free)
        #expect(transition.source == .reconciliation)

        // The same state again on the next sweep is not a second change.
        let again = registry.syncCloudSessions([cloud(.free, updated: 200)], now: Date())
        #expect(again.isEmpty)

        let removed = registry.syncCloudSessions([], now: Date())
        #expect(removed == [.sessionRemoved(rowID)])
    }

    @Test("Sync leaves every other row alone")
    func leavesOthers() throws {
        var registry = SessionRegistry()
        let json = #"{"v":1,"id":"h","provider":"claudeCode","hook_event_name":"Stop","ppid":4242,"session_id":"term-1"}"#
        _ = registry.ingest(try EventWireDecoder.decode(line: Data(json.utf8)))
        _ = registry.syncCloudSessions([cloud(.busy)], now: Date())
        _ = registry.syncCloudSessions([], now: Date())
        #expect(registry.all.map(\.id) == [SessionID.provider(.claudeCode, "term-1")])
    }

    @Test("No process checks: a wake, the wake lock and a restart all leave cloud rows to the cache")
    func noProcessChecks() throws {
        var registry = SessionRegistry()
        _ = registry.syncCloudSessions([cloud(.busy)], now: Date())
        registry.markAllReconnecting(now: Date())
        let row = try #require(registry[rowID])
        #expect(row.state == .busy)
        #expect(WakeLockPolicy.workingSessions(in: [row]).isEmpty)
        #expect(StatePersistence.filterToLiveSessions([row], isAlive: { _, _ in true }).isEmpty)
    }
}
