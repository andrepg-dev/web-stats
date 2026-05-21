import AppKit
import Foundation

struct SiteRecord: Identifiable, Codable, Equatable {
    var id: String { domain }
    let domain: String
    var seconds: TimeInterval
    var visits: Int
    var lastSeen: Date
}

struct TrackerSnapshot: Codable {
    var sites: [SiteRecord]
    var currentDomain: String?
    var lastUpdated: Date
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

final class HeadlessBraveTracker {
    private let pollInterval: TimeInterval = 5
    private var sites: [SiteRecord] = []
    private var currentURL: String?
    private var currentDomain: String?
    private var lastError: String?
    private var timer: Timer?
    private var lastTick = Date()
    private var previousDomain: String?
    private let storeURL: URL

    init() {
        AppPaths.prepareDataDirectory()
        storeURL = AppPaths.statsFile
        load()
    }

    func start() {
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func tick() {
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
            save()
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
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.brave.Browser"
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let snapshot = try JSONDecoder().decode(TrackerSnapshot.self, from: data)
            sites = snapshot.sites
            currentDomain = snapshot.currentDomain
        } catch {
            lastError = "Could not read saved totals: \(error.localizedDescription)"
        }
    }

    private func save() {
        let snapshot = TrackerSnapshot(sites: sites, currentDomain: currentDomain, lastUpdated: Date())
        do {
            let data = try JSONEncoder.pretty.encode(snapshot)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            lastError = "Could not save totals: \(error.localizedDescription)"
        }
    }

    static func domain(from urlString: String) -> String? {
        guard let url = URL(string: urlString), var host = url.host(percentEncoded: false) else {
            return nil
        }
        host = host.lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
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

let tracker = HeadlessBraveTracker()
tracker.start()
RunLoop.main.run()
