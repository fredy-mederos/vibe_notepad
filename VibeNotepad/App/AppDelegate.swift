import AppKit
import SwiftUI

/// Handles everything that arrives through AppKit: files opened from Finder/`open`,
/// `vibeNotePad://` links, the Dock menu, reactivation and quitting (hot exit).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    /// Set by the main window so we can reopen it after it was closed.
    var openMainWindow: (() -> Void)?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Workspace.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for request in LaunchRouter.requests(fromArguments: CommandLine.arguments) {
            LaunchRouter.open(request)
        }
        Workspace.shared.recents.refreshMissing()
        AppUpdater.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if url.isFileURL {
                files.append(url)
            } else if LaunchRouter.isAppLink(url) {
                LaunchRouter.handle(url)
            }
        }
        if !files.isEmpty { Workspace.shared.open(urls: files) }
        // Debug links drive the app from scripts without bringing it up.
        if !urls.allSatisfy({ $0.host?.hasPrefix("debug-") == true }) { showMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        Workspace.shared.checkExternalChanges()
        Workspace.shared.recents.refreshMissing()
        // Commits and checkouts usually happen in another app.
        Workspace.shared.gitStateDidChange()
        // A new version found while the app was in the background is announced when it comes to the front.
        AppUpdater.shared.announceIfNew()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let workspace = Workspace.shared
        let settings = AppSettings.shared
        if settings.hotExit && settings.restoreSession {
            workspace.saveSession()
            return .terminateNow
        }
        let dirty = workspace.documents.filter(\.isDirty)
        guard !dirty.isEmpty else {
            workspace.saveSession()
            return .terminateNow
        }
        Task { @MainActor in
            for document in dirty {
                guard await workspace.closeAsync(document) else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            workspace.saveSession()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newItem = NSMenuItem(title: "New File", action: #selector(newFileFromDock(_:)), keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)
        let recents = Workspace.shared.recents.all.filter { !Workspace.shared.recents.isMissing($0.path) }.prefix(12)
        if !recents.isEmpty {
            menu.addItem(.separator())
            for item in recents {
                let entry = NSMenuItem(title: item.name, action: #selector(openFromDock(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.url
                entry.image = NSImage(systemSymbolName: item.pinned ? "pin.fill" : "doc.text", accessibilityDescription: nil)
                entry.toolTip = item.path
                menu.addItem(entry)
            }
        }
        return menu
    }

    @objc private func newFileFromDock(_ sender: NSMenuItem) {
        Workspace.shared.newDocument()
        showMainWindow()
    }

    @objc private func openFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Workspace.shared.open(url: url)
        showMainWindow()
    }

    func showMainWindow() {
        NSApp.activate()
        if let window = Workspace.shared.mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}
