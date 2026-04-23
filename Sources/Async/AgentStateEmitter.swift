import Foundation

/// Public handoff from rmux to agents: writes `.cmux/state.json` whenever an
/// Async workspace transitions, and (on first convertToAsync) seeds a copy of
/// `CLAUDE.async.md` in the workspace cwd so agents have operating notes.
///
/// See docs-rmux/agent-state.md for the JSON schema and docs-rmux/spec.md §7
/// for the broader contract.
enum AgentStateEmitter {
    /// Current schema version of `.cmux/state.json`. See docs-rmux/agent-state.md.
    static let stateSchemaVersion = 1

    /// Write the workspace's current Async state to `.cmux/state.json` under
    /// its working directory. For Normal workspaces, removes any stale state
    /// file. Always atomic (temp + rename), never partial reads.
    @MainActor
    static func writeState(for workspace: Workspace, at instant: Date = Date()) {
        let cwd = workspace.currentDirectory
        guard !cwd.isEmpty else { return }
        // Safety: Workspaces constructed without an explicit working directory
        // fall back to the user's home, and the unit-test suite exercises many
        // transitions on such bare workspaces. Refusing to write to $HOME
        // keeps tests from polluting the user's dotfiles; an Async workspace
        // that actually targets a project will have a real cwd.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return }

        let dirPath = (cwd as NSString).appendingPathComponent(".cmux")
        let filePath = (dirPath as NSString).appendingPathComponent("state.json")

        guard workspace.mode == .async else {
            try? FileManager.default.removeItem(atPath: filePath)
            return
        }

        do {
            try FileManager.default.createDirectory(
                atPath: dirPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            return
        }

        let payload = buildPayload(workspace: workspace, at: instant)
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .prettyPrinted]
        ) else { return }

        let tmpPath = filePath + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: [.atomic])
            try? FileManager.default.removeItem(atPath: filePath)
            try FileManager.default.moveItem(atPath: tmpPath, toPath: filePath)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
    }

    /// Drop a minimal `CLAUDE.async.md` into the workspace cwd so the agent has
    /// operating notes (what phases mean, what the state file is). Never
    /// overwrites an existing file — the user may have customised it.
    @MainActor
    static func ensureTemplate(for workspace: Workspace) {
        let cwd = workspace.currentDirectory
        guard !cwd.isEmpty else { return }
        // Same $HOME guard as `writeState(for:)`.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return }

        let dest = (cwd as NSString).appendingPathComponent("CLAUDE.async.md")
        guard !FileManager.default.fileExists(atPath: dest) else { return }
        try? asyncAgentTemplateContent.write(
            toFile: dest,
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Payload

    @MainActor
    private static func buildPayload(workspace: Workspace, at instant: Date) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var payload: [String: Any] = [
            "schemaVersion": stateSchemaVersion,
            "workspaceId": workspace.id.uuidString,
            "phase": workspace.asyncPhase?.rawValue ?? "unknown",
            "updatedAt": formatter.string(from: instant),
            "syncing": NSNull(),
            "selfRunning": NSNull(),
            "awaitingAttendance": NSNull(),
        ]

        switch workspace.asyncPhase {
        case .syncing:
            if let startedAt = workspace.syncStartedAt,
               let planned = workspace.plannedDuration {
                let elapsed = max(0, Int(instant.timeIntervalSince(startedAt)))
                let overrun = max(0, elapsed - Int(planned))
                payload["syncing"] = [
                    "startedAt": formatter.string(from: startedAt),
                    "plannedDurationSeconds": Int(planned),
                    "elapsedSeconds": elapsed,
                    "overrunSeconds": overrun,
                ] as [String: Any]
            }
        case .selfRunning:
            if let nextSyncAt = workspace.nextSyncAt {
                let remaining = max(0, Int(nextSyncAt.timeIntervalSince(instant)))
                payload["selfRunning"] = [
                    "nextSyncAt": formatter.string(from: nextSyncAt),
                    "remainingSeconds": remaining,
                ] as [String: Any]
            }
        case .awaitingAttendance:
            if let scheduledAt = workspace.nextSyncAt {
                let overdue = max(0, Int(instant.timeIntervalSince(scheduledAt)))
                payload["awaitingAttendance"] = [
                    "scheduledAt": formatter.string(from: scheduledAt),
                    "overdueSeconds": overdue,
                ] as [String: Any]
            }
        case .preparing, .none:
            break
        }

        return payload
    }

    // MARK: - Template

    private static let asyncAgentTemplateContent: String = """
    # rmux Async workspace — agent operating notes

    This workspace is managed by **rmux** (a cmux fork) as an *Async workspace*:
    the human operator runs it through periodic **Sync sessions**; between
    sessions the agent self-runs without human oversight.

    ## Phase awareness

    rmux writes the current phase to `.cmux/state.json` (also exposed through
    `$CMUX_STATE_FILE`). Read it before replying.

    | phase | meaning | what you should do |
    | --- | --- | --- |
    | `preparing` | Ready-to-sync screen is open; no user prompt yet. | Nothing; wait for the first user turn. |
    | `syncing` | Human is present. | Lead with a summary of what happened since the previous sync. Raise permission gaps, ambiguities, and blocking questions *now* — you will not be able to ask them during self-running. Pace for the planned duration. |
    | `selfRunning` | Human is not watching; Sync is scheduled for later. | Do not ask clarifying questions. If you hit a permission gap, stop and log it; do not try to route around it. Prefer conservative moves and write down everything you would have asked for the next sync. Do not emit OSC 9/99/777 notifications. |
    | `awaitingAttendance` | Sync slot has passed; human has not started the session. | Same as `selfRunning`. |

    ## `.cmux/state.json` schema (v1)

    ```json
    {
      "schemaVersion": 1,
      "workspaceId": "...",
      "phase": "syncing | preparing | selfRunning | awaitingAttendance",
      "updatedAt": "2026-04-24T00:00:00Z",
      "syncing": { "startedAt": "...", "plannedDurationSeconds": 1800,
                   "elapsedSeconds": 540, "overrunSeconds": 0 },
      "selfRunning": { "nextSyncAt": "...", "remainingSeconds": 7200 },
      "awaitingAttendance": { "scheduledAt": "...", "overdueSeconds": 300 }
    }
    ```

    Phase-specific objects are `null` outside the matching phase. The `*Seconds`
    fields are snapshots at write time — prefer the absolute ISO timestamps when
    computing live deltas.

    ## Messages from rmux

    Lines beginning with `[cmux] ` are system events injected by rmux (via the
    Claude Code `UserPromptSubmit` hook and, in later phases, MCP). Treat them
    as ground truth for the current phase.
    """
}
