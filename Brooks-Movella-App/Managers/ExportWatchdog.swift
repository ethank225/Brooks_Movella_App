import Foundation

// MARK: - ExportWatchdog

/// Per-file timeout watchdog that fires if no BLE packets arrive within `timeout` seconds.
///
/// Both `beat()` and the timer fire on `sdkQueue` — no lock needed.
final class ExportWatchdog {

    private var lastPacketAt: Date
    private let timeout: TimeInterval
    private var timer: DispatchSourceTimer?

    init(timeout: TimeInterval, queue: DispatchQueue, onTimeout: @escaping () -> Void) {
        self.timeout = timeout
        self.lastPacketAt = Date()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastPacketAt) > self.timeout {
                self.stop()
                onTimeout()
            }
        }
        self.timer = source
        source.resume()
    }

    /// Called from the SDK data callback on `sdkQueue` to signal data is still flowing.
    func beat() {
        lastPacketAt = Date()
    }

    /// Cancel the timer. Safe to call multiple times.
    func stop() {
        timer?.cancel()
        timer = nil
    }
}
