import Foundation

/// Public handoff from rmux to agents.
///
/// **Per-workspace, not per-cwd.** State is written to
/// `AgentStatePaths.stateFilePath(for:)` (default
/// `~/Library/Application Support/<bundleId>/workspaces/<id>/state.json`).
/// The terminal env carries `CMUX_STATE_FILE=<that path>`, and the global
/// hook script (`~/.cmux/prompt-hook.sh`, registered via the cwd's
/// `.claude/settings.local.json`) reads it. This makes multiple Async
/// workspaces in the same cwd safe and prevents stale state files from a
/// deleted workspace affecting a new one that happens to land in the same
/// directory.
///
/// **Everything rmux writes is outside git's path.** `settings.local.json` is
/// gitignored by Claude Code convention; the state file and hook script live
/// under $HOME. rmux never touches `CLAUDE.md`, `settings.json`, or the
/// project root. The agent receives phase guidance through the per-turn
/// hook output alone — no in-tree documentation is planted.
///
/// See docs-rmux/spec.md §7 and docs-rmux/agent-state.md.
enum AgentStateEmitter {
    /// Current schema version of `state.json`. See docs-rmux/agent-state.md.
    static let stateSchemaVersion = 1

    /// Write the workspace's current Async state to its per-workspace state
    /// file. For Normal workspaces, removes any stale state file. Always
    /// atomic (temp + rename), never partial reads.
    @MainActor
    static func writeState(for workspace: Workspace, at instant: Date = Date()) {
        let dirURL = AgentStatePaths.stateDirectory(for: workspace.id)
        let filePath = AgentStatePaths.stateFilePath(for: workspace.id)

        guard workspace.mode == .async else {
            try? FileManager.default.removeItem(atPath: filePath)
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: dirURL,
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

    /// Remove a workspace's state file. Call when a workspace is permanently
    /// destroyed so its state doesn't linger in Application Support.
    @MainActor
    static func discardState(forWorkspaceId workspaceId: UUID) {
        let filePath = AgentStatePaths.stateFilePath(for: workspaceId)
        try? FileManager.default.removeItem(atPath: filePath)
        let dirURL = AgentStatePaths.stateDirectory(for: workspaceId)
        try? FileManager.default.removeItem(at: dirURL)
    }

    /// Install (or refresh) the global Claude Code `UserPromptSubmit` hook
    /// script, then merge a registration entry into the workspace cwd's
    /// `.claude/settings.local.json` pointing at that global script.
    ///
    /// The script lives at `AgentStatePaths.globalHookScriptPath` (one file
    /// for all rmux Async workspaces). `settings.local.json` is per-project
    /// personal config (gitignored by Claude Code convention) — a deliberate
    /// choice so the hook, which contains a user-absolute path, never lands
    /// in a shared repo. Writing to `settings.json` would pollute git.
    ///
    /// Idempotent at both layers: the script is overwritten so logic upgrades
    /// land automatically; the settings.local.json merge skips when an entry
    /// already references the global hook path.
    @MainActor
    static func ensureClaudeCodeHook(for workspace: Workspace) {
        let cwd = workspace.currentDirectory
        guard !cwd.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return }

        writeGlobalPromptHookScript()
        mergeClaudeSettings(in: cwd)
    }

    // MARK: - Hook script

    @MainActor
    private static func writeGlobalPromptHookScript() {
        let dirURL = AgentStatePaths.globalHookDir
        let path = AgentStatePaths.globalHookScriptPath
        do {
            try FileManager.default.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try promptHookScriptContent.write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: path
            )
        } catch {
            return
        }
    }

    @MainActor
    private static func mergeClaudeSettings(in cwd: String) {
        let dir = (cwd as NSString).appendingPathComponent(".claude")
        let path = (dir as NSString).appendingPathComponent("settings.local.json")
        let hookPath = AgentStatePaths.globalHookScriptPath

        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            return
        }

        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []

        // Skip if any existing entry already points at our hook script (by
        // suffix `prompt-hook.sh` under the global hook dir, OR an exact
        // match against the configured hook path — covers test injection).
        // Legacy `<cwd>/.cmux/prompt-hook.sh` entries from the pre-1.5 layout
        // are intentionally NOT matched: we'll add the new global entry
        // alongside them, and the next run can clean up the legacy one.
        let alreadyRegistered = entries.contains { entry -> Bool in
            guard let subHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return subHooks.contains { sub in
                guard let command = sub["command"] as? String else { return false }
                return command == hookPath
            }
        }
        if alreadyRegistered { return }

        let newEntry: [String: Any] = [
            "matcher": ".*",
            "hooks": [
                [
                    "type": "command",
                    "command": hookPath,
                ] as [String: Any],
            ],
        ]
        entries.append(newEntry)
        hooks["UserPromptSubmit"] = entries
        root["hooks"] = hooks

        guard let payload = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .prettyPrinted]
        ) else { return }
        let tmpPath = path + ".tmp"
        do {
            try payload.write(to: URL(fileURLWithPath: tmpPath), options: [.atomic])
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
    }

    // MARK: - Shell script body

    /// Contents of `prompt-hook.sh`. Reads `$CMUX_STATE_FILE` (set by rmux
    /// per terminal) and emits `[cmux] ...` lines per spec §7.3.2. Depends on
    /// `bash` and `jq`; when `jq` is missing it emits a single informational
    /// line and exits 0. When `$CMUX_STATE_FILE` is unset or unreadable
    /// (terminal opened outside rmux, or workspace is Normal), exits silent.
    private static let promptHookScriptContent: String = """
    #!/bin/bash
    # rmux UserPromptSubmit hook — managed by rmux.
    # Reads the per-workspace state file pointed at by $CMUX_STATE_FILE and
    # emits "[cmux] …" lines describing the current Async workspace phase so
    # Claude Code can prepend them to every user turn. See docs-rmux/spec.md
    # §7.3.2.
    set -eu

    STATE_FILE="${CMUX_STATE_FILE:-}"
    [ -n "$STATE_FILE" ] || exit 0
    [ -r "$STATE_FILE" ] || exit 0

    if ! command -v jq >/dev/null 2>&1; then
      echo "[cmux] phase=unknown (install jq — 'brew install jq' — for phase-aware hook output)"
      exit 0
    fi

    format_hms() {
      # integer seconds → HH:MM:SS
      local total=${1:-0}
      [[ "$total" =~ ^[0-9]+$ ]] || total=0
      printf "%02d:%02d:%02d" $((total/3600)) $(((total%3600)/60)) $((total%60))
    }

    phase=$(jq -r '.phase // "unknown"' "$STATE_FILE")

    case "$phase" in
      syncing)
        plannedSec=$(jq -r '.syncing.plannedDurationSeconds // 0' "$STATE_FILE")
        elapsedSec=$(jq -r '.syncing.elapsedSeconds // 0' "$STATE_FILE")
        overrunSec=$(jq -r '.syncing.overrunSeconds // 0' "$STATE_FILE")
        planned=$(format_hms "$plannedSec")
        elapsed=$(format_hms "$elapsedSec")
        if [ "$overrunSec" -gt 0 ] 2>/dev/null; then
          over=$(format_hms "$overrunSec")
          echo "[cmux] phase=syncing elapsed=$elapsed planned=$planned over=$over"
          echo "[cmux] Time is up. Wrap up and end the sync."
        else
          remaining=$(format_hms $((plannedSec - elapsedSec)))
          echo "[cmux] phase=syncing elapsed=$elapsed planned=$planned remaining=$remaining"
          echo "[cmux] Surface permission gaps & blocking questions now. Self-running starts when this sync ends."
        fi
        ;;
      selfRunning)
        nextAt=$(jq -r '.selfRunning.nextSyncAt // "unknown"' "$STATE_FILE")
        remSec=$(jq -r '.selfRunning.remainingSeconds // 0' "$STATE_FILE")
        remaining=$(format_hms "$remSec")
        echo "[cmux] phase=self-running next_sync=$nextAt remaining=$remaining"
        echo "[cmux] Human is not watching. Don't ask clarifying questions; log them for next sync."
        ;;
      awaitingAttendance)
        scheduled=$(jq -r '.awaitingAttendance.scheduledAt // "unknown"' "$STATE_FILE")
        overdueSec=$(jq -r '.awaitingAttendance.overdueSeconds // 0' "$STATE_FILE")
        overdue=$(format_hms "$overdueSec")
        echo "[cmux] phase=awaiting-attendance scheduled=$scheduled overdue=$overdue"
        echo "[cmux] Scheduled sync time has passed; human not yet here. Continue as before."
        ;;
      preparing)
        echo "[cmux] phase=preparing"
        echo "[cmux] Sync is about to start; summarize progress and banked questions."
        ;;
      *)
        # Unknown phase — stay silent so the agent isn't spammed with noise.
        ;;
    esac

    exit 0
    """

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
}
