import SwiftUI
import MovellaDotSdk
import UserNotifications

@main
struct YourApp: App {
    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
