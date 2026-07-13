import Foundation
import CoreWLAN
import CoreLocation

/// macOS 15+ gates programmatic Wi-Fi control behind Location Services:
/// without it, scan results come back with the SSID redacted and
/// `CWInterface.associate` fails with -3900 tmpErr even with the correct
/// password (verified on macOS 26 — the Wi-Fi menu works because system UI
/// is exempt). Requesting once at launch is what makes Wi-Fi printing
/// possible at all on modern macOS.
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var authorized = false

    override init() {
        super.init()
        manager.delegate = self
        cacheStatus(manager.authorizationStatus)
    }

    func requestIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Safe to read from any thread — CLLocationManager itself wants the
    /// main thread, so the status is cached via the delegate callback.
    var isAuthorized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authorized
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        cacheStatus(manager.authorizationStatus)
    }

    private func cacheStatus(_ status: CLAuthorizationStatus) {
        let granted = status == .authorizedAlways || status == .authorized
        lock.lock()
        authorized = granted
        lock.unlock()
    }
}

enum WiFiAutomationError: LocalizedError {
    case missingPrinterSSID
    case missingWiFiDevice
    case commandFailed(String)
    case connectionTimeout(String)

    var errorDescription: String? {
        switch self {
        case .missingPrinterSSID:
            return "Printer Wi-Fi SSID is empty."
        case .missingWiFiDevice:
            return "Could not find the Mac's Wi-Fi device."
        case let .commandFailed(message):
            return message
        case let .connectionTimeout(message):
            return message
        }
    }
}

struct WiFiPrintSession {
    let service: String
    let previousSSID: String?
    let settings: PrintAutomationSettings

    func restore() async throws {
        guard settings.enabled, settings.reconnectToPreviousWiFi else { return }
        let target = WiFiPrintAutomation.restoreTargetSSID(
            previousSSID: previousSSID,
            configuredRestoreSSID: settings.restoreSSID,
            printerSSID: settings.printerSSID,
            preferredNetworks: WiFiPrintAutomation.preferredNetworks()
        )
        if let target {
            do {
                try await WiFiPrintAutomation.connectAndWait(
                    service: service,
                    ssid: target,
                    password: nil
                )
                return
            } catch {
                // Direct rejoin can fail (e.g. the network's password isn't
                // readable to us) — fall through to the system auto-join.
            }
        }
        try await WiFiPrintAutomation.autoJoinFallback(printerSSID: settings.printerSSID)
    }
}

enum WiFiPrintAutomation {
    static let airportTool = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"

    /// macOS 15+ redacts the SSID from every CLI (networksetup reports
    /// "not associated" even while connected — verified on macOS 26), so
    /// SSID reads can never succeed there. Deciding by OS version, not by
    /// observed failures, matters: a read that fails because Wi-Fi happens
    /// to be off at launch must not permanently disable the SSID paths on
    /// systems where reads do work.
    static let systemRedactsSSID: Bool = {
        if #available(macOS 15, *) {
            return true
        }
        return false
    }()

    /// The Wi-Fi device name (e.g. "en0") never changes while the app runs,
    /// but probing it spawns `networksetup -listallhardwareports` (hundreds
    /// of ms) — and it used to be probed again inside every SSID read and
    /// every 400ms poll of the connect wait. Resolve it once.
    private static let cachedWiFiDevice: String? = probeWiFiDevice()

    static func wifiDevice() -> String? {
        cachedWiFiDevice
    }

    private static func probeWiFiDevice() -> String? {
        guard let output = try? run("/usr/sbin/networksetup", ["-listallhardwareports"]) else {
            return nil
        }

        let lines = output.components(separatedBy: .newlines)
        var sawWiFiPort = false

        for line in lines {
            if line.hasPrefix("Hardware Port: ") {
                sawWiFiPort = line == "Hardware Port: Wi-Fi"
                continue
            }

            if sawWiFiPort, line.hasPrefix("Device: ") {
                return line.replacingOccurrences(of: "Device: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    static func currentSSID(service: String) -> String? {
        // First choice: in-process CoreWLAN. Instant (no process spawn), and
        // once the user grants Location Services it is the only reader that
        // still works on macOS 15+ (every CLI redacts the SSID there).
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            return ssid
        }
        // On redacted systems the CLI fallbacks below can't do better than
        // the CoreWLAN read — skip their process spawns entirely.
        if systemRedactsSSID {
            return nil
        }

        // Fallback: `networksetup -getairportnetwork <device>`. Works on
        // pre-15 macOS with no Location Services permission. Apple removed
        // the private `airport` tool in macOS 14.4, which used to be the only
        // path here — its loss made waitUntilConnected() always time out (it
        // could never confirm the connection), breaking Wi-Fi printing.
        if let device = wifiDevice(),
           let output = try? run("/usr/sbin/networksetup", ["-getairportnetwork", device]) {
            let marker = "Current Wi-Fi Network: "
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix(marker) {
                    let ssid = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ssid.isEmpty {
                        return ssid
                    }
                }
            }
        }

        // Fallback for macOS < 14.4 where the private airport tool still exists.
        if FileManager.default.fileExists(atPath: airportTool),
           let output = try? run(airportTool, ["-I"]) {
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("SSID: ") {
                    return trimmed.replacingOccurrences(of: "SSID: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }

    static func preferredNetworks() -> [String] {
        guard let device = wifiDevice(),
              let output = try? run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", device]) else {
            return []
        }

        return output
            .components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func autoDetectedPrinterSSID() -> String? {
        let candidates = preferredNetworks()
        let ranked = candidates.sorted { lhs, rhs in
            scoreCandidate(lhs) > scoreCandidate(rhs)
        }
        return ranked.first(where: { scoreCandidate($0) > 0 })
    }

    /// Picks the network to return to after printing. Preference order: the
    /// SSID captured before switching, the user-configured restore SSID, then
    /// the highest-priority preferred network that doesn't look like a
    /// printer. The fallbacks matter on macOS 15+, where the current SSID is
    /// redacted from every CLI and `previousSSID` is therefore usually nil.
    static func restoreTargetSSID(
        previousSSID: String?,
        configuredRestoreSSID: String?,
        printerSSID: String,
        preferredNetworks: [String]
    ) -> String? {
        let printer = printerSSID.trimmingCharacters(in: .whitespacesAndNewlines)

        func usable(_ candidate: String?) -> String? {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, trimmed != printer else { return nil }
            return trimmed
        }

        if let captured = usable(previousSSID) { return captured }
        if let configured = usable(configuredRestoreSSID) { return configured }
        return preferredNetworks
            .compactMap { usable($0) }
            .first { scoreCandidate($0) == 0 }
    }

    private static func scoreCandidate(_ ssid: String) -> Int {
        let lower = ssid.lowercased()
        var score = 0
        if lower.hasPrefix("direct-") { score += 100 }
        if lower.contains("laserjet") { score += 40 }
        if lower.contains("hp") { score += 20 }
        if lower.contains("print") { score += 10 }
        return score
    }

    /// Reads the current IPv4 address of the Wi-Fi device, if any. After a Wi-Fi
    /// association the SSID matches almost immediately, but DHCP on a printer's
    /// SoftAP can take a couple of seconds to hand out an address — and without
    /// an IP the print job cannot reach the printer. This lets us wait for real
    /// reachability instead of just a matching SSID string.
    static func ipv4Address(device: String) -> String? {
        guard let output = try? run("/usr/sbin/ipconfig", ["getifaddr", device]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Job IDs currently queued/active across all CUPS printers (first token
    /// of each `lpstat -o` line). Returns nil when lpstat itself fails — the
    /// callers must treat "unknown" as "not drained", never as "empty"
    /// (an lpstat failure once read as an empty queue and cut the printer
    /// connection mid-transfer).
    static func pendingJobIDs() -> Set<String>? {
        guard let output = try? run("/usr/bin/lpstat", ["-o"]) else {
            return nil
        }
        let ids = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { $0.components(separatedBy: .whitespaces).first }
        return Set(ids)
    }

    /// True when every job that appeared AFTER `baseline` has left the CUPS
    /// queue — i.e. this print's own jobs were delivered (or the printer was
    /// reachable without switching). Scoping to new jobs keeps a stuck job
    /// on some other printer from forcing a switch-and-45s-hold on every
    /// print, and keeps pre-existing jobs from ever reading as "ours".
    /// Requires two consecutive clear reads so a job that hasn't hit the
    /// queue yet isn't mistaken for a delivered one.
    static func newJobsCleared(
        baseline: Set<String>,
        minHoldSeconds: Double = 1.5,
        timeoutSeconds: Double
    ) async -> Bool {
        // Always hold briefly so a job that hasn't been enqueued yet at the
        // instant NSPrintOperation.run() returns still gets a chance to
        // appear in the queue.
        let minHold = UInt64(max(0, minHoldSeconds) * 1_000_000_000)
        if minHold > 0 {
            try? await Task.sleep(nanoseconds: minHold)
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var consecutiveClear = 0
        while Date() < deadline {
            if let current = pendingJobIDs() {
                if current.subtracting(baseline).isEmpty {
                    consecutiveClear += 1
                    if consecutiveClear >= 2 { return true }
                } else {
                    consecutiveClear = 0
                }
            } else {
                consecutiveClear = 0
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Re-enables CUPS destinations that stopped after delivery failures.
    /// The default `printer-error-policy` is stop-printer, so a job spooled
    /// while the printer was unreachable can stop the whole queue — joining
    /// the printer's Wi-Fi afterwards then does nothing until the queue is
    /// resumed. Best-effort: cupsenable may be denied without admin rights.
    static func resumeStoppedPrinters() {
        guard let output = try? run("/usr/bin/lpstat", ["-p"]) else { return }
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // run() forces LANG=C, so the marker is stable English.
            guard trimmed.hasPrefix("printer "), trimmed.contains(" disabled") else { continue }
            let name = trimmed.dropFirst("printer ".count).components(separatedBy: .whitespaces).first
            if let name, !name.isEmpty {
                _ = try? run("/usr/sbin/cupsenable", [name])
            }
        }
    }

    /// Drops the printer association and lets macOS auto-join its own
    /// remembered network — the same recovery the Wi-Fi menu provides.
    /// Used when the direct rejoin fails or no restore target is known.
    static func autoJoinFallback(printerSSID: String, timeoutSeconds: Double = 25.0) async throws {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw WiFiAutomationError.missingWiFiDevice
        }
        let device = wifiDevice()
        let previousIPv4 = device.flatMap { ipv4Address(device: $0) }
        interface.disassociate()
        // Give the interface a beat to actually drop the old lease before
        // polling, so a stale address can't read as a rejoin.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            // With Location granted the SSID is readable and is the direct
            // proof; a fresh non-printer lease is the redacted-system proxy.
            if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty, ssid != printerSSID {
                return
            }
            if let device, let ip = ipv4Address(device: device), ip != previousIPv4 {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw WiFiAutomationError.connectionTimeout(
            "Wi-Fi did not rejoin a network after printing — pick one from the Wi-Fi menu."
        )
    }

    static func prepare(settings: PrintAutomationSettings) async throws -> WiFiPrintSession? {
        guard settings.enabled else { return nil }
        let printerSSID = settings.printerSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !printerSSID.isEmpty else {
            throw WiFiAutomationError.missingPrinterSSID
        }

        // Capture the network we're leaving before switching. currentSSID() can
        // transiently return nil, which would later strand the user on the
        // printer network with no way back — retry a few times to be sure.
        // Skip the retries when reads cannot succeed: on macOS 15+ every
        // path is redacted unless the user granted Location Services, and
        // retrying a hopeless read just added ~1s to every print. A nil
        // capture is survivable either way — restore falls back to
        // restoreSSID / preferred networks / system auto-join.
        var previousSSID = currentSSID(service: settings.wifiService)
        if previousSSID == nil, !systemRedactsSSID || LocationPermission.shared.isAuthorized {
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let ssid = currentSSID(service: settings.wifiService) {
                    previousSSID = ssid
                    break
                }
            }
        }

        if previousSSID != printerSSID {
            try await connectAndWait(
                service: settings.wifiService,
                ssid: printerSSID,
                password: settings.printerPassword.isEmpty ? nil : settings.printerPassword
            )
        }

        return WiFiPrintSession(
            service: settings.wifiService,
            previousSSID: previousSSID,
            settings: settings
        )
    }

    static func connect(service: String, ssid: String, password: String?) throws {
        // CoreWLAN first: it is the same join path the Wi-Fi menu uses, and
        // on macOS 26 it is the only one that works — `networksetup
        // -setairportnetwork` fails with "Could not find network" / -3900
        // even for a broadcasting network it should know (verified live
        // against the HP DIRECT SoftAP). The CLI stays as a fallback for
        // older systems where CoreWLAN might be denied.
        var coreWLANFailure: Error?
        do {
            try coreWLANJoin(ssid: ssid, password: password)
            return
        } catch {
            coreWLANFailure = error
        }

        var arguments = ["-setairportnetwork", service, ssid]
        if let password, !password.isEmpty {
            arguments.append(password)
        }
        do {
            let output = try run("/usr/sbin/networksetup", arguments, combineStderrOnSuccess: true)
            if let failure = joinFailureMessage(output) {
                throw WiFiAutomationError.commandFailed(failure)
            }
        } catch {
            // The CoreWLAN diagnostic is the actionable one (it can name the
            // missing Location permission); prefer it over the CLI noise.
            throw coreWLANFailure ?? error
        }
    }

    private static func coreWLANJoin(ssid: String, password: String?) throws {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw WiFiAutomationError.missingWiFiDevice
        }
        let networks = (try? interface.scanForNetworks(withName: ssid)) ?? []
        guard let network = networks.first else {
            throw WiFiAutomationError.commandFailed("Could not find network \(ssid) in a Wi-Fi scan. The printer may be off, asleep, or out of range.")
        }
        do {
            let effectivePassword = (password?.isEmpty == false) ? password : nil
            try interface.associate(to: network, password: effectivePassword)
        } catch {
            if network.ssid == nil {
                // The scan found the network but macOS redacted it — the
                // telltale of missing Location Services access, which also
                // makes associate() fail with -3900 tmpErr.
                throw WiFiAutomationError.commandFailed(
                    "macOS blocked the Wi-Fi switch. Allow Location Services for iLabel2Mac (System Settings → Privacy & Security → Location Services), then print again. (\(error.localizedDescription))"
                )
            }
            throw WiFiAutomationError.commandFailed("Joining \(ssid) failed: \(error.localizedDescription)")
        }
    }

    /// `networksetup -setairportnetwork` exits 0 even when the join fails
    /// (verified on macOS 26.5), reporting the problem only as text — e.g.
    /// "Could not find network X." when the SSID isn't broadcasting, or
    /// "Failed to join network X." on a bad password. Treating those as
    /// success made a failed switch look like it worked, and the print job
    /// then went to the wrong network. The markers are English-only on
    /// purpose: networksetup's output is not localized (verified under
    /// LANG=ko_KR.UTF-8 on macOS 26.5). This detection is load-bearing —
    /// waitUntilConnected's stable-lease success path assumes a join that
    /// produced no failure text here really did associate.
    static func joinFailureMessage(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let failureMarkers = [
            "could not find network",
            "failed to join network",
            "could not join",
            "is not a wi-fi interface",
            "error"
        ]
        if failureMarkers.contains(where: { lowered.contains($0) }) {
            return trimmed
        }
        return nil
    }

    static func connectAndWait(
        service: String,
        ssid: String,
        password: String?,
        timeoutSeconds: Double = 20.0
    ) async throws {
        // Snapshot the lease before switching: on macOS 15+ the SSID is
        // redacted from every CLI, so a changed DHCP address is the only
        // observable proof that we actually moved to the new network.
        let device = wifiDevice()
        let previousIPv4 = device.flatMap { ipv4Address(device: $0) }
        try connect(service: service, ssid: ssid, password: password)
        try await waitUntilConnected(
            service: service,
            expectedSSID: ssid,
            timeoutSeconds: timeoutSeconds,
            previousIPv4: previousIPv4
        )
    }

    static func waitUntilConnected(
        service: String,
        expectedSSID: String,
        timeoutSeconds: Double = 20.0,
        previousIPv4: String? = nil
    ) async throws {
        let device = wifiDevice()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var associated = false
        var ssidReadable = false
        var sameLeaseSince: Date?
        while Date() < deadline {
            // currentSSID is cheap here: the CoreWLAN read is in-process,
            // and on macOS 15+ the slow CLI fallbacks are short-circuited.
            // With Location Services granted it verifies the exact SSID even
            // on redacted systems; without it, the DHCP branch below decides.
            if let ssid = currentSSID(service: service) {
                ssidReadable = true
                if ssid == expectedSSID {
                    associated = true
                    // SSID matches — now make sure DHCP has actually given us
                    // an address, otherwise the printer is still unreachable.
                    if device == nil || ipv4Address(device: device!) != nil {
                        return
                    }
                }
            } else if let device {
                let ip = ipv4Address(device: device)
                if let ip, ip != previousIPv4 {
                    // SSID unreadable (redacted on macOS 15+): a fresh DHCP
                    // lease that differs from the pre-switch address means the
                    // join completed and the new network is reachable.
                    return
                }
                if let ip, ip == previousIPv4 {
                    // Same address as before the switch. A genuine
                    // re-association always drops the lease at least briefly,
                    // so an address that never wavers means we were already on
                    // the target network (the join command itself reported no
                    // failure, or connect() would have thrown). Without this,
                    // printing while already on the printer's network spins
                    // for the full timeout and fails.
                    if let since = sameLeaseSince {
                        if Date().timeIntervalSince(since) >= 4.0 {
                            return
                        }
                    } else {
                        sameLeaseSince = Date()
                    }
                } else {
                    sameLeaseSince = nil
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        // We associated with the SSID but never confirmed an IP before the
        // deadline. Association is the hard part; DHCP may just be slow, so let
        // the print proceed rather than aborting the whole operation.
        if associated {
            return
        }
        // SSID never became readable (redacted): only accept the join if the
        // interface picked up a *different* address than before the switch.
        // Accepting any address at all treated "still on the old network"
        // as success, silently masking every failed switch on macOS 15+.
        if !ssidReadable, let device, let ip = ipv4Address(device: device), ip != previousIPv4 {
            return
        }
        throw WiFiAutomationError.connectionTimeout(
            "Timed out waiting to connect to \(expectedSSID). The network address never changed — the printer may be off, asleep, or out of range."
        )
    }

    @discardableResult
    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        combineStderrOnSuccess: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        // Force the C locale so output parsers (lpstat "disabled" lines,
        // networksetup failure markers) see stable English regardless of the
        // user's system language (lpstat is localized — Korean by default
        // on this machine).
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["LANG": "C", "LC_ALL": "C"]
        ) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = error.isEmpty ? output : error
            throw WiFiAutomationError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // networksetup reports some failures with exit code 0; callers that
        // parse output for failure text need stderr too, not just stdout.
        if combineStderrOnSuccess, !error.isEmpty {
            return (output + "\n" + error).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
