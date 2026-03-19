import Foundation

struct Runner: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    var sensorUuids: [String]

    init(id: String = UUID().uuidString, label: String, sensorUuids: [String] = []) {
        self.id = id
        self.label = label
        self.sensorUuids = sensorUuids
    }
}
