import Foundation

// MARK: - Workout (fetched from Supabase)

struct Workout: Codable, Identifiable {
    let id: UUID
    let sessionId: UUID
    var blobAddress: String
    var sensorAddress: String
    var recordedTime: String

    enum CodingKeys: String, CodingKey {
        case id            = "workout_id"
        case sessionId     = "trial_id"
        case blobAddress   = "blob_address"
        case sensorAddress = "sensor_address"
        case recordedTime  = "recorded_time"
    }
}

// MARK: - WorkoutPayload (for DB insert, no workout_id)

struct WorkoutPayload: Codable {
    let sessionId:     UUID
    let blobAddress:   String
    let sensorAddress: String
    let recordedTime:  String

    enum CodingKeys: String, CodingKey {
        case sessionId     = "trial_id"
        case blobAddress   = "blob_address"
        case sensorAddress = "sensor_address"
        case recordedTime  = "recorded_time"
    }
}

// MARK: - WorkoutTemplate (local only, derived from sessions)

struct WorkoutTemplate: Identifiable, Hashable {
    var shoeBrand: String
    var shoeModel: String
    var shoeGeneration: String
    var study: String
    var test: String
    var product: String
    var conditionType: String

    var id: String {
        [shoeBrand, shoeModel, shoeGeneration, study, test, product, conditionType]
            .joined(separator: "§")
    }

    var displayName: String {
        "\(shoeModel) \(shoeGeneration) (\(study), \(test)) — \(product)"
    }

    static func == (lhs: WorkoutTemplate, rhs: WorkoutTemplate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - WorkoutTemplateRow (used internally by SupabaseManager)

struct WorkoutTemplateRow: Codable {
    let shoeBrand: String
    let shoeModel: String
    let shoeGeneration: String
    let study: String
    let test: String
    let product: String
    let conditionType: String  // ← add this

    enum CodingKeys: String, CodingKey {
        case shoeBrand      = "shoe_brand"
        case shoeModel      = "shoe_model"
        case shoeGeneration = "shoe_generation"
        case study
        case test
        case product
        case conditionType  = "condition_type"  // ← add this
    }
}

// MARK: - Session

struct Session: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let shoeBrand: String
    let shoeModel: String
    let shoeGeneration: String
    let study: String
    let test: String
    let product: String
    let conditionType: String
    let recordedDate: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id             = "trial_id"
        case userId         = "user_id"
        case shoeBrand      = "shoe_brand"
        case shoeModel      = "shoe_model"
        case shoeGeneration = "shoe_generation"
        case study
        case test
        case product
        case conditionType  = "condition_type"
        case recordedDate   = "recorded_date"
        case createdAt      = "created_at"
    }
}

// MARK: - SessionPayload

struct SessionPayload: Codable {
    let userId:         UUID
    let shoeBrand:      String
    let shoeModel:      String
    let shoeGeneration: String
    let study:          String
    let test:           String
    let product:        String
    let conditionType:  String
    let recordedDate:   String

    enum CodingKeys: String, CodingKey {
        case userId         = "user_id"
        case shoeBrand      = "shoe_brand"
        case shoeModel      = "shoe_model"
        case shoeGeneration = "shoe_generation"
        case study
        case test
        case product
        case conditionType  = "condition_type"
        case recordedDate   = "recorded_date"
    }
}
