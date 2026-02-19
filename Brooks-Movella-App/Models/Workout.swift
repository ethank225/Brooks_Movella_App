import Foundation

// MARK: - Workout (fetched from Supabase)

struct Workout: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    var shoeBrand: String
    var shoeModel: String
    var shoeGeneration: String
    var condition: String
    var study: String
    var test: String
    var product: String
    var conditionType: String
    var blobAddress: String
    var sessionId: UUID?

    enum CodingKeys: String, CodingKey {
        case id             = "workout_id"
        case userId         = "user_id"
        case shoeBrand      = "shoe_brand"
        case shoeModel      = "shoe_model"
        case shoeGeneration = "shoe_generation"
        case condition
        case study
        case test
        case product
        case conditionType  = "condition_type"
        case blobAddress    = "blob_address"
        case sessionId      = "session_id"
    }
}

// MARK: - WorkoutPayload (for DB insert, no workout_id)

struct WorkoutPayload: Codable {
    var userId: UUID
    var shoeBrand: String
    var shoeModel: String
    var shoeGeneration: String
    var study: String
    var test: String
    var product: String
    var conditionType: String
    var blobAddress: String
    var sessionId: UUID?

    enum CodingKeys: String, CodingKey {
        case userId         = "user_id"
        case shoeBrand      = "shoe_brand"
        case shoeModel      = "shoe_model"
        case shoeGeneration = "shoe_generation"
        case study
        case test
        case product
        case conditionType  = "condition_type"
        case blobAddress    = "blob_address"
        case sessionId      = "session_id"
    }
}

// MARK: - WorkoutTemplate (derived from distinct past workouts, local only)

struct WorkoutTemplate: Identifiable, Hashable {
    var shoeBrand: String
    var shoeModel: String
    var shoeGeneration: String
    var study: String
    var test: String
    var product: String
    var conditionType: String

    /// Content-derived ID so Picker and ForEach treat same-content templates as equal.
    var id: String {
        [shoeBrand, shoeModel, shoeGeneration, study, test, product, conditionType]
            .joined(separator: "§")
    }

    var displayName: String { "\(shoeBrand) \(shoeModel) \(shoeGeneration) \(study) \(product)" }

    static func == (lhs: WorkoutTemplate, rhs: WorkoutTemplate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
