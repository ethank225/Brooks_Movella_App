import SwiftUI

struct ExportResultsSection: View {
    @ObservedObject var exportManager: ExportManager
    let onRetryUpload: (ExportTask) -> Void

    @State private var showShareSheet = false
    @State private var sharePackageURL: URL?

    private var isExporting: Bool { exportManager.exportPhase == .exporting }
    private var isDone: Bool { exportManager.exportPhase == .done }
    private var hasFailed: Bool {
        exportManager.tasks.contains { $0.status == .failed || $0.status == .canceled }
    }
    private var hasExportedFiles: Bool {
        !exportManager.exportedSessionFolderURLs.isEmpty || !exportManager.exportedFileURLs.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            SectionCard(
                title: isDone ? "Export Results" : "Exporting...",
                icon: isDone ? "checkmark.circle" : "arrow.up.circle"
            ) {
                ForEach(exportManager.tasks) { task in
                    ExportTaskRow(task: task, onRetryUpload: {
                        onRetryUpload(task)
                    }, onRetryTransfer: {
                        exportManager.retrySingleTask(task)
                    }, isExporting: isExporting)
                }
            }

            if isExporting {
                FullWidthButton(icon: "xmark.circle", label: "Cancel Export", color: .red) {
                    exportManager.cancelExport()
                }
                .padding(.horizontal)
            }

            if isDone {
                VStack(spacing: 12) {
                    if hasFailed {
                        FullWidthButton(icon: "arrow.clockwise", label: "Retry All Failed", color: .orange) {
                            exportManager.retryFailed()
                        }
                    }

                    if hasExportedFiles {
                        FullWidthButton(icon: "square.and.arrow.up", label: "Share Exported Files", color: .blue) {
                            if let url = exportManager.packageForSharing() {
                                print("📄 Sharing package: \(url.lastPathComponent)")
                                sharePackageURL = url
                                showShareSheet = true
                            } else {
                                // Fallback: share individual files.
                                sharePackageURL = nil
                                showShareSheet = true
                            }
                        }

                        Text("Files also saved to Files \u{2192} Exports")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        exportManager.resetExport()
                        exportManager.clearCart()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear & Start Over")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                    }
                }
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let packageURL = sharePackageURL {
                ShareSheet(urls: [packageURL])
            } else if !exportManager.exportedFileURLs.isEmpty {
                ShareSheet(urls: exportManager.exportedFileURLs)
            }
        }
    }
}
