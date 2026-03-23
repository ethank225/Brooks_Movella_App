import Foundation
import Combine

class SensorNameStore: ObservableObject {
    static let shared = SensorNameStore()

    static let defaultsKey = "dot_names"
    private let defaults: UserDefaults
    private let storeKey: String

    @Published private(set) var names: [String: String]

    init(defaults: UserDefaults = .standard, key: String = "dot_names") {
        self.defaults = defaults
        self.storeKey = key
        names = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
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
        defaults.set(names, forKey: storeKey)
    }
}
