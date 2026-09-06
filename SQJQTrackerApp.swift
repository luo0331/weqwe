import SwiftUI

@main
struct SQJQTrackerApp: App {
    @StateObject private var session = GameSession()
    @StateObject private var records = RecordStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(session)
                .environmentObject(records)
                .preferredColorScheme(.dark)
                .onAppear { FrameServer.start() }
        }
    }
}
