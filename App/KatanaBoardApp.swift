import SwiftUI

@main
struct KatanaBoardApp: App {
    @State private var session = AmpSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .preferredColorScheme(.dark)
                // .tsl files opened from Files, Mail or Safari.
                .onOpenURL { session.importFile(at: $0) }
        }
    }
}
