import SwiftUI
import MovellaDotSdk

@main
struct YourApp: App {
    init() {
        DotLog.setLogEnable(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
