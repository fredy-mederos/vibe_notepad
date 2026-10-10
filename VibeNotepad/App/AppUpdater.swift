import AppKit
import Observation

/// Checks GitHub for a newer Vibe Notepad: a few seconds after launch (at most once an hour), once a day while it
/// stays open, and whenever you ask (Vibe Notepad → Check for Updates…, Settings → General). Each check is one
/// request (`ReleaseFeed`); nothing is downloaded until you choose Download. A new version the automatic checks
/// find is announced once, in an alert; Settings keeps showing it until you update.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Vibe Notepad's repository: its source, and the releases it checks.
    static let repository = "fredy-mederos/vibe_notepad"
    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }

    /// The newest release GitHub named at the last check, kept between launches; nil when there’s none yet.
    private(set) var latest: Release?
    /// When GitHub last answered.
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    /// Why the last check failed, until one succeeds.
    private(set) var failure: String?

    /// The newest release, when it’s newer than this copy of Vibe Notepad.
    var available: Release? {
        guard let latest, VersionNumber.isValid(BuildInfo.version),
              VersionNumber.isVersion(BuildInfo.version, olderThan: latest.version) else { return nil }
        return latest
    }

    @ObservationIgnored private var feed = ReleaseFeed(repository: repository, diskImageName: "VibeNotepad.dmg")
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// False while a debug build tries another repository, so that one’s releases aren’t kept.
    @ObservationIgnored private var keepsState = true
    @ObservationIgnored private var checksAutomatically = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var announcedVersion: String?
    @ObservationIgnored private var isAnnouncing = false
    @ObservationIgnored private var schedule: Task<Void, Never>?

    private enum Key {
        static let latest = "updates.latestRelease"
        static let lastChecked = "updates.lastChecked"
        static let lastAttempt = "updates.lastAttempt"
        static let announced = "updates.announcedVersion"
    }

    private init() {
        latest = defaults.data(forKey: Key.latest).flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
        lastChecked = defaults.object(forKey: Key.lastChecked) as? Date
        lastAttempt = defaults.object(forKey: Key.lastAttempt) as? Date
        announcedVersion = defaults.string(forKey: Key.announced)
    }

    /// Starts the automatic checks; call once, at launch. Debug builds (Vibe Notepad Dev) check only when asked.
    func start() {
        #if !DEBUG
        guard schedule == nil else { return }
        checksAutomatically = true
        schedule = Task {
            try? await Task.sleep(for: .seconds(5))
            await checkIfDue(after: 60 * 60)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                await checkIfDue(after: 24 * 60 * 60)
            }
        }
        #endif
    }

    /// Checks unless GitHub was asked less than `interval` ago, then announces a new version.
    private func checkIfDue(after interval: TimeInterval) async {
        if let last = [lastChecked, lastAttempt].compactMap({ $0 }).max(), Date.now.timeIntervalSince(last) < interval { return }
        await check()
        announceIfNew()
    }

    /// Asks GitHub for the newest release now.
    func check() async {
        guard !isChecking else { return }
        guard VersionNumber.isValid(BuildInfo.version) else {
            failure = "This build has no version number."
            return
        }
        isChecking = true
        defer { isChecking = false }
        lastAttempt = .now
        save(lastAttempt, Key.lastAttempt)
        do {
            latest = try await feed.latestRelease()
            lastChecked = .now
            failure = nil
            save(latest.flatMap { try? JSONEncoder().encode($0) }, Key.latest)
            save(lastChecked, Key.lastChecked)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Vibe Notepad → Check for Updates…: checks now, then says what GitHub answered.
    func checkFromMenu() {
        Task {
            await check()
            if let release = available {
                announce(release, askedFor: true)
            } else if let failure {
                showAlert("Couldn’t check for updates", failure)
            } else if let latest, latest.version != BuildInfo.version {
                showAlert("Vibe Notepad is up to date", "You have version \(BuildInfo.version); the newest release is \(latest.version).")
            } else if latest != nil {
                showAlert("Vibe Notepad is up to date", "Version \(BuildInfo.version) is the newest version.")
            } else {
                showAlert("Vibe Notepad is up to date", "No version of Vibe Notepad has been released on GitHub yet.")
            }
        }
    }

    /// Announces a new version the automatic checks found: once per version, and only while Vibe Notepad is in
    /// front (it’s called again when the app comes to the front).
    func announceIfNew() {
        guard checksAutomatically, let release = available, release.version != announcedVersion, NSApp.isActive else { return }
        announce(release, askedFor: false)
    }

    /// Opens the release’s disk image (the browser downloads it), or its page when it has none.
    func download(_ release: Release) {
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    private func announce(_ release: Release, askedFor: Bool) {
        guard !isAnnouncing else { return }
        isAnnouncing = true
        announcedVersion = release.version
        save(release.version, Key.announced)
        let alert = NSAlert()
        alert.messageText = "Vibe Notepad \(release.version) is available"
        alert.informativeText = "You have version \(BuildInfo.version). Download the new one, open it and drag Vibe Notepad into Applications to replace this copy."
        let downloadButton = alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Release Notes")
        // An alert that shows up on its own can arrive while you type: Return shouldn’t start a download.
        if !askedFor { downloadButton.keyEquivalent = "" }
        present(alert) { [self] response in
            isAnnouncing = false
            switch response {
            case .alertFirstButtonReturn: download(release)
            case .alertThirdButtonReturn: NSWorkspace.shared.open(release.pageURL)
            default: break
            }
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        present(alert) { _ in }
    }

    /// As a sheet on the front window, or on its own when no window is open.
    private func present(_ alert: NSAlert, then handle: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.mainWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            NSApp.activate()
            handle(alert.runModal())
        }
    }

    private func save(_ value: Any?, _ key: String) {
        guard keepsState else { return }
        defaults.set(value, forKey: key)
    }

    #if DEBUG
    /// `vibenotepad-dev://debug-updates?repository=owner/name`: checks that repository’s releases (or Vibe
    /// Notepad’s) the way the launch check does, alert included, without keeping what it finds.
    func debugCheck(repository: String?) {
        if let repository {
            feed.repository = repository
            keepsState = false
        }
        checksAutomatically = true
        announcedVersion = nil
        Task {
            await check()
            announceIfNew()
        }
    }
    #endif
}
