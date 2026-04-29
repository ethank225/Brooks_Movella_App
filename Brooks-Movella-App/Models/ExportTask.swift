import Foundation
import Combine
import SwiftUI

// MARK: - Export Phase

enum ExportPhase: Equatable {
    case idle
    case fetching
    case ready
    case exporting
    case done
}

// MARK: - Session Type

/// Classifies a cart session for export naming, metadata, and folder organization.
/// All display properties (label, icon, colors) live here so both the browse page
/// and cart page reference one source of truth.
enum SessionType: String, Codable, CaseIterable, Equatable {
    case run          // default — normal recording
    case calibration  // static calibration recording

    // MARK: - Export

    var label: String {
        switch self {
        case .run:         return "Run"
        case .calibration: return "Calibration"
        }
    }

    var shortLabel: String {
        switch self {
        case .run:         return "RUN"
        case .calibration: return "CAL"
        }
    }

    var suffix: String {
        switch self {
        case .run:         return ""
        case .calibration: return "_cal"
        }
    }

    // MARK: - Display

    var icon: String {
        switch self {
        case .run:         return "figure.run"
        case .calibration: return "scope"
        }
    }

    var color: Color {
        switch self {
        case .run:         return .green
        case .calibration: return .blue
        }
    }

    var pillBackground: Color {
        switch self {
        case .run:         return Color.green.opacity(0.15)
        case .calibration: return Color.blue.opacity(0.15)
        }
    }

    var cardBackground: Color {
        switch self {
        case .run:         return Color.green.opacity(0.04)
        case .calibration: return Color.blue.opacity(0.06)
        }
    }

    var borderColor: Color {
        switch self {
        case .run:         return Color.green.opacity(0.4)
        case .calibration: return Color.blue.opacity(0.4)
        }
    }
}

// MARK: - ExportTask

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
    @Published var hasPacketLoss: Bool = false

    init(cartItem: CartItem) {
        self.id = cartItem.id
        self.cartItem = cartItem
    }
}

nonisolated enum ExportStatus: Codable, Equatable, Sendable {
    case queued
    case running
    case success
    case failed
    case canceled
}

nonisolated enum UploadStatus: Codable, Equatable, Sendable {
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
