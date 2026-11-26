import Foundation

/// Fork addition: the record Claude Code keeps of each running process in
/// `~/.claude/sessions/<pid>.json`, the one `claude agents --json` lists.
///
/// It carries the process's current status, which is what lets a session that
/// came back from a restart or a wake as `reconnecting` be re-verified without
/// waiting for its next hook. Before this, an idle session sat in
/// `reconnecting` until someone next typed into it, which could be hours.
///
/// Only the status and the ids that tie the file to a row are read.
public struct ClaudeSessionFile: Sendable, Equatable {
    public var pid: pid_t
    public var sessionID: String?
    public var hostSessionID: String?
    /// nil for a status this build does not know; the caller then leaves the
    /// row as it is.
    public var state: AgentState?
    public var statusUpdatedAt: Date?

    public static func read(pid: pid_t, home: URL) -> ClaudeSessionFile? {
        guard pid > 0 else { return nil }
        let url = home.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return nil }
        return parse(data, expectedPID: pid)
    }

    static func parse(_ data: Data, expectedPID: pid_t) -> ClaudeSessionFile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid == expectedPID
        else { return nil }
        let updated = (object["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeSessionFile(
            pid: pid,
            sessionID: object["sessionId"] as? String,
            hostSessionID: object["hostSessionId"] as? String,
            state: state(status: object["status"] as? String, waitingFor: object["waitingFor"] as? String),
            statusUpdatedAt: updated
        )
    }

    /// Claude Code maps its own turn state to `busy`, `waiting` (with what it
    /// waits for) and `idle`, and shows `shell` for an idle session running a
    /// shell command.
    static func state(status: String?, waitingFor: String?) -> AgentState? {
        switch status {
        case "busy": return .busy
        case "idle", "shell": return .free
        case "waiting": return waitingFor == "permission prompt" ? .waitingForApproval : .waitingForInput
        default: return nil
        }
    }

    /// Whether this file describes the agent behind `session`.
    public func describes(_ session: AgentSession) -> Bool {
        guard session.pid == pid else { return false }
        if let sessionID, sessionID == session.providerSessionID { return true }
        if let hostSessionID, hostSessionID == session.hostSessionID { return true }
        return false
    }
}
