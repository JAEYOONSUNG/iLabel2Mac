import AppKit
import Foundation

/// Checks the project homepage's `feed.json` for a newer macOS build and, when
/// one exists, offers to download it. The feed is a few hundred bytes and this
/// is the only outbound request the checker makes; the DMG itself is fetched by
/// the browser only after the person says so. An ad-hoc-signed bundle cannot
/// swap itself out safely, so this names the newer version and hands over the
/// download — the same rule an unsigned build gets everywhere.
@MainActor
enum UpdateChecker {
    static let feedURL = URL(string: "https://jaeyoonsung.github.io/iLabel-Studio/feed.json")!
    static let releasesURL = URL(string: "https://github.com/JAEYOONSUNG/iLabel-Studio/releases/latest")!
    private static let skippedVersionKey = "UpdateCheckerSkippedVersion"
    private static let lastPromptKey = "UpdateCheckerLastPrompt"
    private static let checkEvery: TimeInterval = 6 * 60 * 60
    private static var promptedThisSession = false

    struct FeedEntry: Decodable {
        let version: String
        let url: String
        let notes: String?
    }

    /// `1.1.34` against `1.1.9`: compared as numbers, field by field, because
    /// string order puts 1.1.9 after 1.1.34 and would offer a downgrade.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            (value
                .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: "-")
                .first ?? "")
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let lhs = parts(candidate)
        let rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// A launch is the moment to look — somebody who reopens after a release is
    /// ready to restart anyway. `promptedThisSession` holds the rest of the
    /// session, and the stored time bounds long-running ones.
    static func checkSoon() {
        Task { await check() }
    }

    static func check() async {
        guard !promptedThisSession else { return }
        guard let current = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return } // running from source there is no bundle to replace

        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastPromptKey) as? Date,
           Date().timeIntervalSince(last) < checkEvery { return }

        var request = URLRequest(url: feedURL, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 64 * 1024,
              let feed = try? JSONDecoder().decode([String: FeedEntry].self, from: data),
              let entry = feed["mac"],
              isVersion(entry.version, newerThan: current)
        else { return } // silent: a Mac with no network must not be told something is wrong

        if defaults.string(forKey: skippedVersionKey) == entry.version { return }

        promptedThisSession = true
        defaults.set(Date(), forKey: lastPromptKey)

        let alert = NSAlert()
        alert.messageText = "iLabel Studio \(entry.version) is available"
        var detail = "You have \(current)."
        if let notes = entry.notes, !notes.isEmpty { detail += "\n\n\(notes)" }
        detail += "\n\nThe download opens in your browser. Quit iLabel Studio, then drag the new app into Applications to replace this one."
        alert.informativeText = detail
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: entry.url) ?? releasesURL)
        case .alertThirdButtonReturn:
            defaults.set(entry.version, forKey: skippedVersionKey)
        default:
            break
        }
    }
}
