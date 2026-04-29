import Foundation

// MARK: - Session Grouping

extension ExportManager {

    /// Recompute `runnerGroups` from the current `recordings` dict.
    /// Called automatically after `fetchRecordings` completes.
    func rebuildSessionGroups() {
        print("🔄 rebuildSessionGroups — recordings keys: \(recordings.keys.map { String($0.prefix(8)) }), file counts: \(recordings.mapValues { $0.count })")
        let dots = DotManager.shared.connectedDots
        let dotMap = Dictionary(uniqueKeysWithValues: dots.map { ($0.address, $0) })
        print("🔄 dotMap keys: \(dotMap.keys.map { String($0.prefix(8)) }), connectedDots: \(dots.count)")
        let isMultiRunner = RunnerStore.shared.isMultiRunnerMode
        let runners = RunnerStore.shared.runners

        if isMultiRunner {
            var groups: [RunnerRecordingGroup] = []
            var assignedAddresses = Set<String>()

            for runner in runners {
                let dotGroup = Set(runner.sensorUuids)
                assignedAddresses.formUnion(dotGroup)
                let sessions = Self.groupIntoSessions(
                    recordings: recordings,
                    dotMap: dotMap,
                    dotGroup: dotGroup,
                    expectedSensorCount: dotGroup.count
                )
                let dotNames = runner.sensorUuids.compactMap { dotMap[$0]?.displayName }
                groups.append(RunnerRecordingGroup(
                    id: runner.id,
                    runnerName: runner.label,
                    dotNames: dotNames,
                    sessions: sessions
                ))
            }

            // Unmatched: dots that have recordings but aren't assigned to any runner.
            let unmatchedAddresses = Set(recordings.keys).subtracting(assignedAddresses)
            if !unmatchedAddresses.isEmpty {
                let sessions = Self.groupIntoSessions(
                    recordings: recordings,
                    dotMap: dotMap,
                    dotGroup: unmatchedAddresses,
                    expectedSensorCount: unmatchedAddresses.count
                )
                if !sessions.isEmpty {
                    let dotNames = unmatchedAddresses.compactMap { dotMap[$0]?.displayName }
                    groups.append(RunnerRecordingGroup(
                        id: "__unmatched__",
                        runnerName: "Unassigned Sensors",
                        dotNames: dotNames.sorted(),
                        sessions: sessions
                    ))
                }
            }

            runnerGroups = groups
        } else {
            // Single-runner mode: one group with all connected dots.
            let allAddresses = Set(recordings.keys)
            let sessions = Self.groupIntoSessions(
                recordings: recordings,
                dotMap: dotMap,
                dotGroup: allAddresses,
                expectedSensorCount: allAddresses.count
            )
            runnerGroups = [RunnerRecordingGroup(
                id: "all",
                runnerName: "All Sensors",
                dotNames: allAddresses.compactMap { dotMap[$0]?.displayName }.sorted(),
                sessions: sessions
            )]
        }
    }

    /// Group files from `dotGroup` into sessions using a timestamp-proximity window.
    /// Files within `windowSeconds` of the session's average timestamp are grouped together.
    static func groupIntoSessions(
        recordings: [String: [RecordingFile]],
        dotMap: [String: Dot],
        dotGroup: Set<String>,
        expectedSensorCount: Int,
        windowSeconds: Int = 30
    ) -> [RecordingSession] {
        // Collect all files from dots in this group.
        let allFiles: [(RecordingFile, Dot)] = dotGroup.flatMap { address -> [(RecordingFile, Dot)] in
            guard let files = recordings[address], let dot = dotMap[address] else { return [] }
            return files.map { ($0, dot) }
        }

        guard !allFiles.isEmpty else { return [] }

        let sorted = allFiles.sorted { $0.0.timestamp < $1.0.timestamp }

        print("📋 Grouping \(sorted.count) files from \(dotGroup.count) dots:")
        for (file, dot) in sorted {
            let date = Date(timeIntervalSince1970: TimeInterval(file.timestamp))
            print("  [\(dot.displayName)] file\(file.fileIndex) — raw timestamp: \(file.timestamp), as date: \(date), size: \(file.fileSize)")
        }

        var sessions: [RecordingSession] = []

        for (file, dot) in sorted {
            let sessionFile = RecordingSession.SessionFile(id: file.id, dot: dot, recording: file)

            // Try to find an existing session within the time window.
            // Compare against the session's average timestamp to prevent chain-drift.
            if let matchIdx = sessions.firstIndex(where: {
                let avgTimestamp = $0.files.map { Int($0.recording.timestamp) }.reduce(0, +) / max($0.files.count, 1)
                return abs(Int(file.timestamp) - avgTimestamp) <= windowSeconds
            }) {
                let avg = sessions[matchIdx].files.map { Int($0.recording.timestamp) }.reduce(0, +) / max(sessions[matchIdx].files.count, 1)
                print("  → Assigned to session \(matchIdx) (delta from avg: \(abs(Int(file.timestamp) - avg))s)")
                sessions[matchIdx].files.append(sessionFile)
            } else {
                print("  → Created new session \(sessions.count)")
                sessions.append(RecordingSession(
                    id: UUID(),
                    timestamp: Date(timeIntervalSince1970: TimeInterval(file.timestamp)),
                    files: [sessionFile],
                    expectedSensorCount: expectedSensorCount
                ))
            }
        }

        // Newest first.
        return sessions.sorted { $0.timestamp > $1.timestamp }
    }
}
