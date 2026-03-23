import Foundation

/// Ensures `@Published` mutations happen on the main thread.
/// Runs synchronously if already on main, otherwise dispatches async.
func setOnMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() }
    else { DispatchQueue.main.async(execute: work) }
}
