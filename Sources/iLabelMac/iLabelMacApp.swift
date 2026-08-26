import SwiftUI

@main
struct iLabelMacApp: App {
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(store.appearanceMode.colorScheme)
                .onAppear {
                    // macOS 15+ refuses programmatic Wi-Fi joins (and redacts
                    // SSIDs) unless the app has Location Services access, so
                    // Wi-Fi printing needs this granted once.
                    LocationPermission.shared.requestIfNeeded()
                    UpdateChecker.checkSoon()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
