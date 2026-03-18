import Foundation

struct MockExportGenerator {

    static let csvHeader = "packet_counter,timestamp,euler_x,euler_y,euler_z,acc_x,acc_y,acc_z,gyr_x,gyr_y,gyr_z\n"

    /// Write a CSV with `packetCount` rows. Pass counter values in `dropping` to simulate gaps.
    /// Returns the file URL, or nil if the file couldn't be written.
    static func makeCSV(packetCount: Int, dropping: Set<Int> = [], label: String) -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Exports", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("❌ MockExportGenerator: failed to create Exports directory: \(error)")
            return nil
        }

        let url = dir.appendingPathComponent("mock_\(label).csv")
        var csv = csvHeader

        let baseTimestamp: UInt32 = UInt32(Date().timeIntervalSince1970)
        for i in 0..<packetCount {
            guard !dropping.contains(i) else { continue }
            let t = Double(i)
            let row = String(
                format: "%u,%u,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                UInt32(i),
                baseTimestamp + UInt32(i),
                sin(t * 0.01) * 30.0,
                cos(t * 0.01) * 20.0,
                sin(t * 0.02) * 10.0,
                sin(t * 0.03) * 9.81,
                cos(t * 0.03) * 1.5,
                9.81 + sin(t * 0.05) * 0.3,
                cos(t * 0.02) * 0.5,
                sin(t * 0.04) * 0.3,
                cos(t * 0.04) * 0.2
            )
            csv.append(row)
        }

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("❌ MockExportGenerator: failed to write CSV: \(error)")
            return nil
        }
        return url
    }

    /// Create a complete ExportTask (status: .success, outputURL set, hasPacketLoss set).
    /// Returns nil if the CSV could not be written.
    static func makeTask(label: String, packetCount: Int, dropping: Set<Int> = []) -> ExportTask? {
        guard let url = makeCSV(packetCount: packetCount, dropping: dropping, label: label) else {
            return nil
        }

        let recording = RecordingFile(
            dotAddress: "MOCK_\(label)",
            macAddress: "00:00:00:00:00:00",
            fileIndex: 0,
            fileSize: packetCount * 88,
            timestamp: UInt32(Date().timeIntervalSince1970)
        )
        var item = CartItem(recording: recording)
        item.label = label

        let task = ExportTask(cartItem: item)
        let isValid = ExportManager.shared.validatePacketCount(csvURL: url)

        if isValid {
            task.status = .success
            task.progress = 1.0
            task.subphase = .complete
            task.outputURL = url
        } else {
            // Mirror real pipeline: delete the partial CSV and mark failed.
            try? FileManager.default.removeItem(at: url)
            task.status = .failed
            task.hasPacketLoss = true
            task.error = "Packet loss detected"
        }

        return task
    }
}
