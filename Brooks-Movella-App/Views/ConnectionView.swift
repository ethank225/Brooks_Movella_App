import SwiftUI
import MovellaDotSdk

struct ConnectionView: View {

    private let manager = DotManager.shared

    @State private var discoveredByAddress: [String: DotDevice] = [:]
    @State private var connectedAddresses: Set<String> = []
    @State private var isScanning = false

    private var discoveredList: [DotDevice] {
        discoveredByAddress.values
            .sorted { $0.displayAddress() < $1.displayAddress() }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !connectedAddresses.isEmpty {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        Text("\(connectedAddresses.count) connected")
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

                    ForEach(discoveredList, id: \.displayAddressString) { device in
                        DeviceRow(
                            device: device,
                            isConnected: connectedAddresses.contains(device.displayAddress()),
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
                        if isScanning {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isScanning)
                }
            }
            .refreshable {
                startScan()
            }
            .onAppear {
                manager.activate()
                startScan()
            }
            .onDisappear {
                manager.stopScan()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .dotManagerUpdated)
            ) { _ in
                syncState()
            }
        }
    }

    // MARK: - Actions

    private func startScan() {
        isScanning = true
        manager.startScan()
    }

    private func toggleConnection(_ device: DotDevice) {
        let address = device.displayAddress()

        if connectedAddresses.contains(address) {
            // Disconnect
            if let dot = manager.dot(for: device) {
                manager.disconnect(dot)
            }
        } else {
            // Connect via scan-then-connect pattern.
            // The SDK requires connect to be called inside the onDiscover callback,
            // so we trigger a fresh scan with the target address queued up.
            let macAddress = device.macAddress ?? ""
            manager.connectByAddress(macAddress)
        }
    }

    // MARK: - State Sync

    private func syncState() {
        var dict = discoveredByAddress
        for d in manager.discovered {
            dict[d.displayAddress()] = d
        }
        discoveredByAddress = dict
        connectedAddresses = Set(manager.dots.map { $0.address })
        isScanning = manager.isScanning
    }
}

// MARK: - Stable SwiftUI ID

private extension DotDevice {
    var displayAddressString: String { displayAddress() }
}

// MARK: - Device Row

struct DeviceRow: View {
    let device: DotDevice
    let isConnected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(isConnected ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text("DOT \(device.shortName())")
                    .font(.headline)
                Text(device.displayAddress())
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
