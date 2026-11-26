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
