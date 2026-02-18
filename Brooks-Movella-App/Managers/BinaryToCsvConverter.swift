import Foundation

/// Reads a `.bin` file written by `BinaryStreamWriter` and converts it to CSV.
/// Processes records in chunks for bounded memory usage. Intended to run on `fileQueue`.
enum BinaryToCsvConverter {

    private static let csvHeader = "packet_counter,timestamp,euler_x,euler_y,euler_z,acc_x,acc_y,acc_z,gyr_x,gyr_y,gyr_z\n"
    private static let recordSize = BinaryStreamWriter.recordSize  // 44
    private static let headerSize = BinaryStreamWriter.headerSize  // 16
    private static let chunkRecords = 1000

    /// Convert a `.bin` file to `.csv`.
    /// - Parameters:
    ///   - binURL: Path to the binary file.
    ///   - csvURL: Destination CSV path (created/overwritten).
    ///   - onProgress: Called with 0.0–1.0 as conversion progresses.
    /// - Returns: The `csvURL` on success.
    /// - Throws: If reading or writing fails.
    static func convert(
        binURL: URL,
        csvURL: URL,
        onProgress: @escaping (Double) -> Void
    ) throws -> URL {
        // Open input
        let inputHandle = try FileHandle(forReadingFrom: binURL)
        defer { try? inputHandle.close() }

        let fileSize = try FileManager.default.attributesOfItem(atPath: binURL.path)[.size] as? Int ?? 0
        guard fileSize >= headerSize else {
            throw ConversionError.invalidFile
        }

        let totalRecords = (fileSize - headerSize) / recordSize
        guard totalRecords > 0 else {
            throw ConversionError.noRecords
        }

        // Skip header
        inputHandle.seek(toFileOffset: UInt64(headerSize))

        // Create output
        FileManager.default.createFile(atPath: csvURL.path, contents: Data(csvHeader.utf8))
        let outputHandle = try FileHandle(forWritingTo: csvURL)
        defer { try? outputHandle.close() }
        outputHandle.seekToEndOfFile()

        var outputBuffer = Data()
        outputBuffer.reserveCapacity(chunkRecords * 120)  // ~120 bytes per CSV row
        let outputFlushThreshold = 262_144  // 256 KB

        var recordsProcessed = 0

        while recordsProcessed < totalRecords {
            let remaining = totalRecords - recordsProcessed
            let toRead = min(remaining, chunkRecords)
            let chunk = inputHandle.readData(ofLength: toRead * recordSize)

            guard chunk.count == toRead * recordSize else { break }

            chunk.withUnsafeBytes { rawBuffer in
                let base = rawBuffer.baseAddress!

                for i in 0..<toRead {
                    let offset = i * recordSize

                    let pkg = base.load(fromByteOffset: offset + 0, as: UInt32.self)
                    let ts  = base.load(fromByteOffset: offset + 4, as: UInt32.self)
                    let e0  = base.load(fromByteOffset: offset + 8,  as: Float32.self)
                    let e1  = base.load(fromByteOffset: offset + 12, as: Float32.self)
                    let e2  = base.load(fromByteOffset: offset + 16, as: Float32.self)
                    let a0  = base.load(fromByteOffset: offset + 20, as: Float32.self)
                    let a1  = base.load(fromByteOffset: offset + 24, as: Float32.self)
                    let a2  = base.load(fromByteOffset: offset + 28, as: Float32.self)
                    let g0  = base.load(fromByteOffset: offset + 32, as: Float32.self)
                    let g1  = base.load(fromByteOffset: offset + 36, as: Float32.self)
                    let g2  = base.load(fromByteOffset: offset + 40, as: Float32.self)

                    let row = String(format: "%u,%u,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                                     pkg, ts,
                                     e0, e1, e2,
                                     a0, a1, a2,
                                     g0, g1, g2)
                    outputBuffer.append(Data(row.utf8))
                }
            }

            // Flush output buffer periodically
            if outputBuffer.count >= outputFlushThreshold {
                outputHandle.write(outputBuffer)
                outputBuffer.removeAll(keepingCapacity: true)
            }

            recordsProcessed += toRead

            let progress = Double(recordsProcessed) / Double(totalRecords)
            onProgress(progress)
        }

        // Flush remaining
        if !outputBuffer.isEmpty {
            outputHandle.write(outputBuffer)
        }

        return csvURL
    }

    enum ConversionError: Error, LocalizedError {
        case invalidFile
        case noRecords

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Binary file is too small or corrupt"
            case .noRecords:   return "Binary file contains no records"
            }
        }
    }
}
