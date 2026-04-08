import Foundation
import QuartzCore
import MovellaDotSdk

// MARK: - BLE Transfer

extension ExportManager {

    // MARK: Per-Device Export

    /// Export all files for a single dot sequentially, streaming CSV rows directly to disk.
    ///
    /// Calls `completion` when all files for this dot are done (success, failed, or canceled).
    func exportFilesForDot(dot: Dot, tasks: [ExportTask], completion: @escaping () -> Void) {
        let fileIndices = tasks.map { $0.cartItem.recording.fileIndex }

        let formatBytes: [UInt8] = [
            UInt8(XSRecordingData.timestamp.rawValue),
            UInt8(XSRecordingData.eulerAngles.rawValue),
            UInt8(XSRecordingData.acceleration.rawValue),
            UInt8(XSRecordingData.angularVelocity.rawValue)
        ]

        var taskIndex = 0

        // Install the GATT explorer for the entire device export window so write ACKs
        // and ready-to-send events are visible. keepDelegateInstalled prevents it from
        // stepping down after discovery; finish() tears it down when all files are done.
        let explorer = DotGATTExplorer(dot: dot)
        explorer.keepDelegateInstalled = true
        activeExplorers[dot.address] = explorer
        explorer.start()

        let finish: () -> Void = { [weak self] in
            explorer.stop()
            self?.activeExplorers.removeValue(forKey: dot.address)
            completion()
        }

        func exportNextFile() {
            guard taskIndex < tasks.count, !currentExportCanceled else {
                finish()
                return
            }

            let task = tasks[taskIndex]
            let fileIndex = fileIndices[taskIndex]

            setTaskStatus(task, .running)
            setOnMain { task.subphase = .transferring }

            var packetsReceived = 0
            var exportCompleted = false
            var doneFired = false

            let csvPath = csvURL(for: task)
            let estimatedDurationSeconds = max(Double(task.cartItem.recording.fileSize) / (88.0 * 33.0), 1.0)

            // Open the CSV file on fileQueue, then begin the BLE transfer on sdkQueue.
            fileQueue.async { [weak self] in
                guard let self else { finish(); return }

                // Write the header row and open the file handle.
                let csvHeader = "packet_counter,timestamp,euler_x,euler_y,euler_z,acc_x,acc_y,acc_z,gyr_x,gyr_y,gyr_z\n"
                FileManager.default.createFile(atPath: csvPath.path, contents: Data(csvHeader.utf8))
                guard let fileHandle = try? FileHandle(forWritingTo: csvPath) else {
                    self.setTaskStatus(task, .failed, error: "Failed to open CSV file")
                    self.sdkQueue.async { taskIndex += 1; exportNextFile() }
                    return
                }
                fileHandle.seekToEndOfFile()
                self.activeFileHandles[dot.address] = fileHandle

                // Begin the BLE transfer.
                self.sdkQueue.async { [weak self] in
                    guard let self else { finish(); return }

                    var batch = Data()
                    batch.reserveCapacity(200 * 120)

                    let device = dot.device
                    device.stopExportFileData()
                    
                    // Log negotiated MTU
                    let mtu = dot.device.peripheral.maximumWriteValueLength(for: .withoutResponse)
                    print("📶 [\(dot.address)] Negotiated MTU: \(mtu) bytes")
                    setOnMain { self.isTransferring = true }

                    // Bump the generation so stale callbacks from prior attempts are ignored.
                    self.exportFileGenerations[dot.address, default: 0] += 1
                    let generation = self.exportFileGenerations[dot.address, default: 0]

                    device.exportDataFormat = Data(formatBytes)
                    device.recording.exportFileList = [NSNumber(value: fileIndex)]

                    let exportStartTime = CACurrentMediaTime()
                    var lastProgressUpdate = exportStartTime
                    var cbTimeTotal: Double = 0
                    var cbTimeMax: Double = 0

                    // MARK: Watchdog — fires `dataTimeoutInterval` seconds after the last packet.
                    // If `doneFired == true` the stream is fully drained → success path.
                    // If `doneFired == false` no done signal received → genuine stall → fail path.
                    let watchdog = ExportWatchdog(
                        timeout: self.dataTimeoutInterval,
                        queue: self.sdkQueue
                    ) { [weak self] in
                        guard let self, !exportCompleted else { return }
                        exportCompleted = true

                        self.activeWatchdogs.removeValue(forKey: dot.address)
                        setOnMain { self.isTransferring = false }
                        self.exportFileGenerations[dot.address, default: 0] += 1
                        device.setDidParseExportFileDataBlock(nil)
                        device.recording.exportFileDone = { _, _ in }

                        if doneFired {
                            // exportFileDone was received — stream is drained → finalize as success.
                            let finalChunk: Data? = batch.isEmpty ? nil : batch
                            batch.removeAll(keepingCapacity: true)
                            let finalPackets = packetsReceived
                            let elapsed = CACurrentMediaTime() - exportStartTime
                            let avgCb = finalPackets > 0 ? cbTimeTotal / Double(finalPackets) : 0

                            self.fileQueue.async {
                                if let finalChunk { fileHandle.write(finalChunk) }
                                try? fileHandle.close()
                                self.activeFileHandles.removeValue(forKey: dot.address)

                                let pps = elapsed > 0 ? Double(finalPackets) / elapsed : 0
                                print("📡 [\(dot.address)] \(finalPackets) pkts in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", pps)) pkt/s), cb avg \(String(format: "%.2f", avgCb * 1000))ms")

                                let isValid = self.validatePacketCount(csvURL: csvPath)
                                if !isValid {
                                    try? FileManager.default.removeItem(at: csvPath)
                                    setOnMain { task.hasPacketLoss = true }
                                    self.setTaskStatus(task, .failed, error: "Packet loss detected")
                                } else {
                                    // Log file size at finalization for truncation debugging
                                    if let attrs = try? FileManager.default.attributesOfItem(atPath: csvPath.path),
                                       let size = attrs[.size] as? Int {
                                        print("📏 [\(dot.address)] Final CSV size: \(csvPath.lastPathComponent) = \(size) bytes (\(size / 1024) KB)")
                                    }
                                    setOnMain {
                                        task.progress = 1.0
                                        task.outputURL = csvPath
                                        task.subphase = .complete
                                        task.status = .success
                                        print("✅ Exported \(task.cartItem.label) → \(csvPath.lastPathComponent)")
                                        self.onTaskCompleted?(task)
                                    }
                                }
                                self.sdkQueue.async { taskIndex += 1; exportNextFile() }
                            }
                        } else {
                            // No exportFileDone yet — genuine stall → fail.
                            print("⏰ [\(dot.address)] Export timeout for \(task.cartItem.label)")
                            device.stopExportFileData()
                            self.fileQueue.async {
                                try? fileHandle.close()
                                self.activeFileHandles.removeValue(forKey: dot.address)
                                try? FileManager.default.removeItem(at: csvPath)
                                self.setTaskStatus(task, .failed, error: "Export timed out")
                                self.sdkQueue.async { taskIndex += 1; exportNextFile() }
                            }
                        }
                    }
                    self.activeWatchdogs[dot.address] = watchdog

                    // MARK: Packet callback — fires on sdkQueue for every BLE packet.
                    device.setDidParseExportFileDataBlock { [weak self] plotData in
                        let cbStart = CACurrentMediaTime()
                        guard let self, !exportCompleted else { return }
                        guard self.exportFileGenerations[dot.address] == generation else { return }

                        watchdog.beat()
                        packetsReceived += 1

                        let row = String(
                            format: "%u,%u,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                            plotData.packageCounter, plotData.timeStamp,
                            plotData.euler0, plotData.euler1, plotData.euler2,
                            plotData.acc0, plotData.acc1, plotData.acc2,
                            plotData.gyr0, plotData.gyr1, plotData.gyr2
                        )
                        batch.append(Data(row.utf8))

                        // Flush to disk every 200 packets.
                        if packetsReceived % 200 == 0 {
                            let captured = batch
                            batch.removeAll(keepingCapacity: true)
                            // Dispatch to fileQueue — never dispatch back to sdkQueue from here (deadlock).
                            self.fileQueue.async {
                                fileHandle.write(captured)
                            }
                        }

                        // Update progress at most every 100 packets or 0.5 seconds.
                        let now = CACurrentMediaTime()
                        if packetsReceived % 100 == 0 || (now - lastProgressUpdate) >= 0.5 {
                            lastProgressUpdate = now
                            let progress = min((now - exportStartTime) / estimatedDurationSeconds, 0.99)
                            setOnMain { task.progress = progress }
                        }

                        let cbDuration = CACurrentMediaTime() - cbStart
                        cbTimeTotal += cbDuration
                        if cbDuration > cbTimeMax { cbTimeMax = cbDuration }
                        if packetsReceived % 500 == 0 {
                            let avg = cbTimeTotal / Double(packetsReceived)
                            print("⚡ [\(dot.address)] cb avg \(String(format: "%.3f", avg * 1000))ms, max \(String(format: "%.3f", cbTimeMax * 1000))ms @ \(packetsReceived) pkts")
                        }
                    }

                    // MARK: Done callback — fires on sdkQueue when BLE transport is done.
                    // The SDK fires this before all parsed packet callbacks are dispatched,
                    // so we only record the signal here. The watchdog handles finalization
                    // once the packet stream goes silent.
                    device.recording.exportFileDone = { [weak self] _, _ in
                        guard let self, !doneFired else { return }
                        guard self.exportFileGenerations[dot.address] == generation else { return }
                        doneFired = true
                        print("📥 [\(dot.address)] exportFileDone at pkt \(packetsReceived) — waiting for stream to drain")
                        // Remaining packet callbacks keep flowing; watchdog will close the file.
                    }

                    device.recording.updateExportingStatus = { status in
                        if status == .isStopExportingData {
                            print("📤 [\(dot.address)] Export stopped")
                        }
                    }

                    print("📁 [\(dot.address)] Requesting fileIndex: \(fileIndex)")
                    device.startExportFileData()
                    print("📤 [\(dot.address)] Started export for file \(fileIndex)")
                }
            }
        }

        exportNextFile()
    }

    // MARK: Packet Count Validation

    /// Returns `false` if actual row count ≠ (lastCounter − firstCounter + 1).
    func validatePacketCount(csvURL: URL) -> Bool {
        guard let content = try? String(contentsOf: csvURL, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst() // skip header
        guard !lines.isEmpty else { return false }

        let counters = lines.compactMap { line -> UInt32? in
            guard let col = line.components(separatedBy: ",").first else { return nil }
            return UInt32(col)
        }
        guard let first = counters.first, let last = counters.last else { return false }

        let expected = Int(last - first) + 1
        if counters.count != expected {
            print("⚠️ Packet loss: \(counters.count) rows, expected \(expected) (\(first)…\(last))")
            return false
        }
        return true
    }
}
