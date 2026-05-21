import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var tracker: BraveTracker?
    private var backgroundAgent: BackgroundAgentController?
    private var menuBarLoginItem: MenuBarLoginItemController?
    private var titleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let tracker = BraveTracker(mode: .viewer)
        let backgroundAgent = BackgroundAgentController()
        let menuBarLoginItem = MenuBarLoginItemController()
        self.tracker = tracker
        self.backgroundAgent = backgroundAgent
        self.menuBarLoginItem = menuBarLoginItem
        menuBarLoginItem.ensureInstalled()

        let content = MenuBarDashboard()
            .environmentObject(tracker)
            .environmentObject(backgroundAgent)
            .frame(width: 420, height: 560)

        let hostingController = NSHostingController(rootView: content)
        let popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 560)
        self.popover = popover

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        let icon = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "web-stats")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.toolTip = "web-stats"
        if icon == nil {
            statusItem.button?.title = "WS"
        }
        self.statusItem = statusItem

        updateStatusTitle()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tracker?.refreshNow()
                self?.backgroundAgent?.refresh()
                self?.updateStatusTitle()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    @objc private func togglePopover() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        button.title = " \(menuBarTitle())"
        button.toolTip = tracker?.currentDomain.map { "web-stats: \($0)" } ?? "web-stats"
    }

    private func menuBarTitle() -> String {
        guard let tracker else { return "0s" }
        if let currentDomain = tracker.currentDomain {
            let seconds = tracker.sites.first { $0.domain == currentDomain }?.seconds ?? 0
            return "\(Self.compactDomain(currentDomain)) \(DurationFormatter.string(from: seconds))"
        }

        if let topSite = tracker.rankedSites.first {
            return "\(Self.compactDomain(topSite.domain)) \(DurationFormatter.string(from: topSite.seconds))"
        }

        return "0s"
    }

    private static func compactDomain(_ domain: String) -> String {
        guard domain.count > 22 else { return domain }
        let end = domain.suffix(19)
        return "...\(end)"
    }
}

enum AppPaths {
    static let appName = "web-stats"
    static let oldAppName = "BraveSiteTracker"

    static var dataDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appName, isDirectory: true)
    }

    static var oldDataDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(oldAppName, isDirectory: true)
    }

    static var statsFile: URL {
        dataDirectory.appendingPathComponent("site-totals.json")
    }

    static func prepareDataDirectory() {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let oldStats = oldDataDirectory.appendingPathComponent("site-totals.json")
        if !FileManager.default.fileExists(atPath: statsFile.path),
           FileManager.default.fileExists(atPath: oldStats.path) {
            try? FileManager.default.copyItem(at: oldStats, to: statsFile)
        }
    }
}

struct SiteRecord: Identifiable, Codable, Equatable {
    var id: String { domain }
    let domain: String
    var seconds: TimeInterval
    var visits: Int
    var lastSeen: Date
}

struct TrackerSnapshot: Codable {
    var sites: [SiteRecord]
    var currentURL: String?
    var currentDomain: String?
    var lastError: String?
    var lastUpdated: Date
}

@MainActor
final class BraveTracker: ObservableObject {
    enum Mode {
        case tracking
        case viewer
    }

    @Published private(set) var sites: [SiteRecord] = []
    @Published private(set) var currentURL: String?
    @Published private(set) var currentDomain: String?
    @Published private(set) var isTracking = false
    @Published private(set) var lastError: String?

    private let pollInterval: TimeInterval = 5
    private var timer: Timer?
    private var lastTick = Date()
    private var previousDomain: String?
    private let storeURL: URL
    private let mode: Mode

    init(mode: Mode = .tracking) {
        self.mode = mode
        AppPaths.prepareDataDirectory()
        storeURL = AppPaths.statsFile
        load()
        if mode == .tracking {
            start()
        } else {
            startViewerUpdates()
        }
    }

    func start() {
        guard mode == .tracking else {
            refreshNow()
            return
        }
        guard !isTracking else { return }
        isTracking = true
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        tick()
    }

    func stop() {
        guard mode == .tracking else { return }
        guard isTracking else { return }
        tick()
        timer?.invalidate()
        timer = nil
        isTracking = false
        previousDomain = nil
        currentDomain = nil
        currentURL = nil
        save()
    }

    func reset() {
        sites.removeAll()
        previousDomain = nil
        currentDomain = nil
        currentURL = nil
        lastError = nil
        save()
    }

    func refreshNow() {
        mode == .tracking ? tick() : load()
    }

    var rankedSites: [SiteRecord] {
        sites.sorted {
            if $0.seconds == $1.seconds {
                return $0.domain < $1.domain
            }
            return $0.seconds > $1.seconds
        }
    }

    var totalSeconds: TimeInterval {
        sites.reduce(0) { $0 + $1.seconds }
    }

    var dataDirectoryURL: URL {
        storeURL.deletingLastPathComponent()
    }

    var statsFileURL: URL {
        storeURL
    }

    private func tick() {
        guard mode == .tracking else { return }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(lastTick))
        if let previousDomain, isBraveFrontmost() {
            addTime(elapsed, to: previousDomain, at: now)
        }

        lastTick = now

        guard isBraveFrontmost() else {
            previousDomain = nil
            currentDomain = nil
            currentURL = nil
            lastError = nil
            return
        }

        do {
            let url = try BraveAppleScript.activeTabURL()
            let activeDomain = Self.domain(from: url)
            currentURL = url
            currentDomain = activeDomain
            if let activeDomain, activeDomain != previousDomain {
                countVisit(to: activeDomain, at: now)
            }
            previousDomain = activeDomain
            if activeDomain != nil {
                lastError = nil
            }
        } catch {
            currentURL = nil
            currentDomain = nil
            previousDomain = nil
            lastError = error.localizedDescription
        }

        save()
    }

    private func startViewerUpdates() {
        isTracking = true
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.load()
            }
        }
    }

    private func addTime(_ seconds: TimeInterval, to domain: String, at date: Date) {
        guard seconds > 0 else { return }

        if let index = sites.firstIndex(where: { $0.domain == domain }) {
            sites[index].seconds += seconds
            sites[index].lastSeen = date
        } else {
            sites.append(SiteRecord(domain: domain, seconds: seconds, visits: 0, lastSeen: date))
        }
    }

    private func countVisit(to domain: String, at date: Date) {
        if let index = sites.firstIndex(where: { $0.domain == domain }) {
            sites[index].visits += 1
            sites[index].lastSeen = date
        } else {
            sites.append(SiteRecord(domain: domain, seconds: 0, visits: 1, lastSeen: date))
        }
    }

    private func isBraveFrontmost() -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == "com.brave.Browser"
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let snapshot = try JSONDecoder().decode(TrackerSnapshot.self, from: data)
            sites = snapshot.sites
            currentURL = snapshot.currentURL
            currentDomain = snapshot.currentDomain
            lastError = snapshot.lastError
        } catch {
            lastError = "Could not read saved totals: \(error.localizedDescription)"
        }
    }

    private func save() {
        let snapshot = TrackerSnapshot(
            sites: sites,
            currentURL: currentURL,
            currentDomain: currentDomain,
            lastError: lastError,
            lastUpdated: Date()
        )
        do {
            let data = try JSONEncoder.pretty.encode(snapshot)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            lastError = "Could not save totals: \(error.localizedDescription)"
        }
    }

    static func domain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              var host = url.host(percentEncoded: false) else {
            return nil
        }
        host = host.lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
    }
}

enum LaunchAgentPlist {
    static func write(_ propertyList: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }
}

enum CurrentAppBundle {
    static var url: URL? {
        let candidates = [
            Bundle.main.bundleURL,
            Bundle.main.executableURL
        ].compactMap { $0 }

        for candidate in candidates {
            if let appURL = enclosingAppBundle(from: candidate) {
                return appURL
            }
        }

        return nil
    }

    private static func enclosingAppBundle(from url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        if !candidate.hasDirectoryPath {
            candidate.deleteLastPathComponent()
        }

        while candidate.path != "/" {
            if candidate.pathExtension == "app",
               FileManager.default.fileExists(
                   atPath: candidate
                       .appendingPathComponent("Contents/Info.plist")
                       .path
               ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return nil
    }
}

@MainActor
final class MenuBarLoginItemController {
    private let label = "dev.local.webstats.menubar"
    private let plistURL: URL

    init() {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        plistURL = launchAgents.appendingPathComponent("\(label).plist")
    }

    func ensureInstalled() {
        do {
            try install()
        } catch {
            try? "Menu bar login item failed: \(error.localizedDescription)\n"
                .write(
                    to: URL(fileURLWithPath: "/tmp/web-stats.menubar.err"),
                    atomically: true,
                    encoding: .utf8
                )
            // The menu bar app still works when opened manually; this only affects login startup.
        }
    }

    private func install() throws {
        guard let appURL = CurrentAppBundle.url else {
            throw NSError(domain: "web-stats", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not resolve web-stats.app from \(Bundle.main.bundleURL.path)."
            ])
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try LaunchAgentPlist.write([
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/open",
                "-gj",
                appURL.path
            ],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ], to: plistURL)
    }
}

@MainActor
final class BackgroundAgentController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastError: String?

    private let label = "dev.local.webstats.agent"
    private let plistURL: URL

    init() {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        plistURL = launchAgents.appendingPathComponent("\(label).plist")
        isEnabled = FileManager.default.fileExists(atPath: plistURL.path)
        ensureInstalledAndRunning()
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? ensureInstalledAndRunning() : remove()
    }

    func refresh() {
        isEnabled = FileManager.default.fileExists(atPath: plistURL.path)
    }

    func ensureInstalledAndRunning() {
        do {
            try install()
            try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path], allowFailure: true)
            try launchctl(["enable", "gui/\(getuid())/\(label)"], allowFailure: true)
            try launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"], allowFailure: true)
            isEnabled = true
            lastError = nil
        } catch {
            refresh()
            lastError = "Background agent failed: \(error.localizedDescription)"
        }
    }

    private func remove() {
        do {
            try launchctl(["bootout", "gui/\(getuid())/\(label)"], allowFailure: true)
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
            isEnabled = false
            lastError = nil
        } catch {
            refresh()
            lastError = "Could not remove background agent: \(error.localizedDescription)"
        }
    }

    private func install() throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let bundleURL = CurrentAppBundle.url ?? Bundle.main.bundleURL
        let executableURL = bundleURL
            .appendingPathComponent("Contents/MacOS/web-stats-agent")
        try LaunchAgentPlist.write([
            "Label": label,
            "ProgramArguments": [
                executableURL.path
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": "/tmp/web-stats.agent.log",
            "StandardErrorPath": "/tmp/web-stats.agent.err"
        ], to: plistURL)
    }

    private func launchctl(_ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 || allowFailure else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "launchctl failed"
            throw NSError(domain: "web-stats", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
        }
    }
}

enum BraveAppleScript {
    enum ScriptError: LocalizedError {
        case emptyURL
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyURL:
                return "Brave has no active tab URL."
            case .scriptFailed(let message):
                return message
            }
        }
    }

    static func activeTabURL() throws -> String {
        let source = """
        tell application "Brave Browser"
            if (count of windows) is 0 then return ""
            return URL of active tab of front window
        end tell
        """

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let result = script.executeAndReturnError(&errorInfo).stringValue else {
            let message = errorInfo?[NSAppleScript.errorMessage] as? String
            throw ScriptError.scriptFailed(message ?? "Could not read Brave active tab. macOS may need Automation permission.")
        }

        guard !result.isEmpty else {
            throw ScriptError.emptyURL
        }

        return result
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

struct MenuBarDashboard: View {
    @EnvironmentObject private var tracker: BraveTracker
    @EnvironmentObject private var backgroundAgent: BackgroundAgentController
    @State private var showingResetAlert = false

    var body: some View {
        VStack(spacing: 0) {
            MenuHeaderView(showingResetAlert: $showingResetAlert)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MenuSummary()
                    MenuTopSites()
                    MenuSettings()
                }
                .padding(18)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Reset all tracked time?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                tracker.reset()
            }
        } message: {
            Text("This deletes local totals stored by web-stats.")
        }
        .onAppear {
            backgroundAgent.refresh()
            tracker.refreshNow()
        }
    }
}

struct MenuHeaderView: View {
    @EnvironmentObject private var tracker: BraveTracker
    @EnvironmentObject private var backgroundAgent: BackgroundAgentController
    @Binding var showingResetAlert: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("web-stats")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                tracker.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")

            Button {
                backgroundAgent.setEnabled(!backgroundAgent.isEnabled)
            } label: {
                Image(systemName: backgroundAgent.isEnabled ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help(backgroundAgent.isEnabled ? "Stop background tracker" : "Start background tracker")

            Button(role: .destructive) {
                showingResetAlert = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Reset tracked totals")
        }
        .padding(16)
    }

    private var statusText: String {
        if let error = tracker.lastError {
            return error
        }
        if let domain = tracker.currentDomain {
            return "Tracking \(domain)"
        }
        return backgroundAgent.isEnabled ? "Background tracker running" : "Background tracker off"
    }
}

struct MenuSummary: View {
    @EnvironmentObject private var tracker: BraveTracker
    @EnvironmentObject private var backgroundAgent: BackgroundAgentController

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
                StatBlock(title: "Tracked Sites", value: "\(tracker.sites.count)")
                StatBlock(title: "Total Time", value: DurationFormatter.string(from: tracker.totalSeconds))
            }
            GridRow {
                StatBlock(title: "Top Site", value: tracker.rankedSites.first?.domain ?? "None")
                StatBlock(title: "Status", value: backgroundAgent.isEnabled ? "Background" : "Off")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuTopSites: View {
    @EnvironmentObject private var tracker: BraveTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Websites")
                .font(.subheadline.weight(.semibold))

            if tracker.rankedSites.isEmpty {
                EmptyStateView()
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(tracker.rankedSites.prefix(8).enumerated()), id: \.element.domain) { index, site in
                        SiteRow(rank: index + 1, site: site, maxSeconds: max(1, tracker.rankedSites.first?.seconds ?? 1))
                    }
                }
            }
        }
    }
}

struct SiteRow: View {
    let rank: Int
    let site: SiteRecord
    let maxSeconds: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                Text(site.domain)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(DurationFormatter.string(from: site.seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: site.seconds / maxSeconds)
                .progressViewStyle(.linear)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }
}

struct MenuSettings: View {
    @EnvironmentObject private var tracker: BraveTracker
    @EnvironmentObject private var backgroundAgent: BackgroundAgentController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Toggle("Background tracker", isOn: Binding(
                get: { backgroundAgent.isEnabled },
                set: { backgroundAgent.setEnabled($0) }
            ))

            Text("Keeps tracking after menubar app closes and starts again at login.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = backgroundAgent.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Local data")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(tracker.statsFileURL.path)
                    .font(.caption)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([tracker.statsFileURL])
                } label: {
                    Label("Show Data File", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Current URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(tracker.currentURL ?? "No active Brave tab")
                    .font(.caption)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Menu Bar", systemImage: "power")
            }
            .buttonStyle(.bordered)
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No tracked sites yet")
                .font(.callout.weight(.semibold))
            Text("Bring Brave to the front and browse. Time appears here after a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
    }
}

enum DurationFormatter {
    static let compact: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    static func string(from seconds: TimeInterval) -> String {
        compact.string(from: seconds) ?? "0s"
    }
}
