import AppKit
import SwiftUI

/// With the sidebar collapsed ("just the text") the tabs are hidden. Moving the pointer up to the
/// title bar slides them down over the text; they go away shortly after it leaves the title bar
/// and the tabs.
extension Workspace {
    /// Height of `TabBarView`.
    static let tabBarHeight: CGFloat = 38

    func installTabReveal(on window: NSWindow) {
        window.acceptsMouseMovedEvents = true
        guard tabRevealMonitor == nil else { return }
        tabRevealMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            Workspace.shared.pointerMoved(event)
            return event
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if window === Workspace.shared.windowReference { Workspace.shared.hideTabs(animated: true) }
            }
        }
    }

    /// Reveals the tabs while the pointer is over the title bar (or the revealed tabs).
    func pointerMoved(_ event: NSEvent) {
        guard let window = windowReference, event.window === window, !settings.showsSidebar, !documents.isEmpty else {
            if event.window === windowReference { hideTabs(animated: true) }
            return
        }
        let fromTop = window.frame.height - event.locationInWindow.y
        let titleBar = window.frame.height - window.contentLayoutRect.maxY
        let zone = titleBar + (tabsRevealed ? Self.tabBarHeight + 8 : 0)
        if fromTop <= zone {
            tabHideTask?.cancel()
            tabHideTask = nil
            if !tabsRevealed {
                withAnimation(.snappy(duration: 0.22)) { tabsRevealed = true }
            }
        } else if tabsRevealed, tabHideTask == nil {
            // A short grace period, so moving down onto a tab doesn't hide them on the way.
            tabHideTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                Workspace.shared.hideTabs(animated: true)
            }
        }
    }

    func hideTabs(animated: Bool) {
        tabHideTask?.cancel()
        tabHideTask = nil
        guard tabsRevealed else { return }
        if animated {
            withAnimation(.snappy(duration: 0.25)) { tabsRevealed = false }
        } else {
            tabsRevealed = false
        }
    }
}
