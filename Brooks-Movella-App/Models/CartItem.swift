import Foundation

/// A recording file that has been added to the export cart with an editable label.
struct CartItem: Identifiable {
    let id: String
    let recording: RecordingFile
    var label: String
    var sessionId: UUID = UUID()

    init(recording: RecordingFile) {
        self.id = recording.id
        self.recording = recording
        let sensorName = SensorNameStore.shared.names[recording.dotAddress]
            ?? "DOT_\(String(recording.dotAddress.prefix(4)))"
        self.label = "\(sensorName)_file\(recording.fileIndex)"
    }
}
