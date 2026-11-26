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

    /// Whether the user is looking at a desktop or cloud session, for holding
    /// back its notification. nil for any other session, which the caller
    /// judges as before.
    ///
    /// The app being in front is not enough: one window holds every session,
    /// so that would silence all of them while the user reads one. Only the
    /// session it is showing is held back. When the log cannot tell, a desktop
    /// session falls back to "the app is in front", as before, and a cloud
    /// session is not held back, as before.
    static func isUserLooking(
        at session: AgentSession,
        frontmostBundleIdentifier: String?,
        focus: ClaudeDesktopFocus?
    ) -> Bool? {
        guard session.isDesktopSession || session.isCloudSession else { return nil }
        guard frontmostBundleIdentifier == HostApplication.claudeDesktop.bundleIdentifier else { return false }
        switch focus {
        case .session(let id): return id == session.hostSessionID
        case .nothing: return false
        case nil: return session.isDesktopSession
        }
    }
}
