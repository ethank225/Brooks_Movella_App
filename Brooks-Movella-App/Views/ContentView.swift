import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ConnectionView()
                .tabItem {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("Connect")
                }
            
            SyncView()
                .tabItem {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync")
                }
            
            ExportView()
                .tabItem {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
        }
    }
}
