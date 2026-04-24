import Foundation

/// Centralised filesystem paths for the rmux agent-handoff contract.
/// See docs-rmux/spec.md §7 and docs-rmux/agent-state.md.
///
/// **Identity is workspace, not cwd.** The state file lives under
/// Application Support keyed by the workspace UUID so that:
///   - multiple Async workspaces in the same cwd don't clobber each other,
///   - a stale state file from a deleted workspace can never bleed into a
///     freshly-created one that happens to share the cwd, and
///   - the project tree stays free of `.cmux/state.json` clutter.
///
/// The terminal env carries `CMUX_STATE_FILE=<absolute path>` so the
/// Claude Code prompt-hook can find the file without consulting cwd.
enum AgentStatePaths {

    /// Root for per-workspace state directories. Overridable in tests.
    /// Default: `~/Library/Application Support/<bundleId>/workspaces`.
    static var stateRoot: URL = defaultStateRoot()

    /// Directory holding the global, cwd-independent hook script that
    /// `.claude/settings.json` registers. Overridable in tests.
    /// Default: `~/.cmux`.
    static var globalHookDir: URL = defaultGlobalHookDir()

    /// Per-workspace directory `<stateRoot>/<workspaceId>/`.
    static func stateDirectory(for workspaceId: UUID) -> URL {
        stateRoot.appendingPathComponent(workspaceId.uuidString, isDirectory: true)
    }

    /// Absolute path to `<stateRoot>/<workspaceId>/state.json`.
    static func stateFilePath(for workspaceId: UUID) -> String {
        stateDirectory(for: workspaceId)
            .appendingPathComponent("state.json")
            .path
    }

    /// Absolute path to the global hook script.
    /// `<.claude/settings.json>` registers this exact path.
    static var globalHookScriptPath: String {
        globalHookDir.appendingPathComponent("prompt-hook.sh").path
    }

    // MARK: - Defaults

    static func defaultStateRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleId = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.unknown"
        return appSupport
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
    }

    static func defaultGlobalHookDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmux", isDirectory: true)
    }

    /// Restore both overrides to their defaults. Used by tests in tearDown.
    static func resetToDefaults() {
        stateRoot = defaultStateRoot()
        globalHookDir = defaultGlobalHookDir()
    }
}
