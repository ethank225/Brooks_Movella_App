import Foundation
import Combine

/// Tracks the status and progress of exporting a single recording file.
final class ExportTask: ObservableObject, Identifiable {
    let id: String
    let cartItem: CartItem

    @Published var status: ExportStatus = .queued
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var outputURL: URL?
    @Published var subphase: ExportSubphase = .idle
    @Published var uploadStatus: UploadStatus = .pending
    @Published var uploadError: String?

    init(cartItem: CartItem) {
        self.id = cartItem.id
        self.cartItem = cartItem
    }
}

nonisolated enum ExportStatus: Equatable, Sendable {
    case queued
    case running
    case success
    case failed
    case canceled
}

nonisolated enum UploadStatus: Equatable, Sendable {
    case pending
    case uploading
    case uploaded
    case failed
}

nonisolated enum ExportSubphase: Equatable, Sendable {
    case idle
    case transferring
    case complete
}
