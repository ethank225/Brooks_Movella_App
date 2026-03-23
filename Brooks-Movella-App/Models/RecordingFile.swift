import Foundation

/// Identifies a single recorded file on a Movella DOT sensor's flash storage.
struct RecordingFile: Identifiable, Hashable {
    let dotAddress: String   // UUID — used for keying/grouping throughout the app
    let macAddress: String   // Bluetooth MAC address — e.g. "D4:22:CD:07:A8:15"
    let fileIndex: Int
    let fileSize: Int
    let timestamp: UInt32

    var id: String { "\(dotAddress)_\(fileIndex)" }

    /// Human-readable file size (e.g. "1.2 MB", "340 KB").
    var formattedSize: String {
        if fileSize >= 1_000_000 {
            return String(format: "%.1f MB", Double(fileSize) / 1_000_000)
        } else if fileSize >= 1_000 {
            return String(format: "%.0f KB", Double(fileSize) / 1_000)
        }
        return "\(fileSize) B"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Formatted date from the SDK's UInt32 timestamp.
    var formattedDate: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return Self.dateFormatter.string(from: date)
    }
}
