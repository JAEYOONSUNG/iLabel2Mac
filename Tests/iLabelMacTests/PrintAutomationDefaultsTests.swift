import XCTest
@testable import iLabelMac

final class PrintAutomationDefaultsTests: XCTestCase {
    private func configured(
        ssid: String,
        password: String = "pw",
        enabled: Bool = true
    ) -> PrintAutomationSettings {
        var settings = PrintAutomationSettings.default
        settings.printerSSID = ssid
        settings.printerPassword = password
        settings.enabled = enabled
        return settings
    }

    func testSeededDefaultEnablesSwitchingWhenPrinterDetected() {
        let seeded = PrintAutomationSettings.seededDefault(detectedPrinterSSID: "DIRECT-e0-HP M255 LaserJet")
        XCTAssertTrue(seeded.enabled)
        XCTAssertEqual(seeded.printerSSID, "DIRECT-e0-HP M255 LaserJet")
        XCTAssertTrue(seeded.reconnectToPreviousWiFi)
        XCTAssertEqual(seeded.settleSeconds, 2.0)
    }

    func testSeededDefaultStaysDisabledWithoutDetection() {
        XCTAssertFalse(PrintAutomationSettings.seededDefault(detectedPrinterSSID: nil).enabled)
        XCTAssertFalse(PrintAutomationSettings.seededDefault(detectedPrinterSSID: "  ").enabled)
        XCTAssertEqual(PrintAutomationSettings.seededDefault(detectedPrinterSSID: nil), .default)
    }

    func testOpeningDocumentKeepsMachineSettingsWhenConfigured() {
        // The reported bug: opening an old project reverted the checkbox and
        // credentials to whatever the file was saved with.
        let machine = configured(ssid: "DIRECT-e0-HP M255 LaserJet", enabled: true)
        let staleDocument = configured(ssid: "DIRECT-old", password: "", enabled: false)

        let resolved = PrintAutomationSettings.resolvedOnOpen(
            machineCached: machine,
            documentValue: staleDocument
        )
        XCTAssertEqual(resolved, machine)
    }

    func testOpeningDocumentSeedsUnconfiguredMachine() {
        // A colleague's file on a fresh Mac should provide the setup.
        let fromFile = configured(ssid: "DIRECT-e0-HP M255 LaserJet")
        let resolved = PrintAutomationSettings.resolvedOnOpen(
            machineCached: .default,
            documentValue: fromFile
        )
        XCTAssertEqual(resolved, fromFile)
    }

    func testIsConfiguredIgnoresWhitespaceSSID() {
        var settings = PrintAutomationSettings.default
        XCTAssertFalse(settings.isConfigured)
        settings.printerSSID = "   "
        XCTAssertFalse(settings.isConfigured)
        settings.printerSSID = "DIRECT-x"
        XCTAssertTrue(settings.isConfigured)
    }
}
