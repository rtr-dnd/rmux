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

    /// Install the Claude Code `UserPromptSubmit` hook that reads
    /// `.cmux/state.json` and prepends a `[cmux] ...` status line to every
    /// user turn. Writes `.cmux/prompt-hook.sh` (executable) and merges an
    /// entry into `.claude/settings.json`.
    ///
    /// Idempotent: if an entry already references `.cmux/prompt-hook.sh`
    /// anywhere in `UserPromptSubmit`, no change is made. The script file is
    /// always rewritten so shell logic upgrades land automatically.
    @MainActor
    static func ensureClaudeCodeHook(for workspace: Workspace) {
        let cwd = workspace.currentDirectory
        guard !cwd.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return }

        writePromptHookScript(in: cwd)
        mergeClaudeSettings(in: cwd)
    }

    // MARK: - Hook script

    @MainActor
    private static func writePromptHookScript(in cwd: String) {
        let dir = (cwd as NSString).appendingPathComponent(".cmux")
        let path = (dir as NSString).appendingPathComponent("prompt-hook.sh")
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
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
        let path = (dir as NSString).appendingPathComponent("settings.json")
        let absoluteHookPath = (cwd as NSString).appendingPathComponent(".cmux/prompt-hook.sh")

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

        // Skip if any existing entry already points at .cmux/prompt-hook.sh —
        // lets the user customise or move the hook and have cmux respect it.
        let alreadyRegistered = entries.contains { entry -> Bool in
            guard let subHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return subHooks.contains { sub in
                guard let command = sub["command"] as? String else { return false }
                return command.hasSuffix(".cmux/prompt-hook.sh") || command == absoluteHookPath
            }
        }
        if alreadyRegistered { return }

        let newEntry: [String: Any] = [
            "matcher": ".*",
            "hooks": [
                [
                    "type": "command",
                    "command": absoluteHookPath,
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

    /// Contents of `.cmux/prompt-hook.sh`. Reads `.cmux/state.json` and emits
    /// `[cmux] ...` lines per spec §7.3.2. Depends on `bash` and `jq`; when
    /// `jq` is missing it emits a single informational line and exits 0.
    private static let promptHookScriptContent: String = """
    #!/bin/bash
    # rmux UserPromptSubmit hook — managed by rmux.
    # Reads .cmux/state.json and emits "[cmux] …" lines describing the
    # current Async workspace phase so Claude Code can prepend them to every
    # user turn. See docs-rmux/spec.md §7.3.2.
    set -eu

    STATE_FILE="${CMUX_STATE_FILE:-.cmux/state.json}"
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
