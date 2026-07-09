import XCTest
@testable import iLabelMac

final class WiFiRestoreTests: XCTestCase {
    private let printer = "DIRECT-6E-HP LaserJet"
    private let preferred = ["HomeNet5G", "DIRECT-6E-HP LaserJet", "CafeGuest"]

    func testCapturedPreviousSSIDWinsOverEverything() {
        let target = WiFiPrintAutomation.restoreTargetSSID(
            previousSSID: "OfficeNet",
            configuredRestoreSSID: "HomeNet5G",
            printerSSID: printer,
            preferredNetworks: preferred
        )
        XCTAssertEqual(target, "OfficeNet")
    }

    func testConfiguredRestoreSSIDUsedWhenCaptureFailed() {
        // macOS 15+ redacts the SSID, so previousSSID is usually nil there.
        let target = WiFiPrintAutomation.restoreTargetSSID(
            previousSSID: nil,
            configuredRestoreSSID: "HomeNet5G",
            printerSSID: printer,
            preferredNetworks: preferred
        )
        XCTAssertEqual(target, "HomeNet5G")
    }

    func testAutoPicksTopPreferredNonPrinterNetwork() {
        let target = WiFiPrintAutomation.restoreTargetSSID(
            previousSSID: nil,
            configuredRestoreSSID: nil,
            printerSSID: printer,
            preferredNetworks: preferred
        )
        XCTAssertEqual(target, "HomeNet5G")
    }

    func testNeverRestoresToThePrinterItself() {
        let target = WiFiPrintAutomation.restoreTargetSSID(
            previousSSID: printer,
            configuredRestoreSSID: printer,
            printerSSID: printer,
            preferredNetworks: [printer]
        )
        XCTAssertNil(target)
    }
}
