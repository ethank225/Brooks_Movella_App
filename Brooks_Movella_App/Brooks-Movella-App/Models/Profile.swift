import Foundation

// MARK: - Profile (fetched from Supabase, has id)

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var firstName: String
    var lastName: String
    var gender: String
    var heightInches: Double
    var weightLbs: Double
    var birthDate: String   // "YYYY-MM-DD"
    var shoeSize: Double
    var shoeWidth: String
    var shoeGender: String

    enum CodingKeys: String, CodingKey {
        case id           = "user_id"  // <-- add this
        case firstName    = "first_name"
        case lastName     = "last_name"
        case gender
        case heightInches = "height_inches"
        case weightLbs    = "weight_lbs"
        case birthDate    = "birth_date"
        case shoeSize     = "shoe_size"
        case shoeWidth    = "shoe_width"
        case shoeGender   = "shoe_gender"
    }

    var displayName: String { "\(firstName) \(lastName)" }

    var birthDateAsDate: Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: birthDate)
    }
}

// MARK: - ProfilePayload (for insert and update, no id)

struct ProfilePayload: Codable {
    var firstName: String
    var lastName: String
    var gender: String
    var heightInches: Double
    var weightLbs: Double
    var birthDate: String   // "YYYY-MM-DD"
    var shoeSize: Double
    var shoeWidth: String
    var shoeGender: String

    enum CodingKeys: String, CodingKey {
        case firstName    = "first_name"
        case lastName     = "last_name"
        case gender
        case heightInches = "height_inches"
        case weightLbs    = "weight_lbs"
        case birthDate    = "birth_date"
        case shoeSize     = "shoe_size"
        case shoeWidth    = "shoe_width"
        case shoeGender   = "shoe_gender"
    }
}
