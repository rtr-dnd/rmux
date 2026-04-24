import AppKit
import Combine

/// Titlebar accessory that hosts one of two rmux Async affordances,
/// depending on the currently-selected workspace in this window:
///   - **syncing workspace**: elapsed-time HUD (`HH:MM:SS / 予定 …`) plus
///     a red "End Sync" button.
///   - **any other state** (Normal, preparing, selfRunning,
///     awaitingAttendance): a primary-blue "Start Async Session" pull-down
///     that expands into "Sync Now" / "Sync Later…" — the same two flows
///     in the File menu.
///
/// **Implemented in pure AppKit** (`NSTextField` / `NSButton` /
/// `NSPopUpButton` inside an `NSStackView`) on purpose. SwiftUI inside
/// `NSTitlebarAccessoryViewController` doesn't reliably inherit the
/// window's effective appearance — `.primary` kept resolving dark-on-dark
/// against macOS's dark titlebar vibrancy. AppKit views use
/// `NSColor.labelColor` / `.secondaryLabelColor` directly via the drawing
/// appearance stack, matching how cmux's existing `WindowToolbarController`
/// (Sources/WindowToolbarController.swift:169) renders its focused-command
/// label. See docs-rmux/spec.md §6.1.4.
@MainActor
final class SyncingTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    static let accessoryIdentifier = NSUserInterfaceItemIdentifier("rmux.syncing.titlebar.accessory")

    private let tabManager: TabManager

    // Syncing-state controls
    private let hudLabel = NSTextField(labelWithString: "")
    private let plannedLabel = NSTextField(labelWithString: "")
    private lazy var endSyncButton = NSButton(title: "", target: self, action: #selector(endSyncTapped))

    // Async-start control
    private lazy var asyncStartButton: NSButton = NSButton(
        title: String(localized: "async.titlebar.start.menu",
                      defaultValue: "Start Async Session"),
        target: self,
        action: #selector(asyncStartTapped)
    )

    // Containers
    private let syncingStack = NSStackView()
    private let rootStack = NSStackView()

    // State + refresh plumbing
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceCancellable: AnyCancellable?
    private weak var observedWorkspace: Workspace?
    private var hudTimer: Timer?
    private var currentSyncingWorkspace: Workspace?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)
        view = makeRootView()
        view.identifier = Self.accessoryIdentifier
        // Pin this accessory to the dark appearance so NSColor.labelColor
        // resolves to white against macOS's titlebar vibrancy. The titlebar
        // visually picks up the dark terminal content below it even in
        // system light mode, so following window.effectiveAppearance (which
        // stays `aqua` under light mode + app=system) gives unreadable
        // black-on-dark text. rmux's intended use is a dark terminal, so
        // pinning here is a pragmatic match; users who flip to a light
        // terminal theme will see white text on a light titlebar but that
        // combination is rare in practice.
        view.appearance = NSAppearance(named: .darkAqua)
        layoutAttribute = .right
        configureControls()
        subscribeToTabManager()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) unavailable")
    }

    deinit {
        hudTimer?.invalidate()
    }

    // MARK: - View setup

    private func makeRootView() -> NSView {
        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = 0
        rootStack.distribution = .fill
        rootStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 18)
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
        host.autoresizingMask = [.width, .height]
        host.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            rootStack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        return host
    }

    private func configureControls() {
        // HUD labels — colours match cmux's WindowToolbarController (see
        // top-of-file comment).
        hudLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        hudLabel.textColor = .labelColor
        hudLabel.lineBreakMode = .byClipping
        hudLabel.setContentHuggingPriority(.required, for: .horizontal)

        plannedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        plannedLabel.textColor = .secondaryLabelColor
        plannedLabel.lineBreakMode = .byClipping
        plannedLabel.setContentHuggingPriority(.required, for: .horizontal)

        // End Sync — destructive red prominent button.
        endSyncButton.bezelStyle = .push
        endSyncButton.controlSize = .small
        endSyncButton.bezelColor = .systemRed
        endSyncButton.image = NSImage(systemSymbolName: "calendar.badge.minus",
                                      accessibilityDescription: nil)
        endSyncButton.imagePosition = .imageLeading
        endSyncButton.title = String(localized: "async.syncing.endSyncButton",
                                     defaultValue: "End Sync")

        syncingStack.orientation = .horizontal
        syncingStack.alignment = .centerY
        syncingStack.spacing = 8
        syncingStack.setViews([hudLabel, plannedLabel, endSyncButton], in: .center)

        // Start Async Session — primary-blue prominent button with an
        // attached NSMenu shown on click.
        asyncStartButton.bezelStyle = .push
        asyncStartButton.controlSize = .small
        asyncStartButton.bezelColor = .controlAccentColor
        asyncStartButton.image = NSImage(systemSymbolName: "calendar.badge.plus",
                                         accessibilityDescription: nil)
        asyncStartButton.imagePosition = .imageLeading
    }

    // MARK: - Observation

    private func subscribeToTabManager() {
        tabManager.$tabs
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        tabManager.$selectedTabId
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func observe(_ workspace: Workspace?) {
        guard workspace !== observedWorkspace else { return }
        observedWorkspace = workspace
        workspaceCancellable = workspace?.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
    }

    // MARK: - State refresh

    private func selectedWorkspace() -> Workspace? {
        guard let id = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == id })
    }

    private func refresh() {
        let workspace = selectedWorkspace()
        observe(workspace)

        if let workspace,
           workspace.mode == .async,
           workspace.asyncPhase == .syncing,
           let startedAt = workspace.syncStartedAt,
           let planned = workspace.plannedDuration {
            showSyncingState(
                workspace: workspace,
                startedAt: startedAt,
                planned: planned
            )
        } else if workspace == nil || workspace?.mode == .normal {
            // Normal (or no) selected workspace → offer the Async start
            // entry. Hidden during Async states other than syncing
            // (preparing / selfRunning / awaitingAttendance already have
            // their own full-screen overlays with the right affordances;
            // another "Start Async Session" button in the titlebar would
            // be redundant and confusing there).
            showAsyncStartState()
        } else {
            showEmptyState()
        }
    }

    private func showSyncingState(
        workspace: Workspace,
        startedAt: Date,
        planned: TimeInterval
    ) {
        currentSyncingWorkspace = workspace
        rootStack.setViews([syncingStack], in: .trailing)
        rootStack.setViews([], in: .center)
        rootStack.setViews([], in: .leading)
        updateHUD(startedAt: startedAt, planned: planned)
        armHUDTimer()
    }

    private func showAsyncStartState() {
        currentSyncingWorkspace = nil
        rootStack.setViews([asyncStartButton], in: .trailing)
        rootStack.setViews([], in: .center)
        rootStack.setViews([], in: .leading)
        invalidateHUDTimer()
    }

    private func showEmptyState() {
        currentSyncingWorkspace = nil
        rootStack.setViews([], in: .trailing)
        rootStack.setViews([], in: .center)
        rootStack.setViews([], in: .leading)
        invalidateHUDTimer()
    }

    // MARK: - HUD timer + formatting

    private func armHUDTimer() {
        invalidateHUDTimer()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let workspace = self.currentSyncingWorkspace,
                      let startedAt = workspace.syncStartedAt,
                      let planned = workspace.plannedDuration else { return }
                self.updateHUD(startedAt: startedAt, planned: planned)
            }
        }
        if let timer = hudTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func invalidateHUDTimer() {
        hudTimer?.invalidate()
        hudTimer = nil
    }

    private func updateHUD(startedAt: Date, planned: TimeInterval) {
        let now = Date()
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let overrun = max(0, elapsed - Int(planned))
        let isOverrun = overrun > 0
        let blinkVisible = !isOverrun || (elapsed % 2 == 0)

        let elapsedText = Self.formatHMS(elapsed)
        let plannedText = Self.formatHMS(Int(planned))

        hudLabel.stringValue = elapsedText
        hudLabel.textColor = isOverrun ? .systemRed : .labelColor
        hudLabel.alphaValue = blinkVisible ? 1.0 : 0.45

        let plannedLabelText: String
        if isOverrun {
            let overText = Self.formatHMS(overrun)
            plannedLabelText = String(
                localized: "async.syncing.plannedSuffixWithOverrun",
                defaultValue: "/ planned \(plannedText)  (+\(overText))"
            )
        } else {
            plannedLabelText = String(
                localized: "async.syncing.plannedSuffix",
                defaultValue: "/ planned \(plannedText)"
            )
        }
        plannedLabel.stringValue = plannedLabelText
        plannedLabel.textColor = isOverrun ? .systemRed : .secondaryLabelColor
        plannedLabel.alphaValue = blinkVisible ? 1.0 : 0.45
    }

    private static func formatHMS(_ totalSeconds: Int) -> String {
        let t = max(0, totalSeconds)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    // MARK: - Actions

    @objc private func endSyncTapped() {
        guard let workspace = currentSyncingWorkspace else { return }
        NewAsyncWorkspaceFlow.presentScheduleNextSyncSheet(
            parentWindow: view.window,
            initialDate: nil,
            initialPlannedDuration: workspace.plannedDuration,
            onConfirm: { scheduled in
                workspace.nextSyncPlannedDuration = scheduled.plannedDuration
                try? workspace.transition(
                    .endSyncing(nextSyncAt: scheduled.at, at: Date())
                )
            },
            onEndWithoutSchedule: {
                try? workspace.transition(.endSyncingAndRevert(at: Date()))
            }
        )
    }

    @objc private func asyncStartTapped() {
        let menu = NSMenu()
        let nowItem = NSMenuItem(
            title: String(localized: "async.titlebar.start.now",
                          defaultValue: "Sync Now"),
            action: #selector(syncNowTapped),
            keyEquivalent: ""
        )
        nowItem.target = self
        menu.addItem(nowItem)

        let laterItem = NSMenuItem(
            title: String(localized: "async.titlebar.start.later",
                          defaultValue: "Sync Later…"),
            action: #selector(syncLaterTapped),
            keyEquivalent: ""
        )
        laterItem.target = self
        menu.addItem(laterItem)

        let point = NSPoint(x: 0, y: asyncStartButton.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: asyncStartButton)
    }

    @objc private func syncNowTapped() {
        _ = NewAsyncWorkspaceFlow.createNow(debugSource: "titlebar.asyncStart.now")
    }

    @objc private func syncLaterTapped() {
        NewAsyncWorkspaceFlow.createLater(debugSource: "titlebar.asyncStart.later")
    }
}
