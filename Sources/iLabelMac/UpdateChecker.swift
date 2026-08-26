import AppKit
import CryptoKit
import SwiftUI

/// Checks the project homepage's `feed.json` for a newer macOS build and, when
/// one exists, offers it in the app's own design — a small card in the corner
/// of the editor, not an alert parked over the canvas. Saying yes downloads the
/// DMG in-app, verifies it against the SHA-256 the feed pinned, swaps the
/// bundle in place, and relaunches. Nothing is downloaded without being asked.
///
/// The in-app path matters beyond convenience: a browser-downloaded DMG is
/// quarantined, and Gatekeeper refuses to launch an ad-hoc-signed app from a
/// quarantined image. A download made by the app itself carries no quarantine,
/// and the feed's checksum — served from the project's own HTTPS origin — is
/// what vouches for the bytes instead.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Offer: Decodable, Equatable {
        let version: String
        let url: String
        let notes: String?
        let sha256: String?
    }

    enum Phase: Equatable {
        case offer
        /// Fraction complete, or nil while the size is still unknown.
        case downloading(Double?)
        case installing
        case failed(String)
    }

    @Published var offer: Offer?
    @Published var phase: Phase = .offer

    /// Overridable so a lab copy can watch its own feed and a test can serve one
    /// from a file.
    static var feedURL: URL {
        if let raw = ProcessInfo.processInfo.environment["ILABEL_UPDATE_FEED"],
           let url = URL(string: raw) { return url }
        return URL(string: "https://jaeyoonsung.github.io/iLabel-Studio/feed.json")!
    }
    static let releasesURL = URL(string: "https://github.com/JAEYOONSUNG/iLabel-Studio/releases/latest")!
    private static let skippedVersionKey = "UpdateCheckerSkippedVersion"
    private var checkedThisSession = false

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
    /// ready to restart anyway, and the feed is a few hundred bytes. One check
    /// per session; the skip preference silences a version for good.
    func checkSoon() {
        Task { await check() }
    }

    func check() async {
        guard !checkedThisSession else { return }
        checkedThisSession = true
        guard let current = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return } // running from source there is no bundle to replace

        var request = URLRequest(url: Self.feedURL, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
              data.count < 64 * 1024,
              let feed = try? JSONDecoder().decode([String: Offer].self, from: data),
              let entry = feed["mac"],
              Self.isVersion(entry.version, newerThan: current)
        else { return } // silent: a Mac with no network must not be told something is wrong

        if UserDefaults.standard.string(forKey: Self.skippedVersionKey) == entry.version { return }

        phase = .offer
        offer = entry
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    func install() {
        guard let offer, phase == .offer || phase.isFailure else { return }
        phase = .downloading(nil)
        let bundleURL = Bundle.main.bundleURL
        // The checker is a process-lifetime singleton, so the detached work
        // reports back through it by name — capturing `self` weakly here trips
        // Swift 6's Sendable checking for no benefit.
        Task.detached(priority: .userInitiated) {
            do {
                try await Self.performInstall(offer: offer, bundleURL: bundleURL) { fraction in
                    Task { @MainActor in UpdateChecker.shared.phase = .downloading(fraction) }
                } installing: {
                    Task { @MainActor in UpdateChecker.shared.phase = .installing }
                }
                await MainActor.run { Self.relaunch(bundleURL) }
            } catch {
                let message = (error as? InstallError)?.message ?? error.localizedDescription
                Task { @MainActor in UpdateChecker.shared.phase = .failed(message) }
            }
        }
    }

    func openDownloadsPage() {
        NSWorkspace.shared.open(
            offer.flatMap { URL(string: $0.url) } ?? Self.releasesURL)
        offer = nil
    }

    func skip() {
        guard let offer else { return }
        UserDefaults.standard.set(offer.version, forKey: Self.skippedVersionKey)
        self.offer = nil
    }

    func later() {
        offer = nil
    }

    // MARK: - The install itself

    struct InstallError: Error {
        let message: String
    }

    private nonisolated static func performInstall(
        offer: Offer,
        bundleURL: URL,
        progress: @escaping @Sendable (Double?) -> Void,
        installing: @escaping @Sendable () -> Void
    ) async throws {
        guard let remote = URL(string: offer.url) else {
            throw InstallError(message: "The update feed has no usable download address.")
        }
        guard let expected = offer.sha256?.lowercased(), expected.count == 64 else {
            throw InstallError(message: "The update feed carries no checksum, so the download cannot be verified.")
        }

        let fm = FileManager.default
        let workspace = fm.temporaryDirectory
            .appendingPathComponent("ilabel-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        // 1. Download, showing every megabyte — a silent transfer reads as frozen.
        let dmg = workspace.appendingPathComponent("update.dmg")
        try await download(remote, to: dmg, progress: progress)

        // 2. The checksum from the feed's HTTPS origin is what vouches for the bytes.
        let digest = try sha256(of: dmg)
        guard digest == expected else {
            throw InstallError(message: "The downloaded file does not match the published checksum, so it was not installed.")
        }

        installing()

        // 3. Mount the image somewhere predictable.
        let mount = workspace.appendingPathComponent("mount", isDirectory: true)
        try run("/usr/bin/hdiutil",
                ["attach", dmg.path, "-nobrowse", "-readonly", "-quiet",
                 "-mountpoint", mount.path],
                failure: "The update image could not be opened.")
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"], failure: "")
        }

        guard let replacement = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw InstallError(message: "The update image holds no application.")
        }

        // 4. Swap the bundle: the old app steps aside first so a failed copy
        //    can put it straight back.
        let backup = workspace.appendingPathComponent("previous.app")
        try fm.moveItem(at: bundleURL, to: backup)
        do {
            try run("/usr/bin/ditto", [replacement.path, bundleURL.path],
                    failure: "The new version could not be copied into place.")
        } catch {
            try? fm.moveItem(at: backup, to: bundleURL)
            throw error
        }
    }

    private nonisolated static func download(
        _ remote: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: remote)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError(message: "The download answered HTTP \(http.statusCode).")
        }
        let total = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data(capacity: 256 * 1024)
        var received: Int64 = 0
        var lastReported = -1
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    let percent = Int(received * 100 / total)
                    if percent != lastReported {
                        lastReported = percent
                        progress(Double(received) / Double(total))
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        progress(1)
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private nonisolated static func run(
        _ tool: String, _ arguments: [String], failure: String
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError(message: failure.isEmpty
                ? "\(tool) exited with status \(process.terminationStatus)."
                : failure)
        }
        return process.terminationStatus
    }

    /// `quitAndInstall`, by hand: a detached shell waits for this process to
    /// exit and opens the new bundle.
    private static func relaunch(_ bundleURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c",
            "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; " +
            "/usr/bin/open \"\(bundleURL.path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }
}

extension UpdateChecker.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The offer card, styled like every other panel in the editor.
struct UpdateBannerView: View {
    @ObservedObject var checker: UpdateChecker = .shared

    var body: some View {
        if let offer = checker.offer {
            VStack(alignment: .leading, spacing: 8) {
                switch checker.phase {
                case .offer:
                    Text("iLabel Studio \(offer.version) is available")
                        .font(.system(size: 12, weight: .bold))
                    Text(offerText(for: offer))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Button("Skip") { checker.skip() }
                        Button("Later") { checker.later() }
                        Button("Install Update") { checker.install() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)

                case .downloading(let fraction):
                    Text("Downloading \(offer.version)…")
                        .font(.system(size: 12, weight: .bold))
                    if let fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                        Text("\(Int(fraction * 100))% — it installs and relaunches by itself.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("Starting the download…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                case .installing:
                    Text("Installing \(offer.version)…")
                        .font(.system(size: 12, weight: .bold))
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("iLabel Studio relaunches in a moment.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                case .failed(let message):
                    Text("The update could not be installed")
                        .font(.system(size: 12, weight: .bold))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Button("Close") { checker.later() }
                        Button("Open Downloads Page") { checker.openDownloadsPage() }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 300, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appCardBackground())
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Update available")
        }
    }

    private func offerText(for offer: UpdateChecker.Offer) -> String {
        var detail = "You have \(checker.currentVersion)."
        if let notes = offer.notes, !notes.isEmpty { detail += " \(notes)" }
        detail += " Installing downloads the update, verifies it, and relaunches the app."
        return detail
    }
}
