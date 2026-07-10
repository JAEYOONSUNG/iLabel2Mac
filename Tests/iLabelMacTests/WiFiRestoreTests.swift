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

    // `networksetup -setairportnetwork` exits 0 on failure and reports the
    // problem only as text (verified on macOS 26.5), so join success/failure
    // must be decided from the output.

    func testJoinFailureDetectedWhenNetworkNotFound() {
        let message = WiFiPrintAutomation.joinFailureMessage("Could not find network DIRECT-6E-HP LaserJet.")
        XCTAssertEqual(message, "Could not find network DIRECT-6E-HP LaserJet.")
    }

    func testJoinFailureDetectedOnBadPassword() {
        XCTAssertNotNil(WiFiPrintAutomation.joinFailureMessage("Failed to join network HomeNet5G."))
    }

    func testJoinFailureDetectedOnGenericError() {
        XCTAssertNotNil(WiFiPrintAutomation.joinFailureMessage("Error: en0 is not a Wi-Fi interface."))
    }

    func testSilentOutputMeansJoinSucceeded() {
        XCTAssertNil(WiFiPrintAutomation.joinFailureMessage(""))
        XCTAssertNil(WiFiPrintAutomation.joinFailureMessage("  \n"))
    }
}
