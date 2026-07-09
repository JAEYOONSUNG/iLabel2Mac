import Foundation

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
        guard let target = WiFiPrintAutomation.restoreTargetSSID(
            previousSSID: previousSSID,
            configuredRestoreSSID: settings.restoreSSID,
            printerSSID: settings.printerSSID,
            preferredNetworks: WiFiPrintAutomation.preferredNetworks()
        ) else { return }
        try await WiFiPrintAutomation.connectAndWait(
            service: service,
            ssid: target,
            password: nil
        )
    }
}

enum WiFiPrintAutomation {
    static let airportTool = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"

    static func wifiDevice() -> String? {
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
        // Preferred: `networksetup -getairportnetwork <device>`. Works on modern
        // macOS with no extra frameworks or Location Services permission.
        // Apple removed the private `airport` tool in macOS 14.4, which used to
        // be the only path here — its loss made waitUntilConnected() always time
        // out (it could never confirm the connection), breaking Wi-Fi printing.
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

    /// Number of print jobs currently queued/active across all CUPS printers.
    /// `lpstat -o` lists one line per pending job and prints nothing when the
    /// queue is empty. Any failure is treated as "unknown" (0) so it never
    /// blocks the restore step indefinitely.
    static func pendingPrintJobCount() -> Int {
        guard let output = try? run("/usr/bin/lpstat", ["-o"]) else {
            return 0
        }
        return output
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    /// Holds the current (printer) Wi-Fi connection until CUPS has drained the
    /// spooled job to the printer. `NSPrintOperation.run()` only submits the job
    /// to the spooler and returns; the network transmission happens afterwards.
    /// Restoring Wi-Fi before that transmission finishes silently kills the job,
    /// which is the whole reason Wi-Fi printing appeared to "do nothing".
    static func waitForPrintJobsToClear(minHoldSeconds: Double = 1.5, timeoutSeconds: Double = 45.0) async {
        // Always hold briefly so a job that hasn't been enqueued yet at the
        // instant run() returns still gets a chance to appear in the queue.
        let minHold = UInt64(max(0, minHoldSeconds) * 1_000_000_000)
        if minHold > 0 {
            try? await Task.sleep(nanoseconds: minHold)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        // Require the queue to read empty twice in a row to avoid restoring in a
        // gap between two jobs on a multi-slot print.
        var consecutiveEmpty = 0
        while Date() < deadline {
            if pendingPrintJobCount() == 0 {
                consecutiveEmpty += 1
                if consecutiveEmpty >= 2 { return }
            } else {
                consecutiveEmpty = 0
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
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
        var previousSSID = currentSSID(service: settings.wifiService)
        if previousSSID == nil {
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
        var arguments = ["-setairportnetwork", service, ssid]
        if let password, !password.isEmpty {
            arguments.append(password)
        }
        _ = try run("/usr/sbin/networksetup", arguments)
    }

    static func connectAndWait(
        service: String,
        ssid: String,
        password: String?,
        timeoutSeconds: Double = 12.0
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
        timeoutSeconds: Double = 12.0,
        previousIPv4: String? = nil
    ) async throws {
        let device = wifiDevice()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var associated = false
        var ssidReadable = false
        while Date() < deadline {
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
            } else if let device, let ip = ipv4Address(device: device), ip != previousIPv4 {
                // SSID unreadable (redacted on macOS 15+): a fresh DHCP lease
                // that differs from the pre-switch address means the join
                // completed and the new network is reachable.
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        // We associated with the SSID but never confirmed an IP before the
        // deadline. Association is the hard part; DHCP may just be slow, so let
        // the print proceed rather than aborting the whole operation.
        if associated {
            return
        }
        // SSID never became readable (redacted): if the interface holds any
        // address at all, assume the join worked rather than failing a print
        // we can't actually verify.
        if !ssidReadable, let device, ipv4Address(device: device) != nil {
            return
        }
        throw WiFiAutomationError.connectionTimeout("Timed out waiting to connect to \(expectedSSID)")
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

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

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
