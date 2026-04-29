import SwiftUI

struct ExportTaskRow: View {
    @ObservedObject var task: ExportTask
    @ObservedObject private var dotManager = DotManager.shared
    var onRetryUpload: (() -> Void)? = nil
    var onRetryTransfer: (() -> Void)? = nil
    var isExporting: Bool = false

    private var sensorReady: Bool {
        dotManager.dot(forUuid: task.cartItem.recording.dotAddress)?.connectionPhase == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.cartItem.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                ExportSubphaseTag(status: task.status, subphase: task.subphase)
            }

            // Progress bar + spinner
            if task.status == .running || task.status == .success {
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.3))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(progressBarColor)
                                .frame(width: geo.size.width * min(task.progress, 1.0))
                        }
                    }
                    .frame(height: 6)

                    if task.status == .running {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    }
                }
            }

            // Packet loss warning
            if task.hasPacketLoss {
                Label("Packet loss detected", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // BLE export error (suppressed when hasPacketLoss — the symbol label below covers it)
            if let error = task.error, !task.hasPacketLoss {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Retry transfer button for failed BLE transfers
            if task.status == .failed {
                let retryDisabled = isExporting || !sensorReady
                Button(action: { onRetryTransfer?() }) {
                    Label("Retry Transfer", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(retryDisabled ? Color.gray : Color.orange)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(retryDisabled)

                if !isExporting && !sensorReady {
                    Text("Reconnect sensor to retry")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // File path
            if let url = task.outputURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Upload status
            if task.status == .success {
                uploadStatusRow
            }
        }
        .padding(10)
        .background(taskBackground)
        .cornerRadius(10)
        .animation(AppAnimation.phase, value: task.status)
        .animation(AppAnimation.phase, value: task.uploadStatus)
        .animation(AppAnimation.phase, value: task.hasPacketLoss)
    }

    @ViewBuilder
    private var uploadStatusRow: some View {
        switch task.uploadStatus {
        case .pending:
            EmptyView()
        case .uploading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Uploading to Supabase…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .uploaded:
            Label("Uploaded", systemImage: "checkmark.icloud.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                if let uploadError = task.uploadError {
                    Text("Upload failed: \(uploadError)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Button(action: { onRetryUpload?() }) {
                    Label("Retry Upload", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var progressBarColor: Color {
        if task.hasPacketLoss { return .orange }
        switch task.subphase {
        case .transferring: return .blue
        case .complete:     return .green
        case .idle:         return task.status == .success ? .green : .blue
        }
    }

    private var taskBackground: Color {
        if task.hasPacketLoss { return Color.orange.opacity(0.08) }
        switch task.status {
        case .running:  return Color.blue.opacity(0.08)
        case .success:  return Color.green.opacity(0.08)
        case .failed:   return Color.red.opacity(0.08)
        case .canceled: return Color.orange.opacity(0.08)
        case .queued:   return Color.gray.opacity(0.1)
        }
    }
}

private struct ExportSubphaseTag: View {
    let status: ExportStatus
    let subphase: ExportSubphase

    var body: some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var label: String {
        switch status {
        case .queued:   return "Queued"
        case .running:
            switch subphase {
            case .transferring: return "Transferring"
            default:            return "Exporting"
            }
        case .success:  return "Done"
        case .failed:   return "Failed"
        case .canceled: return "Canceled"
        }
    }

    private var color: Color {
        switch status {
        case .queued:   return .gray
        case .running:  return .blue
        case .success:  return .green
        case .failed:   return .red
        case .canceled: return .orange
        }
    }
}
