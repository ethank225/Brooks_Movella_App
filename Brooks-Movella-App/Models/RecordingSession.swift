import Foundation

/// A group of recording files from multiple sensors that were recorded at approximately
/// the same time (within a configurable time window).
struct RecordingSession: Identifiable {
    let id: UUID
    let timestamp: Date          // earliest file timestamp in the group
    var files: [SessionFile]
    let expectedSensorCount: Int // dots in the runner/group

    struct SessionFile: Identifiable {
        let id: String           // matches RecordingFile.id
        let dot: Dot
        let recording: RecordingFile
    }

    var sensorCount: Int {
        Set(files.map { $0.dot.address }).count
    }

    var isComplete: Bool { sensorCount >= expectedSensorCount }

    var totalSize: Int { files.reduce(0) { $0 + $1.recording.fileSize } }
}

/// A runner's recording sessions plus metadata for the UI header.
struct RunnerRecordingGroup: Identifiable {
    let id: String          // runner ID or "all" for single-runner mode
    let runnerName: String
    let dotNames: [String]  // display names of dots in this runner
    let sessions: [RecordingSession]
}
