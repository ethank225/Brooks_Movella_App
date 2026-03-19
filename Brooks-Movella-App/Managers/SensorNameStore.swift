import Foundation
import Combine

class SensorNameStore: ObservableObject {
    static let shared = SensorNameStore()

    private static let defaultsKey = "dot_names"

    @Published private(set) var names: [String: String]

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    func name(for uuid: String) -> String {
        names[uuid] ?? uuid
    }

    func setName(_ name: String, for uuid: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearName(for: uuid)
            return
        }
        names[uuid] = trimmed
        persist()
    }

    func clearName(for uuid: String) {
        names.removeValue(forKey: uuid)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(names, forKey: Self.defaultsKey)
    }
}
