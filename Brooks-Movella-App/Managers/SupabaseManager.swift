import Foundation
import Combine
import Supabase

@MainActor
final class SupabaseManager: ObservableObject {

    static let shared = SupabaseManager()

    @Published var profiles: [Profile] = []
    @Published var workoutTemplates: [WorkoutTemplate] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let client: SupabaseClient

    private init() {
        let info = Bundle.main.infoDictionary
        let urlString = (info?["SUPABASE_URL"] as? String) ?? ""
        let anonKey   = (info?["SUPABASE_ANON_KEY"] as? String) ?? ""

        let url = URL(string: urlString) ?? URL(string: "https://lzncbzjdkbfarqhyrrfh.supabase.co")!
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    // MARK: - Fetch

    func fetchProfiles() async {
        isLoading = true
        errorMessage = nil
        do {
            profiles = try await client
                .from("users")
                .select()
                .order("last_name", ascending: true)
                .execute()
                .value
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Create

    func createProfile(_ payload: ProfilePayload) async throws {
        let created: Profile = try await client
            .from("users")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value
        profiles.append(created)
        profiles.sort { $0.lastName.lowercased() < $1.lastName.lowercased() }
    }

    // MARK: - Update

    func updateProfile(id: UUID, payload: ProfilePayload) async throws {
        let updated: Profile = try await client
            .from("users")
            .update(payload)
            .eq("user_id", value: id.uuidString)
            .select()
            .single()
            .execute()
            .value
        if let idx = profiles.firstIndex(where: { $0.id == id }) {
            profiles[idx] = updated
        }
    }

    // MARK: - Delete

    func deleteProfile(id: UUID) async throws {
        try await client
            .from("users")
            .delete()
            .eq("user_id", value: id.uuidString)
            .execute()
        profiles.removeAll { $0.id == id }
    }

    // MARK: - Workout Templates

    /// Fetches distinct workout metadata combos from the workouts table, most recent first.
    func fetchWorkoutTemplates() async {
        do {
            let rows: [WorkoutTemplateRow] = try await client
                .from("workouts")
                .select("shoe_brand,shoe_model,shoe_generation,study,test,product,condition_type")
                .order("created_at", ascending: false)
                .execute()
                .value

            var seen = Set<WorkoutTemplate>()
            var templates: [WorkoutTemplate] = []
            for row in rows {
                let t = WorkoutTemplate(
                    shoeBrand:      row.shoeBrand,
                    shoeModel:      row.shoeModel,
                    shoeGeneration: row.shoeGeneration,
                    study:          row.study,
                    test:           row.test,
                    product:        row.product,
                    conditionType:  row.conditionType
                )
                if seen.insert(t).inserted { templates.append(t) }
            }
            workoutTemplates = templates
        } catch {
            print("⚠️ fetchWorkoutTemplates: \(error)")
        }
    }

    // MARK: - Upload Workout

    /// Uploads a CSV to Supabase Storage and inserts a row in the workouts table.
    func uploadWorkout(csvURL: URL, userId: UUID, sessionId: UUID, template: WorkoutTemplate) async throws {
        let csvData = try Data(contentsOf: csvURL)
        let storagePath = "\(userId.uuidString)/\(sessionId.uuidString)/\(csvURL.lastPathComponent)"

        try await client.storage
            .from("run-data")
            .upload(storagePath, data: csvData, options: FileOptions(contentType: "text/csv"))

        let payload = WorkoutPayload(
            userId:         userId,
            shoeBrand:      template.shoeBrand,
            shoeModel:      template.shoeModel,
            shoeGeneration: template.shoeGeneration,
            study:          template.study,
            test:           template.test,
            product:        template.product,
            conditionType:  template.conditionType,
            blobAddress:    storagePath,
            sessionId:      sessionId
        )
        try await client.from("workouts").insert(payload).execute()
    }
}

// MARK: - Private helpers

private struct WorkoutTemplateRow: Codable {
    let shoeBrand: String
    let shoeModel: String
    let shoeGeneration: String
    let study: String
    let test: String
    let product: String
    let conditionType: String

    enum CodingKeys: String, CodingKey {
        case shoeBrand      = "shoe_brand"
        case shoeModel      = "shoe_model"
        case shoeGeneration = "shoe_generation"
        case study
        case test
        case product
        case conditionType  = "condition_type"
    }
}
