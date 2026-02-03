import SwiftUI
import MovellaDotSdk

struct ConnectionView: View {

    private let manager = DotManager.shared

    // UUID -> DotDevice
    @State private var discoveredByUuid: [String: DotDevice] = [:]

    // Connected UUIDs only
    @State private var connectedUuids: Set<String> = []

    @State private var isScanning = false

    private var discoveredList: [DotDevice] {
        discoveredByUuid.values.sorted { left, right in
            manager.displayAddress(for: left) < manager.displayAddress(for: right)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {

                if !connectedUuids.isEmpty {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        Text("\(connectedUuids.count) connected")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1))
                }

                List {
                    if discoveredList.isEmpty && isScanning {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Scanning for sensors...")
                                .foregroundColor(.secondary)
                        }
                    } else if discoveredList.isEmpty {
                        Text("No sensors found. Pull to scan.")
                            .foregroundColor(.secondary)
                    }

                    ForEach(discoveredList, id: \.uuid) { device in
                        DeviceRow(
                            title: "DOT \(device.uuid)",
                            subtitle: manager.displayAddress(for: device),
                            isConnected: connectedUuids.contains(device.uuid),
                            onToggle: { toggleConnection(device) }
                        )
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        startScan()
                    } label: {
                        if isScanning { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isScanning)
                }
            }
            .refreshable { startScan() }
            .onAppear {
                manager.activate()
                syncState()
                startScan()
            }
            .onDisappear {
                manager.stopScan()
            }

            // ✅ FIX: listen to the notification DotManager actually posts
            .onReceive(NotificationCenter.default.publisher(for: .dotManagerUpdated)) { _ in
                syncState()
            }
        }
    }

    private func startScan() {
        isScanning = true
        manager.startScan()
    }

    private func toggleConnection(_ device: DotDevice) {
        let uuid = device.uuid

        if connectedUuids.contains(uuid) {
            if let dot = manager.dot(forUuid: uuid) {
                manager.disconnect(dot)
            }
        } else {
            manager.connectByUuid(uuid)
        }
    }

    private func syncState() {
        var newDiscovered: [String: DotDevice] = [:]
        for d in manager.discovered {
            if !d.uuid.isEmpty {
                newDiscovered[d.uuid] = d
            }
        }
        discoveredByUuid = newDiscovered

        // Connected = dots whose wrapper says they're connected
        connectedUuids = Set(manager.dots.filter { $0.isConnected }.map { $0.address })

        // Mirror scanning state from manager
        isScanning = manager.isScanning
    }
}

struct DeviceRow: View {
    let title: String
    let subtitle: String
    let isConnected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(isConnected ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isConnected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}
