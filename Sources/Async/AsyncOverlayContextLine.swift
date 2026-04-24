import SwiftUI

/// Shared context line under the workspace title on Async overlays.
/// Shows the current working directory (tilde-abbreviated when under $HOME)
/// and, when available, the current git branch with a dirty marker.
/// Used by ReadyToSyncOverlay / SelfRunningOverlay / OverdueOverlay so
/// the human can eyeball "where am I going to work" before they act.
struct AsyncOverlayContextLine: View {
    let cwd: String?
    let branch: String?
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let cwd = abbreviated(cwd) {
                Label(cwd, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let branch, !branch.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branch)
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                    if isDirty {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    private func abbreviated(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
