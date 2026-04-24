import AppKit
import Bonsplit
import Combine
import SwiftUI

/// Mounts the Async phase overlay as an `NSHostingView` directly on the host
/// window's content view. Purely cosmetic — the overlay content is always
/// `AsyncPhaseOverlayRoot` rendered on top of everything else in the window.
///
/// Why bypass SwiftUI's ZStack: the terminal surfaces are portal-hosted AppKit
/// views that sit above sibling SwiftUI content, which would make the overlay
/// appear *behind* the terminal inside a ZStack (see CLAUDE.md "Terminal find
/// layering contract"). Mounting as a top-level subview of the window's
/// contentView puts us unambiguously above the portals.
struct AsyncOverlayMount: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AsyncOverlayAnchorView {
        let anchor = AsyncOverlayAnchorView()
        anchor.coordinator = context.coordinator
        context.coordinator.anchor = anchor
        context.coordinator.workspace = workspace
        #if DEBUG
        dlog("rmux.overlay.makeNSView phase=\(workspace.asyncPhase?.rawValue ?? "nil")")
        #endif
        return anchor
    }

    func updateNSView(_ nsView: AsyncOverlayAnchorView, context: Context) {
        context.coordinator.workspace = workspace
        context.coordinator.anchor = nsView
        #if DEBUG
        dlog("rmux.overlay.updateNSView phase=\(workspace.asyncPhase?.rawValue ?? "nil") hasWindow=\(nsView.window != nil)")
        #endif
        context.coordinator.refresh()
    }

    static func dismantleNSView(_ nsView: AsyncOverlayAnchorView, coordinator: Coordinator) {
        coordinator.detachOverlay()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: AsyncOverlayAnchorView?
        weak var workspace: Workspace? {
            didSet {
                guard workspace !== oldValue else { return }
                subscribeToWorkspaceChanges()
            }
        }
        private var hosting: NSHostingView<AsyncPhaseOverlayRoot>?
        private var overlayWindow: NSWindow?
        private weak var parentWindow: NSWindow?
        private var parentFrameObservation: Any?
        private var cancellable: AnyCancellable?

        fileprivate func attachIfNeeded() {
            refresh()
        }

        fileprivate func detachOverlay() {
            if let overlayWindow, let parent = overlayWindow.parent {
                parent.removeChildWindow(overlayWindow)
            }
            overlayWindow?.orderOut(nil)
            overlayWindow = nil
            hosting = nil
            if let parentFrameObservation {
                NotificationCenter.default.removeObserver(parentFrameObservation)
            }
            parentFrameObservation = nil
            parentWindow = nil
        }

        fileprivate func refresh() {
            guard let anchor else {
                #if DEBUG
                dlog("rmux.overlay.refresh skip=noAnchor")
                #endif
                detachOverlay()
                return
            }
            guard let window = anchor.window else {
                #if DEBUG
                dlog("rmux.overlay.refresh skip=noWindow")
                #endif
                detachOverlay()
                return
            }
            guard let workspace else {
                #if DEBUG
                dlog("rmux.overlay.refresh skip=noWorkspace")
                #endif
                detachOverlay()
                return
            }

            let phase = workspace.mode == .async ? workspace.asyncPhase : nil
            guard let phase else {
                #if DEBUG
                dlog("rmux.overlay.refresh detach phase=nil (normal workspace)")
                #endif
                detachOverlay()
                return
            }

            // The anchor view is stretched to fill the workspace content area
            // (see WorkspaceContentView), so its window-space frame is exactly
            // the region the overlay should cover — excluding the sidebar,
            // title bar, and traffic lights.
            let anchorRectInWindow = anchor.convert(anchor.bounds, to: nil)
            guard anchorRectInWindow.width > 1, anchorRectInWindow.height > 1 else {
                #if DEBUG
                dlog("rmux.overlay.refresh skip=anchorNotSized rect=\(anchorRectInWindow)")
                #endif
                detachOverlay()
                return
            }

            // Two modes of overlay geometry:
            //  - "fill": the overlay spans the whole workspace content area
            //    (preparing / selfRunning / awaitingAttendance). Bottom corners
            //    follow the main window's rounded radius, top corners stay square.
            //  - "pill": during `syncing`, the terminal is foreground and the
            //    overlay is a small floating chip anchored to the top-right
            //    that hosts the "Sync を終える" affordance (future: elapsed-time
            //    HUD in Step 9). All four corners rounded as a self-contained
            //    pill; no mouse-passthrough needed because only the pill rect
            //    is captured.
            let overlayRectInWindow: CGRect
            let mask: CACornerMask
            switch phase {
            case .syncing:
                let pillSize = CGSize(width: 400, height: 44)
                let padding: CGFloat = 12
                // Window coordinates: AppKit bottom-left origin, so the top
                // edge of the workspace content is at maxY.
                overlayRectInWindow = CGRect(
                    x: anchorRectInWindow.maxX - pillSize.width - padding,
                    y: anchorRectInWindow.maxY - pillSize.height - padding,
                    width: pillSize.width,
                    height: pillSize.height
                )
                mask = [
                    .layerMinXMinYCorner, .layerMaxXMinYCorner,
                    .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
                ]
            case .preparing, .selfRunning, .awaitingAttendance:
                overlayRectInWindow = anchorRectInWindow
                let cornerEdgeTolerance: CGFloat = 1
                let touchesLeftEdge = anchorRectInWindow.minX <= cornerEdgeTolerance
                let windowRightEdge = window.contentLayoutRect.maxX
                let touchesRightEdge = abs(anchorRectInWindow.maxX - windowRightEdge) <= cornerEdgeTolerance
                var m: CACornerMask = []
                if touchesLeftEdge { m.insert(.layerMinXMaxYCorner) }
                if touchesRightEdge { m.insert(.layerMaxXMaxYCorner) }
                mask = m
            }

            let overlayScreenRect = window.convertToScreen(overlayRectInWindow)

            #if DEBUG
            dlog("rmux.overlay.refresh mount phase=\(phase.rawValue) rectInWindow=\(overlayRectInWindow) screenRect=\(overlayScreenRect) corners=\(maskDescription(mask))")
            #endif

            let root = AsyncPhaseOverlayRoot(workspace: workspace, phase: phase)

            if let overlayWindow, let hosting {
                hosting.rootView = root
                hosting.layer?.maskedCorners = mask
                if overlayWindow.parent !== window {
                    window.addChildWindow(overlayWindow, ordered: .above)
                    parentWindow = window
                    installFrameObserver(for: window)
                }
                overlayWindow.setFrame(overlayScreenRect, display: true)
                return
            }

            // Build a transparent, borderless child window that floats above the
            // parent's content area. Child-window relationship keeps it anchored
            // while the parent is moved/resized, and resolves the layering issue
            // that portals cause inside contentView.
            let h = NSHostingView(rootView: root)
            let overlay = NSWindow(
                contentRect: overlayScreenRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            overlay.isReleasedWhenClosed = false
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.ignoresMouseEvents = false
            overlay.level = .normal
            overlay.collectionBehavior = [
                .transient,
                .ignoresCycle,
                .fullScreenAuxiliary,
            ]
            overlay.contentView = h
            // macOS main windows have rounded bottom corners (~10pt radius).
            // Our borderless child window is rectangular, so we clip the
            // contentView's layer only for corners that actually touch the
            // main window edge (the sidebar / right panel, when present, hide
            // the respective corner so rounding there creates a visible gap).
            //
            // NSHostingView's layer is geometry-flipped so MaxY ↦ bottom.
            h.wantsLayer = true
            h.layer?.cornerRadius = 10
            h.layer?.maskedCorners = mask
            h.layer?.masksToBounds = true
            window.addChildWindow(overlay, ordered: .above)
            overlay.orderFront(nil)
            overlayWindow = overlay
            hosting = h
            parentWindow = window
            installFrameObserver(for: window)
            #if DEBUG
            dlog("rmux.overlay.childWindow created frame=\(overlay.frame) visible=\(overlay.isVisible) parentVisible=\(window.isVisible)")
            #endif
        }

        private func installFrameObserver(for parent: NSWindow) {
            if let parentFrameObservation {
                NotificationCenter.default.removeObserver(parentFrameObservation)
            }
            parentFrameObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: parent,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }

        private func subscribeToWorkspaceChanges() {
            cancellable = nil
            guard let workspace else { return }
            cancellable = workspace.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }
}

/// Invisible NSView whose window-space frame matches the workspace content
/// area. The Coordinator sizes a child window to that rect so the overlay
/// covers only the bonsplit region (not the sidebar or traffic lights).
final class AsyncOverlayAnchorView: NSView {
    weak var coordinator: AsyncOverlayMount.Coordinator?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.attachIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        coordinator?.attachIfNeeded()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        coordinator?.attachIfNeeded()
    }
}

/// SwiftUI root the NSHostingView renders. Switches on phase so the correct
/// shell appears. See docs-rmux/spec.md §6.1 for the contract.
struct AsyncPhaseOverlayRoot: View {
    @ObservedObject var workspace: Workspace
    let phase: AsyncPhase

    var body: some View {
        switch phase {
        case .preparing:
            ReadyToSyncOverlay(
                workspaceTitle: workspace.title,
                cwd: workspace.currentDirectory,
                branch: workspace.gitBranch?.branch,
                isDirty: workspace.gitBranch?.isDirty ?? false,
                initialPlannedDuration: workspace.nextSyncPlannedDuration,
                onStart: { duration in
                    try? workspace.transition(.enterSyncing(plannedDuration: duration, at: Date()))
                },
                onCancel: {
                    try? workspace.transition(.cancelPreparing)
                }
            )
        case .selfRunning:
            if let nextSyncAt = workspace.nextSyncAt {
                SelfRunningOverlay(
                    workspaceTitle: workspace.title,
                    cwd: workspace.currentDirectory,
                    branch: workspace.gitBranch?.branch,
                    isDirty: workspace.gitBranch?.isDirty ?? false,
                    nextSyncAt: nextSyncAt,
                    initialPlannedDuration: workspace.nextSyncPlannedDuration,
                    onReschedule: { scheduled in
                        workspace.nextSyncPlannedDuration = scheduled.plannedDuration
                        try? workspace.transition(.reschedule(nextSyncAt: scheduled.at))
                    },
                    onSyncNow: {
                        try? workspace.transition(.interruptToPreparing)
                    }
                )
            }
        case .awaitingAttendance:
            if let scheduledAt = workspace.nextSyncAt {
                OverdueOverlay(
                    workspaceTitle: workspace.title,
                    cwd: workspace.currentDirectory,
                    branch: workspace.gitBranch?.branch,
                    isDirty: workspace.gitBranch?.isDirty ?? false,
                    scheduledAt: scheduledAt,
                    initialPlannedDuration: workspace.nextSyncPlannedDuration,
                    onStartNow: {
                        try? workspace.transition(.startOverdueSession)
                    },
                    onReschedule: { scheduled in
                        workspace.nextSyncPlannedDuration = scheduled.plannedDuration
                        try? workspace.transition(.reschedule(nextSyncAt: scheduled.at))
                    }
                )
            }
        case .syncing:
            if let startedAt = workspace.syncStartedAt,
               let planned = workspace.plannedDuration {
                SyncingActionBar(
                    syncStartedAt: startedAt,
                    plannedDuration: planned,
                    onEndSync: { scheduled in
                        workspace.nextSyncPlannedDuration = scheduled.plannedDuration
                        try? workspace.transition(.endSyncing(nextSyncAt: scheduled.at, at: Date()))
                    },
                    onEndSyncAndRevert: {
                        try? workspace.transition(.endSyncingAndRevert(at: Date()))
                    }
                )
            }
        }
    }
}

#if DEBUG
private func maskDescription(_ mask: CACornerMask) -> String {
    var parts: [String] = []
    if mask.contains(.layerMinXMinYCorner) { parts.append("tl") }
    if mask.contains(.layerMaxXMinYCorner) { parts.append("tr") }
    if mask.contains(.layerMinXMaxYCorner) { parts.append("bl") }
    if mask.contains(.layerMaxXMaxYCorner) { parts.append("br") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}
#endif
