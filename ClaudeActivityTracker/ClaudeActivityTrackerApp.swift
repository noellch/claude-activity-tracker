import SwiftUI

@main
struct ClaudeActivityTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem!
    var popover: NSPopover!
    var activityMonitor: ClaudeActivityMonitor!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Initialize activity monitor
        activityMonitor = ClaudeActivityMonitor()

        // Create status bar item
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusBarItem.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Claude Activity")
            button.action = #selector(togglePopover)
            updateStatusBarTitle()
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(monitor: activityMonitor)
        )

        // Update status bar after each refresh
        activityMonitor.onRefreshComplete = { [weak self] in
            self?.updateStatusBarTitle()
        }

        // File watcher: auto-refresh when JSONL files change
        activityMonitor.startWatching()

        // Fallback timer: refresh every 5 minutes in case watcher misses something
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.activityMonitor.refresh()
            self?.updateStatusBarTitle()
        }

        // Initial load
        activityMonitor.refresh()
    }

    func updateStatusBarTitle() {
        if let button = statusBarItem.button {
            let stats = activityMonitor.todayStats
            let sessionCount = stats.totalSessions
            let icon = "✦"
            if sessionCount > 0 {
                button.title = " \(icon) \(sessionCount)"
            } else {
                button.title = ""
            }
        }
    }

    @objc func togglePopover() {
        guard let button = statusBarItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            activityMonitor.refresh()
            updateStatusBarTitle()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
