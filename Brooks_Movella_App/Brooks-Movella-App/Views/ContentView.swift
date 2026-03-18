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
                    Image(systemName: "record.circle")
                    Text("Record")
                }
            
            ExportView()
                .tabItem {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }

            ProfilesView()
                .tabItem {
                    Image(systemName: "person.2")
                    Text("Profiles")
                }
        }
    }
}
