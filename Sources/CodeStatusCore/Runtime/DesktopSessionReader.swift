import Foundation

/// Fork addition: reads the Claude desktop app's own record of a session, to
/// decide whether a paused desktop row should stay.
///
/// The app keeps one JSON file per Code session under
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`,
/// named after its `local_...` id. Three values are read out of it and nothing
/// else: whether it is archived, when its last turn ended, and when the user
/// last focused it. The rest of the file (model settings, tool lists) is never
/// kept.
///
/// This is the app's private format, so every miss is soft: a file that cannot
/// be read is reported as such, and the caller keeps the row rather than
/// guessing that it was read.
public struct DesktopSessionReader: Sendable {

    /// What the desktop app says about one session.
    public struct Record: Sendable, Equatable {
        public var isArchived: Bool
        /// When the last turn ended, from `lastTurnEdgeAt`.
        public var lastTurnEndedAt: Date?
        /// When the user last had the session in front of them, from `lastFocusedAt`.
        public var lastFocusedAt: Date?

        public init(isArchived: Bool, lastTurnEndedAt: Date?, lastFocusedAt: Date?) {
            self.isArchived = isArchived
            self.lastTurnEndedAt = lastTurnEndedAt
            self.lastFocusedAt = lastFocusedAt
        }

        /// Whether something CodeStatus saw end unseen at `since` is still
        /// unseen: not archived, and not switched to since.
        ///
        /// `lastTurnEdgeAt` against `lastFocusedAt` alone is not enough: the
        /// app moves `lastFocusedAt` only when the user switches to a session,
        /// so a turn they watched end in front of them reads as unread.
        public func isStillUnseen(since: Date?) -> Bool {
            guard !isArchived, let since else { return false }
            guard let focused = lastFocusedAt else { return true }
            return focused < since
        }
    }

    public enum Lookup: Sendable, Equatable {
        case found(Record)
        /// No file under any account: the session was deleted, or it was a
        /// spare the app threw away before anyone claimed it.
        case missing
        /// The directory or file is there but could not be read or parsed.
        /// Treated as "do not know", never as "read".
        case unreadable
    }

    private let root: URL

    public init(home: URL) {
        root = home
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    public init(root: URL) {
        self.root = root
    }

    public func lookup(hostSessionID: String) -> Lookup {
        // Checked before it is joined to a path: the id came over a socket.
        guard ClaudeDesktop.isValidHostSessionID(hostSessionID) else { return .missing }
        let fileManager = FileManager.default
        guard let accounts = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return fileManager.fileExists(atPath: root.path) ? .unreadable : .missing
        }
        for account in accounts where !account.hasPrefix(".") {
            let accountURL = root.appendingPathComponent(account, isDirectory: true)
            guard let orgs = try? fileManager.contentsOfDirectory(atPath: accountURL.path) else { continue }
            for org in orgs where !org.hasPrefix(".") {
                let file = accountURL
                    .appendingPathComponent(org, isDirectory: true)
                    .appendingPathComponent(hostSessionID + ".json")
                guard fileManager.fileExists(atPath: file.path) else { continue }
                guard let data = try? Data(contentsOf: file),
                      let record = Self.parse(data)
                else { return .unreadable }
                return .found(record)
            }
        }
        return .missing
    }

    static func parse(_ data: Data) -> Record? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Record(
            isArchived: object["isArchived"] as? Bool ?? false,
            lastTurnEndedAt: date(object["lastTurnEdgeAt"]),
            lastFocusedAt: date(object["lastFocusedAt"])
        )
    }

    /// Milliseconds since the epoch.
    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}
