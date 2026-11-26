import Foundation

/// Fork addition: Claude Code sessions running in the cloud (claude.ai/code),
/// as the Claude desktop app last saw them.
///
/// A cloud session runs on Anthropic's machines, so no hook of ours ever runs
/// for it and nothing reaches the socket. The desktop app does know about
/// them: its sidebar lists them, and the web app inside it persists its React
/// Query cache, which holds the sessions list, to IndexedDB. This reads that
/// one query out of it and nothing else.
///
/// It is the app's private cache, so:
/// - Only the newest blob is read, and only when it has changed.
/// - Any failure returns nil, which the caller treats as "no news" and leaves
///   the rows as they were, never as "everything ended".
/// - It is only as fresh as the app keeps it. The caller drops every cloud row
///   when the app is not running, since then nothing is updating it.
public final class CloudSessionReader: @unchecked Sendable {

    /// One cloud session, reduced to what a row needs.
    public struct Session: Sendable, Equatable {
        /// `session_...`, the id claude.ai/code uses in its URLs.
        public var id: String
        public var title: String?
        /// `owner/name` of the repository it works in, when it has one.
        public var repository: String?
        public var state: AgentState
        public var isUnread: Bool
        public var updatedAt: Date?

        public init(id: String, title: String?, repository: String?, state: AgentState, isUnread: Bool, updatedAt: Date?) {
            self.id = id
            self.title = title
            self.repository = repository
            self.state = state
            self.isUnread = isUnread
            self.updatedAt = updatedAt
        }

        /// What CodeStatus lists: work in progress, and anything the user has
        /// not seen since it last changed. A finished session already read, or
        /// one that has sat waiting for weeks after being read, is history.
        public var isWorthListing: Bool {
            state == .busy || isUnread
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var sessions: [Session]
        /// When the app last fetched the list.
        public var fetchedAt: Date?
    }

    private let blobRoot: URL
    private var cachedPath: String?
    private var cachedModified: Date?
    private var cachedSnapshot: Snapshot?
    /// Blobs already found not to be the query cache, by path and date, so the
    /// app's other large blob is not decompressed on every sweep.
    private var notTheCache: [String: Date] = [:]

    public init(home: URL) {
        blobRoot = home.appendingPathComponent(
            "Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.blob", isDirectory: true
        )
    }

    public init(blobRoot: URL) {
        self.blobRoot = blobRoot
    }

    /// The sessions list from the newest copy of the cache, or nil when it
    /// cannot be found or read.
    public func read() -> Snapshot? {
        for (path, modified) in candidateBlobs() {
            if path == cachedPath, modified == cachedModified { return cachedSnapshot }
            if notTheCache[path] == modified { continue }
            guard let data = FileManager.default.contents(atPath: path),
                  data.count <= ChromiumValueDecoding.maxDecompressedBytes,
                  let value = try? ChromiumValueDecoding.decodeIndexedDBBlob(Array(data))
            else {
                // Not decodable as it stands. If it was caught mid-write, the
                // finished file has a new date and is tried again then.
                notTheCache[path] = modified
                continue
            }
            guard let snapshot = Self.snapshot(from: value) else {
                if value["clientState"] == nil { notTheCache[path] = modified }
                continue
            }
            cachedPath = path
            cachedModified = modified
            cachedSnapshot = snapshot
            return snapshot
        }
        return nil
    }

    /// Blob files, newest first. They live two levels down, in folders named
    /// after the high byte of their number, and each save writes a new one.
    private func candidateBlobs() -> [(String, Date)] {
        let fileManager = FileManager.default
        guard let databases = try? fileManager.contentsOfDirectory(atPath: blobRoot.path) else { return [] }
        var found: [(String, Date)] = []
        for database in databases where !database.hasPrefix(".") {
            let databasePath = blobRoot.appendingPathComponent(database).path
            guard let buckets = try? fileManager.contentsOfDirectory(atPath: databasePath) else { continue }
            for bucket in buckets where !bucket.hasPrefix(".") {
                let bucketPath = databasePath + "/" + bucket
                guard let files = try? fileManager.contentsOfDirectory(atPath: bucketPath) else { continue }
                for file in files where !file.hasPrefix(".") {
                    let path = bucketPath + "/" + file
                    guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                          attributes[.type] as? FileAttributeType == .typeRegular,
                          let modified = attributes[.modificationDate] as? Date
                    else { continue }
                    found.append((path, modified))
                }
            }
        }
        return found.sorted { $0.1 > $1.1 }
    }

    // MARK: - Reading the query

    static let queryName = "sessions_api_list_sessions"

    static func snapshot(from cache: JSValue) -> Snapshot? {
        guard let queries = cache["clientState"]?["queries"]?.elements, !queries.isEmpty else { return nil }
        // Several variants of the query can be cached (filters, pages). The
        // freshest one wins, and a session appearing in more than one keeps
        // its first, freshest record.
        let lists = queries.filter { $0["queryKey"]?[0]?.string == queryName }
        guard !lists.isEmpty else { return nil }
        let ordered = lists.sorted {
            ($0["state"]?["dataUpdatedAt"]?.number ?? 0) > ($1["state"]?["dataUpdatedAt"]?.number ?? 0)
        }
        var seen: Set<String> = []
        var sessions: [Session] = []
        for list in ordered {
            for page in list["state"]?["data"]?["pages"]?.elements ?? [] {
                for record in page["data"]?.elements ?? [] {
                    guard let session = session(from: record), seen.insert(session.id).inserted else { continue }
                    sessions.append(session)
                }
            }
        }
        let fetchedAt = ordered.first?["state"]?["dataUpdatedAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
        return Snapshot(sessions: sessions, fetchedAt: fetchedAt)
    }

    static func session(from record: JSValue) -> Session? {
        guard let id = record["id"]?.string, isValidCloudSessionID(id) else { return nil }
        // Archived sessions are not "active"; the app hides them too.
        if let lifecycle = record["lifecycle_status"]?.string, lifecycle != "active" { return nil }
        // A Remote Control bridge to a session on this Mac: the hook already
        // reports that one, as itself.
        if record["environment_kind"]?.string == "bridge" { return nil }

        let repository = record["session_context"]?["sources"]?.elements
            .compactMap { $0["url"]?.string }
            .compactMap(repositoryName(fromGitURL:))
            .first
        return Session(
            id: id,
            title: record["title"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
            repository: repository,
            state: state(of: record),
            isUnread: record["unread"]?.bool ?? false,
            updatedAt: record["updated_at"]?.string.flatMap(parseDate)
        )
    }

    /// Mapped from the fields the app's own sidebar decides on.
    ///
    /// `status_bucket` is the app's summary (`working`, `blocked`,
    /// `review_ready`, `completed`); `worker_status` and `session_status` say
    /// whether a turn is running right now.
    static func state(of record: JSValue) -> AgentState {
        let bucket = record["status_bucket"]?.string
        let worker = record["worker_status"]?.string
        let session = record["session_status"]?.string
        if worker == "running" || session == "running" { return .busy }
        // Just created: the machine is still starting, and the first turn
        // follows. Seen as `pending` with no worker yet.
        if session == "pending" { return .busy }
        if bucket == "working" {
            // The app treats `working` with an idle worker and a live
            // connection as still working; with no connection the turn is over.
            return record["connection_status"]?.string == "disconnected" ? .free : .busy
        }
        if bucket == "blocked" || record["post_turn_summary"]?["status_category"]?.string == "need_input" {
            return .waitingForInput
        }
        return .free
    }

    /// `session_` and then the id's own alphabet, as the list reports it; the
    /// id ends up in a link.
    public static func isValidCloudSessionID(_ value: String) -> Bool {
        guard value.hasPrefix("session_") else { return false }
        let rest = value.dropFirst("session_".count)
        return !rest.isEmpty && rest.count <= 64
            && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func repositoryName(fromGitURL string: String) -> String? {
        guard let url = URL(string: string), let host = url.host, !host.isEmpty else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? nil : "\(parts[0])/\(name)"
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public extension CloudSessionReader {
    /// Where the session opens: the desktop app's own link when it is there,
    /// claude.ai otherwise.
    static func openURLs(for id: String) -> (app: URL, web: URL)? {
        guard isValidCloudSessionID(id),
              let app = URL(string: "claude://code/\(id)"),
              let web = URL(string: "https://claude.ai/code/\(id)")
        else { return nil }
        return (app, web)
    }
}
