import Foundation

/// Writes fixed-width binary records to disk with buffered I/O.
/// Must be called from `ExportManager.fileQueue` only — no internal locking.
///
/// **File format:**
/// - 16-byte header: magic "DOTS", version UInt16, fields UInt16, bytesPerRecord UInt32, reserved 4 bytes
/// - Per-record (44 bytes, packed, little-endian): UInt32 packageCounter, UInt32 timestamp,
///   Float32 euler0..2, Float32 acc0..2, Float32 gyr0..2
final class BinaryStreamWriter {

    static let headerSize = 16
    static let recordSize = 44

    private var handle: FileHandle?
    private var buffer = Data()
    private let flushThreshold = 262_144  // 256 KB

    init(url: URL) {
        // Build 16-byte header
        var header = Data(count: Self.headerSize)
        // Magic "DOTS"
        header[0] = 0x44  // D
        header[1] = 0x4F  // O
        header[2] = 0x54  // T
        header[3] = 0x53  // S
        // Version = 1 (UInt16 LE)
        header[4] = 1; header[5] = 0
        // Fields per record = 11 (UInt16 LE)
        header[6] = 11; header[7] = 0
        // Bytes per record = 44 (UInt32 LE)
        header[8] = 44; header[9] = 0; header[10] = 0; header[11] = 0
        // Reserved = 0
        header[12] = 0; header[13] = 0; header[14] = 0; header[15] = 0

        FileManager.default.createFile(atPath: url.path, contents: header)
        self.handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    /// Append raw record data (already packed as 44-byte records) to the buffer.
    func appendData(_ data: Data) {
        buffer.append(data)
        if buffer.count >= flushThreshold {
            flush()
        }
    }

    /// Write any remaining buffered data to disk.
    func flush() {
        guard !buffer.isEmpty, let handle else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Flush remaining data and close the file handle.
    func close() {
        flush()
        try? handle?.close()
        handle = nil
    }
}
