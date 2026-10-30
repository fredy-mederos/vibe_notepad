import AppKit
import SwiftUI

// Settings → General's About and Updates sections. Vibe GitTree and Vibe Clean show the same rows.

/// Version, build (commit count · commit), configuration and build time, with Copy Version Info for bug reports.
struct AboutSection: View {
    var body: some View {
        Section("About \(BuildInfo.name)") {
            LabeledContent("Version", value: BuildInfo.version)
            LabeledContent("Build") {
                Text(verbatim: BuildInfo.buildDescription)
                    .monospacedDigit()
            }
            LabeledContent("Configuration") {
                Text(BuildInfo.configuration)
                    .foregroundStyle(BuildInfo.isDebug ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help(BuildInfo.isDebug
                          ? "Vibe Notepad Dev, a development build from Xcode or make run."
                          : "An optimized build, as installed by make install or downloaded from GitHub.")
            }
            LabeledContent("Built") {
                if let date = BuildInfo.date {
                    Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                } else {
                    Text("Unknown")
                }
            }
            HStack {
                Link("Source on GitHub", destination: AppUpdater.repositoryURL)
                Spacer()
                Button("Copy Version Info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BuildInfo.summary, forType: .string)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// What the last update check found, with Check Now, or Download when there’s a newer version.
struct UpdatesSection: View {
    private let updater = AppUpdater.shared

    var body: some View {
        Section {
            LabeledContent {
                if updater.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if let release = updater.available {
                    Button("Download") { updater.download(release) }
                } else {
                    Button("Check Now") { Task { await updater.check() } }
                }
            } label: {
                Text(title)
                Text(detail)
            }
            if let release = updater.available {
                Link("Release Notes", destination: release.pageURL)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Vibe Notepad asks GitHub for the newest release when it opens and once a day while it’s open. Vibe Notepad → Check for Updates… asks any time.")
        }
    }

    private var title: String {
        if updater.isChecking { return String(localized: "Checking for updates…") }
        if let release = updater.available { return String(localized: "Vibe Notepad \(release.version) is available") }
        if updater.failure != nil { return String(localized: "Couldn’t check for updates") }
        if updater.lastChecked != nil { return String(localized: "Vibe Notepad is up to date") }
        return String(localized: "Not checked yet", comment: "Updates: no check has been made")
    }

    private var detail: String {
        if let release = updater.available {
            guard let date = release.publishedAt?.formatted(date: .abbreviated, time: .omitted) else {
                return String(localized: "You have \(BuildInfo.version)", comment: "Updates: the version installed")
            }
            return String(localized: "You have \(BuildInfo.version) · released \(date)", comment: "Updates: the version installed, and when the new one was released")
        }
        if let failure = updater.failure { return failure }
        if let checked = updater.lastChecked {
            let when = checked.formatted(.relative(presentation: .named))
            return updater.latest == nil ? String(localized: "Checked \(when) · no releases yet", comment: "Updates; the placeholder is like “5 minutes ago”")
                : String(localized: "Checked \(when)", comment: "Updates; the placeholder is like “5 minutes ago”")
        }
        return BuildInfo.isDebug ? String(localized: "Debug builds check only when you ask.") : String(localized: "Vibe Notepad checks when it opens.")
    }
}
