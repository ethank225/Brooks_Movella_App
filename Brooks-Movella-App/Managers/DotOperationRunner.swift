import Foundation

/// Stateless helper for bulk sequential device operations.
final class DotOperationRunner {

    private let sdkQueue: DispatchQueue

    init(sdkQueue: DispatchQueue) {
        self.sdkQueue = sdkQueue
    }

    // MARK: - Bulk Operation

    /// Runs `operation` on each dot sequentially on `sdkQueue`,
    /// then calls `completion` on the main thread with overall success.
    func runAll(
        dots: [Dot],
        operation: @escaping (Dot, @escaping (Bool) -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        sdkQueue.async { [self] in
            executeSequentially(items: dots, operation: operation) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    // MARK: - Storage Refresh

    /// Refreshes flash storage info for each dot, waiting for initialization first.
    /// `onDotComplete` fires after each dot finishes (success or skip).
    ///
    /// `settleDelay` is an extra pause inserted after `isInitialized()` becomes
    /// true but before `getFlashInfo` is called. Pass a non-zero value when
    /// reconnecting after a Bluetooth power-off/reset — `bindDevice` causes
    /// `isInitialized()` to return `true` before the SDK finishes its internal
    /// BLE re-initialisation handshake, so the flash callback never fires without
    /// this settle period.
    func refreshStorage(
        dots: [Dot],
        settleDelay: TimeInterval = 0,
        onDotComplete: @escaping (Dot, Bool) -> Void,
        completion: @escaping () -> Void
    ) {
        guard !dots.isEmpty else { completion(); return }

        print("💾 Queueing storage refresh for \(dots.count) dots")

        sdkQueue.async { [self] in
            executeSequentially(items: dots) { dot, done in
                waitForInitialization(dot: dot, timeout: 5.0, settleDelay: settleDelay) { ready in
                    if !ready {
                        print("⚠️ [\(dot.address)] Not initialized, skipping storage refresh")
                        onDotComplete(dot, false)
                        done(false)
                        return
                    }

                    dot.getFlashInfo { flashSuccess in
                        onDotComplete(dot, flashSuccess)
                        done(flashSuccess)
                    }
                }
            } completion: { _ in
                print("💾 Storage refresh queue finished")
                completion()
            }
        }
    }

    // MARK: - Helpers

    /// Executes `operation` on each item one at a time, collecting success.
    func executeSequentially<T>(
        items: [T],
        operation: @escaping (T, @escaping (Bool) -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        var index = 0
        var allSuccess = true

        func next() {
            guard index < items.count else {
                completion(allSuccess)
                return
            }
            let item = items[index]
            operation(item) { success in
                if !success { allSuccess = false }
                index += 1
                next()
            }
        }
        next()
    }

    /// Polls `dot.isInitialized` using asyncAfter to yield sdkQueue between checks.
    ///
    /// After `isInitialized()` returns `true`, waits an additional `settleDelay`
    /// seconds on `sdkQueue` before signalling completion. This prevents
    /// `getFlashInfo` from being dispatched while the SDK is still mid-BLE-handshake
    /// after a Bluetooth power-off/reset reconnect (where `bindDevice` prematurely
    /// sets `isInitialized() = true` before characteristic reads finish).
    ///
    /// **Optimization:** if `dot.bleConnectionProven` is true (a successful BLE
    /// round-trip has happened on the current device reference), the settle
    /// delay is skipped — we already have proof the channel is live. The full
    /// delay still applies when the flag is false, so the fallback for the
    /// edge case where `checkSensorActivity` timed out is unchanged.
    private func waitForInitialization(dot: Dot, timeout: TimeInterval, settleDelay: TimeInterval = 0, completion: @escaping (Bool) -> Void) {
        let start = Date()

        func check() {
            if dot.isInitialized {
                let effectiveDelay: TimeInterval
                if dot.bleConnectionProven {
                    if settleDelay > 0 {
                        print("💾 [\(dot.address)] BLE proven ready — skipping \(settleDelay)s settle delay")
                    }
                    effectiveDelay = 0
                } else {
                    effectiveDelay = settleDelay
                }
                if effectiveDelay > 0 {
                    print("⏳ [\(dot.address)] isInitialized=true — settling \(effectiveDelay)s before flash query")
                    sdkQueue.asyncAfter(deadline: .now() + effectiveDelay) {
                        completion(true)
                    }
                } else {
                    completion(true)
                }
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                completion(false)
                return
            }
            sdkQueue.asyncAfter(deadline: .now() + 0.2) {
                check()
            }
        }
        check()
    }
}
