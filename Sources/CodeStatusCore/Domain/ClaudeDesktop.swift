import Foundation

/// Fork addition: what CodeStatus knows about Claude Code sessions that the
/// Claude desktop app runs.
///
/// The desktop app reads the same `~/.claude/settings.json`, so the hook fires
/// for its sessions exactly as for a terminal. What differs is the lifecycle:
///
/// - The app starts a process when a session is opened, and stops it again on
///   its own: when memory runs short, when the app quits, when it restarts.
///   The session itself carries on and is resumed with a new process the next
///   time it is opened. So a process exit is the app pausing the session, not
///   the session ending.
/// - It keeps a warm spare process in `~/.claude/spares/` ready for the next
///   new session. A spare that is never claimed is not a session anyone made.
/// - It has no terminal, so no `TERM_PROGRAM` and no tty.
///
/// A row is therefore keyed on the app's own id for the session (`local_...`,
/// from `CLAUDE_CODE_HOST_SESSION_ID`), which survives all of the above, and a
/// paused row stays only while the app says it has not been read.
public enum ClaudeDesktop {
    /// `CLAUDE_CODE_ENTRYPOINT` in sessions the desktop app runs.
    public static let entrypoint = "claude-desktop"

    /// The app's own pattern for a local session id, as its deep link handler
    /// checks it. Matched before the id goes anywhere near a path or a URL.
    public static func isValidHostSessionID(_ value: String) -> Bool {
        guard value.hasPrefix("local_") else { return false }
        let rest = value.dropFirst("local_".count)
        guard !rest.isEmpty, rest.count <= 64 else { return false }
        return rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Whether a working directory is one of the app's warm spares.
    public static func isSpareDirectory(_ cwd: String?) -> Bool {
        guard let cwd else { return false }
        return cwd.contains("/.claude/spares/")
    }

    /// The deep link that opens one session in the desktop app. The same link
    /// the app puts in its own Dock menu for "Continue Last Session".
    public static func continueURL(hostSessionID: String) -> URL? {
        guard isValidHostSessionID(hostSessionID) else { return nil }
        return URL(string: "claude://code/continue?session=\(hostSessionID)")
    }
}

// MARK: - Whether the user has seen a turn end

public extension ClaudeDesktop {
    /// Records, on a desktop session, whether the user saw its turn end.
    ///
    /// The app's own record cannot answer that: `lastFocusedAt` moves only
    /// when the user switches *to* a session, so one they watched finish reads
    /// as finished after they last looked. So CodeStatus remembers what it saw
    /// at the moment the turn ended. Returns nil when nothing changes.
    static func noteTurnChange(
        _ session: AgentSession,
        transition: Transition,
        userWasLooking: Bool
    ) -> AgentSession? {
        guard session.isDesktopSession, transition.source == .hook else { return nil }
        var updated = session
        switch transition.to {
        case .busy:
            updated.unseenSince = nil
        case .free, .waitingForInput, .waitingForApproval, .failed:
            guard transition.from == .busy else { return nil }
            updated.unseenSince = userWasLooking ? nil : transition.occurredAt
        default:
            return nil
        }
        return updated.unseenSince == session.unseenSince ? nil : updated
    }
}

// MARK: - Which session the app is showing

/// What the desktop app has in front of the user, as its own log last said.
public enum ClaudeDesktopFocus: Sendable, Equatable {
    /// A Code session: `local_...` on this Mac or `session_...` in the cloud.
    case session(String)
    /// No session: another tab, or nothing selected.
    case nothing
}

public extension ClaudeDesktop {
    /// The line the app writes each time the selected session changes.
    static let focusMarker = "LocalSessions.setFocusedSession: sessionId="

    /// The last focus change in a stretch of the app's `main.log`, or nil when
    /// there is none in it or it does not look as expected.
    static func focus(inLog text: String) -> ClaudeDesktopFocus? {
        guard let range = text.range(of: focusMarker, options: .backwards) else { return nil }
        let value = text[range.upperBound...].prefix { !$0.isWhitespace }
        if value == "null" { return .nothing }
        let id = String(value)
        guard isValidHostSessionID(id) || CloudSessionReader.isValidCloudSessionID(id) else { return nil }
        return .session(id)
    }

    /// Reads the end of the app's log. Only the tail: the file runs to ten
    /// megabytes before the app rotates it, and the last focus change is what
    /// matters.
    static func readFocus(home: URL, tailBytes: UInt64 = 512 * 1024) -> ClaudeDesktopFocus? {
        let url = home.appendingPathComponent("Library/Logs/Claude/main.log")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return focus(inLog: String(decoding: data, as: UTF8.self))
    }

    /// Sessions open in their own window. The app rewrites this file as those
    /// windows open and close. They sit on screen beside the main window, and
    /// the main window's focus line says nothing about them.
    static func readPopoutSessions(home: URL) -> Set<String> {
        let url = home.appendingPathComponent("Library/Application Support/Claude/session-popouts.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return [] }
        return popoutSessions(in: data)
    }

    static func popoutSessions(in data: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = object["windows"] as? [[String: Any]]
        else { return [] }
        return Set(windows.compactMap { window in
            guard window["kind"] as? String == "session", let key = window["key"] as? String,
                  isValidHostSessionID(key) || CloudSessionReader.isValidCloudSessionID(key)
            else { return nil }
            return key
        })
    }

    /// Whether the user is looking at a desktop or cloud session, for holding
    /// back its notification. nil for any other session, which the caller
    /// judges as before. A session in its own window counts as looked at
    /// while the app is in front: that window is on screen.
    ///
    /// The app being in front is not enough: one window holds every session,
    /// so that would silence all of them while the user reads one. Only the
    /// session it is showing is held back. When the log cannot tell, a desktop
    /// session falls back to "the app is in front", as before, and a cloud
    /// session is not held back, as before.
    static func isUserLooking(
        at session: AgentSession,
        frontmostBundleIdentifier: String?,
        focus: ClaudeDesktopFocus?,
        popouts: Set<String> = []
    ) -> Bool? {
        guard session.isDesktopSession || session.isCloudSession else { return nil }
        guard frontmostBundleIdentifier == HostApplication.claudeDesktop.bundleIdentifier else { return false }
        if let id = session.hostSessionID, popouts.contains(id) { return true }
        switch focus {
        case .session(let id): return id == session.hostSessionID
        case .nothing: return false
        case nil: return session.isDesktopSession
        }
    }
}
