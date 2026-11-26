import Foundation

/// Something the registry did in response to an event, for consumers to react to.
public enum RegistryEvent: Sendable, Equatable {
    case sessionAdded(SessionID)
    /// The only signal that should ever produce a sound or a notification.
    case sessionChanged(Transition)
    case sessionRefreshed(SessionID)
    case sessionRemoved(SessionID)
    case eventDropped(EventID, DropReason)

    public enum DropReason: String, Sendable, Equatable {
        case duplicate
        case outOfOrder
        case unmapped
        case sessionAlreadyEnded
        case unroutable
    }
}

/// The single source of truth for what sessions exist and what they are doing.
///
/// HUD, menu bar, notifications, and diagnostics all read from here; none of
/// them keeps its own idea of state. Value semantics keep it trivially testable;
/// the app owns exactly one instance behind a serial context.
public struct SessionRegistry: Sendable {
    private var sessions: [SessionID: AgentSession] = [:]
    private var dedup: EventDeduplicator
    /// Routes events that identify a session only by process, such as exits
    /// reported by the process watcher.
    private var pidIndex: [pid_t: SessionID] = [:]

    public init(dedupCapacity: Int = 4096) {
        dedup = EventDeduplicator(capacity: dedupCapacity)
    }

    // MARK: - Reading

    public var all: [AgentSession] {
        Array(sessions.values)
    }

    public subscript(id: SessionID) -> AgentSession? {
        sessions[id]
    }

    /// Sessions the HUD lists, ordered by how much they want the user: the ones
    /// needing attention first, then busy, then the rest, most recently changed
    /// first.
    ///
    /// Only sessions an agent has actually reported on. A session found by
    /// scanning processes proves something is running; it says nothing about
    /// what that something is doing, and listing it as `Unknown` forever dilutes
    /// the one question the HUD exists to answer. Those are still tracked, still
    /// watched for exit, and still adopt a real state the moment a hook arrives
    /// — see ``unreported``.
    public var visible: [AgentSession] {
        sessions.values
            .filter(\.isListed)
            .sorted { lhs, rhs in
                let l = displayPriority(lhs.state), r = displayPriority(rhs.state)
                if l != r { return l > r }
                return lhs.stateChangedAt > rhs.stateChangedAt
            }
    }

    /// Live sessions no agent has reported on yet.
    ///
    /// Surfaced as a count rather than hidden: silently omitting a running agent
    /// would be its own kind of dishonesty. Usually this means hooks were
    /// installed after the session started, since both agents read their hook
    /// configuration once at session start.
    ///
    /// One process can hold two entries here — process discovery keys a session
    /// on `(provider, pid, startTime)` while a hook keys it on the agent's own
    /// session id, so the same agent is adopted twice before the hook arrives.
    /// Counting both reported an agent as silent while its own row sat directly
    /// above saying otherwise, which reads as the app inventing sessions. The
    /// pid is what proves they are the same process.
    public var unreported: [AgentSession] {
        let reportingPIDs = Set(sessions.values.filter(\.hasHookEvidence).compactMap(\.pid))
        return sessions.values.filter { session in
            guard session.state.isActive, !session.hasHookEvidence else { return false }
            guard let pid = session.pid else { return true }
            return !reportingPIDs.contains(pid)
        }
    }

    private func displayPriority(_ state: AgentState) -> Int {
        switch state {
        case .waitingForApproval, .waitingForInput: return 4
        case .failed: return 3
        case .busy: return 2
        case .free: return 1
        case .discovering, .reconnecting, .unknown: return 0
        case .ended: return -1
        }
    }

    /// Counts per HUD bucket.
    ///
    /// Ended sessions are excluded, and so are sessions no agent has reported
    /// on. "Two busy" has to mean two agents we watched go busy; padding it with
    /// processes we merely found would make the number partly guesswork, which
    /// is the one thing these counters must never be.
    public func counts() -> [StateBucket: Int] {
        var result: [StateBucket: Int] = [:]
        for session in sessions.values where session.isListed {
            result[session.state.bucket, default: 0] += 1
        }
        return result
    }

    // MARK: - Ingesting

    /// Applies one event, returning what changed.
    ///
    /// De-duplication happens here rather than in the reducer so that a repeated
    /// delivery costs nothing and, crucially, cannot fire a second notification.
    public mutating func ingest(_ event: AgentEvent, now: Date = Date()) -> [RegistryEvent] {
        guard dedup.admit(event.id) else {
            return [.eventDropped(event.id, .duplicate)]
        }

        // A process exit concerns every session on that process, not only the
        // one the pid index last pointed at. Process discovery and the hook key
        // the same agent twice (see ``unreported``), and routing the exit to one
        // of them left the other active forever: the reaper found its process
        // gone every ten seconds and its exit was dropped as a duplicate each
        // time after the first.
        if event.kind == .processExited, event.providerSessionID == nil, let pid = event.pid {
            var ids = Set(sessions.values.filter { $0.pid == pid && $0.state.isActive }.map(\.id))
            if let indexed = pidIndex[pid], sessions[indexed] != nil { ids.insert(indexed) }
            guard !ids.isEmpty else { return [.eventDropped(event.id, .unroutable)] }
            return ids.sorted { $0.rawValue < $1.rawValue }.flatMap { apply(event, to: $0) }
        }

        guard let id = resolveSessionID(for: event) else {
            return [.eventDropped(event.id, .unroutable)]
        }
        return retireLegacyDesktopRow(for: event, keeping: id) + apply(event, to: id)
    }

    /// Before the fork keyed desktop sessions on the app's own id, they were
    /// keyed on the agent's session id like any other. A row saved that way
    /// would sit beside the new one forever, since nothing routes to it now.
    private mutating func retireLegacyDesktopRow(for event: AgentEvent, keeping id: SessionID) -> [RegistryEvent] {
        guard event.isFromClaudeDesktop,
              let agentSessionID = event.providerSessionID, !agentSessionID.isEmpty
        else { return [] }
        let legacy = SessionID.provider(event.provider, agentSessionID)
        guard legacy != id, sessions[legacy] != nil else { return [] }
        return remove(legacy)
    }

    private mutating func apply(_ event: AgentEvent, to id: SessionID) -> [RegistryEvent] {
        var results: [RegistryEvent] = []
        var session: AgentSession
        if let existing = sessions[id] {
            session = existing
        } else {
            // A session can first become known through any event, not only
            // SessionStart — CodeStatus may have started after the agent did.
            session = AgentSession(
                id: id,
                provider: event.provider,
                state: .discovering,
                now: event.timestamp,
                sourceAdapter: event.source == .hook ? "\(event.provider.rawValue)Hook" : "processWatcher"
            )
            session.capabilities = [.canOpen]
            if event.providerSessionID != nil {
                session.capabilities.insert(.canIdentifyExactConversation)
            }
            results.append(.sessionAdded(id))
        }

        let reduction = StateReducer.reduce(session, applying: event)
        sessions[id] = reduction.session
        indexPID(for: reduction.session)
        // A paused desktop session has let go of its process. Leaving the index
        // pointing at it would route a recycled pid's exit here.
        if session.pid != nil, reduction.session.pid == nil,
           let pid = session.pid, pidIndex[pid] == id {
            pidIndex.removeValue(forKey: pid)
        }

        switch reduction.outcome {
        case .stateChanged(let transition):
            results.append(.sessionChanged(transition))
        case .refreshed:
            results.append(.sessionRefreshed(id))
        case .ignoredOutOfOrder:
            results.append(.eventDropped(event.id, .outOfOrder))
        case .ignoredUnmapped:
            results.append(.eventDropped(event.id, .unmapped))
        case .ignoredEnded:
            results.append(.eventDropped(event.id, .sessionAlreadyEnded))
        }
        return results
    }

    private func resolveSessionID(for event: AgentEvent) -> SessionID? {
        // Fork addition: the desktop app's own id outlives every process and
        // every agent session id one desktop session goes through: its warm
        // spare, each resume, and `/clear`.
        if event.isFromClaudeDesktop, let hostSessionID = event.hostSessionID {
            return SessionID.provider(event.provider, hostSessionID)
        }
        // Preferred: the agent's own session id, which survives pid reuse and
        // is stable across tabs, windows, and resumes.
        if let providerSessionID = event.providerSessionID, !providerSessionID.isEmpty {
            return SessionID.provider(event.provider, providerSessionID)
        }
        // Fallback for process-sourced events, which know only a pid.
        if let pid = event.pid, let known = pidIndex[pid] {
            return known
        }
        return nil
    }

    private mutating func indexPID(for session: AgentSession) {
        guard let pid = session.pid else { return }
        pidIndex[pid] = session.id
    }

    // MARK: - Lifecycle

    /// Registers a session discovered by scanning processes rather than by a hook.
    ///
    /// Deliberately enters ``AgentState/unknown``: we know a session exists but
    /// have no evidence of what it is doing, and inventing `free` or `busy` here
    /// is exactly the guesswork this project refuses to do.
    public mutating func adopt(
        provider: AgentProvider,
        pid: pid_t,
        startTime: UInt64,
        now: Date
    ) -> RegistryEvent? {
        if let existing = pidIndex[pid], sessions[existing] != nil { return nil }
        let id = SessionID.process(provider, pid: pid, startTime: startTime)
        guard sessions[id] == nil else { return nil }

        var session = AgentSession(
            id: id,
            provider: provider,
            state: .unknown,
            stateConfidence: .low,
            now: now,
            sourceAdapter: "processWatcher"
        )
        session.pid = pid
        session.processStartTime = startTime
        session.capabilities = [.canOpen]
        sessions[id] = session
        pidIndex[pid] = id
        return .sessionAdded(id)
    }

    /// Puts every active session into ``AgentState/reconnecting`` after a wake or
    /// a daemon restart, so nothing is presented as trustworthy until it has
    /// been re-verified.
    public mutating func markAllReconnecting(now: Date) {
        for (id, var session) in sessions where session.state.isActive {
            guard session.state != .reconnecting else { continue }
            // Nothing on this Mac can re-verify a ChatGPT conversation, so it
            // would sit in `reconnecting` until the browser next spoke. Its
            // state is the extension's own record, which a sleep does not lose.
            guard session.hasLocalProcess else { continue }
            // A paused desktop session has no process to re-verify either; the
            // desktop app's own record decides whether it stays.
            guard !session.isPausedDesktopSession else { continue }
            session.previousState = session.state
            session.state = .reconnecting
            session.stateConfidence = .low
            session.stateChangedAt = now
            sessions[id] = session
        }
    }

    /// Drops ended sessions once their brief on-screen transition has elapsed.
    @discardableResult
    public mutating func pruneEnded(olderThan interval: TimeInterval, now: Date) -> [RegistryEvent] {
        var removed: [RegistryEvent] = []
        for (id, session) in sessions
        where session.state == .ended && now.timeIntervalSince(session.stateChangedAt) >= interval {
            sessions.removeValue(forKey: id)
            if let pid = session.pid, pidIndex[pid] == id { pidIndex.removeValue(forKey: pid) }
            removed.append(.sessionRemoved(id))
        }
        return removed
    }

    /// Replaces a session wholesale, used by enrichment passes that resolve
    /// git root, tty, or workspace after the fact.
    public mutating func update(_ session: AgentSession) {
        guard sessions[session.id] != nil else { return }
        sessions[session.id] = session
        indexPID(for: session)
    }

    /// Fork addition: makes the cloud rows match what the desktop app's cache
    /// lists, adding, updating and removing them.
    ///
    /// Pass only the sessions worth a row (see
    /// ``CloudSessionReader/Session/isWorthListing``); every cloud row not in
    /// the list is removed. A state change becomes a ``Transition`` like any
    /// other, so finishing in the cloud notifies like finishing in a terminal.
    /// Its id is derived from the session and its update time, so the same
    /// change seen on two sweeps is announced once.
    public mutating func syncCloudSessions(_ listed: [CloudSessionReader.Session], now: Date) -> [RegistryEvent] {
        var results: [RegistryEvent] = []
        var keep: Set<SessionID> = []

        for cloud in listed {
            let id = SessionID.provider(.claudeCode, cloud.id)
            keep.insert(id)
            var session: AgentSession
            if let existing = sessions[id] {
                session = existing
            } else {
                session = AgentSession(
                    id: id, provider: .claudeCode, state: .discovering,
                    now: cloud.updatedAt ?? now, sourceAdapter: "claudeDesktopCache"
                )
                session.hostApplication = .claudeCloud
                session.controlTarget.hostApplication = .claudeCloud
                session.hostSessionID = cloud.id
                session.capabilities = [.canOpen, .canIdentifyExactConversation]
                session.hasHookEvidence = true
                session.stateConfidence = .medium
                results.append(.sessionAdded(id))
            }

            let before = session
            session.sessionTitle = cloud.title
            session.repositoryName = cloud.repository.map { ($0 as NSString).lastPathComponent }
            session.workspaceName = cloud.repository
            if let updated = cloud.updatedAt { session.lastEventAt = updated }

            if cloud.state != session.state {
                let at = cloud.updatedAt ?? now
                let transition = Transition(
                    sessionID: id,
                    from: session.state,
                    to: cloud.state,
                    eventID: EventID("cloud-\(cloud.id)-\(Int(at.timeIntervalSince1970 * 1000))-\(cloud.state.rawValue)"),
                    source: .reconciliation,
                    confidence: .medium,
                    occurredAt: at,
                    reason: "Claude desktop app's list of cloud sessions"
                )
                session.previousState = session.state
                session.state = cloud.state
                session.stateChangedAt = at
                sessions[id] = session
                // A row's first state is where it starts, not news.
                if before.state != .discovering { results.append(.sessionChanged(transition)) }
            } else if session != before {
                sessions[id] = session
                results.append(.sessionRefreshed(id))
            }
        }

        for (id, session) in sessions where session.isCloudSession && !keep.contains(id) {
            results += remove(id)
        }
        return results
    }

    /// Puts back sessions saved before a restart.
    ///
    /// ``update(_:)`` only replaces sessions that already exist, so restoring
    /// through it put nothing back at all (fork fix).
    public mutating func restore(_ restored: [AgentSession]) {
        for session in restored where sessions[session.id] == nil {
            sessions[session.id] = session
            indexPID(for: session)
        }
    }

    /// Drops one session immediately, without waiting for it to end and linger.
    ///
    /// For the user dismissing a row by hand. Separate from ``pruneEnded`` on
    /// purpose: that one collects sessions the agent told us were finished,
    /// where this one throws away a session we may still believe is running.
    @discardableResult
    public mutating func remove(_ id: SessionID) -> [RegistryEvent] {
        guard let session = sessions.removeValue(forKey: id) else { return [] }
        if let pid = session.pid, pidIndex[pid] == id { pidIndex.removeValue(forKey: pid) }
        return [.sessionRemoved(id)]
    }
}
