import Foundation
import MovellaDotSdk

/// Encapsulates Bluetooth scan lifecycle. Not thread-safe — caller serializes access.
final class DotScanner {

    private let sdkQueue: DispatchQueue

    init(sdkQueue: DispatchQueue) {
        self.sdkQueue = sdkQueue
    }

    /// Check Bluetooth power and begin scanning.
    /// `onReady` is called on `sdkQueue` just before the scan starts,
    /// giving the caller a chance to update state.
    func scan(onReady: @escaping () -> Void) {
        sdkQueue.async {
            guard DotConnectionManager.managerStateIsPoweredOn() else {
                print("❌ Bluetooth not powered on")
                return
            }
            onReady()
            DotConnectionManager.scan()
        }
    }

    func stopScan() {
        sdkQueue.async {
            DotConnectionManager.stopScan()
        }
    }
}
