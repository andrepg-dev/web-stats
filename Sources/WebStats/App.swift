import AppKit
import Charts
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var tracker: BraveTracker?
    private var menuBarLoginItem: MenuBarLoginItemController?
    private var titleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let tracker = BraveTracker()
        let menuBarLoginItem = MenuBarLoginItemController()
        self.tracker = tracker
        self.menuBarLoginItem = menuBarLoginItem
        menuBarLoginItem.ensureInstalled()
        LegacyTrackerCleanup.removeObsoleteArtifacts()

        let content = MenuBarDashboard()
            .environmentObject(tracker)
            .frame(width: 460, height: 680)

        let hostingController = NSHostingController(rootView: content)
        let popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 680)
        self.popover = popover

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        let icon = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "web-stats")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "web-stats"
        if icon == nil {
            statusItem.button?.title = "WS"
        }
        self.statusItem = statusItem

        updateStatusTitle()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
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
        if button.image != nil {
            button.title = ""
        }
        if let currentDomain = tracker?.currentDomain {
            button.toolTip = "web-stats: \(currentDomain)"
        } else if let error = tracker?.lastError {
            button.toolTip = "web-stats: \(error)"
        } else {
            button.toolTip = "web-stats"
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

struct DailySiteRecord: Identifiable, Codable, Equatable {
    var id: String { "\(day)|\(domain)" }
    let day: String
    let domain: String
    var seconds: TimeInterval
    var visits: Int
    var lastSeen: Date
}

struct StatsSnapshot: Codable {
    var schemaVersion: Int
    var days: [DailySiteRecord]
    var lastUpdated: Date
}

struct DailyTotal: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    let seconds: TimeInterval
}

struct DailyDomainTotal: Identifiable, Equatable {
    var id: String { "\(day)|\(domain)" }
    let day: Date
    let domain: String
    let seconds: TimeInterval
}

enum StatsRange: Int, CaseIterable, Identifiable {
    case seven = 7
    case thirty = 30
    case sixty = 60

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { "\(rawValue) days" }
    var exportName: String { "\(rawValue)-days" }
}

enum StatsExportResult {
    case saved(URL)
    case cancelled
    case failed(Error)
}

enum AppPaths {
    static let appName = "web-stats"

    static var dataDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appName, isDirectory: true)
    }

    static var statsHistoryFile: URL {
        dataDirectory.appendingPathComponent("stats-history.json")
    }

    static func prepareDataDirectory() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }
}

enum StatsDate {
    static let calendar = Calendar.current

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func date(from dayKey: String) -> Date? {
        dayFormatter.date(from: dayKey)
    }

    static func startDate(for range: StatsRange, endingAt date: Date = Date()) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
    }

    static func days(in range: StatsRange, endingAt date: Date = Date()) -> [Date] {
        let start = startDate(for: range, endingAt: date)
        return (0..<range.days).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
    }
}

@MainActor
final class BraveTracker: ObservableObject {
    @Published private(set) var sites: [SiteRecord] = []
    @Published private(set) var dailyRecords: [DailySiteRecord] = []
    @Published private(set) var currentURL: String?
    @Published private(set) var currentDomain: String?
    @Published private(set) var isTracking = false
    @Published private(set) var lastError: String?

    private let pollInterval: TimeInterval = 5
    private let maxCountedInterval: TimeInterval = 120
    private let storeURL = AppPaths.statsHistoryFile
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastTick = Date()
    private var previousDomain: String?
    private var hasUnsavedChanges = false

    private static let braveBundleIdentifier = "com.brave.Browser"

    init() {
        do {
            try AppPaths.prepareDataDirectory()
            load()
        } catch {
            lastError = "Could not prepare history storage: \(error.localizedDescription)"
        }
        start()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func start() {
        guard !isTracking else { return }
        isTracking = true
        installActivationObserver()
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        tick()
    }

    func stop() {
        guard isTracking else { return }
        tick()
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        isTracking = false
        previousDomain = nil
        currentDomain = nil
        currentURL = nil
    }

    func reset() {
        sites.removeAll()
        dailyRecords.removeAll()
        previousDomain = nil
        currentDomain = nil
        currentURL = nil
        lastError = nil
        hasUnsavedChanges = true
        saveIfNeeded()
    }

    func refreshNow() {
        tick()
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

    var historyFileURL: URL {
        storeURL
    }

    func dailyTotals(for range: StatsRange) -> [DailyTotal] {
        let recordsByDay = Dictionary(grouping: records(for: range), by: \.day)
        return StatsDate.days(in: range).map { day in
            let key = StatsDate.dayKey(for: day)
            let seconds = recordsByDay[key]?.reduce(0) { $0 + $1.seconds } ?? 0
            return DailyTotal(day: day, seconds: seconds)
        }
    }

    func dailyDomainTotals(for range: StatsRange) -> [DailyDomainTotal] {
        records(for: range)
            .compactMap { record in
                guard let day = StatsDate.date(from: record.day) else { return nil }
                return DailyDomainTotal(day: day, domain: record.domain, seconds: record.seconds)
            }
            .sorted {
                if $0.day == $1.day {
                    return $0.domain < $1.domain
                }
                return $0.day < $1.day
            }
    }

    func rankedSites(for range: StatsRange) -> [SiteRecord] {
        aggregateSites(from: records(for: range))
    }

    func chartDomains(for range: StatsRange) -> [String] {
        rankedSites(for: range).prefix(6).map(\.domain)
    }

    func recentSites(for range: StatsRange) -> [SiteRecord] {
        records(for: range)
            .reduce(into: [String: SiteRecord]()) { result, record in
                let existing = result[record.domain]
                let current = SiteRecord(
                    domain: record.domain,
                    seconds: (existing?.seconds ?? 0) + record.seconds,
                    visits: (existing?.visits ?? 0) + record.visits,
                    lastSeen: max(existing?.lastSeen ?? .distantPast, record.lastSeen)
                )
                result[record.domain] = current
            }
            .values
            .sorted {
                if $0.lastSeen == $1.lastSeen {
                    return $0.seconds > $1.seconds
                }
                return $0.lastSeen > $1.lastSeen
            }
    }

    func totalSeconds(for range: StatsRange) -> TimeInterval {
        records(for: range).reduce(0) { $0 + $1.seconds }
    }

    func exportStats(for range: StatsRange) -> StatsExportResult {
        refreshNow()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "web-stats-\(range.exportName).csv"

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        do {
            try csvString(for: range).write(to: url, atomically: true, encoding: .utf8)
            return .saved(url)
        } catch {
            lastError = "Could not export stats: \(error.localizedDescription)"
            return .failed(error)
        }
    }

    private func tick() {
        let now = Date()
        let braveIsFrontmost = isBraveFrontmost()
        if let previousDomain {
            addElapsedTime(from: lastTick, to: now, for: previousDomain)
        }

        lastTick = now

        guard braveIsFrontmost else {
            previousDomain = nil
            currentDomain = nil
            currentURL = nil
            lastError = nil
            saveIfNeeded()
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

        pruneHistory()
        saveIfNeeded()
    }

    private func addTime(_ seconds: TimeInterval, to domain: String, at date: Date) {
        guard seconds > 0 else { return }

        if let index = sites.firstIndex(where: { $0.domain == domain }) {
            sites[index].seconds += seconds
            sites[index].lastSeen = date
        } else {
            sites.append(SiteRecord(domain: domain, seconds: seconds, visits: 0, lastSeen: date))
        }

        upsertDailyRecord(day: StatsDate.dayKey(for: date), domain: domain, seconds: seconds, visits: 0, at: date)
    }

    private func countVisit(to domain: String, at date: Date) {
        if let index = sites.firstIndex(where: { $0.domain == domain }) {
            sites[index].visits += 1
            sites[index].lastSeen = date
        } else {
            sites.append(SiteRecord(domain: domain, seconds: 0, visits: 1, lastSeen: date))
        }

        upsertDailyRecord(day: StatsDate.dayKey(for: date), domain: domain, seconds: 0, visits: 1, at: date)
    }

    private func isBraveFrontmost() -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Self.braveBundleIdentifier
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

    private func installActivationObserver() {
        guard activationObserver == nil else { return }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.handleActivatedApplication(app)
            }
        }
    }

    private func handleActivatedApplication(_ app: NSRunningApplication?) {
        let now = Date()

        if app?.bundleIdentifier == Self.braveBundleIdentifier {
            lastTick = now
            tick()
            return
        }

        if let previousDomain {
            addElapsedTime(from: lastTick, to: now, for: previousDomain)
        }

        lastTick = now
        previousDomain = nil
        currentDomain = nil
        currentURL = nil
        lastError = nil
        saveIfNeeded()
    }

    private func addElapsedTime(from start: Date, to end: Date, for domain: String) {
        let elapsed = end.timeIntervalSince(start)
        guard elapsed > 0, elapsed <= maxCountedInterval else { return }

        var segmentStart = start
        while segmentStart < end {
            let startOfDay = StatsDate.calendar.startOfDay(for: segmentStart)
            guard let nextDay = StatsDate.calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
                addTime(end.timeIntervalSince(segmentStart), to: domain, at: segmentStart)
                return
            }

            let segmentEnd = min(end, nextDay)
            addTime(segmentEnd.timeIntervalSince(segmentStart), to: domain, at: segmentStart)
            segmentStart = segmentEnd
        }
    }

    private func upsertDailyRecord(day: String, domain: String, seconds: TimeInterval, visits: Int, at date: Date) {
        if let index = dailyRecords.firstIndex(where: { $0.day == day && $0.domain == domain }) {
            dailyRecords[index].seconds += seconds
            dailyRecords[index].visits += visits
            dailyRecords[index].lastSeen = max(dailyRecords[index].lastSeen, date)
        } else {
            dailyRecords.append(DailySiteRecord(
                day: day,
                domain: domain,
                seconds: seconds,
                visits: visits,
                lastSeen: date
            ))
        }

        hasUnsavedChanges = true
    }

    private func records(for range: StatsRange) -> [DailySiteRecord] {
        let start = StatsDate.startDate(for: range)
        return dailyRecords.filter { record in
            guard let date = StatsDate.date(from: record.day) else { return false }
            return date >= start
        }
    }

    private func aggregateSites(from records: [DailySiteRecord]) -> [SiteRecord] {
        Dictionary(grouping: records, by: \.domain).map { domain, records in
            SiteRecord(
                domain: domain,
                seconds: records.reduce(0) { $0 + $1.seconds },
                visits: records.reduce(0) { $0 + $1.visits },
                lastSeen: records.map(\.lastSeen).max() ?? .distantPast
            )
        }
        .sorted {
            if $0.seconds == $1.seconds {
                return $0.domain < $1.domain
            }
            return $0.seconds > $1.seconds
        }
    }

    private func rebuildSitesFromHistory() {
        sites = aggregateSites(from: dailyRecords)
    }

    private func pruneHistory() {
        let start = StatsDate.startDate(for: .sixty)
        let countBefore = dailyRecords.count
        dailyRecords = dailyRecords.filter { record in
            guard let date = StatsDate.date(from: record.day) else { return false }
            return date >= start
        }

        if dailyRecords.count != countBefore {
            rebuildSitesFromHistory()
            hasUnsavedChanges = true
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }

        do {
            let snapshot = try JSONDecoder.webStats.decode(StatsSnapshot.self, from: data)
            dailyRecords = snapshot.days
            hasUnsavedChanges = false
            pruneHistory()
            rebuildSitesFromHistory()
            saveIfNeeded()
        } catch {
            lastError = "Could not read history: \(error.localizedDescription)"
        }
    }

    private func saveIfNeeded() {
        guard hasUnsavedChanges else { return }
        save()
    }

    private func save() {
        do {
            let snapshot = StatsSnapshot(
                schemaVersion: 1,
                days: dailyRecords.sorted {
                    if $0.day == $1.day {
                        return $0.domain < $1.domain
                    }
                    return $0.day < $1.day
                },
                lastUpdated: Date()
            )
            let data = try JSONEncoder.webStats.encode(snapshot)
            try data.write(to: storeURL, options: .atomic)
            hasUnsavedChanges = false
        } catch {
            lastError = "Could not save history: \(error.localizedDescription)"
        }
    }

    private func csvString(for range: StatsRange) -> String {
        let formatter = ISO8601DateFormatter()
        var rows = [
            ["date", "domain", "time_seconds", "time_minutes", "time_hours", "visits", "last_seen"]
        ]

        for record in records(for: range).sorted(by: { lhs, rhs in
            if lhs.day == rhs.day {
                return lhs.domain < rhs.domain
            }
            return lhs.day < rhs.day
        }) {
            rows.append([
                record.day,
                record.domain,
                String(Int(record.seconds.rounded())),
                String(format: "%.2f", record.seconds / 60),
                String(format: "%.2f", record.seconds / 3600),
                String(record.visits),
                formatter.string(from: record.lastSeen)
            ])
        }

        return rows.map(Self.csvLine).joined(separator: "\n") + "\n"
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
                return "\"\(escaped)\""
            }
            return escaped
        }
        .joined(separator: ",")
    }
}

extension JSONDecoder {
    static var webStats: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var webStats: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
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

enum LegacyTrackerCleanup {
    private static let labels = [
        "dev.local.webstats.agent",
        "dev.local.BraveSiteTracker.agent"
    ]

    static func removeObsoleteArtifacts() {
        removeObsoleteAgents()
        removeObsoleteHistoryFiles()
    }

    private static func removeObsoleteAgents() {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

        for label in labels {
            runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
            let plistURL = launchAgents.appendingPathComponent("\(label).plist")
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func removeObsoleteHistoryFiles() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first

        guard let appSupport else { return }

        for appName in ["web-stats", "BraveSiteTracker"] {
            let fileURL = appSupport
                .appendingPathComponent(appName, isDirectory: true)
                .appendingPathComponent("site-totals.json")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
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

struct MenuBarDashboard: View {
    @EnvironmentObject private var tracker: BraveTracker
    @State private var showingResetAlert = false
    @State private var selectedRange: StatsRange = .seven

    var body: some View {
        VStack(spacing: 0) {
            MenuHeaderView(showingResetAlert: $showingResetAlert)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    MenuSummaryCard()
                    MenuStatsSection(selectedRange: $selectedRange)
                    MenuSettingsCard()
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Reset all tracked time?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                tracker.reset()
            }
        } message: {
            Text("This deletes saved web-stats history.")
        }
        .onAppear {
            tracker.refreshNow()
        }
    }
}

struct MenuHeaderView: View {
    @EnvironmentObject private var tracker: BraveTracker
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
        return tracker.isTracking ? "Waiting for Brave" : "Tracking paused"
    }
}

struct MenuSummary: View {
    @EnvironmentObject private var tracker: BraveTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                StatBlock(title: "Tracked Sites", value: "\(tracker.sites.count)")
                StatBlock(title: "Total Time", value: DurationFormatter.string(from: tracker.totalSeconds))
                StatBlock(title: "Top Site", value: tracker.rankedSites.first?.domain ?? "None")
                StatBlock(title: "Current Site", value: tracker.currentDomain ?? "None")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuSummaryCard: View {
    var body: some View {
        DashboardCard {
            MenuSummary()
        }
    }
}

struct MenuStatsSection: View {
    @EnvironmentObject private var tracker: BraveTracker
    @Binding var selectedRange: StatsRange
    @State private var exportMessage: String?
    @State private var showingAllTopWebsites = false

    private var rangeSites: [SiteRecord] {
        tracker.rankedSites(for: selectedRange)
    }

    private var axisStride: Int {
        switch selectedRange {
        case .seven:
            return 1
        case .thirty:
            return 5
        case .sixty:
            return 10
        }
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("History")
                            .font(.subheadline.weight(.semibold))
                        Text("7, 30, 60 day view")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        exportStats()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Picker("Range", selection: $selectedRange) {
                    Text("7 days").tag(StatsRange.seven)
                    Text("30 days").tag(StatsRange.thirty)
                    Text("60 days").tag(StatsRange.sixty)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    StatBlock(title: "Total", value: DurationFormatter.string(from: tracker.totalSeconds(for: selectedRange)))
                    StatBlock(title: "Daily Avg", value: DurationFormatter.string(from: tracker.totalSeconds(for: selectedRange) / Double(selectedRange.days)))
                }

                let chartDomains = tracker.chartDomains(for: selectedRange)
                Chart(tracker.dailyDomainTotals(for: selectedRange)) { point in
                    BarMark(
                        x: .value("Day", point.day, unit: .day),
                        y: .value("Minutes", point.seconds / 60)
                    )
                    .foregroundStyle(by: .value("Website", point.domain))
                }
                .chartForegroundStyleScale(
                    domain: chartDomains,
                    range: chartDomains.map(DomainPalette.color(for:))
                )
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: axisStride)) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxisLabel("Minutes")
                .frame(height: 190)

                if !chartDomains.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(chartDomains.prefix(6), id: \.self) { domain in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(DomainPalette.color(for: domain))
                                        .frame(width: 8, height: 8)
                                    Text(domain)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                            }
                        }
                    }
                }

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Top Websites")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Max 20")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if rangeSites.isEmpty {
                        Text("No data for this range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(Array(rangeSites.prefix(showingAllTopWebsites ? 20 : 10).enumerated()), id: \.element.domain) { index, site in
                                SiteRow(
                                    rank: index + 1,
                                    site: site,
                                    maxSeconds: max(1, rangeSites.first?.seconds ?? 1),
                                    swatch: DomainPalette.color(for: site.domain)
                                )
                            }
                        }

                        if rangeSites.count > 10 {
                            Button {
                                showingAllTopWebsites.toggle()
                            } label: {
                                Text(showingAllTopWebsites ? "Show less" : "Show more")
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recently Visited")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Max 6")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    let recentSites = tracker.recentSites(for: selectedRange)

                    if recentSites.isEmpty {
                        Text("No recent visits for this range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(Array(recentSites.prefix(6).enumerated()), id: \.element.domain) { index, site in
                                RecentSiteRow(
                                    rank: index + 1,
                                    site: site,
                                    swatch: DomainPalette.color(for: site.domain)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func exportStats() {
        switch tracker.exportStats(for: selectedRange) {
        case .saved(let url):
            exportMessage = "Exported \(url.lastPathComponent)"
        case .cancelled:
            break
        case .failed(let error):
            exportMessage = error.localizedDescription
        }
    }
}

struct SiteRow: View {
    let rank: Int
    let site: SiteRecord
    let maxSeconds: TimeInterval
    let swatch: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(swatch)
                    .frame(width: 8, height: 8)
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
    }
}

struct RecentSiteRow: View {
    let rank: Int
    let site: SiteRecord
    let swatch: Color

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(swatch)
                .frame(width: 8, height: 8)
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(site.domain)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer()
            Text(Self.formatter.localizedString(for: site.lastSeen, relativeTo: Date()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
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

struct MenuSettingsCard: View {
    @EnvironmentObject private var tracker: BraveTracker

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current URL")
                    .font(.subheadline.weight(.semibold))

                Text(tracker.currentURL ?? "No active Brave tab")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("History file")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(tracker.historyFileURL.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit", systemImage: "power")
                    }
                    .buttonStyle(.bordered)
                }
            }
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

struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

enum DomainPalette {
    static func color(for domain: String) -> Color {
        let hash = stableHash(domain)
        let hue = Double(hash % 360) / 360.0
        let saturation = 0.58 + Double((hash >> 8) % 20) / 100.0
        let brightness = 0.72 + Double((hash >> 16) % 14) / 100.0
        return Color(hue: hue, saturation: min(saturation, 0.85), brightness: min(brightness, 0.92))
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
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
