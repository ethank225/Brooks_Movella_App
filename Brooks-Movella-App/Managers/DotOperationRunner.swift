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
    func refreshStorage(
        dots: [Dot],
        onDotComplete: @escaping (Dot, Bool) -> Void,
        completion: @escaping () -> Void
    ) {
        guard !dots.isEmpty else { completion(); return }

        print("💾 Queueing storage refresh for \(dots.count) dots")

        sdkQueue.async { [self] in
            executeSequentially(items: dots) { dot, done in
                waitForInitialization(dot: dot, timeout: 5.0) { ready in
                    if !ready {
                        print("⚠️ [\(dot.address)] Not initialized, skipping storage refresh")
                        onDotComplete(dot, false)
                        done(false)
                        return
                    }

                    dot.getFlashInfo { _ in
                        onDotComplete(dot, true)
                        done(true)
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

    /// Polls `dot.isInitialized` on the current (background) thread.
    private func waitForInitialization(dot: Dot, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let start = Date()

        func check() {
            if dot.isInitialized {
                completion(true)
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                completion(false)
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
            check()
        }
        check()
    }
}
