// Empty stub. The syncing HUD + "End Sync" button used to live here as a
// SwiftUI view, but Phase 2 moved the entire titlebar control stack to
// pure AppKit (see Sources/Async/SyncingTitlebarAccessory.swift) so
// `Color.primary` / `Color.secondary` / `Color.accentColor` resolve
// against the window's real drawing appearance instead of SwiftUI's
// Environment colorScheme (which was giving dark-on-dark text in the
// titlebar).
//
// Kept as a file so the existing xcodeproj entry doesn't need editing;
// the symbols inside are unreferenced and stripped by the linker.

import Foundation

enum SyncingActionBarUnused {}
