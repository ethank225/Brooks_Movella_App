import SwiftUI

struct ExportResultsSection: View {
    @ObservedObject var exportManager: ExportManager
    let onRetryUpload: (ExportTask) -> Void
    let onRetryFailed: () -> Void

    @State private var showShareSheet = false

    private var isExporting: Bool { exportManager.exportPhase == .exporting }
    private var isDone: Bool { exportManager.exportPhase == .done }
    private var hasFailed: Bool {
        exportManager.tasks.contains { $0.status == .failed || $0.uploadStatus == .failed }
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
                        exportManager.retryFailed()
                    })
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
                        FullWidthButton(icon: "arrow.clockwise", label: "Retry Failed", color: .orange) {
                            onRetryFailed()
                        }
                    }

                    if !exportManager.exportedFileURLs.isEmpty {
                        FullWidthButton(icon: "square.and.arrow.up", label: "Share Exported Files", color: .blue) {
                            showShareSheet = true
                        }
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
            if !exportManager.exportedFileURLs.isEmpty {
                ShareSheet(urls: exportManager.exportedFileURLs)
            }
        }
    }
}
